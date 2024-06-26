//! Generates a compiled script file from a type resolved AST

const std = @import("std");

const Parser = @import("parser.zig");
const Resolvinator = @import("resolvinator.zig");
const MMTypes = @import("MMTypes.zig");

const Genny = @This();

pub const Error = std.mem.Allocator.Error || error{InvalidUtf8};

pub const CompilationOptions = struct {
    revision: MMTypes.Revision,
    optimization_mode: std.builtin.OptimizeMode,
};

pub const S64ConstantTable = std.AutoArrayHashMap(i64, void);
pub const FloatConstantTable = std.ArrayHashMap([4]f32, void, struct {
    pub fn hash(self: @This(), s: [4]f32) u32 {
        _ = self;
        return @truncate(std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(&s)));
    }

    pub fn eql(self: @This(), a: [4]f32, b: [4]f32, b_index: usize) bool {
        _ = self;
        _ = b_index;
        return std.mem.eql(f32, &a, &b);
    }
}, true);
pub const TypeReferenceTable = std.AutoArrayHashMap(MMTypes.TypeReference, void);
pub const FieldReferenceTable = std.AutoArrayHashMap(MMTypes.FieldReference, void);
pub const FunctionReferenceTable = std.AutoArrayHashMap(MMTypes.FunctionReference, void);
pub const BytecodeList = std.ArrayList(MMTypes.Bytecode);
pub const ArgumentList = std.ArrayList(MMTypes.Argument);
pub const LineNumberList = std.ArrayList(u16);
pub const LocalVariableTable = std.StringArrayHashMap(MMTypes.LocalVariable);
pub const LocalVariableList = std.ArrayList(MMTypes.LocalVariable);

ast: Parser.Tree,
a_string_table: *Resolvinator.AStringTable,
w_string_table: *Resolvinator.WStringTable,
s64_constants: S64ConstantTable,
f32_constants: FloatConstantTable,
type_references: TypeReferenceTable,
function_references: FunctionReferenceTable,
field_references: FieldReferenceTable,
bytecode: BytecodeList,
arguments: ArgumentList,
line_numbers: LineNumberList,
local_variables: LocalVariableList,
compilation_options: CompilationOptions,
type_intern_pool: *Parser.TypeInternPool,

pub fn init(
    ast: Parser.Tree,
    a_string_table: *Resolvinator.AStringTable,
    w_string_table: *Resolvinator.WStringTable,
    compilation_options: CompilationOptions,
    type_intern_pool: *Parser.TypeInternPool,
) Genny {
    return .{
        .ast = ast,
        .a_string_table = a_string_table,
        .w_string_table = w_string_table,
        .s64_constants = S64ConstantTable.init(ast.allocator),
        .f32_constants = FloatConstantTable.init(ast.allocator),
        .type_references = TypeReferenceTable.init(ast.allocator),
        .bytecode = BytecodeList.init(ast.allocator),
        .arguments = ArgumentList.init(ast.allocator),
        .line_numbers = LineNumberList.init(ast.allocator),
        .local_variables = LocalVariableList.init(ast.allocator),
        .function_references = FunctionReferenceTable.init(ast.allocator),
        .field_references = FieldReferenceTable.init(ast.allocator),
        .compilation_options = compilation_options,
        .type_intern_pool = type_intern_pool,
    };
}

pub fn deinit(self: *Genny) void {
    self.s64_constants.deinit();
    self.f32_constants.deinit();
    self.type_references.deinit();
    self.bytecode.deinit();
    self.arguments.deinit();
    self.line_numbers.deinit();
    self.local_variables.deinit();
    self.function_references.deinit();
    self.field_references.deinit();

    self.* = undefined;
}

const Codegen = struct {
    pub const RegisterAllocator = struct {
        const FreeSpace = struct {
            start: u16,
            size: u16,
        };

        const FreeSpaceList = std.DoublyLinkedList(FreeSpace);

        allocator: std.mem.Allocator,
        /// A linked list of the free spaces
        free_spaces: FreeSpaceList,
        /// The highest register in use
        highest_register: u16,
        compilation_options: CompilationOptions,
        local_variables: *LocalVariableTable,
        register_local_variables: LocalVariableList,
        local_variable_register_name_table: std.AutoHashMap(u16, []const u8),
        genny: *Genny,

        pub fn registerName(self: *RegisterAllocator, register: u16) ![]const u8 {
            if (self.genny.compilation_options.optimization_mode != .Debug and self.genny.compilation_options.optimization_mode != .ReleaseSafe)
                return "";

            const get_or_put = try self.local_variable_register_name_table.getOrPut(register);

            if (!get_or_put.found_existing)
                get_or_put.value_ptr.* = try std.fmt.allocPrint(self.allocator, "$r{d}", .{register});

            return get_or_put.value_ptr.*;
        }

        pub fn init(
            allocator: std.mem.Allocator,
            compilation_options: CompilationOptions,
            local_variables: *LocalVariableTable,
            genny: *Genny,
        ) !RegisterAllocator {
            var free_spaces = FreeSpaceList{};

            //Add the initial block of free space
            const free_space_node = try allocator.create(FreeSpaceList.Node);
            free_space_node.* = .{
                .data = .{
                    .start = 0,
                    .size = std.math.maxInt(u16),
                },
            };
            free_spaces.append(free_space_node);

            return .{
                .free_spaces = free_spaces,
                .highest_register = 0,
                .allocator = allocator,
                .compilation_options = compilation_options,
                .local_variables = local_variables,
                .register_local_variables = LocalVariableList.init(allocator),
                .local_variable_register_name_table = std.AutoHashMap(u16, []const u8).init(allocator),
                .genny = genny,
            };
        }

        pub fn allocate(self: *RegisterAllocator, machine_type: MMTypes.MachineType) !Register {
            return allocateInternal(self, machine_type, true);
        }

        pub fn allocateArgument(self: *RegisterAllocator, machine_type: MMTypes.MachineType) !Register {
            return allocateInternal(self, machine_type, false);
        }

        /// Allocates a regester from the memory space, and returns the start register for the passed data type
        fn allocateInternal(self: *RegisterAllocator, machine_type: MMTypes.MachineType, create_local_vars: bool) !Register {
            if (machine_type == .void) {
                std.debug.panic("Attempted to allocate void register", .{});
            }

            const size = machine_type.size();

            var item = self.free_spaces.first;
            while (item) |node| : (item = node.next) {
                const node_start = node.data.start;

                //Calculate the amount of alignment needed, since we need to align all registers to the size of the underlying data type
                const alignment_needed = blk: {
                    if (node_start % size == 0) {
                        break :blk 0;
                    }

                    break :blk size - (node_start % size);
                };

                //Skip spaces which are too small to fit our data
                if (node.data.size < size + alignment_needed)
                    continue;

                if (alignment_needed != 0) {
                    const new_node = try self.allocator.create(FreeSpaceList.Node);
                    new_node.* = .{
                        .data = .{
                            .start = node_start,
                            .size = alignment_needed,
                        },
                    };
                    self.free_spaces.insertBefore(node, new_node);
                }

                const start = node_start + alignment_needed;

                node.data.start += size + alignment_needed;
                node.data.size -= size + alignment_needed;

                self.highest_register = @max(self.highest_register, start + size - 1);

                //If this free space is all taken up now, just remove this node
                if (node.data.size == 0) {
                    self.free_spaces.remove(node);
                    self.allocator.destroy(node);
                }

                if (create_local_vars and machine_type == .object_ref or machine_type == .safe_ptr) {
                    //TODO: make this optional under a debug option
                    const name = try self.registerName(start);

                    try self.register_local_variables.append(
                        MMTypes.LocalVariable{
                            .modifiers = .{},
                            .name = @intCast((try self.genny.a_string_table.getOrPut(name)).index),
                            .offset = start,
                            .type_reference = @intCast((try self.genny.type_references.getOrPut(MMTypes.TypeReference{
                                .type_name = 0xFFFFFFFF,
                                .array_base_machine_type = .void,
                                .dimension_count = 0,
                                .fish_type = .void,
                                .machine_type = machine_type,
                                .script = null,
                            })).index),
                        },
                    );
                }

                return .{ start, machine_type };
            }

            @panic("Ran out of register space... this is probably a bug, you shouldnt be using 16kb of stack space.");
        }

        pub fn free(self: *RegisterAllocator, register: Register) !void {
            _ = register; // autofix
            _ = self; // autofix

            // TODO: register re-use
        }
    };

    bytecode: BytecodeList,
    line_numbers: LineNumberList,
    register_allocator: RegisterAllocator,
    genny: *Genny,
    compilation_options: CompilationOptions,

    fn ensureAlignment(address: u16, machine_type: MMTypes.MachineType) void {
        // 4 % 0 is UB
        if (machine_type.size() == 0)
            return;

        if (address % machine_type.size() > 0) {
            std.debug.panic("BUG: Bad alignment! Memory address {d} fails alignment check {d}!", .{ address, machine_type.size() });
        }
    }

    pub fn appendBytecode(self: *Codegen, bytecode: MMTypes.Bytecode) !void {
        //TODO: pass line numbers all the way down from the parser (ouch)
        try self.line_numbers.append(@intCast(self.bytecode.items.len));

        try self.bytecode.append(bytecode);
    }

    pub fn lastEmitBytecodeIndex(self: *Codegen) usize {
        return self.bytecode.items.len - 1;
    }

    pub fn nextEmitBytecodeIndex(self: *Codegen) usize {
        return self.bytecode.items.len;
    }

    pub fn emitLoadConstStringWide(self: *Codegen, dst_idx: u16, str: []const u16) !void {
        ensureAlignment(dst_idx, .object_ref);

        try self.appendBytecode(MMTypes.Bytecode.init(.{ .LCsw = .{
            .constant_idx = @intCast((try self.genny.w_string_table.getOrPut(str)).index),
            .dst_idx = dst_idx,
        } }, .void));
    }

    pub fn emitLoadConstStringAscii(self: *Codegen, dst_idx: u16, str: []const u8) !void {
        ensureAlignment(dst_idx, .object_ref);

        try self.appendBytecode(MMTypes.Bytecode.init(.{ .LCsa = .{
            .constant_idx = @intCast((try self.genny.a_string_table.getOrPut(str)).index),
            .dst_idx = dst_idx,
        } }, .void));
    }

    pub fn emitAssert(self: *Codegen, src_idx: u16) !void {
        ensureAlignment(src_idx, .object_ref);

        try self.appendBytecode(MMTypes.Bytecode.init(.{ .ASSERT = .{ .src_idx = src_idx } }, .void));
    }

    pub fn emitCallVo(self: *Codegen, dst_idx: u16, call_idx: u16, machine_type: MMTypes.MachineType) !void {
        ensureAlignment(dst_idx, machine_type);

        try self.appendBytecode(MMTypes.Bytecode.init(.{ .CALLVo = .{ .dst_idx = dst_idx, .call_idx = call_idx } }, machine_type));
    }

    pub fn emitArg(self: *Codegen, arg_idx: u16, src_idx: u16, machine_type: MMTypes.MachineType) !void {
        ensureAlignment(arg_idx, machine_type);
        ensureAlignment(src_idx, machine_type);

        try self.appendBytecode(MMTypes.Bytecode.init(.{ .ARG = .{ .src_idx = src_idx, .arg_idx = arg_idx } }, machine_type));
    }

    pub fn emitCall(self: *Codegen, dst_idx: u16, call_idx: u16, machine_type: MMTypes.MachineType) !void {
        ensureAlignment(dst_idx, machine_type);

        try self.appendBytecode(MMTypes.Bytecode.init(.{ .CALL = .{ .dst_idx = dst_idx, .call_idx = call_idx } }, machine_type));
    }

    pub fn emitNativeInvoke(self: *Codegen, dst_idx: u16, call_address: u24, toc_index: u8, machine_type: MMTypes.MachineType) !void {
        ensureAlignment(dst_idx, machine_type);

        // The current version of the extended runtime only allows s32 sized return types
        std.debug.assert(machine_type.size() == MMTypes.MachineType.s32.size());

        try self.appendBytecode(MMTypes.Bytecode.init(.{ .EXT_INVOKE = .{
            .dst_idx = dst_idx,
            .call_address = call_address,
            .toc_index = toc_index,
        } }, machine_type));
    }

    pub fn emitLoadConstInt(self: *Codegen, dst_idx: u16, s32: i32) !void {
        ensureAlignment(dst_idx, .s32);

        try self.appendBytecode(MMTypes.Bytecode.init(.{ .LCi = .{ .dst_idx = dst_idx, .constant_idx = @bitCast(s32) } }, .s32));
    }

    pub fn emitLoadConstBool(self: *Codegen, dst_idx: u16, boolean: bool) !void {
        try self.appendBytecode(MMTypes.Bytecode.init(.{ .LCb = .{ .dst_idx = dst_idx, .constant_idx = if (boolean) 0x80000000 else 0 } }, .bool));
    }

    pub fn emitLoadConstNullSafePtr(self: *Codegen, dst_idx: u16) !void {
        ensureAlignment(dst_idx, .safe_ptr);

        try self.appendBytecode(MMTypes.Bytecode.init(.{ .LC_NULLsp = .{ .constant_idx = 0, .dst_idx = dst_idx } }, .void));
    }

    pub fn emitLoadConstNullObjectPtr(self: *Codegen, dst_idx: u16) !void {
        ensureAlignment(dst_idx, .object_ref);

        try self.appendBytecode(MMTypes.Bytecode.init(.{ .LC_NULLo = .{ .constant_idx = 0, .dst_idx = dst_idx } }, .void));
    }

    pub fn emitSetObjectMember(self: *Codegen, src_idx: u16, base_idx: u16, field_ref: u16, machine_type: MMTypes.MachineType) !void {
        ensureAlignment(src_idx, machine_type);
        ensureAlignment(base_idx, .object_ref);

        try self.appendBytecode(MMTypes.Bytecode.init(.{ .SET_OBJ_MEMBER = .{
            .src_idx = src_idx,
            .base_idx = base_idx,
            .field_ref = field_ref,
        } }, machine_type));
    }

    pub fn emitSetSafePtrMember(self: *Codegen, src_idx: u16, base_idx: u16, field_ref: u16, machine_type: MMTypes.MachineType) !void {
        ensureAlignment(src_idx, machine_type);
        ensureAlignment(base_idx, .safe_ptr);

        try self.appendBytecode(MMTypes.Bytecode.init(.{ .SET_SP_MEMBER = .{
            .src_idx = src_idx,
            .base_idx = base_idx,
            .field_ref = field_ref,
        } }, machine_type));
    }

    pub fn emitGetObjectMember(self: *Codegen, dst_idx: u16, base_idx: u16, field_ref: u16, machine_type: MMTypes.MachineType) !void {
        ensureAlignment(dst_idx, machine_type);
        ensureAlignment(base_idx, .object_ref);

        try self.appendBytecode(MMTypes.Bytecode.init(.{ .GET_OBJ_MEMBER = .{
            .dst_idx = dst_idx,
            .base_idx = base_idx,
            .field_ref = field_ref,
        } }, machine_type));
    }

    pub fn emitGetSafePtrMember(self: *Codegen, dst_idx: u16, base_idx: u16, field_ref: u16, machine_type: MMTypes.MachineType) !void {
        ensureAlignment(dst_idx, machine_type);
        ensureAlignment(base_idx, .safe_ptr);

        try self.appendBytecode(MMTypes.Bytecode.init(.{ .GET_SP_MEMBER = .{
            .dst_idx = dst_idx,
            .base_idx = base_idx,
            .field_ref = field_ref,
        } }, machine_type));
    }

    pub fn emitBoolToS32(self: *Codegen, dst_idx: u16, src_idx: u16) !void {
        ensureAlignment(dst_idx, .s32);
        ensureAlignment(src_idx, .bool);

        try self.appendBytecode(MMTypes.Bytecode.init(.{ .INTb = .{ .src_idx = src_idx, .dst_idx = dst_idx } }, .void));
    }

    pub fn emitS32ToF32(self: *Codegen, dst_idx: u16, src_idx: u16) !void {
        ensureAlignment(dst_idx, .s32);
        ensureAlignment(src_idx, .f32);

        try self.appendBytecode(MMTypes.Bytecode.init(.{ .FLOATi = .{ .src_idx = src_idx, .dst_idx = dst_idx } }, .void));
    }

    pub fn emitMoveObjectRef(self: *Codegen, dst_idx: u16, src_idx: u16) !void {
        ensureAlignment(dst_idx, .object_ref);
        ensureAlignment(src_idx, .object_ref);

        try self.appendBytecode(MMTypes.Bytecode.init(.{ .MOVo = .{ .src_idx = src_idx, .dst_idx = dst_idx } }, .void));
    }

    pub fn emitMoveS32(self: *Codegen, dst_idx: u16, src_idx: u16) !void {
        ensureAlignment(dst_idx, .s32);
        ensureAlignment(src_idx, .s32);

        try self.appendBytecode(MMTypes.Bytecode.init(.{ .MOVi = .{ .src_idx = src_idx, .dst_idx = dst_idx } }, .void));
    }

    pub fn emitRet(self: *Codegen, src_idx: u16, machine_type: MMTypes.MachineType) !void {
        ensureAlignment(src_idx, machine_type);

        try self.appendBytecode(MMTypes.Bytecode.init(.{ .RET = .{ .src_idx = src_idx } }, machine_type));
    }

    pub fn emitBranchNotEqualZero(self: *Codegen, src_idx: u16) !usize {
        try self.appendBytecode(MMTypes.Bytecode.init(.{ .BNEZ = .{
            .branch_offset = undefined,
            .src_idx = src_idx,
        } }, .void));

        //Return the index of the last item inserted, which is our branch instruction, so that the branch offset can be filled in later
        return self.bytecode.items.len - 1;
    }

    pub fn emitBranchEqualZero(self: *Codegen, src_idx: u16) !usize {
        try self.appendBytecode(MMTypes.Bytecode.init(.{ .BEZ = .{
            .branch_offset = undefined,
            .src_idx = src_idx,
        } }, .void));

        //Return the index of the last item inserted, which is our branch instruction, so that the branch offset can be filled in later
        return self.bytecode.items.len - 1;
    }

    pub fn emitBranch(self: *Codegen) !usize {
        try self.appendBytecode(MMTypes.Bytecode.init(.{ .B = .{
            .src_idx = 0xFFFF,
            .branch_offset = undefined,
        } }, .void));

        //Return the index of the last item inserted, which is our branch instruction, so that the branch offset can be filled in later
        return self.bytecode.items.len - 1;
    }

    pub fn emitLogicalNegationBoolean(self: *Codegen, dst_idx: u16, src_idx: u16) !void {
        try self.appendBytecode(MMTypes.Bytecode.init(
            .{ .LOG_NEGb = .{ .dst_idx = dst_idx, .src_idx = src_idx } },
            .void,
        ));
    }

    pub fn emitLoadConstFloat(self: *Codegen, dst_idx: u16, value: f32) !void {
        ensureAlignment(dst_idx, .f32);

        try self.appendBytecode(MMTypes.Bytecode.init(
            .{ .LCf = .{ .constant_idx = @bitCast(value), .dst_idx = dst_idx } },
            .void,
        ));
    }

    pub fn emitLoadConstVector4(self: *Codegen, dst_idx: u16, value: [4]f32) !void {
        ensureAlignment(dst_idx, .v4);

        const constant_idx: u32 = @intCast((try self.genny.f32_constants.getOrPut(value)).index);

        try self.appendBytecode(MMTypes.Bytecode.init(
            .{ .LCv4 = .{
                .constant_idx = constant_idx,
                .dst_idx = dst_idx,
            } },
            .void,
        ));
    }

    pub fn emitSetVectorElement(self: *Codegen, dst_idx: u16, element: u2, src_idx: u16) !void {
        ensureAlignment(dst_idx, .v4);
        ensureAlignment(src_idx, .f32);

        switch (element) {
            inline else => |element_val| {
                const tag_name = comptime switch (element_val) {
                    0 => @tagName(MMTypes.InstructionType.SET_V4_X),
                    1 => @tagName(MMTypes.InstructionType.SET_V4_Y),
                    2 => @tagName(MMTypes.InstructionType.SET_V4_Z),
                    3 => @tagName(MMTypes.InstructionType.SET_V4_W),
                };

                try self.appendBytecode(MMTypes.Bytecode.init(
                    @unionInit(MMTypes.TaggedInstruction, tag_name, .{
                        .src_idx = src_idx,
                        .base_idx = dst_idx,
                    }),
                    .void,
                ));
            },
        }
    }

    pub fn emitIntNotEqual(self: *Codegen, dst_idx: u16, left_idx: u16, right_idx: u16) !void {
        ensureAlignment(left_idx, .s32);
        ensureAlignment(right_idx, .s32);

        try self.appendBytecode(MMTypes.Bytecode.init(.{ .NEi = .{
            .dst_idx = dst_idx,
            .src_a_idx = left_idx,
            .src_b_idx = right_idx,
        } }, .void));
    }

    pub fn emitIntEqual(self: *Codegen, dst_idx: u16, left_idx: u16, right_idx: u16) !void {
        ensureAlignment(left_idx, .s32);
        ensureAlignment(right_idx, .s32);

        try self.appendBytecode(MMTypes.Bytecode.init(.{ .EQi = .{
            .dst_idx = dst_idx,
            .src_a_idx = left_idx,
            .src_b_idx = right_idx,
        } }, .void));
    }

    pub fn emitSafePtrNotEqual(self: *Codegen, dst_idx: u16, left_idx: u16, right_idx: u16) !void {
        ensureAlignment(left_idx, .safe_ptr);
        ensureAlignment(right_idx, .safe_ptr);

        try self.appendBytecode(MMTypes.Bytecode.init(.{ .NEsp = .{
            .dst_idx = dst_idx,
            .src_a_idx = left_idx,
            .src_b_idx = right_idx,
        } }, .void));
    }

    pub fn emitObjectPtrNotEqual(self: *Codegen, dst_idx: u16, left_idx: u16, right_idx: u16) !void {
        ensureAlignment(left_idx, .object_ref);
        ensureAlignment(right_idx, .object_ref);

        try self.appendBytecode(MMTypes.Bytecode.init(.{ .NEo = .{
            .dst_idx = dst_idx,
            .src_a_idx = left_idx,
            .src_b_idx = right_idx,
        } }, .void));
    }

    pub fn emitIntBitwiseAnd(self: *Codegen, dst_idx: u16, left_idx: u16, right_idx: u16) !void {
        ensureAlignment(left_idx, .s32);
        ensureAlignment(right_idx, .s32);

        try self.appendBytecode(MMTypes.Bytecode.init(.{ .BIT_ANDi = .{
            .dst_idx = dst_idx,
            .src_a_idx = left_idx,
            .src_b_idx = right_idx,
        } }, .void));
    }

    pub fn emitBoolBitwiseAnd(self: *Codegen, dst_idx: u16, lefthand: u16, righthand: u16) !void {
        try self.appendBytecode(MMTypes.Bytecode.init(.{ .BIT_ANDb = .{
            .dst_idx = dst_idx,
            .src_a_idx = lefthand,
            .src_b_idx = righthand,
        } }, .void));
    }

    pub fn emitBoolBitwiseOr(self: *Codegen, dst_idx: u16, lefthand: u16, righthand: u16) !void {
        try self.appendBytecode(MMTypes.Bytecode.init(.{ .BIT_ORi = .{
            .dst_idx = dst_idx,
            .src_a_idx = lefthand,
            .src_b_idx = righthand,
        } }, .void));
    }

    pub fn emitFloatGreaterThan(self: *Codegen, dst_idx: u16, lefthand: u16, righthand: u16) !void {
        ensureAlignment(lefthand, .f32);
        ensureAlignment(righthand, .f32);

        try self.appendBytecode(MMTypes.Bytecode.init(.{ .GTf = .{
            .dst_idx = dst_idx,
            .src_a_idx = lefthand,
            .src_b_idx = righthand,
        } }, .void));
    }

    pub fn emitFloatLessThanOrEqual(self: *Codegen, dst_idx: u16, lefthand: u16, righthand: u16) !void {
        ensureAlignment(lefthand, .f32);
        ensureAlignment(righthand, .f32);

        try self.appendBytecode(MMTypes.Bytecode.init(.{ .LTEf = .{
            .dst_idx = dst_idx,
            .src_a_idx = lefthand,
            .src_b_idx = righthand,
        } }, .void));
    }

    pub fn emitAddFloat(self: *Codegen, dst_idx: u16, lefthand: u16, righthand: u16) !void {
        ensureAlignment(dst_idx, .f32);
        ensureAlignment(lefthand, .f32);
        ensureAlignment(righthand, .f32);

        try self.appendBytecode(MMTypes.Bytecode.init(.{ .ADDf = .{
            .dst_idx = dst_idx,
            .src_a_idx = lefthand,
            .src_b_idx = righthand,
        } }, .void));
    }

    pub fn emitAddInt(self: *Codegen, dst_idx: u16, lefthand: u16, righthand: u16) !void {
        ensureAlignment(dst_idx, .s32);
        ensureAlignment(lefthand, .s32);
        ensureAlignment(righthand, .s32);

        try self.appendBytecode(MMTypes.Bytecode.init(.{ .ADDi = .{
            .dst_idx = dst_idx,
            .src_a_idx = lefthand,
            .src_b_idx = righthand,
        } }, .void));
    }

    pub fn emitMultiplyInt(self: *Codegen, dst_idx: u16, lefthand: u16, righthand: u16) !void {
        ensureAlignment(dst_idx, .s32);
        ensureAlignment(lefthand, .s32);
        ensureAlignment(righthand, .s32);

        try self.appendBytecode(MMTypes.Bytecode.init(.{ .MULi = .{
            .dst_idx = dst_idx,
            .src_a_idx = lefthand,
            .src_b_idx = righthand,
        } }, .void));
    }

    pub fn emitSubtractInt(self: *Codegen, dst_idx: u16, lefthand: u16, righthand: u16) !void {
        ensureAlignment(dst_idx, .s32);
        ensureAlignment(lefthand, .s32);
        ensureAlignment(righthand, .s32);

        try self.appendBytecode(MMTypes.Bytecode.init(.{ .SUBi = .{
            .dst_idx = dst_idx,
            .src_a_idx = lefthand,
            .src_b_idx = righthand,
        } }, .void));
    }

    pub fn emitExtLoad(self: *Codegen, dst_idx: u16, src_idx: u16, machine_type: MMTypes.MachineType) !void {
        ensureAlignment(src_idx, .s32);
        ensureAlignment(dst_idx, machine_type);

        // Only size s32 types work in the current version of the extended runtime
        std.debug.assert(machine_type.size() == MMTypes.MachineType.s32.size());

        try self.appendBytecode(MMTypes.Bytecode.init(.{ .EXT_LOAD = .{
            .src_idx = src_idx,
            .dst_idx = dst_idx,
        } }, machine_type));
    }

    pub fn emitExtStore(self: *Codegen, dst_idx: u16, src_idx: u16, machine_type: MMTypes.MachineType) !void {
        ensureAlignment(src_idx, machine_type);
        ensureAlignment(dst_idx, .s32);

        // Only size s32 types work in the current version of the extended runtime
        std.debug.assert(machine_type.size() == MMTypes.MachineType.s32.size());

        try self.appendBytecode(MMTypes.Bytecode.init(.{ .EXT_STORE = .{
            .src_idx = src_idx,
            .dst_idx = dst_idx,
        } }, machine_type));
    }
};

const Register = struct { u16, MMTypes.MachineType };

/// Compiles an expression, returning the register and the resulting machine type
fn compileExpression(
    codegen: *Codegen,
    function_local_variables: *LocalVariableTable,
    scope_local_variables: *LocalVariableTable,
    expression: *Parser.Node.Expression,
    discard_result: bool,
    result_register: ?Register,
) Error!?Register {
    return switch (expression.contents) {
        .assignment => |assignment| blk: {
            switch (assignment.destination.contents) {
                .variable_access => |variable_access| {
                    const variable = scope_local_variables.get(variable_access) orelse std.debug.panic("missing variable {s}", .{variable_access});

                    const register: Register = .{ @intCast(variable.offset), codegen.genny.type_references.keys()[variable.type_reference].machine_type };

                    _ = try compileExpression(
                        codegen,
                        function_local_variables,
                        scope_local_variables,
                        assignment.value,
                        false,
                        register,
                    );

                    break :blk if (discard_result) null else register;
                },
                .field_access => |field_access| {
                    const source_variable = scope_local_variables.get(field_access.source.contents.variable_access).?;
                    const source_variable_type = codegen.genny.type_references.keys()[source_variable.type_reference];

                    const machine_type = codegen.genny.type_intern_pool.get(expression.type).resolved.fish.machine_type;

                    const register = (try compileExpression(
                        codegen,
                        function_local_variables,
                        scope_local_variables,
                        assignment.value,
                        false,
                        result_register,
                    )).?;

                    if (register[1] != machine_type)
                        std.debug.panic(
                            "BUG: register type is {s} when it should be {s}",
                            .{ @tagName(register[1]), @tagName(machine_type) },
                        );

                    const field_reference: u16 = @intCast((try codegen.genny.field_references.getOrPut(.{
                        .name = @intCast((try codegen.genny.a_string_table.getOrPut(field_access.field)).index),
                        .type_reference = @intCast((try codegen.genny.type_references.getOrPut(source_variable_type)).index),
                    })).index);

                    switch (source_variable_type.machine_type) {
                        .object_ref => {
                            try codegen.emitSetObjectMember(
                                register[0],
                                @intCast(source_variable.offset),
                                field_reference,
                                machine_type,
                            );
                        },
                        .safe_ptr => {
                            try codegen.emitSetSafePtrMember(
                                register[0],
                                @intCast(source_variable.offset),
                                field_reference,
                                machine_type,
                            );
                        },
                        else => |tag| std.debug.panic("unable to do field access on machine type {s}", .{@tagName(tag)}),
                    }

                    // If we the result is being discarded
                    if (result_register == null and discard_result) {
                        try codegen.register_allocator.free(register);

                        break :blk null;
                    }

                    break :blk register;
                },
                .dereference => |dereference| {
                    const intermediate_register = (try compileExpression(
                        codegen,
                        function_local_variables,
                        scope_local_variables,
                        assignment.value,
                        false,
                        null,
                    )).?;

                    const address_register = (try compileExpression(
                        codegen,
                        function_local_variables,
                        scope_local_variables,
                        dereference,
                        false,
                        null,
                    )).?;

                    try codegen.emitExtStore(address_register[0], intermediate_register[0], intermediate_register[1]);

                    if (discard_result) {
                        try codegen.register_allocator.free(intermediate_register);

                        break :blk null;
                    }

                    break :blk intermediate_register;
                },
                else => |tag| std.debug.panic("TODO: codegen for assignment to {s}", .{@tagName(tag)}),
            }
        },
        // We can just lower this into a LCi
        .integer_literal_to_s32, .integer_literal_to_ptr, .integer_literal_to_safe_ptr => |integer_literal| blk: {
            if (discard_result)
                break :blk null;

            const value: i32 = if (integer_literal.contents.integer_literal.base != .decimal) int: {
                const unsigned: u64 = @bitCast(integer_literal.contents.integer_literal.value);

                const unsigned_u32: u32 = @intCast(unsigned);

                break :int @bitCast(unsigned_u32);
            } else @intCast(integer_literal.contents.integer_literal.value);

            const register = result_register orelse try codegen.register_allocator.allocate(.s32);

            try codegen.emitLoadConstInt(register[0], value);

            break :blk register;
        },
        .integer_literal_to_f32 => |int_literal| blk: {
            if (discard_result)
                break :blk null;

            const value: f32 = @floatFromInt(int_literal.contents.integer_literal.value);

            const register = result_register orelse try codegen.register_allocator.allocate(.f32);

            try codegen.emitLoadConstFloat(register[0], value);

            break :blk register;
        },
        .float_literal_to_f32 => |float_literal| blk: {
            if (discard_result)
                break :blk null;

            const value = float_literal.contents.float_literal.value;

            const register = result_register orelse try codegen.register_allocator.allocate(.f32);

            try codegen.emitLoadConstFloat(register[0], @floatCast(value));

            break :blk register;
        },
        .bool_literal => |bool_literal| blk: {
            if (discard_result)
                break :blk null;

            const register = result_register orelse try codegen.register_allocator.allocate(.bool);

            try codegen.emitLoadConstBool(register[0], bool_literal);

            break :blk register;
        },
        inline .null_literal_to_safe_ptr, .null_literal_to_object_ptr, .null_literal_to_ptr => |_, tag| blk: {
            if (discard_result)
                break :blk null;

            const register = result_register orelse try codegen.register_allocator.allocate(.safe_ptr);

            switch (tag) {
                .null_literal_to_object_ptr => try codegen.emitLoadConstNullObjectPtr(register[0]),
                .null_literal_to_safe_ptr => try codegen.emitLoadConstNullSafePtr(register[0]),
                .null_literal_to_ptr => try codegen.emitLoadConstInt(register[0], 0),
                else => @compileError("unhandled null literal load"),
            }

            break :blk register;
        },
        .wide_string_literal => |wide_string_literal| blk: {
            if (discard_result)
                break :blk null;

            const wide_string = try std.unicode.utf8ToUtf16LeAlloc(codegen.register_allocator.allocator, wide_string_literal);

            //If the result register is known, just load directly into that
            if (result_register) |result_idx| {
                try codegen.emitLoadConstStringWide(result_idx[0], wide_string);

                break :blk result_idx;
            }
            // Else, allocate a new register and use that
            else {
                const result_idx = try codegen.register_allocator.allocate(.object_ref);

                try codegen.emitLoadConstStringWide(result_idx[0], wide_string);

                break :blk result_idx;
            }
        },
        .ascii_string_literal => |ascii_string_literal| blk: {
            if (discard_result)
                break :blk null;

            //If the result register is known, just load directly into that
            if (result_register) |result_idx| {
                try codegen.emitLoadConstStringAscii(result_idx[0], ascii_string_literal);

                break :blk result_idx;
            }
            // Else, allocate a new register and use that
            else {
                const result_idx = try codegen.register_allocator.allocate(.object_ref);

                try codegen.emitLoadConstStringAscii(result_idx[0], ascii_string_literal);

                break :blk result_idx;
            }
        },
        // If the result register is unspecified, we do not lower this at all,
        // however if there is a result register specified, we lower this as a simple move.
        .variable_access => |variable_access| blk: {
            const variable = scope_local_variables.get(variable_access).?;

            const variable_machine_type = codegen.genny.type_references.keys()[variable.type_reference].machine_type;

            if (result_register) |result_idx| {
                _ = result_idx; // autofix

                switch (variable_machine_type) {
                    else => |tag| std.debug.panic("TODO: lower variable access move of {s}", .{@tagName(tag)}),
                }
            } else {
                break :blk .{ @intCast(variable.offset), variable_machine_type };
            }
        },
        // We lower this as a simple set of `ARG` instructions followed by a CALL instruction
        .function_call => |function_call| blk: {
            if (function_call.function != .function) {
                std.debug.panic("function call is not resolved correctly {s}", .{function_call.function.name});
            }

            const function = function_call.function.function;

            const called_function_idx: u16 = @intCast((try codegen.genny.function_references.getOrPut(.{
                .name = @intCast((try codegen.genny.a_string_table.getOrPut(function.function.mangled_name.?)).index),
                .type_reference = @intCast((try codegen.genny.type_references.getOrPut(function.owning_type)).index),
            })).index);

            const return_type = codegen.genny.type_intern_pool.get(expression.type).resolved.machineType();

            const parameter_registers = try codegen.register_allocator.allocator.alloc(Register, function_call.parameters.len);

            for (function_call.parameters, parameter_registers) |parameter, *parameter_register| {
                if (try compileExpression(
                    codegen,
                    function_local_variables,
                    scope_local_variables,
                    parameter,
                    false,
                    null,
                )) |parameter_result_register| {
                    parameter_register.* = parameter_result_register;
                } else {
                    @panic("BUG: function call parameter has no result register");
                }
            }

            const native_invoke: ?Parser.Node.Attribute.NativeInvoke = native_invoke_check: {
                for (function_call.function.function.function.attributes) |attribute| {
                    if (attribute.* == .native_invoke)
                        break :native_invoke_check attribute.native_invoke;
                }

                break :native_invoke_check null;
            };

            if (native_invoke != null) {
                var curr_integer_register: u16 = 0;
                var curr_float_register: u16 = 0;
                var curr_vector_register: u16 = 0;

                for (parameter_registers) |parameter_register| {
                    switch (parameter_register[1]) {
                        .bool, .char, .s32, .safe_ptr, .object_ref => {
                            const parameter_size = MMTypes.MachineType.s32.size();

                            if (curr_float_register >= 32) {
                                std.debug.panic("you cant have more than 8 native call int parameters", .{});
                            }

                            // Align to machine type
                            curr_integer_register += (parameter_size - (curr_integer_register % parameter_size)) % parameter_size;

                            if (parameter_register[1].size() < 4) {
                                const temporary_register = try codegen.register_allocator.allocate(.s32);
                                try codegen.emitLoadConstInt(temporary_register[0], 0);
                                try codegen.emitArg(curr_integer_register, temporary_register[0], .s32);
                                try codegen.register_allocator.free(temporary_register);

                                curr_integer_register += parameter_size - parameter_register[1].size();
                            }

                            try codegen.emitArg(curr_integer_register, parameter_register[0], parameter_register[1]);

                            curr_integer_register += parameter_size;
                        },
                        .f32 => {
                            const parameter_size = MMTypes.MachineType.f32.size();

                            if (curr_float_register >= 16) {
                                std.debug.panic("you cant have more than 4 native call float parameters", .{});
                            }

                            // Align to machine type
                            curr_float_register += (parameter_size - (curr_float_register % parameter_size)) % parameter_size;

                            try codegen.emitArg(curr_float_register + 32, parameter_register[0], parameter_register[1]);

                            curr_float_register += parameter_size;
                        },
                        .v4 => {
                            const parameter_size = MMTypes.MachineType.v4.size();

                            if (curr_vector_register >= 4) {
                                std.debug.panic("you cant have more than 1 native call vector parameters", .{});
                            }

                            // Align to machine type
                            curr_vector_register += (parameter_size - (curr_vector_register % parameter_size)) % parameter_size;

                            try codegen.emitArg(curr_vector_register + 48, parameter_register[0], parameter_register[1]);

                            curr_vector_register += parameter_size;
                        },
                        else => |missing_machine_type| std.debug.panic("Unable to native call with {s} machine type parameter", .{@tagName(missing_machine_type)}),
                    }
                }
            } else {
                var curr_arg_register: u16 = 0;

                // If this is a member function call, we need to add the source as the arg0 reg
                if (function_call.source) |source| {
                    // We only want to put arg0 as the `this` param if we are calling a method on a variable, and not a class
                    if (source.contents == .variable_access) {
                        const source_variable = scope_local_variables.get(source.contents.variable_access).?;

                        const source_machine_type = codegen.genny.type_references.keys()[source_variable.type_reference].machine_type;

                        try codegen.emitArg(0, @intCast(source_variable.offset), source_machine_type);

                        curr_arg_register += source_machine_type.size();
                    }
                }

                for (parameter_registers) |parameter_register| {
                    const parameter_size = parameter_register[1].size();

                    // Align to machine type
                    curr_arg_register += (parameter_size - (curr_arg_register % parameter_size)) % parameter_size;

                    try codegen.emitArg(curr_arg_register, parameter_register[0], parameter_register[1]);

                    curr_arg_register += parameter_size;
                }
            }

            const call_result_register = if (result_register) |result_register_idx|
                result_register_idx
                // We actually need to have a valid return register for native invokes
            else if (discard_result and native_invoke == null)
                .{ std.math.maxInt(u16), .void }
                // We need to have a valid s32 return register for native calls
            else if (native_invoke != null and return_type == .void)
                try codegen.register_allocator.allocate(.s32)
            else
                try codegen.register_allocator.allocate(return_type);

            if (native_invoke) |native_invoke_attribute| {
                try codegen.emitNativeInvoke(
                    call_result_register[0],
                    native_invoke_attribute.address,
                    native_invoke_attribute.toc_index,
                    call_result_register[1],
                );
            } else {
                //TODO: use CALLVo and CALLVsp for virtual functions
                try codegen.emitCall(
                    call_result_register[0],
                    called_function_idx,
                    call_result_register[1],
                );
            }

            for (parameter_registers) |parameter_register|
                try codegen.register_allocator.free(parameter_register);

            if (discard_result and native_invoke != null) {
                try codegen.register_allocator.free(call_result_register);
            }

            break :blk call_result_register;
        },
        .cast => |cast_source| blk: {
            if (try compileExpression(
                codegen,
                function_local_variables,
                scope_local_variables,
                cast_source,
                discard_result,
                null,
            )) |source| {
                const register = result_register orelse
                    try codegen.register_allocator.allocate(codegen.genny.type_intern_pool.get(expression.type).resolved.machineType());

                const source_type = codegen.genny.type_intern_pool.get(cast_source.type).resolved.machineType();
                const dst_type = codegen.genny.type_intern_pool.get(expression.type).resolved.machineType();

                switch (tupleMachineTypes(source_type, dst_type)) {
                    tupleMachineTypes(.bool, .s32) => try codegen.emitBoolToS32(register[0], source[0]),
                    tupleMachineTypes(.s32, .f32) => try codegen.emitS32ToF32(register[0], source[0]),
                    tupleMachineTypes(.object_ref, .object_ref) => try codegen.emitMoveObjectRef(register[0], source[0]),
                    tupleMachineTypes(.s32, .s32) => try codegen.emitMoveS32(register[0], source[0]),
                    else => std.debug.panic("TODO: cast from expression {s} to {s}", .{ @tagName(source_type), @tagName(dst_type) }),
                }

                return register;
            }

            break :blk null;
        },
        .field_access => |field_access| blk: {
            if (discard_result)
                break :blk null;

            const source_variable = scope_local_variables.get(field_access.source.contents.variable_access).?;

            const source_variable_type = codegen.genny.type_references.keys()[source_variable.type_reference];

            const machine_type = codegen.genny.type_intern_pool.get(expression.type).resolved.fish.machine_type;

            const register = result_register orelse try codegen.register_allocator.allocate(machine_type);

            const field_reference: u16 = @intCast((try codegen.genny.field_references.getOrPut(.{
                .name = @intCast((try codegen.genny.a_string_table.getOrPut(field_access.field)).index),
                .type_reference = @intCast((try codegen.genny.type_references.getOrPut(source_variable_type)).index),
            })).index);

            switch (source_variable_type.machine_type) {
                .object_ref => {
                    try codegen.emitGetObjectMember(
                        register[0],
                        @intCast(source_variable.offset),
                        field_reference,
                        machine_type,
                    );
                },
                .safe_ptr => {
                    try codegen.emitGetSafePtrMember(
                        register[0],
                        @intCast(source_variable.offset),
                        field_reference,
                        machine_type,
                    );
                },
                else => |tag| std.debug.panic("unable to do field access on machine type {s}", .{@tagName(tag)}),
            }

            break :blk register;
        },
        .logical_negation => |logical_negation| blk: {
            if (try compileExpression(
                codegen,
                function_local_variables,
                scope_local_variables,
                logical_negation,
                false,
                null,
            )) |source_register| {
                const register = result_register orelse try codegen.register_allocator.allocate(.bool);

                try codegen.emitLogicalNegationBoolean(register[0], source_register[0]);

                if (discard_result and result_register == null) {
                    try codegen.register_allocator.free(register);
                    break :blk null;
                }

                break :blk register;
            } else @panic("BUG: logical negation source has no register");
        },
        .block => |block| blk: {
            std.debug.assert(result_register == null);

            try compileBlock(
                codegen,
                function_local_variables,
                scope_local_variables,
                block,
                false,
                .void,
            );

            break :blk null;
        },
        inline .vec2_construction, .vec3_construction, .vec4_construction => |vector_construction| blk: {
            if (discard_result)
                break :blk null;

            const register = result_register orelse try codegen.register_allocator.allocate(.v4);

            for (vector_construction, 0..) |element_expression, i| {
                const element_register = (try compileExpression(
                    codegen,
                    function_local_variables,
                    scope_local_variables,
                    element_expression,
                    false,
                    null,
                )).?;

                try codegen.emitSetVectorElement(register[0], @intCast(i), element_register[0]);

                try codegen.register_allocator.free(element_register);
            }

            break :blk register;
        },
        inline .bitwise_and, .addition, .subtraction, .not_equal, .equal, .greater_than, .less_than_or_equal => |binary, binary_type| blk: {
            const binary_lefthand_type = codegen.genny.type_intern_pool.get(binary.lefthand.type);
            const binary_righthand_type = codegen.genny.type_intern_pool.get(binary.righthand.type);

            //Assert the types are equal if its not a pointer we are dealing with, else make sure that the other operand is an s32
            if ((binary_type == .addition or binary_type == .subtraction) and binary_lefthand_type.resolved == .pointer)
                std.debug.assert(binary_righthand_type.resolved.fish.machine_type == .s32)
            else
                std.debug.assert(binary_lefthand_type.resolved.eql(binary_righthand_type.resolved));

            const hand_type = binary_lefthand_type.resolved;

            // Allocate a result register, in the case of bitwise ops, we need to use the machine type, else use a bool as the result
            const register = result_register orelse try codegen.register_allocator.allocate(switch (binary_type) {
                .bitwise_and, .addition, .subtraction => binary_lefthand_type.resolved.machineType(),
                .not_equal, .equal, .greater_than, .less_than_or_equal => .bool,
                else => @compileError("Missing register type resolution"),
            });

            switch (hand_type) {
                .fish => |fish| {
                    const lefthand = (try compileExpression(
                        codegen,
                        function_local_variables,
                        scope_local_variables,
                        binary.lefthand,
                        false,
                        null,
                    )).?;
                    const righthand = (try compileExpression(
                        codegen,
                        function_local_variables,
                        scope_local_variables,
                        binary.righthand,
                        false,
                        null,
                    )).?;

                    std.debug.assert(lefthand[1] == righthand[1]);
                    std.debug.assert(lefthand[1] == fish.machine_type);

                    switch (fish.machine_type) {
                        .s32 => switch (binary_type) {
                            .equal => try codegen.emitIntEqual(register[0], lefthand[0], righthand[0]),
                            .not_equal => try codegen.emitIntNotEqual(register[0], lefthand[0], righthand[0]),
                            .bitwise_and => try codegen.emitIntBitwiseAnd(register[0], lefthand[0], righthand[0]),
                            .addition => try codegen.emitAddInt(register[0], lefthand[0], righthand[0]),
                            .subtraction => try codegen.emitSubtractInt(register[0], lefthand[0], righthand[0]),
                            else => std.debug.panic("TODO: {s} binary op type for s32", .{@tagName(binary_type)}),
                        },
                        .f32 => switch (binary_type) {
                            .greater_than => try codegen.emitFloatGreaterThan(register[0], lefthand[0], righthand[0]),
                            .less_than_or_equal => try codegen.emitFloatLessThanOrEqual(register[0], lefthand[0], righthand[0]),
                            .addition => try codegen.emitAddFloat(register[0], lefthand[0], righthand[0]),
                            else => std.debug.panic("TODO: {s} binary op type for f32", .{@tagName(binary_type)}),
                        },
                        .safe_ptr => switch (binary_type) {
                            .not_equal => try codegen.emitSafePtrNotEqual(register[0], lefthand[0], righthand[0]),
                            else => std.debug.panic("TODO: {s} binary op type for safe_ptr", .{@tagName(binary_type)}),
                        },
                        .object_ref => switch (binary_type) {
                            .not_equal => try codegen.emitObjectPtrNotEqual(register[0], lefthand[0], righthand[0]),
                            else => std.debug.panic("TODO: {s} binary op type for object_ptr", .{@tagName(binary_type)}),
                        },
                        else => |tag| std.debug.panic("TODO: comparisons for machine type {s}", .{@tagName(tag)}),
                    }

                    try codegen.register_allocator.free(lefthand);
                    try codegen.register_allocator.free(righthand);
                },
                .pointer => |pointer| {
                    const lefthand = (try compileExpression(
                        codegen,
                        function_local_variables,
                        scope_local_variables,
                        binary.lefthand,
                        false,
                        null,
                    )).?;
                    const righthand = (try compileExpression(
                        codegen,
                        function_local_variables,
                        scope_local_variables,
                        binary.righthand,
                        false,
                        null,
                    )).?;

                    std.debug.assert(lefthand[1] == .s32);

                    switch (binary_type) {
                        .not_equal => try codegen.emitIntNotEqual(register[0], lefthand[0], righthand[0]),
                        .equal => try codegen.emitIntEqual(register[0], lefthand[0], righthand[0]),
                        .addition => {
                            const target_type_size = pointer.type.fish.toMachineType().size();

                            // Load the size of the data type into the destination register
                            try codegen.emitLoadConstInt(register[0], target_type_size);
                            // Multiply the amount by the amount of elements weare moving
                            try codegen.emitMultiplyInt(register[0], register[0], righthand[0]);
                            // Add the resulting offset with the pointer, and store it in the result register
                            try codegen.emitAddInt(register[0], register[0], lefthand[0]);
                        },
                        else => |tag| std.debug.panic("TODO: comparisons for op {s}", .{@tagName(tag)}),
                    }

                    try codegen.register_allocator.free(lefthand);
                    try codegen.register_allocator.free(righthand);
                },
                .integer_literal => {
                    @panic("TODO: int literal comparison");
                },
                .float_literal => {
                    @panic("TODO: float literal comparison");
                },
                .null_literal => {
                    @panic("TODO: null literal comparison");
                },
            }

            if (discard_result and result_register != null) {
                try codegen.register_allocator.free(register);
                break :blk null;
            }

            break :blk register;
        },
        inline .logical_and, .logical_or => |logical_op, tag| blk: {
            const lefthand = (try compileExpression(
                codegen,
                function_local_variables,
                scope_local_variables,
                logical_op.lefthand,
                false,
                null,
            )).?;
            std.debug.assert(lefthand[1] == .bool);

            const righthand = (try compileExpression(
                codegen,
                function_local_variables,
                scope_local_variables,
                logical_op.righthand,
                false,
                null,
            )).?;
            std.debug.assert(righthand[1] == .bool);

            if (!discard_result) {
                const register = result_register orelse try codegen.register_allocator.allocate(.bool);

                switch (tag) {
                    .logical_and => try codegen.emitBoolBitwiseAnd(register[0], lefthand[0], righthand[0]),
                    .logical_or => try codegen.emitBoolBitwiseOr(register[0], lefthand[0], righthand[0]),
                    else => @compileError("what"),
                }

                break :blk register;
            }

            try codegen.register_allocator.free(lefthand);
            try codegen.register_allocator.free(righthand);

            break :blk null;
        },
        .dereference => |dereference| blk: {
            if (discard_result)
                break :blk null;

            const register = result_register orelse try codegen.register_allocator.allocate(codegen.genny.type_intern_pool.get(expression.type).resolved.machineType());

            const source_register = (try compileExpression(
                codegen,
                function_local_variables,
                scope_local_variables,
                dereference,
                false,
                null,
            )).?;

            std.debug.assert(source_register[1] == .s32);

            try codegen.emitExtLoad(register[0], source_register[0], register[1]);

            try codegen.register_allocator.free(source_register);

            break :blk register;
        },
        else => |tag| std.debug.panic("cant codegen for expression {s} yet\n", .{@tagName(tag)}),
    };
}

fn tupleMachineTypes(left: MMTypes.MachineType, right: MMTypes.MachineType) u16 {
    return (@as(u16, @intFromEnum(left)) << 8) | @intFromEnum(right);
}

fn compileBlock(
    codegen: *Codegen,
    function_local_variables: *LocalVariableTable,
    scope_local_variables: *LocalVariableTable,
    block: []const Parser.Node,
    top_level: bool,
    return_type: MMTypes.MachineType,
) Error!void {
    var local_variables_from_this_scope = std.ArrayList([]const u8).init(codegen.register_allocator.allocator);

    var return_or_unreachable_emit = false;

    for (block) |node| block_loop: {
        switch (node) {
            .variable_declaration => |variable_declaration| {
                const resolved = codegen.genny.type_intern_pool.get(variable_declaration.type).resolved;

                const type_reference: MMTypes.TypeReference = switch (resolved) {
                    .pointer => |pointer| pointer.fish.?,
                    .fish => |fish| fish,
                    else => @panic("TODO"),
                };

                //Allocate the register that will be used for this local variable
                const register = try codegen.register_allocator.allocate(type_reference.machine_type);

                try local_variables_from_this_scope.append(variable_declaration.name);

                const local_variable: MMTypes.LocalVariable = .{
                    .type_reference = @intCast((try codegen.genny.type_references.getOrPut(type_reference)).index),
                    .name = @intCast((try codegen.genny.a_string_table.getOrPut(variable_declaration.name)).index),
                    .modifiers = .{},
                    .offset = register[0],
                };

                if (variable_declaration.value) |variable_value| {
                    if (try compileExpression(
                        codegen,
                        function_local_variables,
                        scope_local_variables,
                        variable_value,
                        false,
                        register,
                    )) |result_register| {
                        if (result_register[0] != register[0])
                            @panic("BUG: result register of variable assignment was bad");
                    } else {
                        @panic("BUG: expression for variable value didnt return anything?");
                    }
                }

                try function_local_variables.putNoClobber(variable_declaration.name, local_variable);
                try scope_local_variables.putNoClobber(variable_declaration.name, local_variable);
            },
            .expression => |expression| {
                if (try compileExpression(
                    codegen,
                    function_local_variables,
                    scope_local_variables,
                    expression,
                    true,
                    null,
                )) |result_register| {
                    try codegen.register_allocator.free(result_register);
                }
            },
            .return_statement => |return_statement| {
                if (return_statement.expression) |return_value| {
                    const return_register = (try compileExpression(
                        codegen,
                        function_local_variables,
                        scope_local_variables,
                        return_value,
                        false,
                        null,
                    )).?;

                    try codegen.emitRet(return_register[0], return_register[1]);

                    try codegen.register_allocator.free(return_register);
                } else {
                    try codegen.emitRet(0, .void);
                }

                return_or_unreachable_emit = true;

                // At a return statement, immediately break out of the block, we dont need to generate code after a return statement
                break :block_loop;
            },
            .if_statement => |if_statement| {
                const condition_register = (try compileExpression(
                    codegen,
                    function_local_variables,
                    scope_local_variables,
                    if_statement.condition,
                    false,
                    null,
                )).?;

                // If the condition is false (0), we need to skip over the main body,
                // this will either skip ahead to after the main body and continue execution as normal,
                // or it will skip to the else body, which is emit after the main body
                const skip_body_instruction = try codegen.emitBranchEqualZero(condition_register[0]);

                // Now that we are done with the condition, we can get rid of that register
                try codegen.register_allocator.free(condition_register);

                // Compile the main body expression
                std.debug.assert(try compileExpression(
                    codegen,
                    function_local_variables,
                    scope_local_variables,
                    if_statement.body,
                    true,
                    null,
                ) == null);

                // If we have an else body, we need to emit an instruction after the main body to skip over the else block
                const skip_else_instruction: ?usize = if (if_statement.else_body != null) try codegen.emitBranch() else null;

                // Set the branch offset of the instruction to the next instruction to be emit
                codegen.bytecode.items[skip_body_instruction].params.BEZ.branch_offset =
                    @intCast(codegen.bytecode.items.len - skip_body_instruction);

                // If we have an else body, we need to emit that
                if (if_statement.else_body) |else_body| {
                    // Emit the actual body
                    std.debug.assert(try compileExpression(
                        codegen,
                        function_local_variables,
                        scope_local_variables,
                        else_body,
                        true,
                        null,
                    ) == null);

                    // Set the skip else target to the instruction after the current instruction
                    codegen.bytecode.items[skip_else_instruction.?].params.B.branch_offset =
                        @intCast(codegen.bytecode.items.len - skip_else_instruction.?);
                }
            },
            //
            // alloc condition register
            // start: calculate condition
            // if(!condition) goto end;
            // body;
            // goto start;
            // end:
            // free condition register
            //
            .while_statement => |while_statement| {
                // Get the index which starts the condition check
                const condition_start = codegen.nextEmitBytecodeIndex();

                const condition_register = (try compileExpression(
                    codegen,
                    function_local_variables,
                    scope_local_variables,
                    while_statement.condition,
                    false,
                    null,
                )).?;
                std.debug.assert(condition_register[1] == .bool);

                // Emit the branch which will conditionally skip to after the loop if the condition is zero
                const skip_to_end_instruction = try codegen.emitBranchEqualZero(condition_register[0]);

                // Emit the body of the while loop
                std.debug.assert(try compileExpression(
                    codegen,
                    function_local_variables,
                    scope_local_variables,
                    while_statement.body,
                    true,
                    null,
                ) == null);

                // Generate a branch which branches directly back to the condition check
                codegen.bytecode.items[try codegen.emitBranch()].params.B.branch_offset =
                    @as(i32, @intCast(condition_start)) - @as(i32, @intCast(codegen.nextEmitBytecodeIndex()));

                // Update the "skip to end" jump to go to the next instruction emit
                codegen.bytecode.items[skip_to_end_instruction].params.BEZ.branch_offset =
                    @intCast(codegen.nextEmitBytecodeIndex() - skip_to_end_instruction);

                try codegen.register_allocator.free(condition_register);
            },
            .inline_asm_statement => |inline_asm| {
                for (inline_asm.bytecode, 0..) |bytecode, i| {
                    switch (bytecode.op) {
                        inline else => |val, op| blk: {
                            const ParamType = @TypeOf(val);

                            switch (op) {
                                .MOVo,
                                .LC_NULLo,
                                .LCsw,
                                .LCsa,
                                .NEW_ARRAY,
                                .NEW_OBJECT,
                                .CALL,
                                .CALLVo,
                                .CALLVsp,
                                .CASTo,
                                .GET_RP_MEMBER,
                                .GET_SP_MEMBER,
                                .GET_OBJ_MEMBER,
                                .GET_SP_NATIVE_MEMBER,
                                .GET_ELEMENT,
                                => {
                                    // If its any of the machine type dependent instructions, dont add if the target isnt object ref
                                    if ((op == .GET_RP_MEMBER or
                                        op == .GET_SP_MEMBER or
                                        op == .GET_OBJ_MEMBER or
                                        op == .GET_SP_NATIVE_MEMBER or
                                        op == .CALL or
                                        op == .CALLVo or
                                        op == .CALLVsp or
                                        op == .GET_ELEMENT) and
                                        bytecode.machine_type != .object_ref)
                                    {
                                        std.debug.print("skipping\n", .{});

                                        break :blk;
                                    }

                                    const dst_idx = val.dst_idx;

                                    const register_name = try codegen.register_allocator.registerName(dst_idx);

                                    try codegen.register_allocator.register_local_variables.append(.{
                                        .name = @intCast((try codegen.genny.a_string_table.getOrPut(register_name)).index),
                                        .modifiers = .{},
                                        .offset = dst_idx,
                                        .type_reference = @intCast((try codegen.genny.type_references.getOrPut(MMTypes.TypeReference{
                                            .type_name = 0xFFFFFFFF,
                                            .array_base_machine_type = .void,
                                            .dimension_count = 0,
                                            .fish_type = .void,
                                            .machine_type = .object_ref,
                                            .script = null,
                                        })).index),
                                    });
                                },
                                else => {},
                            }

                            switch (op) {
                                .MOVsp,
                                .LC_NULLsp,
                                .CALL,
                                .CALLVo,
                                .CALLVsp,
                                .CASTsp,
                                .GET_RP_MEMBER,
                                .GET_SP_MEMBER,
                                .GET_OBJ_MEMBER,
                                .GET_SP_NATIVE_MEMBER,
                                .GET_ELEMENT,
                                => {
                                    // If its any of the machine type dependent instructions, dont add if the target isnt object ref
                                    if ((op == .GET_RP_MEMBER or
                                        op == .GET_SP_MEMBER or
                                        op == .GET_OBJ_MEMBER or
                                        op == .GET_SP_NATIVE_MEMBER or
                                        op == .CALL or
                                        op == .CALLVo or
                                        op == .CALLVsp or
                                        op == .GET_ELEMENT) and
                                        bytecode.machine_type != .object_ref)
                                    {
                                        std.debug.print("skipping\n", .{});
                                        break :blk;
                                    }

                                    const dst_idx = val.dst_idx;

                                    const register_name = try codegen.register_allocator.registerName(dst_idx);

                                    try codegen.register_allocator.register_local_variables.append(.{
                                        .name = @intCast((try codegen.genny.a_string_table.getOrPut(register_name)).index),
                                        .modifiers = .{},
                                        .offset = dst_idx,
                                        .type_reference = @intCast((try codegen.genny.type_references.getOrPut(MMTypes.TypeReference{
                                            .type_name = 0xFFFFFFFF,
                                            .array_base_machine_type = .void,
                                            .dimension_count = 0,
                                            .fish_type = .void,
                                            .machine_type = .safe_ptr,
                                            .script = null,
                                        })).index),
                                    });
                                },
                                else => {},
                            }

                            switch (ParamType) {
                                Parser.Bytecode.Params.NopClass => {},
                                Parser.Bytecode.Params.LoadBoolConst => codegen.register_allocator.highest_register = @max(codegen.register_allocator.highest_register, val.dst_idx),
                                Parser.Bytecode.Params.LoadCharConst => codegen.register_allocator.highest_register = @max(codegen.register_allocator.highest_register, val.dst_idx + 1),
                                Parser.Bytecode.Params.LoadIntConst => codegen.register_allocator.highest_register = @max(codegen.register_allocator.highest_register, val.dst_idx + 3),
                                Parser.Bytecode.Params.LoadFloatConst => codegen.register_allocator.highest_register = @max(codegen.register_allocator.highest_register, val.dst_idx + 3),
                                Parser.Bytecode.Params.LoadWideStringConst => codegen.register_allocator.highest_register = @max(codegen.register_allocator.highest_register, val.dst_idx + 3),
                                Parser.Bytecode.Params.LoadAsciiStringConst => codegen.register_allocator.highest_register = @max(codegen.register_allocator.highest_register, val.dst_idx + 3),
                                Parser.Bytecode.Params.LoadNullConst => codegen.register_allocator.highest_register = @max(codegen.register_allocator.highest_register, val.dst_idx + 3),
                                Parser.Bytecode.Params.UnaryClass => switch (op) {
                                    .MOVb, .LOG_NEGb => {
                                        codegen.register_allocator.highest_register = @max(codegen.register_allocator.highest_register, val.dst_idx);
                                        codegen.register_allocator.highest_register = @max(codegen.register_allocator.highest_register, val.src_idx);
                                    },
                                    .MOVc => {
                                        codegen.register_allocator.highest_register = @max(codegen.register_allocator.highest_register, val.dst_idx + 1);
                                        codegen.register_allocator.highest_register = @max(codegen.register_allocator.highest_register, val.src_idx + 1);
                                    },
                                    .MOVi,
                                    .INCi,
                                    .DECi,
                                    .NEGi,
                                    .BIT_NEGi,
                                    .LOG_NEGi,
                                    .ABSi,
                                    .MOVf,
                                    .NEGf,
                                    .ABSf,
                                    .SQRTf,
                                    .SINf,
                                    .COSf,
                                    .TANf,
                                    .MOVrp,
                                    .MOVsp,
                                    .MOVo,
                                    => {
                                        codegen.register_allocator.highest_register = @max(codegen.register_allocator.highest_register, val.dst_idx + 3);
                                        codegen.register_allocator.highest_register = @max(codegen.register_allocator.highest_register, val.src_idx + 3);
                                    },
                                    .MOVv4,
                                    .NEGv4,
                                    => {
                                        codegen.register_allocator.highest_register = @max(codegen.register_allocator.highest_register, val.dst_idx + 15);
                                        codegen.register_allocator.highest_register = @max(codegen.register_allocator.highest_register, val.src_idx + 15);
                                    },
                                    .MOVm44 => {
                                        codegen.register_allocator.highest_register = @max(codegen.register_allocator.highest_register, val.dst_idx + 63);
                                        codegen.register_allocator.highest_register = @max(codegen.register_allocator.highest_register, val.src_idx + 63);
                                    },
                                    .MOVs64 => {
                                        codegen.register_allocator.highest_register = @max(codegen.register_allocator.highest_register, val.dst_idx + 7);
                                        codegen.register_allocator.highest_register = @max(codegen.register_allocator.highest_register, val.src_idx + 7);
                                    },
                                    .INTb, .FLOATb => {
                                        codegen.register_allocator.highest_register = @max(codegen.register_allocator.highest_register, val.dst_idx + 3);
                                        codegen.register_allocator.highest_register = @max(codegen.register_allocator.highest_register, val.src_idx);
                                    },
                                    .INTc, .FLOATc => {
                                        codegen.register_allocator.highest_register = @max(codegen.register_allocator.highest_register, val.dst_idx + 3);
                                        codegen.register_allocator.highest_register = @max(codegen.register_allocator.highest_register, val.src_idx + 1);
                                    },
                                    .INTf, .FLOATi, .EXT_LOAD, .EXT_STORE => {
                                        codegen.register_allocator.highest_register = @max(codegen.register_allocator.highest_register, val.dst_idx + 3);
                                        codegen.register_allocator.highest_register = @max(codegen.register_allocator.highest_register, val.src_idx + 3);
                                    },
                                    .BOOLi => {
                                        codegen.register_allocator.highest_register = @max(codegen.register_allocator.highest_register, val.dst_idx);
                                        codegen.register_allocator.highest_register = @max(codegen.register_allocator.highest_register, val.src_idx + 3);
                                    },
                                    .BOOLc => {
                                        codegen.register_allocator.highest_register = @max(codegen.register_allocator.highest_register, val.dst_idx);
                                        codegen.register_allocator.highest_register = @max(codegen.register_allocator.highest_register, val.src_idx + 1);
                                    },
                                    .BOOLf => {
                                        codegen.register_allocator.highest_register = @max(codegen.register_allocator.highest_register, val.dst_idx);
                                        codegen.register_allocator.highest_register = @max(codegen.register_allocator.highest_register, val.src_idx + 3);
                                    },
                                    .EXT_ADDRESS => {
                                        codegen.register_allocator.highest_register = @max(codegen.register_allocator.highest_register, val.dst_idx + 3);
                                    },
                                    // This is a NOP in the runtime
                                    .MOVcp => {},
                                    else => @compileError("unhandled op " ++ @tagName(op)),
                                },
                                Parser.Bytecode.Params.BinaryClass => switch (op) {
                                    .EQb, .NEb, .BIT_ORb, .BIT_ANDb, .BIT_XORb => {
                                        codegen.register_allocator.highest_register = @max(codegen.register_allocator.highest_register, val.dst_idx);
                                        codegen.register_allocator.highest_register = @max(codegen.register_allocator.highest_register, val.src_a_idx);
                                        codegen.register_allocator.highest_register = @max(codegen.register_allocator.highest_register, val.src_b_idx);
                                    },
                                    .LTc, .LTEc, .GTc, .GTEc, .EQc, .NEc => {
                                        codegen.register_allocator.highest_register = @max(codegen.register_allocator.highest_register, val.dst_idx);
                                        codegen.register_allocator.highest_register = @max(codegen.register_allocator.highest_register, val.src_a_idx + 1);
                                        codegen.register_allocator.highest_register = @max(codegen.register_allocator.highest_register, val.src_b_idx + 1);
                                    },
                                    .ADDi,
                                    .SUBi,
                                    .MULi,
                                    .DIVi,
                                    .MODi,
                                    .MINi,
                                    .MAXi,
                                    .SLAi,
                                    .SRAi,
                                    .SRLi,
                                    .BIT_ORi,
                                    .BIT_ANDi,
                                    .BIT_XORi,
                                    .ADDf,
                                    .SUBf,
                                    .MULf,
                                    .DIVf,
                                    .MINf,
                                    .MAXf,
                                    => {
                                        codegen.register_allocator.highest_register = @max(codegen.register_allocator.highest_register, val.dst_idx + 3);
                                        codegen.register_allocator.highest_register = @max(codegen.register_allocator.highest_register, val.src_a_idx + 3);
                                        codegen.register_allocator.highest_register = @max(codegen.register_allocator.highest_register, val.src_b_idx + 3);
                                    },
                                    .ADDs64,
                                    => {
                                        codegen.register_allocator.highest_register = @max(codegen.register_allocator.highest_register, val.dst_idx + 3);
                                        codegen.register_allocator.highest_register = @max(codegen.register_allocator.highest_register, val.src_a_idx + 3);
                                        codegen.register_allocator.highest_register = @max(codegen.register_allocator.highest_register, val.src_b_idx + 3);
                                    },
                                    .ADDv4,
                                    .SUBv4,
                                    .MULSv4,
                                    .DIVSv4,
                                    .DOT2v4,
                                    .DOT3v4,
                                    .DOT4v4,
                                    .CROSS3v4,
                                    => {
                                        codegen.register_allocator.highest_register = @max(codegen.register_allocator.highest_register, val.dst_idx + 15);
                                        codegen.register_allocator.highest_register = @max(codegen.register_allocator.highest_register, val.src_a_idx + 15);
                                        codegen.register_allocator.highest_register = @max(codegen.register_allocator.highest_register, val.src_b_idx + 15);
                                    },
                                    .MULm44 => {
                                        codegen.register_allocator.highest_register = @max(codegen.register_allocator.highest_register, val.dst_idx + 63);
                                        codegen.register_allocator.highest_register = @max(codegen.register_allocator.highest_register, val.src_a_idx + 63);
                                        codegen.register_allocator.highest_register = @max(codegen.register_allocator.highest_register, val.src_b_idx + 63);
                                    },
                                    .LTi,
                                    .LTEi,
                                    .GTi,
                                    .GTEi,
                                    .EQi,
                                    .NEi,
                                    .LTf,
                                    .LTEf,
                                    .GTf,
                                    .GTEf,
                                    .EQf,
                                    .NEf,
                                    .EQrp,
                                    .NErp,
                                    .EQo,
                                    .NEo,
                                    .EQsp,
                                    .NEsp,
                                    => {
                                        codegen.register_allocator.highest_register = @max(codegen.register_allocator.highest_register, val.dst_idx);
                                        codegen.register_allocator.highest_register = @max(codegen.register_allocator.highest_register, val.src_a_idx + 3);
                                        codegen.register_allocator.highest_register = @max(codegen.register_allocator.highest_register, val.src_b_idx + 3);
                                    },
                                    .EQs64,
                                    .NEs64,
                                    => {
                                        codegen.register_allocator.highest_register = @max(codegen.register_allocator.highest_register, val.dst_idx);
                                        codegen.register_allocator.highest_register = @max(codegen.register_allocator.highest_register, val.src_a_idx + 7);
                                        codegen.register_allocator.highest_register = @max(codegen.register_allocator.highest_register, val.src_b_idx + 7);
                                    },
                                    .BIT_ORs64,
                                    .BIT_ANDs64,
                                    .BIT_XORs64,
                                    => {
                                        codegen.register_allocator.highest_register = @max(codegen.register_allocator.highest_register, val.dst_idx + 7);
                                        codegen.register_allocator.highest_register = @max(codegen.register_allocator.highest_register, val.src_a_idx + 7);
                                        codegen.register_allocator.highest_register = @max(codegen.register_allocator.highest_register, val.src_b_idx + 7);
                                    },
                                    // This is a NOP in the runtime
                                    .MOVcp, .IT_RESERVED0_C, .IT_RESERVED1_C => {},
                                    else => @compileError("unhandled op " ++ @tagName(op)),
                                },
                                Parser.Bytecode.Params.GetBuiltinMemberClass, Parser.Bytecode.Params.GetMemberClass, Parser.Bytecode.Params.GetElementClass => if (bytecode.machine_type != .void) {
                                    codegen.register_allocator.highest_register = @max(codegen.register_allocator.highest_register, val.dst_idx + bytecode.machine_type.size() - 1);
                                    codegen.register_allocator.highest_register = @max(codegen.register_allocator.highest_register, val.base_idx + 3);
                                },
                                Parser.Bytecode.Params.SetBuiltinMemberClass, Parser.Bytecode.Params.SetMemberClass, Parser.Bytecode.Params.SetElementClass => if (bytecode.machine_type != .void) {
                                    codegen.register_allocator.highest_register = @max(codegen.register_allocator.highest_register, val.src_idx + bytecode.machine_type.size() - 1);
                                    codegen.register_allocator.highest_register = @max(codegen.register_allocator.highest_register, val.base_idx + 3);
                                },
                                Parser.Bytecode.Params.NewArrayClass => {
                                    codegen.register_allocator.highest_register = @max(codegen.register_allocator.highest_register, val.dst_idx + 3);
                                    codegen.register_allocator.highest_register = @max(codegen.register_allocator.highest_register, val.size_idx + 3);
                                },
                                Parser.Bytecode.Params.ArgClass => if (bytecode.machine_type != .void) {
                                    codegen.register_allocator.highest_register = @max(codegen.register_allocator.highest_register, val.arg_idx + bytecode.machine_type.size() - 1);
                                    codegen.register_allocator.highest_register = @max(codegen.register_allocator.highest_register, val.src_idx + bytecode.machine_type.size() - 1);
                                },
                                Parser.Bytecode.Params.CallClass => if (bytecode.machine_type != .void) {
                                    codegen.register_allocator.highest_register = @max(codegen.register_allocator.highest_register, val.dst_idx + bytecode.machine_type.size() - 1);
                                },
                                Parser.Bytecode.Params.ReturnClass => if (bytecode.machine_type != .void) {
                                    codegen.register_allocator.highest_register = @max(codegen.register_allocator.highest_register, val.src_idx + bytecode.machine_type.size() - 1);
                                },
                                Parser.Bytecode.Params.WriteClass => codegen.register_allocator.highest_register = @max(codegen.register_allocator.highest_register, val.src_idx + bytecode.machine_type.size() - 1),
                                Parser.Bytecode.Params.BranchClass => switch (op) {
                                    .B => {},
                                    .BEZ,
                                    .BNEZ,
                                    => codegen.register_allocator.highest_register = @max(codegen.register_allocator.highest_register, val.src_idx),
                                    else => @compileError("unhandled op " ++ @tagName(op)),
                                },
                                Parser.Bytecode.Params.CastClass => {
                                    codegen.register_allocator.highest_register = @max(codegen.register_allocator.highest_register, val.dst_idx + 3);
                                    codegen.register_allocator.highest_register = @max(codegen.register_allocator.highest_register, val.src_idx + 3);
                                },
                                Parser.Bytecode.Params.NewObjectClass => {
                                    codegen.register_allocator.highest_register = @max(codegen.register_allocator.highest_register, val.dst_idx + 3);
                                },
                                Parser.Bytecode.Params.LoadVectorConst => {
                                    codegen.register_allocator.highest_register = @max(codegen.register_allocator.highest_register, val.dst_idx + 15);
                                },
                                Parser.Bytecode.Params.LoadLongConst => {
                                    codegen.register_allocator.highest_register = @max(codegen.register_allocator.highest_register, val.dst_idx + 7);
                                },
                                Parser.Bytecode.Params.ExternalInvokeClass => {
                                    codegen.register_allocator.highest_register = @max(codegen.register_allocator.highest_register, val.dst_idx + 3);
                                },
                                else => @compileError("unhandled type " ++ @typeName(ParamType)),
                            }

                            const serialized_bytecode: MMTypes.Bytecode = switch (ParamType) {
                                Parser.Bytecode.Params.NopClass => MMTypes.Bytecode.init(.{ .NOP = .{} }, bytecode.machine_type),
                                Parser.Bytecode.Params.LoadBoolConst => MMTypes.Bytecode.init(.{ .LCb = .{
                                    .dst_idx = val.dst_idx,
                                    .constant_idx = if (val.value) 0x80000000 else 0,
                                } }, bytecode.machine_type),
                                Parser.Bytecode.Params.LoadCharConst => MMTypes.Bytecode.init(.{
                                    .LCc = .{
                                        .dst_idx = val.dst_idx,
                                        // For boolean constant loads, it pulls the upper 16 bits of the value as the char constant
                                        .constant_idx = @as(u32, val.value) << 16,
                                    },
                                }, bytecode.machine_type),
                                Parser.Bytecode.Params.LoadIntConst => MMTypes.Bytecode.init(.{ .LCi = .{
                                    .dst_idx = val.dst_idx,
                                    .constant_idx = @bitCast(val.value),
                                } }, bytecode.machine_type),
                                Parser.Bytecode.Params.LoadFloatConst => MMTypes.Bytecode.init(.{ .LCf = .{
                                    .dst_idx = val.dst_idx,
                                    .constant_idx = @bitCast(val.value),
                                } }, bytecode.machine_type),
                                Parser.Bytecode.Params.LoadWideStringConst => MMTypes.Bytecode.init(.{ .LCsw = .{
                                    .dst_idx = val.dst_idx,
                                    .constant_idx = @intCast((try codegen.genny.w_string_table.getOrPut(val.value)).index),
                                } }, bytecode.machine_type),
                                Parser.Bytecode.Params.LoadAsciiStringConst => MMTypes.Bytecode.init(.{ .LCsa = .{
                                    .dst_idx = val.dst_idx,
                                    .constant_idx = @intCast((try codegen.genny.a_string_table.getOrPut(val.value)).index),
                                } }, bytecode.machine_type),
                                Parser.Bytecode.Params.LoadNullConst => switch (op) {
                                    .LC_NULLo, .LC_NULLsp => MMTypes.Bytecode.init(@unionInit(MMTypes.TaggedInstruction, @tagName(op), .{
                                        .dst_idx = val.dst_idx,
                                        .constant_idx = 0,
                                    }), bytecode.machine_type),
                                    else => @compileError("Shit goin bad man " ++ @tagName(op)),
                                },
                                Parser.Bytecode.Params.UnaryClass => MMTypes.Bytecode{
                                    .type = bytecode.machine_type,
                                    .op = op,
                                    .params = @bitCast(MMTypes.UnaryClass{
                                        .dst_idx = val.dst_idx,
                                        .src_idx = val.src_idx,
                                    }),
                                },
                                Parser.Bytecode.Params.BinaryClass => MMTypes.Bytecode{
                                    .type = bytecode.machine_type,
                                    .op = op,
                                    .params = @bitCast(MMTypes.BinaryClass{
                                        .dst_idx = val.dst_idx,
                                        .src_a_idx = val.src_a_idx,
                                        .src_b_idx = val.src_b_idx,
                                    }),
                                },
                                Parser.Bytecode.Params.GetBuiltinMemberClass => @panic("TODO"),
                                Parser.Bytecode.Params.SetBuiltinMemberClass => @panic("TODO"),
                                Parser.Bytecode.Params.GetMemberClass => @panic("TODO"),
                                Parser.Bytecode.Params.SetMemberClass => @panic("TODO"),
                                Parser.Bytecode.Params.GetElementClass => @panic("TODO"),
                                Parser.Bytecode.Params.SetElementClass => @panic("TODO"),
                                Parser.Bytecode.Params.NewArrayClass => @panic("TODO"),
                                Parser.Bytecode.Params.WriteClass => @panic("TODO"),
                                Parser.Bytecode.Params.ArgClass => MMTypes.Bytecode.init(.{
                                    .ARG = .{
                                        .arg_idx = val.arg_idx,
                                        .src_idx = val.src_idx,
                                    },
                                }, bytecode.machine_type),
                                Parser.Bytecode.Params.CallClass => MMTypes.Bytecode{
                                    .type = bytecode.machine_type,
                                    .op = op,
                                    .params = @bitCast(MMTypes.CallClass{
                                        .dst_idx = val.dst_idx,
                                        .call_idx = @intCast((try codegen.genny.function_references.getOrPut(
                                            MMTypes.FunctionReference{
                                                .name = @intCast((try codegen.genny.a_string_table.getOrPut(switch (val.function) {
                                                    .function => |function| function.mangled_name.?,
                                                    .initializer => ".init__",
                                                    .constructor => |constructor| constructor, //TODO: actually check this value
                                                    .name => |name| std.debug.panic("name {s} not resolved", .{name}),
                                                })).index),
                                                .type_reference = @intCast((try codegen.genny.type_references.getOrPut(codegen.genny.type_intern_pool.get(val.type).resolved.fish)).index),
                                            },
                                        )).index),
                                    }),
                                },
                                Parser.Bytecode.Params.ReturnClass => MMTypes.Bytecode.init(.{ .RET = .{
                                    .src_idx = val.src_idx,
                                } }, bytecode.machine_type),
                                Parser.Bytecode.Params.BranchClass => MMTypes.Bytecode{
                                    .type = bytecode.machine_type,
                                    .op = op,
                                    .params = @bitCast(MMTypes.BranchClass{
                                        .src_idx = val.src_idx,
                                        .branch_offset = @as(i32, @intCast(inline_asm.jump_targets.get(val.target).?)) - @as(i32, @intCast(i)),
                                    }),
                                },
                                Parser.Bytecode.Params.CastClass => @panic("TODO"),
                                Parser.Bytecode.Params.NewObjectClass => @panic("TODO"),
                                Parser.Bytecode.Params.LoadVectorConst => MMTypes.Bytecode.init(.{ .LCv4 = .{
                                    .dst_idx = val.dst_idx,
                                    .constant_idx = @intCast((try codegen.genny.f32_constants.getOrPut(val.value)).index),
                                } }, bytecode.machine_type),
                                Parser.Bytecode.Params.LoadLongConst => MMTypes.Bytecode.init(.{ .LCs64 = .{
                                    .dst_idx = val.dst_idx,
                                    .constant_idx = @intCast((try codegen.genny.s64_constants.getOrPut(val.value)).index),
                                } }, bytecode.machine_type),
                                Parser.Bytecode.Params.ExternalInvokeClass => @panic("TODO"),
                                else => @compileError("Unhandled type " ++ @typeName(ParamType)),
                            };
                            try codegen.appendBytecode(serialized_bytecode);
                        },
                    }
                }
            },
            .@"unreachable" => {
                return_or_unreachable_emit = true;

                try emitUnreachable(codegen);
            },
            else => |tag| std.debug.panic("cant codegen for block {s} yet\n", .{@tagName(tag)}),
        }
    }

    //Free all the allocated registers for these variables
    for (local_variables_from_this_scope.items) |local_variable_to_free| {
        const local_variable = function_local_variables.get(local_variable_to_free).?;

        try codegen.register_allocator.free(.{
            @intCast(local_variable.offset),
            codegen.genny.type_references.keys()[local_variable.type_reference].machine_type,
        });
        _ = scope_local_variables.swapRemove(local_variable_to_free);
    }

    if (top_level and !return_or_unreachable_emit) {
        if (return_type == .void) {
            //On void return functions, we can emit an implicit RET
            try codegen.emitRet(0, .void);
        } else {
            //On non void return functions, we need to error
            std.debug.panic("non void return function does not return at end of function!", .{});
        }
    }
}

fn emitUnreachable(codegen: *Codegen) !void {
    // Only emit unreachable in debug and release safe
    switch (codegen.compilation_options.optimization_mode) {
        .Debug, .ReleaseSafe => {},
        .ReleaseFast, .ReleaseSmall => return,
    }

    //TODO: let users force ASSERT to be used, since that can give nice names/text
    //TODO: use WRITE if available, else try to use a patched runtime to call into that game's printf,
    //      if that fails, THEN fall back to the CALLVo crash

    // Allocate a register which will just have 0
    const base_idx = try codegen.register_allocator.allocate(.object_ref);

    // Load 0 into that instruction
    try codegen.emitLoadConstInt(base_idx[0], 0);

    // Copy into a0 so that CALLVo is calling off an invalid object
    try codegen.emitArg(0, base_idx[0], .object_ref);

    // Emit a call instruction which uses a nonsense target and 0 source, causing a script exception
    try codegen.emitCallVo(0, 0, .void);

    try codegen.register_allocator.free(base_idx);
}

fn compileFunction(
    self: *Genny,
    function: union(enum) {
        function: *Parser.Node.Function,
        constructor: *Parser.Node.Constructor,
    },
    class: *Parser.Node.Class,
) !?MMTypes.FunctionDefinition {
    const initializer = blk: {
        var initializer = false;

        if (function == .function)
            for (function.function.attributes) |attribute| {
                if (attribute.* == .native_invoke)
                    return null;

                if (attribute.* == .initializer)
                    initializer = true;
            };

        break :blk initializer;
    };

    var arguments = ArgumentList.init(self.ast.allocator);
    var local_variables = LocalVariableTable.init(self.ast.allocator);
    var scope_local_variables = LocalVariableTable.init(self.ast.allocator);

    var codegen: Codegen = .{
        .bytecode = BytecodeList.init(self.ast.allocator),
        .line_numbers = LineNumberList.init(self.ast.allocator),
        .register_allocator = try Codegen.RegisterAllocator.init(
            self.ast.allocator,
            self.compilation_options,
            &local_variables,
            self,
        ),
        .compilation_options = self.compilation_options,
        .genny = self,
    };

    const modifiers = switch (function) {
        .function => |ast_function| ast_function.modifiers,
        .constructor => |constructor| constructor.modifiers,
    };

    //If the function isnt static, then we need to allocate `r0-r3` for the `this` reference
    if (!modifiers.static) {
        const self_reg = try codegen.register_allocator.allocateArgument(.object_ref);

        std.debug.assert(self_reg[0] == 0);

        const type_reference: u32 = @intCast((try self.type_references.getOrPut(class.type_reference.?)).index);

        const self_variable: MMTypes.LocalVariable = .{
            .modifiers = .{},
            .name = @intCast((try self.a_string_table.getOrPut("this")).index),
            .offset = self_reg[0],
            .type_reference = type_reference,
        };

        try local_variables.put("this", self_variable);
        try scope_local_variables.put("this", self_variable);
    }

    const parameters = switch (function) {
        .function => |ast_function| ast_function.parameters,
        .constructor => |constructor| constructor.parameters,
    };

    for (parameters) |parameter| {
        const fish_type_reference = self.type_intern_pool.get(parameter.type).resolved.valueTypeReference();

        const register = try codegen.register_allocator.allocateArgument(fish_type_reference.machine_type);
        const type_reference: u32 = @intCast((try self.type_references.getOrPut(fish_type_reference)).index);

        const parameter_variable: MMTypes.LocalVariable = .{
            .name = @intCast((try self.a_string_table.getOrPut(parameter.name)).index),
            .modifiers = .{},
            .type_reference = type_reference,
            .offset = register[0],
        };

        try local_variables.put(parameter.name, parameter_variable);
        try scope_local_variables.put(parameter.name, parameter_variable);
        try arguments.append(.{
            .type_reference = type_reference,
            .offset = register[0],
        });
    }

    switch (function) {
        .function => |ast_function| {
            //TODO: arrow expression functions
            try compileBlock(
                &codegen,
                &local_variables,
                &scope_local_variables,
                ast_function.body.?.contents.block,
                true,
                self.type_intern_pool.get(ast_function.return_type).resolved.machineType(),
            );
        },
        .constructor => |constructor| {
            //TODO: arrow expression functions
            try compileBlock(
                &codegen,
                &local_variables,
                &scope_local_variables,
                constructor.body.?.contents.block,
                true,
                .void,
            );
        },
    }

    // Safety crash after a function RET
    try emitUnreachable(&codegen);

    // Stack size is the highest used register + 1, since registers are zero indexed
    const stack_size = codegen.register_allocator.highest_register + 1;

    return .{
        .name = @intCast((try self.a_string_table.getOrPut(if (initializer)
            ".init__"
        else if (function == .constructor) blk: {
            if (parameters.len > 0)
                std.debug.panic("unable to compile constructor with parameters", .{});

            break :blk ".ctor__";
        } else function.function.mangled_name.?)).index),
        .modifiers = modifiers,
        .stack_size = stack_size,
        .type_reference = @intCast((try self.type_references.getOrPut(switch (function) {
            .function => self.type_intern_pool.get(function.function.return_type).resolved.valueTypeReference(),
            .constructor => MMTypes.TypeReference{
                .array_base_machine_type = .void,
                .dimension_count = 0,
                .fish_type = .void,
                .machine_type = .void,
                .script = null,
                .type_name = 0xFFFFFFFF,
            },
        })).index),
        .bytecode = blk: {
            const start = self.bytecode.items.len;

            try self.bytecode.appendSlice(codegen.bytecode.items);

            break :blk .{
                .begin = @intCast(start),
                .end = @intCast(start + codegen.bytecode.items.len),
            };
        },
        .arguments = blk: {
            const start = self.arguments.items.len;

            try self.arguments.appendSlice(arguments.items);

            break :blk .{
                .begin = @intCast(start),
                .end = @intCast(start + arguments.items.len),
            };
        },
        .line_numbers = blk: {
            const start = self.line_numbers.items.len;

            try self.line_numbers.appendSlice(codegen.line_numbers.items);

            break :blk .{
                .begin = @intCast(start),
                .end = @intCast(start + codegen.line_numbers.items.len),
            };
        },
        .local_variables = blk: {
            const start = self.local_variables.items.len;

            const local_variable_values = local_variables.values();
            const register_local_variables = codegen.register_allocator.register_local_variables.items;

            try self.local_variables.appendSlice(local_variable_values);
            try self.local_variables.appendSlice(register_local_variables);

            break :blk .{
                .begin = @intCast(start),
                .end = @intCast(start + local_variable_values.len + register_local_variables.len),
            };
        },
    };
}

pub fn generate(self: *Genny) !MMTypes.Script {
    for (self.ast.root_elements.items) |node| {
        //Skip non class nodes
        if (node != .class)
            continue;

        const class = node.class;

        var functions = std.ArrayList(MMTypes.FunctionDefinition).init(self.ast.allocator);

        for (class.functions) |ast_function| {
            if (try self.compileFunction(.{ .function = ast_function }, class)) |function|
                try functions.append(function);
        }

        for (class.constructors) |constructor| {
            try functions.append((try self.compileFunction(.{ .constructor = constructor }, class)).?);
        }

        // If theres no constructors, or this class is not static, then we need to create a default parameterless constructor
        if (class.constructors.len == 0 and !class.modifiers.static) {
            var local_variables = LocalVariableTable.init(self.ast.allocator);

            var codegen: Codegen = .{
                .bytecode = BytecodeList.init(self.ast.allocator),
                .line_numbers = LineNumberList.init(self.ast.allocator),
                .register_allocator = try Codegen.RegisterAllocator.init(
                    self.ast.allocator,
                    self.compilation_options,
                    &local_variables,
                    self,
                ),
                .compilation_options = self.compilation_options,
                .genny = self,
            };

            try local_variables.put("self", .{
                .modifiers = .{},
                .name = @intCast((try self.a_string_table.getOrPut("self")).index),
                .offset = 0,
                .type_reference = @intCast((try self.type_references.getOrPut(class.type_reference.?)).index),
            });

            std.debug.assert(class.type_reference.?.machine_type == .safe_ptr or class.type_reference.?.machine_type == .object_ref);

            // If the base class has a parameterless constructor, then we need to emit a "call super class"
            if (class.base_class == .resolved and class.base_class.resolved.has_parameterless_constructor) {
                try codegen.emitArg(0, 0, class.type_reference.?.machine_type);
                try codegen.emitCall(
                    std.math.maxInt(u16),
                    @intCast((try self.function_references.getOrPut(MMTypes.FunctionReference{
                        .name = @intCast((try self.a_string_table.getOrPut(".ctor__")).index),
                        .type_reference = @intCast((try self.type_references.getOrPut(class.base_class.resolved.type_reference.?)).index),
                    })).index),
                    .void,
                );
            }

            try codegen.emitRet(0, .void);

            try functions.append(MMTypes.FunctionDefinition{
                .name = @intCast((try self.a_string_table.getOrPut(".ctor__")).index),
                // This holds the self ptr
                .stack_size = 4,
                .local_variables = blk: {
                    const start = self.local_variables.items.len;

                    const local_variable_values = local_variables.values();

                    try self.local_variables.appendSlice(local_variable_values);

                    break :blk .{
                        .begin = @intCast(start),
                        .end = @intCast(start + local_variable_values.len),
                    };
                },
                .type_reference = @intCast((try self.type_references.getOrPut(MMTypes.TypeReference{
                    .array_base_machine_type = .void,
                    .dimension_count = 0,
                    .fish_type = .void,
                    .machine_type = .void,
                    .script = null,
                    .type_name = 0xFFFFFFFF,
                })).index),
                .modifiers = .{},
                .arguments = .{ .begin = 0, .end = 0 },
                .bytecode = blk: {
                    const start = self.bytecode.items.len;

                    try self.bytecode.appendSlice(codegen.bytecode.items);

                    break :blk .{
                        .begin = @intCast(start),
                        .end = @intCast(start + codegen.bytecode.items.len),
                    };
                },
                .line_numbers = blk: {
                    const start = self.line_numbers.items.len;

                    try self.line_numbers.appendSlice(codegen.line_numbers.items);

                    break :blk .{
                        .begin = @intCast(start),
                        .end = @intCast(start + codegen.line_numbers.items.len),
                    };
                },
            });
        }

        return .{
            .up_to_date_script = null,
            .class_name = class.name,
            .super_class_script = if (class.base_class == .resolved) class.base_class.resolved.ident else null,
            .modifiers = class.modifiers,
            // Convert all the GUID type references into the list of depening GUIDs
            .depending_guids = blk: {
                var depending_guids = std.ArrayList(u32).init(self.ast.allocator);

                for (self.type_references.keys()) |type_reference|
                    if (type_reference.script) |script|
                        switch (script) {
                            .guid => |guid| try depending_guids.append(guid),
                            .hash => {},
                        };

                break :blk depending_guids.items;
            },
            .functions = functions.items,
            .bytecode = self.bytecode.items,
            .arguments = self.arguments.items,
            .line_numbers = self.line_numbers.items,
            .local_variables = self.local_variables.items,
            .function_references = self.function_references.keys(),
            .constant_table_s64 = self.s64_constants.keys(),
            .constant_table_float = std.mem.bytesAsSlice(f32, std.mem.sliceAsBytes(self.f32_constants.keys())),
            .field_references = self.field_references.keys(),
            .field_definitions = blk: {
                var field_definitions = std.ArrayList(MMTypes.FieldDefinition).init(self.ast.allocator);

                for (class.fields) |field| {
                    try field_definitions.append(.{
                        .name = @intCast((try self.a_string_table.getOrPut(field.name)).index),
                        .type_reference = @intCast((try self.type_references.getOrPut(self.type_intern_pool.get(field.type).resolved.fish)).index),
                        .modifiers = field.modifiers,
                    });
                }

                break :blk try field_definitions.toOwnedSlice();
            },
            .property_definitions = blk: {
                var property_definitions = std.ArrayList(MMTypes.PropertyDefinition).init(self.ast.allocator);

                for (class.properties) |property| {
                    _ = property; // autofix
                    @panic("TODO: properties");
                    // try property_definitions.append(.{
                    //     .name = @intCast((try self.a_string_table.getOrPut(property.name)).index),
                    //     .type_reference = @intCast((try self.type_reference_table.getOrPut(property.type.resolved.runtime)).index),
                    // });
                }

                break :blk try property_definitions.toOwnedSlice();
            },
            .type_references = self.type_references.keys(),
            .a_string_table = blk: {
                var buf = std.ArrayList(u8).init(self.ast.allocator);
                var strings = std.ArrayList([:0]const u8).init(self.ast.allocator);

                for (self.a_string_table.keys()) |key| {
                    try buf.appendSlice(key);
                    try buf.append(0);
                }

                var start: usize = 0;
                for (self.a_string_table.keys()) |key| {
                    try strings.append(buf.items[start .. start + key.len :0]);

                    start += key.len + 1;
                }

                break :blk .{
                    .buf = try buf.toOwnedSlice(),
                    .strings = try strings.toOwnedSlice(),
                };
            },
            .w_string_table = blk: {
                var buf = std.ArrayList(u16).init(self.ast.allocator);
                var strings = std.ArrayList([:0]const u16).init(self.ast.allocator);

                for (self.w_string_table.keys()) |key| {
                    try buf.appendSlice(key);
                    try buf.append(0);
                }

                var start: usize = 0;
                for (self.w_string_table.keys()) |key| {
                    try strings.append(buf.items[start .. start + key.len :0]);

                    start += key.len + 1;
                }

                break :blk .{
                    .buf = try buf.toOwnedSlice(),
                    .strings = try strings.toOwnedSlice(),
                };
            },
        };
    }

    @panic("no class?");
}

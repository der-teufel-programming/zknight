const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = @import("parser.zig").Ast;
const Node = Ast.Node;
// const Ast = []const Node;
const analyzer = @import("analyzer.zig");
const VM = @import("VM.zig");

const assert = std.debug.assert;

pub const Code = struct {
    code: std.ArrayListUnmanaged(VM.Instr) = .{},
    blocks: std.ArrayListUnmanaged([]const VM.Instr) = .{},
    constants: std.ArrayListUnmanaged(VM.Value) = .{},
    variable_count: usize = 0,

    pub fn deinit(self: *Code, gpa: Allocator) void {
        self.code.deinit(gpa);
        for (self.blocks.items) |block| {
            gpa.free(block);
        }
        self.blocks.deinit(gpa);
        self.constants.deinit(gpa);
    }

    pub fn loadInto(self: *Code, gpa: Allocator, vm: *VM) !void {
        vm.blocks = try self.blocks.toOwnedSlice(gpa);
        vm.code = try self.code.toOwnedSlice(gpa);
        vm.variables = try gpa.alloc(VM.Value, self.variable_count);
        @memset(vm.variables, .null);
        vm.constants = try self.constants.toOwnedSlice(gpa);
    }

    pub fn append(
        self: *Code,
        gpa: Allocator,
        instr: VM.Instr,
    ) !void {
        try self.code.append(gpa, instr);
    }

    pub fn appendBlock(
        self: *Code,
        gpa: Allocator,
        block: []const VM.Instr,
    ) !void {
        try self.blocks.append(gpa, block);
    }

    pub fn extendBlocks(
        self: *Code,
        gpa: Allocator,
        blocks: []const []const VM.Instr,
    ) !void {
        try self.blocks.appendSlice(gpa, blocks);
    }

    pub fn appendConstant(
        self: *Code,
        gpa: Allocator,
        constant: VM.Value,
    ) !void {
        try self.constants.append(gpa, constant);
    }

    pub fn extendConsts(
        self: *Code,
        gpa: Allocator,
        consts: []const VM.Value,
    ) !void {
        try self.constants.appendSlice(gpa, consts);
    }

    pub fn codeSlice(
        self: *Code,
        gpa: Allocator,
    ) ![]const VM.Instr {
        return self.code.toOwnedSlice(gpa);
    }

    pub fn blocksSlice(
        self: *Code,
        gpa: Allocator,
    ) ![]const []const VM.Instr {
        return self.blocks.toOwnedSlice(gpa);
    }

    pub fn constSlice(
        self: *Code,
        gpa: Allocator,
    ) ![]const VM.Value {
        return self.constants.toOwnedSlice(gpa);
    }
};

pub const EmitError = Allocator.Error || std.fmt.ParseIntError || error{InvalidStoreDestination};

pub const Emitter = struct {
    ast: Ast,
    code: Code,
    info: analyzer.Info,

    pub fn init(ast: Ast, info: analyzer.Info) Emitter {
        return .{
            .ast = ast,
            .code = .{},
            .info = info,
        };
    }

    pub fn deinit(e: *Emitter, gpa: std.mem.Allocator) void {
        e.code.deinit(gpa);
        e.* = undefined;
    }

    pub fn emit(e: *Emitter, gpa: std.mem.Allocator, vm: *VM) EmitError!void {
        e.code.variable_count = e.info.variables.count();
        if (e.ast.nodes.len == 0) return;

        try e.emitInner(gpa, 0);

        try e.code.loadInto(gpa, vm);
    }

    fn emitInner(e: *Emitter, gpa: std.mem.Allocator, instr_idx: usize) EmitError!void {
        const tags = e.ast.nodes.items(.tag);
        switch (tags[instr_idx]) {
            .function_at,
            .function_T,
            .function_F,
            .function_N,
            .function_P,
            .function_R,
            .function_colon,
            .function_bang,
            .function_tilde,
            .function_comma,
            .function_r_bracket,
            .function_l_bracket,
            .function_A,
            .function_B,
            .function_C,
            .function_D,
            .function_L,
            .function_O,
            .function_Q,
            .function_plus,
            .function_minus,
            .function_star,
            .function_slash,
            .function_ampersand,
            .function_percent,
            .function_caret,
            .function_less,
            .function_greater,
            .function_question_mark,
            .function_pipe,
            .function_semicolon,
            .function_equal,
            .function_W,
            .function_I,
            .function_G,
            .function_S,
            => try e.emitFunction(gpa, instr_idx),
            .identifier => try e.emitLoad(gpa, instr_idx),
            .integer_literal,
            .string_literal,
            => try e.emitConstant(gpa, instr_idx),
        }
    }

    fn emitStore(e: *Emitter, gpa: std.mem.Allocator, instr_idx: usize) !void {
        const tags = e.ast.nodes.items(.tag);

        assert(tags[instr_idx] == .function_equal);

        const data = e.ast.nodes.items(.data);

        const arguments = data[instr_idx].getNodes(e.ast.node_data);

        const var_idx = arguments[0];
        if (tags[var_idx] != .identifier) return error.InvalidStoreDestination;

        const var_name = data[var_idx].getBytes(e.ast.string_data);
        const idx = e.info.variables.get(var_name).?;
        try e.emitInner(gpa, arguments[1]);
        try e.code.append(gpa, .{ .store_variable = idx });
    }

    fn emitLoad(e: *Emitter, gpa: std.mem.Allocator, instr_idx: usize) !void {
        const tags = e.ast.nodes.items(.tag);
        assert(tags[instr_idx] == .identifier);

        const var_name = e.ast.nodes.items(.data)[instr_idx].getBytes(e.ast.string_data);
        const idx = e.info.variables.get(var_name).?;
        try e.code.append(gpa, .{ .load_variable = idx });
    }

    fn emitConstant(e: *Emitter, gpa: std.mem.Allocator, instr_idx: usize) !void {
        const constant = e.ast.nodes.get(instr_idx);
        assert(constant.tag == .integer_literal or constant.tag == .string_literal);

        const data = constant.data.getBytes(e.ast.string_data);

        const const_idx = e.code.constants.items.len;
        switch (constant.tag) {
            .string_literal => {
                const bytes = try gpa.dupe(u8, data);
                try e.code.appendConstant(gpa, .{ .string = bytes });
            },
            .integer_literal => {
                const number = try std.fmt.parseInt(isize, data, 10);
                try e.code.appendConstant(gpa, .{ .number = number });
            },
            else => unreachable,
        }
        try e.code.append(gpa, .{ .constant = @intCast(const_idx) });
    }

    fn emitNullary(e: *Emitter, gpa: std.mem.Allocator, instr_idx: usize) !void {
        const func = e.ast.nodes.get(instr_idx);
        assert(func.tag.arity().? == 0);

        try e.code.append(
            gpa,
            switch (func.tag) {
                .function_at => .empty_list,
                .function_T => .true,
                .function_F => .false,
                .function_N => .null,
                .function_P => .prompt,
                .function_R => .random,
                else => unreachable,
            },
        );
    }

    fn emitUnary(e: *Emitter, gpa: std.mem.Allocator, instr_idx: usize) !void {
        const func = e.ast.nodes.get(instr_idx);
        assert(func.tag.arity().? == 1);

        const arg = func.data.getNodes(e.ast.node_data)[0];
        if (func.tag == .function_B) {
            try e.emitBlock(gpa, arg);
        } else {
            if (func.tag == .function_O and e.ast.nodes.get(arg).tag == .identifier) {
                try e.code.append(gpa, .invalid);
                return;
            }
            try e.emitInner(gpa, arg);

            switch (func.tag) {
                // ':', '!', '~', ',', '[', ']', 'A', 'B', 'C', 'D', 'L', 'O', 'Q'
                .function_colon => {},
                .function_bang => try e.code.append(gpa, .not),
                .function_tilde => try e.code.append(gpa, .negate),
                .function_comma => try e.code.append(gpa, .box),
                .function_l_bracket => try e.code.append(gpa, .head),
                .function_r_bracket => try e.code.append(gpa, .tail),
                .function_A => try e.code.append(gpa, .ascii),
                .function_B => unreachable,
                .function_C => try e.code.append(gpa, .call),
                .function_D => try e.code.append(gpa, .dump),
                .function_L => try e.code.append(gpa, .length),
                .function_O => try e.code.append(gpa, .output),
                .function_Q => try e.code.append(gpa, .quit),
                else => unreachable,
            }
        }
    }

    fn emitBinary(e: *Emitter, gpa: std.mem.Allocator, instr_idx: usize) !void {
        const func = e.ast.nodes.get(instr_idx);
        assert(func.tag.arity().? == 2);

        const args = func.data.getNodes(e.ast.node_data);
        switch (func.tag) {
            .function_W => {
                const cond = args[0];
                const body = args[1];

                if (e.code.code.items.len == 0) try e.code.append(gpa, .nop);

                const cond_idx = e.code.code.items.len;
                try e.emitInner(gpa, cond);

                const cond_jump_idx = e.code.code.items.len;
                try e.code.append(gpa, .{ .cond = undefined });

                try e.emitInner(gpa, body);
                try e.code.append(gpa, .drop);
                const loop_end_idx = e.code.code.items.len;
                try e.code.append(gpa, .{ .jump = cond_idx - 1 });
                e.code.code.items[cond_jump_idx].cond = loop_end_idx;
                try e.code.append(gpa, .null);
            },
            .function_semicolon => {
                try e.emitInner(gpa, args[0]);
                try e.code.append(gpa, .drop);
                try e.emitInner(gpa, args[1]);
            },
            .function_equal => {
                try e.emitStore(gpa, instr_idx);
            },
            .function_ampersand => {
                try e.emitInner(gpa, args[0]);
                try e.code.append(gpa, .dupe);
                const cond_idx = e.code.code.items.len;
                try e.code.append(gpa, .{ .cond = undefined });
                try e.code.append(gpa, .drop);
                try e.emitInner(gpa, args[1]);
                e.code.code.items[cond_idx].cond = e.code.code.items.len - 1;
            },
            .function_pipe => {
                try e.emitInner(gpa, args[0]);
                try e.code.append(gpa, .dupe);
                try e.code.append(gpa, .not);
                const cond_idx = e.code.code.items.len;
                try e.code.append(gpa, .{ .cond = undefined });
                try e.code.append(gpa, .drop);
                try e.emitInner(gpa, args[1]);
                e.code.code.items[cond_idx].cond = e.code.code.items.len - 1;
            },
            else => {
                for (args) |arg_idx| {
                    try e.emitInner(gpa, arg_idx);
                }
                switch (func.tag) {
                    .function_W => unreachable,
                    .function_semicolon => unreachable,
                    .function_equal => unreachable,
                    .function_plus => try e.code.append(gpa, .add),
                    .function_minus => try e.code.append(gpa, .sub),
                    .function_star => try e.code.append(gpa, .mult),
                    .function_slash => try e.code.append(gpa, .div),
                    .function_ampersand => try e.code.append(gpa, .andthen),
                    .function_percent => try e.code.append(gpa, .mod),
                    .function_caret => try e.code.append(gpa, .exp),
                    .function_less => try e.code.append(gpa, .less),
                    .function_greater => try e.code.append(gpa, .greater),
                    .function_question_mark => try e.code.append(gpa, .equal),
                    .function_pipe => try e.code.append(gpa, .orthen),
                    else => unreachable,
                }
            },
        }
    }

    fn emitTernary(e: *Emitter, gpa: Allocator, instr_idx: usize) !void {
        const func = e.ast.nodes.get(instr_idx);
        assert(func.tag.arity().? == 3);

        const args = func.data.getNodes(e.ast.node_data);

        switch (func.tag) {
            .function_I => {
                const cond = args[0];
                const if_true = args[1];
                const if_false = args[2];
                try e.emitInner(gpa, cond);
                const cond_idx = e.code.code.items.len;
                try e.code.append(gpa, .{ .cond = undefined });
                try e.emitInner(gpa, if_true);
                const if_true_end = e.code.code.items.len;
                try e.code.append(gpa, .{ .jump = undefined });
                e.code.code.items[cond_idx].cond = if_true_end;
                try e.emitInner(gpa, if_false);
                e.code.code.items[if_true_end].jump = e.code.code.items.len - 1;
            },
            .function_G => {
                const arg = args[0];
                const idx = args[1];
                const len = args[2];
                try e.emitInner(gpa, arg);
                try e.emitInner(gpa, idx);
                try e.emitInner(gpa, len);
                try e.code.append(gpa, .get);
            },
            else => unreachable,
        }
    }

    fn emitQuaternary(e: *Emitter, gpa: Allocator, instr_idx: usize) !void {
        const func = e.ast.nodes.get(instr_idx);
        assert(func.tag.arity().? == 4);
        assert(func.tag == .function_S);
        const args = func.data.getNodes(e.ast.node_data);
        for (args) |arg| {
            try e.emitInner(gpa, arg);
        }

        try e.code.append(gpa, .set);
    }

    fn emitFunction(e: *Emitter, gpa: std.mem.Allocator, instr_idx: usize) !void {
        switch (e.ast.nodes.items(.tag)[instr_idx].arity() orelse return) {
            0 => try e.emitNullary(gpa, instr_idx),
            1 => try e.emitUnary(gpa, instr_idx),
            2 => try e.emitBinary(gpa, instr_idx),
            3 => try e.emitTernary(gpa, instr_idx),
            4 => try e.emitQuaternary(gpa, instr_idx),
            else => unreachable,
        }
    }

    fn emitBlock(e: *Emitter, gpa: std.mem.Allocator, instr_idx: usize) !void {
        var new_emitter = Emitter.init(e.ast, e.info);
        defer new_emitter.deinit(gpa);

        try new_emitter.emitInner(gpa, instr_idx);

        const next_block_idx = e.code.blocks.items.len;
        const next_const_idx = e.code.constants.items.len;
        for (new_emitter.code.code.items, 0..) |instr, idx| {
            switch (instr) {
                .block => new_emitter.code.code.items[idx].block += @intCast(next_block_idx),
                .constant => new_emitter.code.code.items[idx].constant += @intCast(next_const_idx),
                else => {},
            }
        }

        try e.code.extendConsts(gpa, new_emitter.code.constants.items);
        try e.code.extendBlocks(gpa, new_emitter.code.blocks.items);
        const block_idx = e.code.blocks.items.len;
        try e.code.appendBlock(gpa, try new_emitter.code.codeSlice(gpa));
        try e.code.append(gpa, .{ .block = @intCast(block_idx) });
    }
};

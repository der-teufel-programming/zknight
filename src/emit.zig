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
    alloc: Allocator,

    pub fn init(alloc: Allocator) Code {
        return .{
            .alloc = alloc,
        };
    }

    pub fn deinit(self: *Code) void {
        self.code.deinit(self.alloc);
        for (self.blocks.items) |block| {
            self.alloc.free(block);
        }
        self.blocks.deinit(self.alloc);
        for (self.constants.items) |cons| {
            cons.free(self.alloc);
        }
        self.constants.deinit(self.alloc);
    }

    pub fn loadInto(self: *Code, vm: *VM) !void {
        vm.blocks = try self.blocks.toOwnedSlice(self.alloc);
        vm.code = try self.code.toOwnedSlice(self.alloc);
        vm.variables = try self.alloc.alloc(VM.Value, self.variable_count);
        vm.constants = try self.constants.toOwnedSlice(self.alloc);
    }

    pub fn append(self: *Code, instr: VM.Instr) !void {
        try self.code.append(self.alloc, instr);
    }

    pub fn appendBlock(self: *Code, block: []const VM.Instr) !void {
        try self.blocks.append(self.alloc, block);
    }

    pub fn extendBlocks(self: *Code, blocks: []const []const VM.Instr) !void {
        try self.blocks.appendSlice(self.alloc, blocks);
    }

    pub fn appendConstant(self: *Code, constant: VM.Value) !void {
        try self.constants.append(self.alloc, constant);
    }

    pub fn extendConsts(self: *Code, consts: []const VM.Value) !void {
        try self.constants.appendSlice(self.alloc, consts);
    }

    pub fn codeSlice(self: *Code) ![]const VM.Instr {
        return self.code.toOwnedSlice(self.alloc);
    }

    pub fn blocksSlice(self: *Code) ![]const []const VM.Instr {
        return self.blocks.toOwnedSlice(self.alloc);
    }

    pub fn constSlice(self: *Code) ![]const VM.Value {
        return self.constants.toOwnedSlice(self.alloc);
    }
};

pub const EmitError = Allocator.Error || std.fmt.ParseIntError || error{InvalidStoreDestination};

pub const Emitter = struct {
    ast: Ast,
    gpa: Allocator,
    code: Code,
    info: analyzer.Info,

    pub fn init(ast: Ast, gpa: Allocator) !Emitter {
        return .{
            .ast = ast,
            .gpa = gpa,
            .code = Code.init(gpa),
            .info = try analyzer.analyze(ast, gpa),
        };
    }

    pub fn deinit(e: *Emitter) void {
        e.code.deinit();
        e.info.deinit();
        e.* = undefined;
    }

    pub fn emit(e: *Emitter, vm: *VM) EmitError!void {
        e.code.variable_count = e.info.variables.count();
        if (e.ast.nodes.len == 0) return;

        try e.emitInner(0);

        try e.code.loadInto(vm);
    }

    fn emitInner(e: *Emitter, instr_idx: usize) EmitError!void {
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
            => try e.emitFunction(instr_idx),
            .identifier => try e.emitLoad(instr_idx),
            .integer_literal,
            .string_literal,
            => try e.emitConstant(instr_idx),
        }
    }

    fn emitStore(e: *Emitter, instr_idx: usize) !void {
        const tags = e.ast.nodes.items(.tag);

        assert(tags[instr_idx] == .function_equal);

        const data = e.ast.nodes.items(.data);

        const arguments = data[instr_idx].getNodes(e.ast.node_data);

        const var_idx = arguments[0];
        if (tags[var_idx] != .identifier) return error.InvalidStoreDestination;

        const var_name = data[var_idx].getBytes(e.ast.string_data);
        const idx = e.info.variables.get(var_name).?;
        try e.emitInner(arguments[1]);
        try e.code.append(.{ .store_variable = idx });
    }

    fn emitLoad(e: *Emitter, instr_idx: usize) !void {
        const tags = e.ast.nodes.items(.tag);
        assert(tags[instr_idx] == .identifier);

        const var_name = e.ast.nodes.items(.data)[instr_idx].getBytes(e.ast.string_data);
        const idx = e.info.variables.get(var_name).?;
        try e.code.append(.{ .load_variable = idx });
    }

    fn emitConstant(e: *Emitter, instr_idx: usize) !void {
        const constant = e.ast.nodes.get(instr_idx);
        assert(constant.tag == .integer_literal or constant.tag == .string_literal);

        const data = constant.data.getBytes(e.ast.string_data);

        const const_idx = e.code.constants.items.len;
        switch (constant.tag) {
            .string_literal => {
                const bytes = try e.code.alloc.dupe(u8, data);
                try e.code.appendConstant(.{ .string = bytes });
            },
            .integer_literal => {
                const number = try std.fmt.parseInt(isize, data, 10);
                try e.code.appendConstant(.{ .number = number });
            },
            else => unreachable,
        }
        try e.code.append(.{ .constant = @intCast(const_idx) });
    }

    fn emitNullary(e: *Emitter, instr_idx: usize) !void {
        const func = e.ast.nodes.get(instr_idx);
        assert(func.tag.arity().? == 0);

        try e.code.append(switch (func.tag) {
            .function_at => .empty_list,
            .function_T => .true,
            .function_F => .false,
            .function_N => .null,
            .function_P => .prompt,
            .function_R => .random,
            else => unreachable,
        });
    }

    fn emitUnary(e: *Emitter, instr_idx: usize) !void {
        const func = e.ast.nodes.get(instr_idx);
        assert(func.tag.arity().? == 1);

        const arg = func.data.getNodes(e.ast.node_data)[0];
        if (func.tag == .function_B) {
            try e.emitBlock(arg);
        } else {
            if (func.tag == .function_O and e.ast.nodes.get(arg).tag == .identifier) {
                try e.code.append(.invalid);
                return;
            }
            try e.emitInner(arg);

            switch (func.tag) {
                // ':', '!', '~', ',', '[', ']', 'A', 'B', 'C', 'D', 'L', 'O', 'Q'
                .function_colon => {},
                .function_bang => try e.code.append(.not),
                .function_tilde => try e.code.append(.negate),
                .function_comma => try e.code.append(.box),
                .function_l_bracket => try e.code.append(.head),
                .function_r_bracket => try e.code.append(.tail),
                .function_A => try e.code.append(.ascii),
                .function_B => unreachable,
                .function_C => try e.code.append(.call),
                .function_D => try e.code.append(.dump),
                .function_L => try e.code.append(.length),
                .function_O => try e.code.append(.output),
                .function_Q => try e.code.append(.quit),
                else => unreachable,
            }
        }
    }

    fn emitBinary(e: *Emitter, instr_idx: usize) !void {
        const func = e.ast.nodes.get(instr_idx);
        assert(func.tag.arity().? == 2);

        const args = func.data.getNodes(e.ast.node_data);
        switch (func.tag) {
            .function_W => {
                const cond = args[0];
                const body = args[1];

                if (e.code.code.items.len == 0) try e.code.append(.nop);

                const cond_idx = e.code.code.items.len;
                try e.emitInner(cond);

                const cond_jump_idx = e.code.code.items.len;
                try e.code.append(.{ .cond = undefined });

                try e.emitInner(body);
                try e.code.append(.drop);
                const loop_end_idx = e.code.code.items.len;
                try e.code.append(.{ .jump = cond_idx - 1 });
                e.code.code.items[cond_jump_idx].cond = loop_end_idx;
                try e.code.append(.null);
            },
            .function_semicolon => {
                try e.emitInner(args[0]);
                try e.code.append(.drop);
                try e.emitInner(args[1]);
            },
            .function_equal => {
                try e.emitStore(instr_idx);
            },
            .function_ampersand => {
                try e.emitInner(args[0]);
                try e.code.append(.dupe);
                const cond_idx = e.code.code.items.len;
                try e.code.append(.{ .cond = undefined });
                try e.code.append(.drop);
                try e.emitInner(args[1]);
                e.code.code.items[cond_idx].cond = e.code.code.items.len - 1;
            },
            .function_pipe => {
                try e.emitInner(args[0]);
                try e.code.append(.dupe);
                try e.code.append(.not);
                const cond_idx = e.code.code.items.len;
                try e.code.append(.{ .cond = undefined });
                try e.code.append(.drop);
                try e.emitInner(args[1]);
                e.code.code.items[cond_idx].cond = e.code.code.items.len - 1;
            },
            else => {
                for (args) |arg_idx| {
                    try e.emitInner(arg_idx);
                }
                switch (func.tag) {
                    .function_W => unreachable,
                    .function_semicolon => unreachable,
                    .function_equal => unreachable,
                    .function_plus => try e.code.append(.add),
                    .function_minus => try e.code.append(.sub),
                    .function_star => try e.code.append(.mult),
                    .function_slash => try e.code.append(.div),
                    .function_ampersand => try e.code.append(.andthen),
                    .function_percent => try e.code.append(.mod),
                    .function_caret => try e.code.append(.exp),
                    .function_less => try e.code.append(.less),
                    .function_greater => try e.code.append(.greater),
                    .function_question_mark => try e.code.append(.equal),
                    .function_pipe => try e.code.append(.orthen),
                    else => unreachable,
                }
            },
        }
    }

    fn emitTernary(e: *Emitter, instr_idx: usize) !void {
        const func = e.ast.nodes.get(instr_idx);
        assert(func.tag.arity().? == 3);

        const args = func.data.getNodes(e.ast.node_data);

        switch (func.tag) {
            .function_I => {
                const cond = args[0];
                const if_true = args[1];
                const if_false = args[2];
                try e.emitInner(cond);
                const cond_idx = e.code.code.items.len;
                try e.code.append(.{ .cond = undefined });
                try e.emitInner(if_true);
                const if_true_end = e.code.code.items.len;
                try e.code.append(.{ .jump = undefined });
                e.code.code.items[cond_idx].cond = if_true_end;
                try e.emitInner(if_false);
                e.code.code.items[if_true_end].jump = e.code.code.items.len - 1;
            },
            .function_G => {
                const arg = args[0];
                const idx = args[1];
                const len = args[2];
                try e.emitInner(arg);
                try e.emitInner(idx);
                try e.emitInner(len);
                try e.code.append(.get);
            },
            else => unreachable,
        }
    }

    fn emitQuaternary(e: *Emitter, instr_idx: usize) !void {
        const func = e.ast.nodes.get(instr_idx);
        assert(func.tag.arity().? == 4);
        assert(func.tag == .function_S);
        const args = func.data.getNodes(e.ast.node_data);
        for (args) |arg| {
            try e.emitInner(arg);
        }

        try e.code.append(.set);
    }

    fn emitFunction(e: *Emitter, instr_idx: usize) !void {
        switch (e.ast.nodes.items(.tag)[instr_idx].arity() orelse return) {
            0 => try e.emitNullary(instr_idx),
            1 => try e.emitUnary(instr_idx),
            2 => try e.emitBinary(instr_idx),
            3 => try e.emitTernary(instr_idx),
            4 => try e.emitQuaternary(instr_idx),
            else => unreachable,
        }
    }

    fn emitBlock(e: *Emitter, instr_idx: usize) !void {
        var new_emitter = try Emitter.init(e.ast, e.gpa);
        defer new_emitter.deinit();

        try new_emitter.emitInner(instr_idx);

        const next_block_idx = e.code.blocks.items.len;
        const next_const_idx = e.code.constants.items.len;
        for (new_emitter.code.code.items, 0..) |instr, idx| {
            switch (instr) {
                .block => new_emitter.code.code.items[idx].block += @intCast(next_block_idx),
                .constant => new_emitter.code.code.items[idx].constant += @intCast(next_const_idx),
                else => {},
            }
        }

        try e.code.extendConsts(try new_emitter.code.constSlice());
        try e.code.extendBlocks(try new_emitter.code.blocksSlice());
        const block_idx = e.code.blocks.items.len;
        try e.code.appendBlock(try new_emitter.code.codeSlice());
        try e.code.append(.{ .block = @intCast(block_idx) });
    }
};

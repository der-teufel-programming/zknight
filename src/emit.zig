const std = @import("std");
const Allocator = std.mem.Allocator;
const parser = @import("parser.zig");
const Node = parser.Node;
const Ast = []const Node;
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
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Code) void {
        self.code.deinit(self.alloc);
        self.blocks.deinit(self.alloc);
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

pub fn emit(ast: Ast, alloc: Allocator, vm: *VM) !void {
    var code = Code.init(alloc);
    defer code.deinit();

    var info = try analyzer.analyze(ast, alloc);
    defer info.deinit();

    code.variable_count = info.variables.count();
    if (ast.len == 0) return;
    try emitInner(0, ast, &code, info);

    try code.loadInto(vm);
}

fn emitInner(instr_idx: usize, ast: Ast, code: *Code, info: analyzer.Info) (Allocator.Error || std.fmt.ParseIntError)!void {
    switch (ast[instr_idx].tag) {
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
        => try emitFunction(instr_idx, ast, code, info),
        .identifier => try emitLoad(instr_idx, ast, code, info),
        .number_literal,
        .string_literal,
        => try emitConstant(instr_idx, ast, code, info),
    }
}

fn emitStore(instr_idx: usize, ast: Ast, code: *Code, info: analyzer.Info) !void {
    assert(ast[instr_idx].tag == .function_equal);

    const var_idx = ast[instr_idx].data.arguments[0];
    assert(ast[var_idx].tag == .identifier);

    const var_name = ast[var_idx].data.bytes;
    const idx = info.variables.get(var_name).?;
    try emitInner(ast[instr_idx].data.arguments[1], ast, code, info);
    try code.append(.{ .store_variable = idx });
}

fn emitLoad(instr_idx: usize, ast: Ast, code: *Code, info: analyzer.Info) !void {
    assert(ast[instr_idx].tag == .identifier);

    const var_name = ast[instr_idx].data.bytes;
    const idx = info.variables.get(var_name).?;
    try code.append(.{ .load_variable = idx });
}
fn emitConstant(instr_idx: usize, ast: Ast, code: *Code, info: analyzer.Info) !void {
    _ = info;
    const constant = ast[instr_idx];
    assert(constant.tag == .number_literal or constant.tag == .string_literal);

    const const_idx = code.constants.items.len;
    switch (constant.tag) {
        .string_literal => {
            const bytes = try code.alloc.dupe(u8, constant.data.bytes);
            try code.appendConstant(.{ .string = bytes });
        },
        .number_literal => {
            const number = try std.fmt.parseInt(isize, constant.data.bytes, 10);
            try code.appendConstant(.{ .number = number });
        },
        else => unreachable,
    }
    try code.append(.{ .constant = @intCast(const_idx) });
}

fn emitNullary(instr_idx: usize, ast: Ast, code: *Code, info: analyzer.Info) !void {
    _ = info;
    const func = ast[instr_idx].tag;
    assert(func.arity().? == 0);

    switch (func) {
        .function_at => try code.append(.empty_list),
        .function_T => try code.append(.true),
        .function_F => try code.append(.false),
        .function_N => try code.append(.null),
        .function_P => try code.append(.prompt),
        .function_R => try code.append(.random),
        else => unreachable,
    }
}

fn emitUnary(instr_idx: usize, ast: Ast, code: *Code, info: analyzer.Info) !void {
    const func = ast[instr_idx].tag;
    assert(func.arity().? == 1);

    const arg = ast[instr_idx].data.arguments[0];
    if (func == .function_B) {
        try emitBlock(arg, ast, code, info);
    } else {
        try emitInner(arg, ast, code, info);

        switch (func) {
            // ':', '!', '~', ',', '[', ']', 'A', 'B', 'C', 'D', 'L', 'O', 'Q'
            .function_colon => {},
            .function_bang => try code.append(.not),
            .function_tilde => try code.append(.negate),
            .function_comma => try code.append(.box),
            .function_l_bracket => try code.append(.head),
            .function_r_bracket => try code.append(.tail),
            .function_A => try code.append(.ascii),
            .function_B => unreachable,
            .function_C => try code.append(.call),
            .function_D => try code.append(.dump),
            .function_L => try code.append(.length),
            .function_O => try code.append(.output),
            .function_Q => try code.append(.quit),
            else => unreachable,
        }
    }
}

fn emitBinary(instr_idx: usize, ast: Ast, code: *Code, info: analyzer.Info) !void {
    const func = ast[instr_idx].tag;
    assert(func.arity().? == 2);

    if (func == .function_W) {
        const args = ast[instr_idx].data.arguments;
        const cond = args[0];
        const body = args[1];

        if (code.code.items.len == 0) try code.append(.nop);

        const cond_idx = code.code.items.len;
        try emitInner(cond, ast, code, info);

        const cond_jump_idx = code.code.items.len;
        try code.append(.{ .cond = undefined });

        try emitInner(body, ast, code, info);
        try code.append(.drop);
        const loop_end_idx = code.code.items.len;
        try code.append(.{ .jump = cond_idx - 1 });
        code.code.items[cond_jump_idx].cond = loop_end_idx;
        try code.append(.null);
    } else if (func == .function_semicolon) {
        const args = ast[instr_idx].data.arguments;
        try emitInner(args[0], ast, code, info);
        try code.append(.drop);
        try emitInner(args[1], ast, code, info);
    } else if (func == .function_equal) {
        try emitStore(instr_idx, ast, code, info);
    } else if (func == .function_ampersand) {
        const args = ast[instr_idx].data.arguments;
        try emitInner(args[0], ast, code, info);
        try code.append(.dupe);
        const cond_idx = code.code.items.len;
        try code.append(.{ .cond = undefined });
        try code.append(.drop);
        try emitInner(args[1], ast, code, info);
        code.code.items[cond_idx].cond = code.code.items.len - 1;
    } else if (func == .function_pipe) {
        const args = ast[instr_idx].data.arguments;
        try emitInner(args[0], ast, code, info);
        try code.append(.dupe);
        try code.append(.not);
        const cond_idx = code.code.items.len;
        try code.append(.{ .cond = undefined });
        try code.append(.drop);
        try emitInner(args[1], ast, code, info);
        code.code.items[cond_idx].cond = code.code.items.len - 1;
    } else {
        const args = ast[instr_idx].data.arguments;
        for (args) |arg_idx| {
            try emitInner(arg_idx, ast, code, info);
        }
        switch (func) {
            .function_W => unreachable,
            .function_semicolon => unreachable,
            .function_equal => unreachable,
            .function_plus => try code.append(.add),
            .function_minus => try code.append(.sub),
            .function_star => try code.append(.mult),
            .function_slash => try code.append(.div),
            .function_ampersand => try code.append(.andthen),
            .function_percent => try code.append(.mod),
            .function_caret => try code.append(.exp),
            .function_less => try code.append(.less),
            .function_greater => try code.append(.greater),
            .function_question_mark => try code.append(.equal),
            .function_pipe => try code.append(.orthen),
            else => unreachable,
        }
    }
}

fn emitTernary(instr_idx: usize, ast: Ast, code: *Code, info: analyzer.Info) !void {
    const func = ast[instr_idx].tag;
    assert(func.arity().? == 3);
    switch (func) {
        .function_I => {
            const cond = ast[instr_idx].data.arguments[0];
            const if_true = ast[instr_idx].data.arguments[1];
            const if_false = ast[instr_idx].data.arguments[2];
            try emitInner(cond, ast, code, info);
            const cond_idx = code.code.items.len;
            try code.append(.{ .cond = undefined });
            try emitInner(if_true, ast, code, info);
            const if_true_end = code.code.items.len;
            try code.append(.{ .jump = undefined });
            code.code.items[cond_idx].cond = if_true_end;
            try emitInner(if_false, ast, code, info);
            code.code.items[if_true_end].jump = code.code.items.len - 1;
        },
        .function_G => {
            const arg = ast[instr_idx].data.arguments[0];
            const idx = ast[instr_idx].data.arguments[1];
            const len = ast[instr_idx].data.arguments[2];
            try emitInner(arg, ast, code, info);
            try emitInner(idx, ast, code, info);
            try emitInner(len, ast, code, info);
            try code.append(.get);
        },
        else => unreachable,
    }
}

fn emitQuaternary(instr_idx: usize, ast: Ast, code: *Code, info: analyzer.Info) !void {
    const func = ast[instr_idx].tag;
    assert(func.arity().? == 4);
    assert(func == .function_S);
    const arg = ast[instr_idx].data.arguments[0];
    const idx = ast[instr_idx].data.arguments[1];
    const len = ast[instr_idx].data.arguments[2];
    const new = ast[instr_idx].data.arguments[3];
    try emitInner(arg, ast, code, info);
    try emitInner(idx, ast, code, info);
    try emitInner(len, ast, code, info);
    try emitInner(new, ast, code, info);

    try code.append(.set);
}

fn emitFunction(instr_idx: usize, ast: Ast, code: *Code, info: analyzer.Info) !void {
    switch (ast[instr_idx].tag.arity() orelse return) {
        0 => try emitNullary(instr_idx, ast, code, info),
        1 => try emitUnary(instr_idx, ast, code, info),
        2 => try emitBinary(instr_idx, ast, code, info),
        3 => try emitTernary(instr_idx, ast, code, info),
        4 => try emitQuaternary(instr_idx, ast, code, info),
        else => unreachable,
    }
}

fn emitBlock(instr_idx: usize, ast: Ast, code: *Code, info: analyzer.Info) !void {
    var new_code = Code.init(code.alloc);
    defer new_code.deinit();

    try emitInner(instr_idx, ast, &new_code, info);

    const next_block_idx = code.blocks.items.len;
    const next_const_idx = code.constants.items.len;
    for (new_code.code.items, 0..) |instr, idx| {
        switch (instr) {
            .block => new_code.code.items[idx].block += @intCast(next_block_idx),
            .constant => new_code.code.items[idx].constant += @intCast(next_const_idx),
            else => {},
        }
    }

    try code.extendConsts(try new_code.constSlice());
    try code.extendBlocks(try new_code.blocksSlice());
    const block_idx = code.blocks.items.len;
    try code.appendBlock(try new_code.codeSlice());
    try code.append(.{ .block = @intCast(block_idx) });
}

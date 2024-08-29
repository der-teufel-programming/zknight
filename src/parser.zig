const std = @import("std");
const assert = std.debug.assert;
const ascii = std.ascii;
const Allocator = std.mem.Allocator;
const Tokenizer = @import("tokenizer.zig").Tokenizer;
const Token = @import("tokenizer.zig").Token;

const ParserOld = struct {
    buffer: []const u8,
    nodes: std.ArrayListUnmanaged(Ast.Node) = .{},
    errors: std.ArrayListUnmanaged(usize) = .{},
    index: usize,
    allocator: Allocator,

    const Index = Ast.Node.Index;

    pub fn init(alloc: Allocator, data: []const u8) ParserOld {
        return .{
            .buffer = data,
            .allocator = alloc,
            .index = 0,
        };
    }

    pub fn deinit(self: *ParserOld) void {
        self.nodes.deinit(self.allocator);
        self.errors.deinit(self.allocator);
    }

    pub const ParseError = error{
        UnexpectedEOF,
        InvalidCharacter,
    } || Allocator.Error;

    pub fn parse(self: *ParserOld) ParseError!Ast.Node.Index {
        // std.log.debug("Parser.parse at idx = {}", .{self.index});
        if (self.buffer.len == 0) return 0;
        var old_index: ?usize = null;
        while (self.index < self.buffer.len and old_index != self.index) {
            old_index = self.index;

            while (self.index < self.buffer.len and (ascii.isWhitespace(self.buffer[self.index]) or self.buffer[self.index] == '(' or self.buffer[self.index] == ')')) : (self.index += 1) {}
            if (self.index >= self.buffer.len) return error.UnexpectedEOF;
            if (self.buffer[self.index] == '#') {
                while (self.index < self.buffer.len and self.buffer[self.index] != '\n') : (self.index += 1) {}
                self.index += 1;
                if (self.index >= self.buffer.len) return error.UnexpectedEOF;
            }
        }
        return switch (self.buffer[self.index]) {
            'a'...'z', '_' => self.parseIdentifier(),
            '0'...'9' => self.parseNumber(),
            'A'...'D',
            'F',
            'G',
            'I',
            'L',
            'N'...'T',
            'W',
            '@',
            ':',
            '!',
            '~',
            ',',
            '[',
            ']',
            '+',
            '-',
            '*',
            '/',
            '%',
            '^',
            '<',
            '>',
            '?',
            '&',
            '|',
            ';',
            '=',
            => self.parseFunction(),
            '"', '\'' => self.parseString(),
            else => blk: {
                try self.errors.append(self.allocator, self.index);
                break :blk error.InvalidCharacter;
            },
        };
    }

    fn parseIdentifier(self: *ParserOld) ParseError!Index {
        assert(ascii.isLower(self.buffer[self.index]) or self.buffer[self.index] == '_');
        const idx = self.index;
        while (self.index < self.buffer.len and (ascii.isLower(self.buffer[self.index]) or ascii.isDigit(self.buffer[self.index]) or self.buffer[self.index] == '_')) : (self.index += 1) {}

        const ident = self.buffer[idx..self.index];
        // std.log.debug("Parser.parseIdentifier: `{s}`", .{ident});
        const ident_idx = self.nodes.items.len;
        try self.nodes.append(self.allocator, .{
            .tag = .identifier,
            .data = .{ .bytes = ident },
            .loc = .{
                .start = idx,
                .end = self.index,
            },
        });
        return @intCast(ident_idx);
    }

    fn parseNumber(self: *ParserOld) ParseError!Index {
        assert(std.ascii.isDigit(self.buffer[self.index]));
        const idx = self.index;
        while (self.index < self.buffer.len and std.ascii.isDigit(self.buffer[self.index])) : (self.index += 1) {}

        const number = self.buffer[idx..self.index];
        // std.log.debug("Parser.parseNumber: `{s}`", .{number});
        const number_idx = self.nodes.items.len;
        try self.nodes.append(self.allocator, .{
            .tag = .number_literal,
            .data = .{ .bytes = number },
            .loc = .{
                .start = idx,
                .end = self.index,
            },
        });
        return @intCast(number_idx);
    }

    fn parseFunction(self: *ParserOld) ParseError!Index {
        const func_start = self.index;
        const func = self.buffer[self.index];
        if (ParserOld.upperFunc(func)) {
            while (self.index < self.buffer.len and (ascii.isUpper(self.buffer[self.index]) or self.buffer[self.index] == '_')) : (self.index += 1) {}
        } else {
            self.index += 1;
        }
        const func_arity = ParserOld.arity(func);
        // std.log.debug("Parser.parseFunction: `{c}` with arity {}", .{ func, func_arity });
        var args = try self.allocator.alloc(Index, func_arity);
        const func_idx = self.nodes.items.len;
        try self.nodes.append(self.allocator, .{
            .tag = Ast.Node.Tag.function(func).?,
            .data = .{ .arguments = &.{} },
            .loc = .{
                .start = func_start,
                .end = self.index,
            },
        });

        for (0..func_arity) |arg_idx| {
            const idx = try self.parse();
            args[arg_idx] = idx;
        }
        self.nodes.items[func_idx].data.arguments = args;

        return @intCast(func_idx);
    }

    fn parseString(self: *ParserOld) ParseError!Index {
        const idx = self.index + 1;
        const double = self.buffer[self.index] == '"';
        self.index += 1;
        if (double) {
            while (self.index < self.buffer.len and self.buffer[self.index] != '"') : (self.index += 1) {}
        } else {
            while (self.index < self.buffer.len and self.buffer[self.index] != '\'') : (self.index += 1) {}
        }
        const string = self.buffer[idx..self.index];
        self.index += 1;
        // std.log.debug("Parser.parseString: `{s}`", .{string});
        const string_idx = self.nodes.items.len;
        try self.nodes.append(self.allocator, .{
            .tag = .string_literal,
            .data = .{ .bytes = string },
            .loc = .{
                .start = idx - 1,
                .end = self.index,
            },
        });

        return @intCast(string_idx);
    }

    fn arity(function: u8) u8 {
        return switch (function) {
            '@', 'T', 'F', 'N', 'P', 'R' => 0,
            ':', '!', '~', ',', '[', ']', 'A', 'B', 'C', 'D', 'L', 'O', 'Q' => 1,
            '+', '-', '*', '/', '&', '%', '^', '<', '>', '?', '|', ';', '=', 'W' => 2,
            'I', 'G' => 3,
            'S' => 4,
            else => unreachable,
        };
    }

    fn upperFunc(function: u8) bool {
        return switch (function) {
            'T', 'F', 'N', 'P', 'R', 'A', 'B', 'C', 'D', 'L', 'O', 'Q', 'W', 'I', 'G', 'S' => true,
            else => false,
        };
    }
};

pub const Ast = struct {
    source: [:0]const u8,

    tokens: TokenList.Slice,
    nodes: NodeList.Slice,
    node_data: []Node.Index,
    string_data: []const u8,

    errors: []const Error,

    pub const TokenIndex = u32;
    pub const DataIndex = u32;

    pub const Node = struct {
        tag: Tag,
        token_idx: TokenIndex,
        data: Data,

        pub const Index = u32;
        pub const Tag = enum {
            integer_literal,
            function_at,
            function_T,
            function_F,
            function_N,
            function_P,
            function_R,
            function_colon,
            function_bang,
            function_tilde,
            function_comma,
            function_r_bracket,
            function_l_bracket,
            function_A,
            function_B,
            function_C,
            function_D,
            function_L,
            function_O,
            function_Q,
            function_plus,
            function_minus,
            function_star,
            function_slash,
            function_ampersand,
            function_percent,
            function_caret,
            function_less,
            function_greater,
            function_question_mark,
            function_pipe,
            function_semicolon,
            function_equal,
            function_W,
            function_I,
            function_G,
            function_S,
            string_literal,
            identifier,

            pub fn symbolFunction(c: u8) ?Tag {
                return switch (c) {
                    '@' => .function_at,
                    ':' => .function_colon,
                    '!' => .function_bang,
                    '~' => .function_tilde,
                    ',' => .function_comma,
                    '[' => .function_l_bracket,
                    ']' => .function_r_bracket,
                    '+' => .function_plus,
                    '-' => .function_minus,
                    '*' => .function_star,
                    '/' => .function_slash,
                    '&' => .function_ampersand,
                    '%' => .function_percent,
                    '^' => .function_caret,
                    '<' => .function_less,
                    '>' => .function_greater,
                    '?' => .function_question_mark,
                    '|' => .function_pipe,
                    ';' => .function_semicolon,
                    '=' => .function_equal,
                    else => null,
                };
            }

            pub fn wordFunction(c: u8) ?Tag {
                return switch (c) {
                    'T' => .function_T,
                    'F' => .function_F,
                    'N' => .function_N,
                    'P' => .function_P,
                    'R' => .function_R,
                    'A' => .function_A,
                    'B' => .function_B,
                    'C' => .function_C,
                    'D' => .function_D,
                    'L' => .function_L,
                    'O' => .function_O,
                    'Q' => .function_Q,
                    'W' => .function_W,
                    'I' => .function_I,
                    'G' => .function_G,
                    'S' => .function_S,
                    else => null,
                };
            }

            pub fn char(self: Tag) ?u8 {
                return switch (self) {
                    .function_at => '@',
                    .function_T => 'T',
                    .function_F => 'F',
                    .function_N => 'N',
                    .function_P => 'P',
                    .function_R => 'R',
                    .function_colon => ':',
                    .function_bang => '!',
                    .function_tilde => '~',
                    .function_comma => ',',
                    .function_l_bracket => '[',
                    .function_r_bracket => ']',
                    .function_A => 'A',
                    .function_B => 'B',
                    .function_C => 'C',
                    .function_D => 'D',
                    .function_L => 'L',
                    .function_O => 'O',
                    .function_Q => 'Q',
                    .function_plus => '+',
                    .function_minus => '-',
                    .function_star => '*',
                    .function_slash => '/',
                    .function_ampersand => '&',
                    .function_percent => '%',
                    .function_caret => '^',
                    .function_less => '<',
                    .function_greater => '>',
                    .function_question_mark => '?',
                    .function_pipe => '|',
                    .function_semicolon => ';',
                    .function_equal => '=',
                    .function_W => 'W',
                    .function_I => 'I',
                    .function_G => 'G',
                    .function_S => 'S',
                    else => null,
                };
            }

            pub fn arity(self: Tag) ?u8 {
                const func_char = self.char() orelse return null;
                return ParserOld.arity(func_char);
            }
        };

        pub const Data = struct {
            idx: DataIndex,
            length: u32,

            pub fn getBytes(
                data: Data,
                bytes: []const u8,
            ) []const u8 {
                return bytes[data.idx..][0..data.length];
            }

            pub fn getNodes(
                data: Data,
                nodes: []const Node.Index,
            ) []const Node.Index {
                return nodes[data.idx..][0..data.length];
            }
        };
    };

    pub fn deinit(tree: *Ast, gpa: Allocator) void {
        tree.tokens.deinit(gpa);
        tree.nodes.deinit(gpa);
        gpa.free(tree.node_data);
        gpa.free(tree.string_data);
        gpa.free(tree.errors);
        tree.* = undefined;
    }

    pub fn render(tree: *Ast, buffer: *std.ArrayList(u8)) !void {
        try tree.renderInner(0, buffer.writer());
    }

    fn renderInner(tree: *Ast, node_idx: Node.Index, out: std.ArrayList(u8).Writer) !void {
        const node = tree.nodes.get(node_idx);
        switch (node.tag) {
            .string_literal => try out.print(
                "'{s}'",
                .{node.data.getBytes(tree.string_data)},
            ),
            .integer_literal,
            .identifier,
            => try out.print(
                "{s}",
                .{node.data.getBytes(tree.string_data)},
            ),
            .function_at,
            .function_colon,
            .function_bang,
            .function_tilde,
            .function_comma,
            .function_r_bracket,
            .function_l_bracket,
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
            .function_T,
            .function_F,
            .function_N,
            .function_P,
            .function_R,
            .function_A,
            .function_B,
            .function_C,
            .function_D,
            .function_L,
            .function_O,
            .function_Q,
            .function_W,
            .function_I,
            .function_G,
            .function_S,
            => {
                const char = node.tag.char() orelse return;
                try out.print("{c}", .{char});
                const arity = node.tag.arity().?;
                if (arity > 0) {
                    const args = node.data.getNodes(tree.node_data);
                    for (args) |arg| {
                        try out.writeAll(" ");
                        try tree.renderInner(arg, out);
                    }
                }
                try out.writeAll(" ");
            },
        }
    }

    const TokenList = std.MultiArrayList(Token);

    const NodeList = std.MultiArrayList(Node);

    const SrcOffset = u32;

    const Error = struct {
        kind: Tag,
        tok_i: TokenIndex,
        data: union(enum) {
            none,
            tag: Token.Tag,
        },

        const Tag = enum {
            unexpected,
            invalid,
            bad_function_name,
        };
    };

    // const Error = struct {
    //     tag: Tag,
    //     is_note: bool = false,
    //     /// True if `token` points to the token before the token causing an issue.
    //     token_is_prev: bool = false,
    //     token: TokenIndex,
    //     extra: union {
    //         none: void,
    //         expected_tag: Token.Tag,
    //     } = .{ .none = {} },

    //     const Tag = enum {};
    // };

    pub fn parse(
        gpa: Allocator,
        source: [:0]const u8,
        mode: Tokenizer.Mode,
    ) Parser.ParseError!Ast {
        var tokens: TokenList = .{};
        defer tokens.deinit(gpa);

        var tokenizer = Tokenizer.init(source, mode);
        while (true) {
            const token = tokenizer.next();
            try tokens.append(gpa, token);
            if (token.tag == .eof) break;
        }

        var parser: Parser = .{
            .source = source,
            .gpa = gpa,
            .token_tags = tokens.items(.tag),
            .token_locs = tokens.items(.loc),
            .errors = .{},
            .nodes = .{},
            .node_data = .{},
            .string_data = .{},
            .scratch = .{},
            .tok_i = 0,
        };
        defer parser.errors.deinit(gpa);
        defer parser.nodes.deinit(gpa);
        defer parser.node_data.deinit(gpa);
        defer parser.string_data.deinit(gpa);
        defer parser.scratch.deinit(gpa);

        // Every token should be a node
        const estimated_node_count = tokens.len + 2;
        try parser.nodes.ensureTotalCapacity(gpa, estimated_node_count);

        try parser.parseProgram();

        return .{
            .source = source,
            .tokens = tokens.toOwnedSlice(),
            .nodes = parser.nodes.toOwnedSlice(),
            .node_data = try parser.node_data.toOwnedSlice(gpa),
            .string_data = try parser.string_data.toOwnedSlice(gpa),
            .errors = try parser.errors.toOwnedSlice(gpa),
        };
    }
};

const Parser = struct {
    source: [:0]const u8,
    gpa: Allocator,
    token_tags: []const Token.Tag,
    token_locs: []const Token.Loc,
    errors: std.ArrayListUnmanaged(Ast.Error),
    nodes: Ast.NodeList,
    node_data: std.ArrayListUnmanaged(Ast.Node.Index),
    string_data: std.ArrayListUnmanaged(u8),
    scratch: std.ArrayListUnmanaged(Ast.Node.Index),
    tok_i: Ast.TokenIndex,

    pub const ParseError = error{ParseError} || Allocator.Error;

    const log = std.log.scoped(.parser);

    /// program <- expr
    pub fn parseProgram(p: *Parser) ParseError!void {
        try p.node_data.append(p.gpa, 0);
        try p.string_data.append(p.gpa, 0);
        try p.nodes.append(p.gpa, undefined);
        var callstack: std.ArrayListUnmanaged(Ast.Node.Index) = .{};
        defer callstack.deinit(p.gpa);
        try p.parseExpr(0, &callstack);
        if (callstack.items.len > 0) return error.ParseError;
    }

    fn parseExpr(p: *Parser, node_idx: Ast.Node.Index, callstack: *std.ArrayListUnmanaged(Ast.Node.Index)) ParseError!void {
        try callstack.append(p.gpa, node_idx);
        defer _ = callstack.pop();
        while (true) {
            const token_tag = p.token_tags[p.tok_i];
            // const token_loc = p.token_locs[p.tok_i];
            // log.debug("token: {s} {}:{}", .{ @tagName(token_tag), token_loc.start, token_loc.end });
            switch (token_tag) {
                .integer_literal => {
                    const data_start: u32 = @intCast(p.string_data.items.len);
                    const tok_loc = p.token_locs[p.tok_i];
                    const data_len: u32 = @intCast(tok_loc.end - tok_loc.start);
                    try p.string_data.appendSlice(p.gpa, tok_loc.slice(p.source) orelse return p.addInvalid());
                    p.nodes.set(node_idx, .{
                        .tag = .integer_literal,
                        .token_idx = p.tok_i,
                        .data = .{
                            .idx = data_start,
                            .length = data_len,
                        },
                    });
                    // log.debug(
                    //     "[{d}] integer {s}",
                    //     .{ callstack.items, p.string_data.items[data_start..][0..data_len] },
                    // );
                    p.tok_i += 1;
                    return;
                },
                .string_literal => {
                    const data_start: u32 = @intCast(p.string_data.items.len);
                    var tok_loc = p.token_locs[p.tok_i];
                    const data_len: u32 = @intCast(tok_loc.end - tok_loc.start - 2);
                    tok_loc.start += 1;
                    tok_loc.end -= 1;
                    try p.string_data.appendSlice(p.gpa, tok_loc.slice(p.source) orelse return p.addInvalid());
                    p.nodes.set(node_idx, .{
                        .tag = .string_literal,
                        .token_idx = p.tok_i,
                        .data = .{
                            .idx = data_start,
                            .length = data_len,
                        },
                    });
                    // log.debug(
                    //     "[{d}] string `{s}`",
                    //     .{ callstack.items, p.string_data.items[data_start..][0..data_len] },
                    // );
                    p.tok_i += 1;
                    return;
                },
                .identifier => {
                    const data_start: u32 = @intCast(p.string_data.items.len);
                    var tok_loc = p.token_locs[p.tok_i];
                    const data_len: u32 = @intCast(tok_loc.end - tok_loc.start);
                    try p.string_data.appendSlice(p.gpa, tok_loc.slice(p.source) orelse return p.addInvalid());
                    p.nodes.set(node_idx, .{
                        .tag = .identifier,
                        .token_idx = p.tok_i,
                        .data = .{
                            .idx = data_start,
                            .length = data_len,
                        },
                    });
                    // log.debug(
                    //     "[{d}] identifier `{s}`",
                    //     .{ callstack.items, p.slice(p.token_locs[p.tok_i]).? },
                    // );
                    p.tok_i += 1;
                    return;
                },
                .symbol_function => {
                    const func_name = p.slice(p.token_locs[p.tok_i]).?;
                    const tag = Ast.Node.Tag.symbolFunction(func_name[0]).?;
                    const arity = tag.arity().?;
                    // log.debug(
                    //     "[{d}] func: {s} ({})",
                    //     .{ callstack.items, @tagName(tag), arity },
                    // );
                    if (arity > 0) {
                        try p.nodes.ensureUnusedCapacity(p.gpa, arity);

                        const data_start: u32 = @intCast(p.node_data.items.len);
                        try p.node_data.ensureUnusedCapacity(p.gpa, arity);
                        const first_node = p.nodes.len;
                        for (0..arity) |_| {
                            // log.debug("Adding {d}", .{p.nodes.len});
                            p.node_data.appendAssumeCapacity(@intCast(p.nodes.len));
                            p.nodes.appendAssumeCapacity(undefined);
                        }
                        p.nodes.set(node_idx, .{
                            .tag = tag,
                            .token_idx = p.tok_i,
                            .data = .{
                                .idx = data_start,
                                .length = arity,
                            },
                        });
                        p.tok_i += 1;
                        for (0..arity) |i| {
                            // log.debug("starting [{d}]", .{first_node + i});
                            try p.parseExpr(@intCast(first_node + i), callstack);
                        }
                        // log.debug("finished [{d}] {s}", .{ callstack.items, @tagName(tag) });
                    } else {
                        p.nodes.set(node_idx, .{
                            .tag = tag,
                            .token_idx = p.tok_i,
                            .data = .{
                                .idx = 0,
                                .length = 0,
                            },
                        });
                        p.tok_i += 1;
                    }
                    return;
                },
                .word_function => {
                    const func_name = p.slice(p.token_locs[p.tok_i]).?;
                    const tag = Ast.Node.Tag.wordFunction(func_name[0]) orelse {
                        try p.addBadFunctionName();
                        return error.ParseError;
                    };
                    const arity = tag.arity().?;
                    // log.debug(
                    //     "[{d}] func: {s} ({d})",
                    //     .{ callstack.items, @tagName(tag), arity },
                    // );
                    if (arity > 0) {
                        const node_start = p.nodes.len;
                        try p.nodes.ensureUnusedCapacity(p.gpa, arity);

                        const data_start: u32 = @intCast(p.node_data.items.len);
                        try p.node_data.ensureUnusedCapacity(p.gpa, arity);
                        const first_node = p.nodes.len;
                        for (0..arity) |i| {
                            p.node_data.appendAssumeCapacity(@intCast(node_start + i));
                            p.nodes.appendAssumeCapacity(undefined);
                        }
                        p.nodes.set(node_idx, .{
                            .tag = tag,
                            .token_idx = p.tok_i,
                            .data = .{
                                .idx = data_start,
                                .length = arity,
                            },
                        });
                        p.tok_i += 1;
                        for (0..arity) |i| {
                            // log.debug("starting [{d}]", .{first_node + i});
                            try p.parseExpr(@intCast(first_node + i), callstack);
                        }
                        // log.debug("finished [{d}] {s}", .{ callstack.items, @tagName(tag) });
                    } else {
                        p.nodes.set(node_idx, .{
                            .tag = tag,
                            .token_idx = p.tok_i,
                            .data = .{
                                .idx = 0,
                                .length = 0,
                            },
                        });
                        p.tok_i += 1;
                    }
                    return;
                },
                .l_paren => {
                    // log.debug("skipping (", .{});
                    p.tok_i += 1;
                },
                .r_paren => {
                    // log.debug("skipping )", .{});
                    p.tok_i += 1;
                },
                .eof => return p.addUnexpected(.eof),
                .invalid => return p.addInvalid(),
            }
        }
    }

    fn addUnexpected(p: *Parser, tag: Token.Tag) !void {
        @branchHint(.cold);
        try p.errors.append(p.gpa, .{
            .kind = .unexpected,
            .tok_i = p.tok_i,
            .data = .{ .tag = tag },
        });
    }

    fn addBadFunctionName(p: *Parser) !void {
        @branchHint(.cold);
        try p.errors.append(p.gpa, .{
            .kind = .bad_function_name,
            .tok_i = p.tok_i,
            .data = .none,
        });
    }

    fn addInvalid(p: *Parser) ParseError {
        @branchHint(.cold);
        try p.errors.append(p.gpa, .{
            .kind = .invalid,
            .tok_i = p.tok_i,
            .data = .none,
        });
        return error.ParseError;
    }

    fn slice(p: *Parser, loc: Token.Loc) ?[]const u8 {
        return loc.slice(p.source);
    }
};

test "empty source" {
    var ast = try Ast.parse(std.testing.allocator, "", .strict);
    defer ast.deinit(std.testing.allocator);
    try std.testing.expect(ast.errors.len == 1);
    try std.testing.expectEqualDeep(
        ast.errors[0],
        Ast.Error{ .kind = .unexpected, .tok_i = 0, .data = .{ .tag = .eof } },
    );
}

test "example" {
    const source =
        \\# Simple guessing game
        \\; = secret RANDOM
        \\; = guess + 0 PROMPT
        \\  OUTPUT IF (? secret guess) "correct!" "wrong!"
    ;
    var ast = try Ast.parse(std.testing.allocator, source, .strict);
    defer ast.deinit(std.testing.allocator);
    try std.testing.expect(ast.errors.len == 0);
}

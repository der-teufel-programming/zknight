const std = @import("std");
const assert = std.debug.assert;
const ascii = std.ascii;
const Allocator = std.mem.Allocator;

const Parser = struct {
    buffer: []const u8,
    nodes: std.ArrayListUnmanaged(Node) = .{},
    errors: std.ArrayListUnmanaged(usize) = .{},
    index: usize,
    allocator: Allocator,

    pub fn init(alloc: Allocator, data: []const u8) Parser {
        return .{
            .buffer = data,
            .allocator = alloc,
            .index = 0,
        };
    }

    pub fn deinit(self: *Parser) void {
        self.nodes.deinit(self.allocator);
        self.errors.deinit(self.allocator);
    }

    pub const ParseError = error{
        UnexpectedEOF,
        InvalidCharacter,
    } || Allocator.Error;

    pub fn parse(self: *Parser) ParseError!Index {
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

    fn parseIdentifier(self: *Parser) ParseError!Index {
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

    fn parseNumber(self: *Parser) ParseError!Index {
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

    fn parseFunction(self: *Parser) ParseError!Index {
        const func_start = self.index;
        const func = self.buffer[self.index];
        if (Parser.upperFunc(func)) {
            while (self.index < self.buffer.len and (ascii.isUpper(self.buffer[self.index]) or self.buffer[self.index] == '_')) : (self.index += 1) {}
        } else {
            self.index += 1;
        }
        const func_arity = Parser.arity(func);
        // std.log.debug("Parser.parseFunction: `{c}` with arity {}", .{ func, func_arity });
        var args = try self.allocator.alloc(Index, func_arity);
        const func_idx = self.nodes.items.len;
        try self.nodes.append(self.allocator, .{
            .tag = Node.Tag.function(func).?,
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

    fn parseString(self: *Parser) ParseError!Index {
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

pub const Index = u32;
pub const Node = struct {
    tag: Tag,
    data: Data,
    loc: Loc,

    pub const Tag = enum {
        number_literal,
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

        pub fn function(c: u8) ?Tag {
            return switch (c) {
                '@' => .function_at,
                'T' => .function_T,
                'F' => .function_F,
                'N' => .function_N,
                'P' => .function_P,
                'R' => .function_R,
                ':' => .function_colon,
                '!' => .function_bang,
                '~' => .function_tilde,
                ',' => .function_comma,
                '[' => .function_l_bracket,
                ']' => .function_r_bracket,
                'A' => .function_A,
                'B' => .function_B,
                'C' => .function_C,
                'D' => .function_D,
                'L' => .function_L,
                'O' => .function_O,
                'Q' => .function_Q,
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
            return Parser.arity(func_char);
        }
    };

    pub const Data = union(enum) {
        bytes: []const u8,
        arguments: []const Index,
    };

    pub const Loc = struct {
        start: usize,
        end: usize,
    };

    pub fn debugPrint(self: Node, ast: []const Node, indent: usize) void {
        if (indent > 0) {
            for (0..(indent - 1)) |_| {
                std.debug.print("  ", .{});
            }
            if (indent > 1) {
                std.debug.print("-- ", .{});
            } else {
                std.debug.print("   ", .{});
            }
        }
        switch (self.tag) {
            .string_literal,
            .identifier,
            .number_literal,
            => std.debug.print("{s}\n", .{self.data.bytes}),
            else => |tag| {
                const char = tag.char().?;
                const args = self.data.arguments;
                std.debug.print("{c}\n", .{char});
                for (args) |arg_idx| {
                    const node = ast[arg_idx];
                    node.debugPrint(ast, indent + 1);
                }
            },
        }
    }
};

pub fn parse(alloc: std.mem.Allocator, buffer: []const u8) ![]const Node {
    var parser = Parser.init(alloc, buffer);
    errdefer parser.deinit();
    errdefer {
        for (parser.nodes.items) |*node| {
            switch (node.data) {
                .arguments => |args| alloc.free(args),
                else => {},
            }
        }
    }
    _ = parser.parse() catch |err| switch (err) {
        error.InvalidCharacter => {
            const idx = parser.errors.items[0];
            std.log.debug("Invalid character at index {}: `{c}`", .{ idx, buffer[idx] });
            return err;
        },
        error.UnexpectedEOF => {
            std.log.debug("Unexpected EOF", .{});
            return err;
        },
        else => return err,
    };
    return parser.nodes.toOwnedSlice(alloc);
}

pub fn debugPrint(ast: []const Node) void {
    if (ast.len == 0) return;
    const root = ast[0];
    root.debugPrint(ast, 0);
}

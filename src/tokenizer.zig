const std = @import("std");

pub const Token = struct {
    tag: Tag,
    loc: Loc,

    pub const Loc = struct {
        start: usize,
        end: usize,

        pub fn slice(loc: Loc, source: [:0]const u8) ?[]const u8 {
            if (loc.start == loc.end) return null;
            return source[loc.start..loc.end];
        }
    };

    pub const Tag = enum {
        integer_literal,
        string_literal,
        identifier,
        symbol_function,
        word_function,
        l_paren,
        r_paren,
        eof,
        invalid,
    };
};

pub const Tokenizer = struct {
    buffer: [:0]const u8,
    index: usize,
    mode: Mode,

    pub const Mode = enum {
        /// In `strict` mode tokenizer considers
        /// characters outside minimum ASCII subset as invalid
        strict,
        extended,
    };

    pub fn init(buffer: [:0]const u8, mode: Mode) Tokenizer {
        return .{
            .buffer = buffer,
            .index = 0,
            .mode = mode,
        };
    }

    const State = enum {
        start,
        function_name,
        identifier,
        integer_literal,
        string_literal_single,
        string_literal_double,
        comment,
        invalid,
    };

    const next_log = std.log.scoped(.next);
    inline fn setLogState(state: *State, next_state: State) void {
        // next_log.debug(
        //     "{s} -> {s}",
        //     .{ @tagName(state.*), @tagName(next_state) },
        // );
        state.* = next_state;
    }

    pub fn next(self: *Tokenizer) Token {
        var state: State = .start;
        var result: Token = .{
            .tag = undefined,
            .loc = .{
                .start = self.index,
                .end = undefined,
            },
        };
        while (true) : (self.index += 1) {
            const c = self.buffer[self.index];
            switch (state) {
                .start => switch (c) {
                    0 => {
                        if (self.index == self.buffer.len) {
                            return .{
                                .tag = .eof,
                                .loc = .{
                                    .start = self.index,
                                    .end = self.index,
                                },
                            };
                        }
                        setLogState(&state, .invalid);
                    },
                    ' ', '\n', '\t', '\r' => {
                        result.loc.start = self.index + 1;
                    },
                    '"' => {
                        setLogState(&state, .string_literal_double);
                        result.tag = .string_literal;
                    },
                    '\'' => {
                        setLogState(&state, .string_literal_single);
                        result.tag = .string_literal;
                    },
                    '#' => {
                        setLogState(&state, .comment);
                    },
                    'a'...'z', '_' => {
                        setLogState(&state, .identifier);
                        result.tag = .identifier;
                    },
                    '(' => {
                        result.tag = .l_paren;
                        self.index += 1;
                        break;
                    },
                    ')' => {
                        result.tag = .r_paren;
                        self.index += 1;
                        break;
                    },
                    'A'...'Z' => {
                        setLogState(&state, .function_name);
                        result.tag = .word_function;
                    },
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
                    => {
                        result.tag = .symbol_function;
                        self.index += 1;
                        break;
                    },
                    '0'...'9' => state = .integer_literal,
                    else => state = .invalid,
                },
                .function_name => switch (c) {
                    'A'...'Z', '_' => continue,
                    else => {
                        result.tag = .word_function;
                        break;
                    },
                },
                .identifier => switch (c) {
                    'a'...'z', '0'...'9', '_' => continue,
                    else => {
                        result.tag = .identifier;
                        break;
                    },
                },
                .integer_literal => switch (c) {
                    '0'...'9' => continue,
                    else => {
                        result.tag = .integer_literal;
                        break;
                    },
                },
                .string_literal_single => switch (c) {
                    '\'' => {
                        result.tag = .string_literal;
                        self.index += 1;
                        break;
                    },
                    '\n', '\t', '\r', ' '...'&', '('...'~' => continue,
                    else => {
                        if (self.mode == .strict) setLogState(&state, .invalid);
                        continue;
                    },
                },
                .string_literal_double => switch (c) {
                    '"' => {
                        result.tag = .string_literal;
                        self.index += 1;
                        break;
                    },
                    '\n', '\t', '\r', ' ', '!', '#'...'~' => continue,
                    else => {
                        if (self.mode == .strict) setLogState(&state, .invalid);
                        continue;
                    },
                },
                .comment => switch (c) {
                    0 => {
                        if (self.index != self.buffer.len) {
                            setLogState(&state, .invalid);
                            continue;
                        }
                        return .{
                            .tag = .eof,
                            .loc = .{
                                .start = self.index,
                                .end = self.index,
                            },
                        };
                    },
                    '\n' => {
                        setLogState(&state, .start);
                        result.loc.start = self.index + 1;
                    },
                    '\t', '\r', ' '...'~' => continue,
                    else => {
                        if (self.mode == .strict) setLogState(&state, .invalid);
                        continue;
                    },
                },
                .invalid => switch (c) {
                    '\n' => {
                        self.index += 1;
                        result.tag = .invalid;
                        break;
                    },
                    0 => {
                        result.tag = .invalid;
                        break;
                    },
                    else => continue,
                },
            }
        }

        result.loc.end = self.index;
        return result;
    }

    fn minimalAscii(char: u8) bool {
        return switch (char) {
            '\t', '\n', '\r', ' '...'~' => true,
            else => false,
        };
    }
};

test "comments" {
    try testTokenize(
        \\# this is a comment
    ,
        &.{},
        .strict,
    );
    try testTokenize(
        "# this comment contains invalid characters \x0f \n",
        &.{.invalid},
        .strict,
    );
}

test "identifiers" {
    try testTokenize(
        \\simple
        \\
        \\underscores_are_ok
        \\
        \\so_are_nums123
        \\
        \\_1290
    , &.{
        .identifier,
        .identifier,
        .identifier,
        .identifier,
    }, .strict);
}

test "string literals" {
    try testTokenize(
        \\'a single string literal'
        \\
        \\'string literals can contain newlines
        \\'
        \\
        \\'strings can"t contain invalid chars in strict mode
    ++ "\x0F '", &.{
        .string_literal,
        .string_literal,
        .invalid,
    }, .strict);

    try testTokenize(
        \\"a double string literal"
        \\
        \\"string literals can contain newlines
        \\"
        \\
        \\"strings can't contain invalid chars in strict mode
    ++ "\x0F \"", &.{
        .string_literal,
        .string_literal,
        .invalid,
    }, .strict);
}

// test "fuzzy" {
//     const input = std.testing.fuzzInput(.{});
//     const src = try std.testing.allocator.dupeZ(u8, input);
//     defer std.testing.allocator.free(src);
//     var tokenizer = Tokenizer.init(src, .strict);
//     while (true) {
//         const tok = tokenizer.next();
//         std.debug.print(
//             "\n({s}) {}..{} `{?s}`\n",
//             .{
//                 @tagName(tok.tag),
//                 tok.loc.start,
//                 tok.loc.end,
//                 tok.loc.slice(src),
//             },
//         );
//         if (tok.tag == .eof) break;
//     }
// }

fn testTokenize(
    source: [:0]const u8,
    expected_token_tags: []const Token.Tag,
    mode: Tokenizer.Mode,
) !void {
    var tokenizer = Tokenizer.init(source, mode);
    for (expected_token_tags) |expected_token_tag| {
        const token = tokenizer.next();
        errdefer std.debug.print(
            "\n{}: {?d}\n",
            .{ token, token.loc.slice(source) },
        );
        try std.testing.expectEqual(expected_token_tag, token.tag);
    }
    // Last token should always be eof, even when the last token was invalid,
    // in which case the tokenizer is in an invalid state, which can only be
    // recovered by opinionated means outside the scope of this implementation.
    const last_token = tokenizer.next();
    errdefer std.debug.print(
        "\n{}: {?d}\n",
        .{ last_token, last_token.loc.slice(source) },
    );
    try std.testing.expectEqual(Token.Tag.eof, last_token.tag);
    try std.testing.expectEqual(source.len, last_token.loc.start);
    try std.testing.expectEqual(source.len, last_token.loc.end);
}

pub fn main() !void {
    const src =
        \\# Simple guessing game
        \\; = secret RANDOM
        \\; = guess + 0 PROMPT
        \\  OUTPUT IF (? secret guess) "correct!" "wrong!"
    ;
    var tok = Tokenizer.init(
        src,
        .strict,
    );
    var toks = std.ArrayList(Token).init(std.heap.page_allocator);
    defer toks.deinit();
    while (true) {
        const t = tok.next();
        try toks.append(t);
        if (t.tag == .eof) break;
    }
    for (toks.items) |t| {
        std.debug.print(
            "({s}) `{?s}`\n",
            .{ @tagName(t.tag), t.loc.slice(src) },
        );
    }
}

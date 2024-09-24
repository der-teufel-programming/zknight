const std = @import("std");
const Ast = @import("parser.zig").Ast;
const Info = @import("analyzer.zig").Info;

const zig_preamble = @embedFile("transpiler/zig-preamble.zig");

pub fn writeZigMain(
    gpa: std.mem.Allocator,
    ast: Ast,
    info: Info,
    writer: anytype,
) !void {
    try writer.writeAll(zig_preamble);
    const zig_code = try generateZigCode(gpa, ast, info);
    defer zig_code.deinit(gpa);
    for (zig_code.variables) |var_| {
        try writer.print(
            "var {_}_{}: Value = undefined;\n",
            .{ std.zig.fmtId(var_.name), var_.index },
        );
    }

    for (zig_code.blocks) |blk| {
        try writer.print(
            "inline fn B_{}(gpa: Allocator) anyerror!Value",
            .{blk.index},
        );
        try writer.writeAll(" {\n");
        var gpa_used = false;
        for (blk.code) |stm| {
            try stm.writeTo(writer);
            if (stm.useGpa()) {
                gpa_used = true;
            }
        }
        if (!gpa_used) try writer.writeAll("    _ = gpa;\n");
        try writer.writeAll("}\n");
    }

    try writer.writeAll(
        \\pub fn main() !u8 {
        \\    var gpa_impl: GPA = .init;
        \\    defer _ = gpa_impl.deinit();
        \\    const gpa = gpa_impl.allocator();
        \\
        \\    const stdin = std.io.getStdIn().reader();
        \\    const stdout_raw = std.io.getStdOut().writer();
        \\    var stdout = std.io.bufferedWriter(stdout_raw);
        \\
    );
    {
        var stdin_used = false;
        var stdout_used = false;
        var gpa_used = false;
        for (zig_code.code) |stm| {
            try stm.writeTo(writer);
            if (stm.useGpa()) {
                gpa_used = true;
            }
            if (stm.useStdIn()) {
                stdin_used = true;
            }
            if (stm.useStdOut()) {
                stdout_used = true;
            }
        }
        if (!stdin_used) {
            try writer.writeAll("    _ = &stdin;\n");
        }
        if (!stdout_used) {
            try writer.writeAll("    _ = &stdout;\n");
        }
        if (!gpa_used) {
            try writer.writeAll("    _ = gpa;\n");
        }
    }
    // try writeZigBody(ast, writer);

    try writer.writeAll(
        \\    return 0;
        \\}
    );
}

const ZigCode = struct {
    variables: []const Variable,
    blocks: []const Block,
    code: []const Statement,

    fn deinit(code: ZigCode, gpa: std.mem.Allocator) void {
        gpa.free(code.variables);
        gpa.free(code.code);
        for (code.blocks) |blk| {
            gpa.free(blk.code);
        }
        gpa.free(code.blocks);
    }

    const Block = struct {
        index: u32,
        code: []const Statement,
    };

    const Function = enum(u8) {
        @"@" = '@',
        T = 'T',
        F = 'F',
        N = 'N',
        P = 'P',
        R = 'R',
        @":" = ':',
        @"!" = '!',
        @"~" = '~',
        @"," = ',',
        @"]" = ']',
        @"[" = '[',
        A = 'A',
        B = 'B',
        C = 'C',
        D = 'D',
        L = 'L',
        O = 'O',
        Q = 'Q',
        @"+" = '+',
        @"-" = '-',
        @"*" = '*',
        @"/" = '/',
        @"&" = '&',
        @"%" = '%',
        @"^" = '^',
        @"<" = '<',
        @">" = '>',
        @"?" = '?',
        @"|" = '|',
        @";" = ';',
        @"=" = '=',
        W = 'W',
        I = 'I',
        G = 'G',
        S = 'S',
    };

    const Statement = struct {
        function: Function,
        arguments: union(enum) {
            zero: void,
            one: []const u8,
            two: struct { f: []const u8, s: []const u8 },
            three: struct { f: []const u8, s: []const u8, t: []const u8 },
            four: struct { f: []const u8, s: []const u8, t: []const u8, fo: []const u8 },
        },

        fn writeTo(stm: Statement, writer: anytype) !void {
            try writer.print("    //{c}\n", .{@intFromEnum(stm.function)});
            switch (stm.function) {
                .@"@" => try writer.writeAll("    _ = try function_at(gpa);\n"),
                .T, .F, .N => {},
                .P => {},
                .R => {},
                .@":" => {},
                .@"!" => {},
                .@"~" => {},
                .@"," => {},
                .@"]" => {},
                .@"[" => {},
                .A => {},
                .B => {},
                .C => {},
                .D => {},
                .L => {},
                .O => {},
                .Q => {},
                .@"+" => {},
                .@"-" => {},
                .@"*" => {},
                .@"/" => {},
                .@"&" => {},
                .@"%" => {},
                .@"^" => {},
                .@"<" => {},
                .@">" => {},
                .@"?" => {},
                .@"|" => {},
                .@";" => {},
                .@"=" => {
                    try writer.print("    {s}.set(gpa, {s});\n", .{ stm.arguments.two.f, stm.arguments.two.s });
                },
                .W => {},
                .I => {},
                .G => {},
                .S => {},
            }
        }

        fn useGpa(stm: Statement) bool {
            return switch (stm.function) {
                .@"@",
                .P,
                .@",",
                .@"[",
                .@"]",
                .A,
                .O,
                .@"+",
                .@"*",
                .@"^",
                .@"<",
                .@">",
                .G,
                .S,
                .@"=",
                => true,
                else => false,
            };
        }

        fn useStdIn(stm: Statement) bool {
            return switch (stm.function) {
                .P => true,
                else => false,
            };
        }

        fn useStdOut(stm: Statement) bool {
            return switch (stm.function) {
                .D, .O => true,
                else => false,
            };
        }
    };

    const Variable = struct {
        name: []const u8,
        index: u32,
    };
};

fn generateZigCode(gpa: std.mem.Allocator, ast: Ast, info: Info) !ZigCode {
    _ = ast; // autofix

    var vars = try std.ArrayList(ZigCode.Variable).initCapacity(
        gpa,
        info.variables.count(),
    );
    defer vars.deinit();
    var it = info.variables.iterator();
    while (it.next()) |entry| {
        vars.appendAssumeCapacity(.{
            .name = entry.key_ptr.*,
            .index = entry.value_ptr.*,
        });
    }

    return .{
        .variables = try vars.toOwnedSlice(),
        .blocks = try gpa.dupe(ZigCode.Block, &.{
            .{
                .index = 1,
                .code = try gpa.dupe(ZigCode.Statement, &.{.{
                    .function = .@"=",
                    .arguments = .{ .two = .{ .f = "n_1", .s = "tmp_2" } },
                }}),
            },
        }),
        .code = &.{},
    };
}

// fn writeZigBody(
//     ast: Ast,
//     info: Info,
//     writer: anytype,
// ) !void {
//     _ = info; // autofix
//     _ = writer; // autofix
//     const tags = ast.nodes.items(.tag);
//     switch (tags[0]) {}
// }

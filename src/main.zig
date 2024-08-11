const std = @import("std");
const parser = @import("parser.zig");
const Ast = @import("parser.zig").Ast;
const analyzer = @import("analyzer.zig");
const Emitter = @import("emit.zig").Emitter;
const VM = @import("VM.zig").VM;

pub fn main() !void {
    var gpa_impl = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_impl.deinit();

    const gpa = gpa_impl.allocator();

    var argsit = try std.process.ArgIterator.initWithAllocator(gpa);
    defer argsit.deinit();
    _ = argsit.skip();
    var files = std.ArrayList([]const u8).init(gpa);
    defer files.deinit();
    var programs = std.ArrayList([]const u8).init(gpa);
    defer programs.deinit();
    const arg = argsit.next() orelse return;

    const program = if (std.mem.eql(u8, "--file", arg) or std.mem.eql(u8, "-f", arg)) blk: {
        const fname = argsit.next() orelse return;
        var f = try std.fs.cwd().openFile(fname, .{});
        defer f.close();
        break :blk try f.readToEndAllocOptions(
            gpa,
            std.math.maxInt(usize),
            null,
            @alignOf(u8),
            0,
        );
    } else if (std.mem.eql(u8, "-e", arg)) blk: {
        break :blk try gpa.dupeZ(u8, argsit.next() orelse return);
    } else return;

    {
        // const ast = try parser.parseOld(gpa, program);
        // defer gpa.free(ast);
        var ast = try Ast.parse(gpa, program, .strict);
        defer ast.deinit(gpa);

        var info = try analyzer.analyze(ast, gpa);
        defer info.deinit();
        const init = std.crypto.random.int(u64);
        var xorisho = std.Random.DefaultPrng.init(init);
        var vm = VM.init(gpa, xorisho.random());
        defer vm.deinit();

        var e = try Emitter.init(ast, gpa);
        defer e.deinit();

        try e.emit(&vm);

        var stdout = std.io.getStdOut();
        const raw_output = stdout.writer();
        var output = std.io.bufferedWriter(raw_output);
        const stdin = std.io.getStdIn();
        const input = stdin.reader();
        const exit_code = (try vm.execute(&output, input)) orelse 0;

        try output.flush();

        std.process.exit(exit_code);
    }
}

test {
    _ = @import("VM.zig");
    _ = @import("tokenizer.zig");
    _ = @import("emit.zig");
    _ = @import("analyzer.zig");
    _ = @import("parser.zig");
}

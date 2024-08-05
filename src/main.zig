const std = @import("std");
const parser = @import("parser.zig");
const analyzer = @import("analyzer.zig");
const emit = @import("emit.zig");
const VM = @import("VM.zig").VM;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var alloc = gpa.allocator();

    var argsit = try std.process.ArgIterator.initWithAllocator(alloc);
    defer argsit.deinit();
    _ = argsit.skip();
    var files = std.ArrayList([]const u8).init(alloc);
    defer files.deinit();
    var programs = std.ArrayList([]const u8).init(alloc);
    defer programs.deinit();
    const arg = argsit.next() orelse return;
    var program: []const u8 = "";

    if (std.mem.eql(u8, "--file", arg) or std.mem.eql(u8, "-f", arg)) {
        const fname = argsit.next() orelse return;
        var f = try std.fs.cwd().openFile(fname, .{});
        defer f.close();
        program = try f.readToEndAlloc(alloc, std.math.maxInt(usize));
    } else if (std.mem.eql(u8, "-e", arg)) {
        program = argsit.next() orelse return;
    }

    {
        const ast = try parser.parse(alloc, program);
        defer alloc.free(ast);
        defer {
            for (ast) |*node| {
                switch (node.data) {
                    .arguments => |args| alloc.free(args),
                    else => {},
                }
            }
        }
        var info = try analyzer.analyze(ast, alloc);
        defer info.deinit();
        const init = std.crypto.random.int(u64);
        var xorisho = std.Random.DefaultPrng.init(init);
        var vm = VM.init(alloc, xorisho.random());
        defer vm.deinit();
        try emit.emit(ast, alloc, &vm);

        var stdout = std.io.getStdOut();
        const raw_output = stdout.writer();
        var output = std.io.bufferedWriter(raw_output);
        const stdin = std.io.getStdIn();
        const input = stdin.reader();
        const exit_code = (try vm.execute(&output, input)) orelse 0;

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

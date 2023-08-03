const std = @import("std");
const parser = @import("parser.zig");
const analyzer = @import("analyzer.zig");
const emit = @import("emit.zig");
const VM = @import("VM.zig").VM;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .safety = false }){};
    defer _ = gpa.deinit();

    var alloc = gpa.allocator();

    var argsit = try std.process.ArgIterator.initWithAllocator(alloc);
    defer argsit.deinit();
    _ = argsit.skip();
    var files = std.ArrayList([]const u8).init(alloc);
    defer files.deinit();
    var programs = std.ArrayList([]const u8).init(alloc);
    defer programs.deinit();
    while (argsit.next()) |arg| {
        if (std.mem.eql(u8, "--file", arg)) {
            const fname = argsit.next() orelse return;
            try files.append(fname);
        } else if (std.mem.eql(u8, "--prog", arg)) {
            const prog = argsit.next() orelse return;
            try programs.append(prog);
        }
    }
    for (programs.items) |prog| {
        const ast = try parser.parse(alloc, prog);
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
        var xorisho = std.rand.DefaultPrng.init(init);
        var vm = VM.init(alloc, xorisho.random());
        defer vm.deinit();
        try emit.emit(ast, alloc, &vm);

        var stdout = std.io.getStdOut();
        var raw_output = stdout.writer();
        var output = std.io.bufferedWriter(raw_output);
        const stdin = std.io.getStdIn();
        var input = stdin.reader();
        const exit_code = (try vm.execute(&output, input)) orelse 0;

        std.debug.print("\nExit code: {}\n", .{exit_code});
    }
    for (files.items) |file| {
        var f = try std.fs.cwd().openFile(file, .{});
        defer f.close();
        const code = try f.readToEndAlloc(alloc, std.math.maxInt(usize));
        defer alloc.free(code);
        const ast = try parser.parse(alloc, code);
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
        var xorisho = std.rand.DefaultPrng.init(init);
        var vm = VM.init(alloc, xorisho.random());
        defer vm.deinit();
        try emit.emit(ast, alloc, &vm);

        var stdout = std.io.getStdOut();
        var raw_output = stdout.writer();
        var output = std.io.bufferedWriter(raw_output);
        const stdin = std.io.getStdIn();
        var input = stdin.reader();
        const exit_code = (try vm.execute(&output, input)) orelse 0;
        if (exit_code != 0) {
            std.os.exit(exit_code);
        }

        // std.debug.print("\nExit code: {}\n", .{exit_code});
    }
}

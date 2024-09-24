const std = @import("std");
const parser = @import("parser.zig");
const Ast = @import("parser.zig").Ast;
const analyzer = @import("analyzer.zig");
const Emitter = @import("emit.zig").Emitter;
const VM = @import("VM.zig");
const transpiler = @import("transpiler.zig");

const debug = @import("build_options").debug;

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
    defer gpa.free(program);

    var debug_only = false;
    var emit_zig: ?[]const u8 = null;

    while (argsit.next()) |flag| {
        if (std.mem.eql(u8, "--debug-only", flag)) {
            debug_only = true;
        } else if (std.mem.eql(u8, "--emit-zig", flag)) {
            emit_zig = argsit.next() orelse "knight-prog.zig";
        }
    }

    var ast = try Ast.parse(gpa, program, .strict);
    defer ast.deinit(gpa);

    if (ast.errors.len > 0) {
        for (ast.errors) |err| {
            std.debug.print("{}\n", .{err});
        }
        return error.ParseError;
    }

    if (debug) {
        var out = std.ArrayList(u8).init(gpa);
        defer out.deinit();
        try ast.render(&out);
        std.debug.print("{s}\n", .{out.items});
    }

    var info = try analyzer.analyze(ast, gpa);
    defer info.deinit(gpa);

    if (emit_zig) |path| {
        const out_file = try std.fs.cwd().createFile(path, .{});
        defer out_file.close();
        try transpiler.writeZigMain(gpa, ast, info, out_file.writer());
    }

    const init = std.crypto.random.int(u64);
    var xorisho = std.Random.DefaultPrng.init(init);
    var vm = VM.init(gpa, xorisho.random());
    defer vm.deinit();

    var e = Emitter.init(ast, info);
    defer e.deinit(gpa);

    try e.emit(gpa, &vm);
    if (debug_only) return;

    std.process.exit(try execute(&vm));
}

fn execute(vm: *VM) !u8 {
    var stdout = std.io.getStdOut();
    const raw_output = stdout.writer();
    var output = std.io.bufferedWriter(raw_output);
    const stdin = std.io.getStdIn();
    const input = stdin.reader();
    const exit_code = (try vm.execute(&output, input)) orelse 0;

    try output.flush();

    return exit_code;
}

test {
    _ = @import("VM.zig");
    _ = @import("tokenizer.zig");
    _ = @import("emit.zig");
    _ = @import("analyzer.zig");
    _ = @import("parser.zig");
}

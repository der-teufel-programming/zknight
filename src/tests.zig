const std = @import("std");
const testing = std.testing;

const parser = @import("parser.zig");
const analyzer = @import("analyzer.zig");
const emit = @import("emit.zig");
const VM = @import("VM.zig").VM;

const RunResult = struct {
    stdout: []const u8,
    exit_code: ?u8,

    pub fn deinit(self: *RunResult, alloc: std.mem.Allocator) void {
        alloc.free(self.stdout);
        self.* = undefined;
    }
};

fn runCode(test_code: []const u8, alloc: std.mem.Allocator) !RunResult {
    const code = try std.mem.join(alloc, " ", &.{ "DUMP", test_code });
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
    defer alloc.free(vm.code);
    defer alloc.free(vm.constants);
    defer for (vm.constants) |c| {
        switch (c) {
            .list => |l| alloc.free(l),
            .string => |s| alloc.free(s),
            else => {},
        }
    };
    defer alloc.free(vm.variables);
    defer for (vm.variables) |c| {
        switch (c) {
            .list => |l| alloc.free(l),
            .string => |s| alloc.free(s),
            else => {},
        }
    };
    defer alloc.free(vm.blocks);
    defer for (vm.blocks) |b| {
        alloc.free(b);
    };
    var out = std.ArrayList(u8).init(alloc);
    var output = out.writer();
    var inp = "some text";
    var inp_stream = std.io.fixedBufferStream(inp);
    var input = inp_stream.reader();
    const exit_code = try vm.execute(output, input);
    return .{
        .stdout = try out.toOwnedSlice(),
        .exit_code = exit_code,
    };
}

fn runAndCheck(
    code: []const u8,
    output: []const u8,
    exit: ?u8,
    alloc: std.mem.Allocator,
) !void {
    var res = try runCode(code, alloc);
    defer res.deinit(alloc);
    try testing.expectEqual(exit, res.exit_code);
    try testing.expectEqualStrings(output, res.stdout);
}

test "comments" {
    var alloc = testing.allocator;

    try runAndCheck("#hello\n3", "3", null, alloc);
    try runAndCheck("# ; QUIT 1\n3", "3", null, alloc);
    try runAndCheck("+ 1#hello\n2", "3", null, alloc);
    try runAndCheck("; = a 1 : + a#world\n2", "3", null, alloc);
    try runAndCheck("; = a 1 : + a#how\na", "2", null, alloc);
    try runAndCheck("LENGTH#are you?\nIF FALSE 0 123", "3", null, alloc);
}

test "variables" {
    var alloc = testing.allocator;
    const code =
        \\; = a 1
        \\; = b 2
        \\; = blk BLOCK
        \\  ; = a 5
        \\  ; = c 6
        \\  ; = e 7
        \\  ; = f 8
        \\  : ++++,a,b,c,d,e
        \\; = c 3
        \\; = d 4
        \\: +CALL blk ,f
    ;
    try runAndCheck(code, "[5, 2, 6, 4, 7, 8]", null, alloc);
}

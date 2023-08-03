const std = @import("std");
const parser = @import("parser.zig");
const Node = parser.Node;

pub const Info = struct {
    variables: std.StringHashMap(u32),

    pub fn init(alloc: std.mem.Allocator) Info {
        return .{ .variables = std.StringHashMap(u32).init(alloc) };
    }

    pub fn deinit(self: *Info) void {
        self.variables.deinit();
    }
};

pub fn analyze(ast: []const Node, alloc: std.mem.Allocator) !Info {
    var info = Info.init(alloc);
    var next_index: u32 = 0;
    errdefer info.deinit();
    for (ast) |node| {
        switch (node.tag) {
            .identifier => {
                const name = node.data.bytes;
                var gop = try info.variables.getOrPut(name);
                if (!gop.found_existing) {
                    gop.value_ptr.* = next_index;
                    next_index += 1;
                }
            },
            else => {},
        }
    }
    return info;
}

const std = @import("std");
const Ast = @import("parser.zig").Ast;
const Node = Ast.Node;

pub const Info = struct {
    variables: std.StringHashMap(u32),

    pub fn init(alloc: std.mem.Allocator) Info {
        return .{ .variables = std.StringHashMap(u32).init(alloc) };
    }

    pub fn deinit(self: *Info) void {
        self.variables.deinit();
    }
};

pub fn analyze(ast: Ast, alloc: std.mem.Allocator) !Info {
    var info = Info.init(alloc);
    errdefer info.deinit();

    var next_index: u32 = 0;

    const tags = ast.nodes.items(.tag);
    const data = ast.nodes.items(.data);
    for (tags, data) |tag, dat| {
        switch (tag) {
            .identifier => {
                const name = ast.string_data[dat.idx..][0..dat.length];
                const gop = try info.variables.getOrPut(name);
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

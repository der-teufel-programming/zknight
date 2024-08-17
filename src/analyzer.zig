const std = @import("std");
const Ast = @import("parser.zig").Ast;
const Node = Ast.Node;

pub const Info = struct {
    variables: std.StringHashMapUnmanaged(u32) = .{},

    pub fn deinit(self: *Info, gpa: std.mem.Allocator) void {
        self.variables.deinit(gpa);
        self.* = undefined;
    }
};

pub fn analyze(ast: Ast, gpa: std.mem.Allocator) !Info {
    var info: Info = .{};
    errdefer info.deinit(gpa);

    var next_index: u32 = 0;

    const tags = ast.nodes.items(.tag);
    const data = ast.nodes.items(.data);
    for (tags, data) |tag, dat| {
        switch (tag) {
            .identifier => {
                const name = dat.getBytes(ast.string_data);
                const gop = try info.variables.getOrPut(gpa, name);
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

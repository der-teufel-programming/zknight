const VM = @This();

constants: []const Value = &.{},
variables: []Value = &.{},
blocks: []const []const Instr = &.{},
code: []const Instr = &.{},
stack: std.ArrayListUnmanaged(Value) = .{},
rand: std.Random,
gpa: Allocator,
instr_idx: usize = 0,

pub fn init(gpa: Allocator, r: std.Random) VM {
    return .{
        .gpa = gpa,
        .rand = r,
    };
}

pub fn deinit(self: *VM) void {
    for (self.constants) |c| {
        c.free(self.gpa);
    }
    self.gpa.free(self.constants);

    for (self.variables) |v| {
        v.free(self.gpa);
    }
    self.gpa.free(self.variables);

    for (self.blocks) |blk| {
        self.gpa.free(blk);
    }
    self.gpa.free(self.blocks);

    for (self.stack.items) |v| {
        v.free(self.gpa);
    }
    self.stack.deinit(self.gpa);

    self.gpa.free(self.code);
}

fn push(self: *VM, value: Value) !void {
    try self.stack.append(self.gpa, value);
}

fn last(self: *VM, default: Value.Type) !*Value {
    if (self.stack.items.len == 0) {
        try self.push(switch (default) {
            .number => .{ .number = 0 },
            .string => try self.emptyString(),
            .list => try self.emptyList(),
            .bool => .{ .bool = false },
            .block => unreachable,
            .null => .null,
        });
    }
    return &self.stack.items[self.stack.items.len - 1];
}

pub fn execute(self: *VM, output: anytype, input: anytype) !?u8 {
    // const log = std.log.scoped(.execute);
    while (self.instr_idx < self.code.len) : (self.instr_idx += 1) {
        const instr = self.code[self.instr_idx];
        // log.debug("[{}]: {}", .{ self.instr_idx, instr });
        switch (instr) {
            .nop => {},
            .true,
            .false,
            => try self.push(.{ .bool = (instr == .true) }),
            .null => try self.push(.null),
            .empty_list => try self.push(try self.emptyList()),
            .call => {
                const block_idx = self.stack.popOrNull() orelse {
                    if (sanitize) return 250;
                    continue;
                };
                defer block_idx.free(self.gpa);
                if (sanitize) {
                    if (block_idx != .block) return 255;
                }
                var block = self.blocks[block_idx.block];
                const index = self.instr_idx;
                std.mem.swap([]const Instr, &self.code, &block);
                self.instr_idx = 0;
                defer std.mem.swap([]const Instr, &self.code, &block);
                defer self.instr_idx = index;
                const exit_code = try self.execute(output, input);
                if (exit_code != null) {
                    return exit_code;
                }
            },
            .quit => {
                const value: Value = self.stack.popOrNull() orelse .{ .number = 0 };
                defer value.free(self.gpa);

                if (sanitize) {
                    if (value == .block) return error.BlockNotAllowed;
                }

                return @intCast(value.toNumber());
            },
            .length => {
                const value: Value = self.stack.popOrNull() orelse try self.emptyList();
                defer value.free(self.gpa);

                if (sanitize) {
                    if (value == .block) return error.BlockNotAllowed;
                }

                try self.push(value.len());
            },
            .not => {
                var value: *Value = try self.last(.bool);
                if (sanitize) {
                    if (value.* == .block) return error.BlockNotAllowed;
                }

                try value.mutate(.bool, self.gpa);
                value.bool = !value.bool;
            },
            .negate => {
                var value: *Value = try self.last(.bool);
                if (sanitize) {
                    if (value.* == .block) return error.BlockNotAllowed;
                }
                try value.mutate(.number, self.gpa);
                value.number = -value.number;
            },
            .ascii => {
                const value: Value = self.stack.popOrNull() orelse try self.emptyString();
                defer value.free(self.gpa);

                switch (value) {
                    .number => |number| try self.push(
                        .{
                            .string = try self.gpa.dupe(u8, &.{@truncate(@abs(number))}),
                        },
                    ),
                    .string => |string| try self.push(.{ .number = string[0] }),
                    else => if (sanitize) return error.BadAscii,
                }
            },
            .box => {
                const value: Value = self.stack.popOrNull() orelse .{ .number = 0 };
                try self.push(.{ .list = try self.gpa.dupe(Value, &.{value}) });
            },
            .head => {
                const value: Value = self.stack.popOrNull() orelse try self.emptyString();
                defer value.free(self.gpa);

                var head: Value = undefined;
                switch (value) {
                    .string => |string| head = .{ .string = try self.gpa.dupe(u8, string[0..1]) },
                    .list => |list| head = try list[0].dupe(self.gpa),
                    else => if (sanitize) return 255,
                }
                try self.push(head);
            },
            .tail => {
                const value: Value = self.stack.popOrNull() orelse try self.emptyString();
                defer value.free(self.gpa);

                switch (value) {
                    .string => |string| try self.push(.{ .string = try self.gpa.dupe(u8, string[1..]) }),
                    .list => |list| {
                        const new_list = try self.gpa.alloc(Value, list.len - 1);
                        for (list[1..], new_list) |val, *v| {
                            v.* = try val.dupe(self.gpa);
                        }
                        try self.push(.{ .list = new_list });
                    },
                    else => return error.BadTail,
                }
            },
            .add => {
                const arg2: Value = self.stack.popOrNull() orelse .{ .number = 0 };
                defer arg2.free(self.gpa);
                const arg1: Value = self.stack.popOrNull() orelse .{ .number = 0 };
                defer arg1.free(self.gpa);

                if (sanitize) {
                    if (arg1 == .block or arg2 == .block) return 255;
                }

                switch (arg1) {
                    .number => |number| try self.push(.{ .number = number + arg2.toNumber() }),
                    .string => |string| {
                        const str2 = try arg2.toString(self.gpa);
                        defer self.gpa.free(str2);
                        try self.push(
                            .{ .string = try std.mem.concat(self.gpa, u8, &.{ string, str2 }) },
                        );
                    },
                    .list => |list| {
                        const list2 = try arg2.toList(self.gpa);
                        defer self.gpa.free(list2);
                        const new_list = try self.gpa.alloc(Value, list.len + list2.len);
                        for (new_list[0..list.len], list) |*nv, v| {
                            nv.* = try v.dupe(self.gpa);
                        }
                        for (new_list[list.len..], list2) |*nv, v| {
                            nv.* = try v.dupe(self.gpa);
                        }
                        try self.push(
                            .{ .list = new_list },
                        );
                    },
                    else => return error.BadAdd,
                }
            },
            .sub => {
                const arg2: Value = self.stack.popOrNull() orelse .{ .number = 0 };
                defer arg2.free(self.gpa);
                const arg1: Value = self.stack.popOrNull() orelse .{ .number = 0 };
                defer arg1.free(self.gpa);

                if (sanitize) {
                    if (arg1 == .block or arg2 == .block) return error.BlockNotAllowed;

                    if (arg1 != .number) return error.BadSub;
                }

                try self.push(.{ .number = arg1.toNumber() - arg2.toNumber() });
            },
            .mult => {
                const arg2: Value = self.stack.popOrNull() orelse .{ .number = 0 };
                defer arg2.free(self.gpa);
                const arg1: Value = self.stack.popOrNull() orelse .{ .number = 0 };
                defer arg1.free(self.gpa);

                if (sanitize) {
                    if (arg1 == .block or arg2 == .block) return error.BlockNotAllowed;
                }

                switch (arg1) {
                    .number => |number| try self.push(.{ .number = number * arg2.toNumber() }),
                    .string => |string| {
                        const str2 = arg2.toNumber();
                        var value_builder = std.ArrayList([]const u8).init(self.gpa);
                        defer value_builder.deinit();
                        try value_builder.appendNTimes(string, @intCast(str2));
                        try self.push(.{ .string = try std.mem.concat(self.gpa, u8, value_builder.items) });
                    },
                    .list => |list| {
                        const str2: usize = @intCast(arg2.toNumber());
                        var value_builder = std.ArrayList([]const Value).init(self.gpa);
                        defer value_builder.deinit();
                        try value_builder.appendNTimes(list, @intCast(str2));
                        const new_list = try self.gpa.alloc(Value, list.len * str2);
                        for (new_list, 0..) |*new, idx| {
                            new.* = try list[idx % list.len].dupe(self.gpa);
                        }
                        try self.push(.{ .list = new_list });
                    },
                    else => return error.BadMult,
                }
            },
            .mod => {
                const arg2: Value = self.stack.popOrNull() orelse .{ .number = 0 };
                defer arg2.free(self.gpa);
                const arg1: Value = self.stack.popOrNull() orelse .{ .number = 0 };
                defer arg1.free(self.gpa);

                if (sanitize) {
                    const num2 = arg2.toNumber();
                    if (arg1 != .number or num2 == 0) return 255;
                    const num1 = arg1.toNumber();
                    if (num1 < 0 or num2 < 0) return 255;
                }
                var result: Value = undefined;

                switch (arg1) {
                    .number => |number| result = .{ .number = std.math.mod(isize, number, arg2.toNumber()) catch return 255 },
                    else => if (sanitize) return 255,
                }
                try self.push(result);
            },
            .div => {
                const arg2: Value = self.stack.popOrNull() orelse .{ .number = 0 };
                defer arg2.free(self.gpa);
                const arg1: Value = self.stack.popOrNull() orelse .{ .number = 0 };
                defer arg1.free(self.gpa);

                if (sanitize) {
                    const num2 = arg2.toNumber();
                    if (arg1 != .number or num2 == 0) return 255;
                }
                var result: Value = undefined;
                switch (arg1) {
                    .number => |number| result = .{ .number = std.math.divTrunc(isize, number, arg2.toNumber()) catch 0 },
                    else => if (sanitize) return 255,
                }
                try self.push(result);
            },
            .exp => {
                const arg2: Value = self.stack.popOrNull() orelse .{ .number = 0 };
                defer arg2.free(self.gpa);
                const arg1: Value = self.stack.popOrNull() orelse .{ .number = 0 };
                defer arg1.free(self.gpa);

                if (sanitize) {
                    if (arg1 == .block or arg2 == .block) return 255;
                }

                switch (arg1) {
                    .number => |number1| {
                        const number2 = arg2.toNumber();
                        if (sanitize) {
                            if (number1 == 0 and number2 < 0) return 255;
                        }
                        try self.push(.{ .number = std.math.powi(isize, number1, number2) catch 0 });
                    },
                    .list => |list1| {
                        if (list1.len == 0) {
                            try self.push(try self.emptyString());
                        } else {
                            const string2 = try arg2.toString(self.gpa);
                            defer self.gpa.free(string2);
                            var list_strings = try self.gpa.alloc([]const u8, list1.len);
                            defer self.gpa.free(list_strings);

                            for (list1, 0..) |elem, idx| {
                                list_strings[idx] = try elem.toString(self.gpa);
                            }
                            defer {
                                for (list_strings) |str| {
                                    self.gpa.free(str);
                                }
                            }
                            const res = try std.mem.join(self.gpa, string2, list_strings);
                            try self.push(.{ .string = res });
                        }
                    },
                    else => return error.BadExp,
                }
            },
            .drop => if (self.stack.popOrNull()) |val| val.free(self.gpa),
            .dupe => {
                const value: Value = self.stack.getLastOrNull() orelse .{ .number = 0 };
                try self.push(try value.dupe(self.gpa));
            },
            .jump => |jump_idx| self.instr_idx = jump_idx,
            .cond => |cond_idx| {
                const condition: Value = self.stack.popOrNull() orelse .{ .bool = false };
                defer condition.free(self.gpa);

                if (sanitize) {
                    if (condition == .block) return error.BlockNotAllowed;
                }
                if (!condition.toBool()) {
                    self.instr_idx = cond_idx;
                }
            },
            .load_variable => |var_idx| try self.push(try self.variables[var_idx].dupe(self.gpa)),
            .store_variable => |var_idx| {
                self.variables[var_idx].free(self.gpa);
                self.variables[var_idx] = try self.stack.getLast().dupe(self.gpa);
            },
            .block => |blk_idx| try self.push(.{ .block = blk_idx }),
            .constant => |const_idx| try self.push(try self.constants[const_idx].dupe(self.gpa)),
            .output => {
                const arg: Value = self.stack.popOrNull() orelse try self.emptyString();
                defer arg.free(self.gpa);

                if (sanitize) {
                    if (arg == .block) return 255;
                }

                const string = try arg.toString(self.gpa);
                defer self.gpa.free(string);

                const backslash_end = if (string.len == 0) false else string[string.len - 1] == '\\';
                var writer = output.writer();
                if (backslash_end) {
                    try writer.writeAll(string[0 .. string.len - 1]);
                } else {
                    try writer.writeAll(string);
                    try writer.writeByte('\n');
                }
                try output.flush();
                try self.push(.null);
            },
            .dump => {
                const arg: Value = self.stack.getLastOrNull() orelse .null;

                const writer = output.writer();
                try arg.dump(writer);
                try output.flush();
            },
            .less => {
                const arg2: Value = self.stack.popOrNull() orelse .{ .number = 0 };
                defer arg2.free(self.gpa);
                const arg1: Value = self.stack.popOrNull() orelse .{ .number = 0 };
                defer arg1.free(self.gpa);

                if (sanitize) {
                    if (arg1 != .number and arg1 != .bool and arg1 != .string and arg1 != .list) return 255;
                    if (arg2 == .block) return 255;
                }

                try self.push(.{ .bool = (try arg1.order(arg2, self.gpa)) == .lt });
            },
            .greater => {
                const arg2: Value = self.stack.popOrNull() orelse .{ .number = 0 };
                defer arg2.free(self.gpa);
                const arg1: Value = self.stack.popOrNull() orelse .{ .number = 0 };
                defer arg1.free(self.gpa);

                if (sanitize) {
                    if (arg1 != .number and arg1 != .bool and arg1 != .string and arg1 != .list) return 255;
                    if (arg2 == .block) return 255;
                }

                try self.push(.{ .bool = (try arg1.order(arg2, self.gpa)) == .gt });
            },
            .equal => {
                const arg2: Value = self.stack.popOrNull() orelse .{ .number = 0 };
                defer arg2.free(self.gpa);
                const arg1: Value = self.stack.popOrNull() orelse .{ .number = 0 };
                defer arg1.free(self.gpa);

                if (sanitize) {
                    if (arg1 == .block or arg2 == .block) return 255;
                }

                try self.push(.{ .bool = arg1.equals(arg2) });
            },
            .andthen => {
                const arg2: Value = self.stack.popOrNull() orelse .{ .number = 0 };
                const arg1: Value = self.stack.popOrNull() orelse .{ .number = 0 };

                if (sanitize) {
                    if (arg1 == .block or arg2 == .block) return 255;
                }

                if (!arg1.toBool()) {
                    arg2.free(self.gpa);
                    try self.push(arg1);
                } else {
                    arg1.free(self.gpa);
                    try self.push(arg2);
                }
            },
            .orthen => {
                const arg2: Value = self.stack.popOrNull() orelse .{ .number = 0 };
                const arg1: Value = self.stack.popOrNull() orelse .{ .number = 0 };

                if (sanitize) {
                    if (arg1 == .block or arg2 == .block) return 255;
                }

                if (arg1.toBool()) {
                    arg2.free(self.gpa);
                    try self.push(arg1);
                } else {
                    arg1.free(self.gpa);
                    try self.push(arg2);
                }
            },
            .prompt => {
                var input_buffer = std.ArrayList(u8).init(self.gpa);
                defer input_buffer.deinit();

                const input_stream = input_buffer.writer();
                var was_eof = false;
                input.streamUntilDelimiter(input_stream, '\n', null) catch |err| {
                    switch (err) {
                        error.EndOfStream => was_eof = true,
                        else => return err,
                    }
                };

                if (input_buffer.items.len == 0 and was_eof) {
                    try self.push(.null);
                } else {
                    const trimmed = std.mem.trimRight(u8, input_buffer.items, "\r");
                    try self.push(.{ .string = try self.gpa.dupe(u8, trimmed) });
                }
            },
            .random => {
                try self.push(.{ .number = self.rand.intRangeAtMost(isize, 0, std.math.maxInt(isize)) });
            },
            .get => {
                const len_arg: Value = self.stack.popOrNull() orelse .{ .number = 0 };
                defer len_arg.free(self.gpa);
                const idx_arg: Value = self.stack.popOrNull() orelse .{ .number = 0 };
                defer idx_arg.free(self.gpa);
                const arg: Value = self.stack.popOrNull() orelse try self.emptyList();
                defer arg.free(self.gpa);

                if (sanitize) {
                    if (len_arg == .block or idx_arg == .block or arg == .block) return 255;
                }

                const len: usize = @intCast(len_arg.toNumber());
                const idx: usize = @intCast(idx_arg.toNumber());
                switch (arg) {
                    .list => |list| {
                        const new_list = try self.gpa.alloc(Value, len);
                        for (new_list, list[idx..][0..len]) |*nv, v| {
                            nv.* = try v.dupe(self.gpa);
                        }
                        try self.push(.{ .list = new_list });
                    },
                    .string => |string| {
                        const new_string = string[idx..][0..len];
                        try self.push(.{ .string = try self.gpa.dupe(u8, new_string) });
                    },
                    else => return error.BadGet,
                }
            },
            .set => {
                const new: Value = self.stack.popOrNull() orelse .{ .number = 0 };
                defer new.free(self.gpa);
                const len_arg: Value = self.stack.popOrNull() orelse .{ .number = 0 };
                defer len_arg.free(self.gpa);
                const idx_arg: Value = self.stack.popOrNull() orelse .{ .number = 0 };
                defer idx_arg.free(self.gpa);
                const arg: Value = self.stack.popOrNull() orelse try self.emptyList();
                defer arg.free(self.gpa);

                if (sanitize) {
                    if (new == .block or len_arg == .block or idx_arg == .block or arg == .block) return 255;
                }

                const len: usize = @intCast(len_arg.toNumber());
                const idx: usize = @intCast(idx_arg.toNumber());
                switch (arg) {
                    .list => |list| {
                        const new_list_mid = try new.toList(self.gpa);
                        defer self.gpa.free(new_list_mid);
                        const new_len = new_list_mid.len;
                        const new_list = try self.gpa.alloc(
                            Value,
                            list.len - len + new_len,
                        );
                        for (new_list[0..idx], list[0..idx]) |*nv, v| {
                            nv.* = try v.dupe(self.gpa);
                        }
                        for (new_list[idx..][0..new_len], new_list_mid) |*nv, v| {
                            nv.* = try v.dupe(self.gpa);
                        }
                        for (new_list[idx + new_len ..], list[idx + len ..]) |*nv, v| {
                            nv.* = try v.dupe(self.gpa);
                        }
                        try self.push(.{ .list = new_list });
                    },
                    .string => |string| {
                        const new_string_one = string[0..idx];
                        const new_string_two = string[idx + len ..];
                        const new_string_mid = try new.toString(self.gpa);
                        defer self.gpa.free(new_string_mid);
                        const new_string = try std.mem.concat(
                            self.gpa,
                            u8,
                            &.{ new_string_one, new_string_mid, new_string_two },
                        );
                        try self.push(.{ .string = new_string });
                    },
                    else => return error.BadSet,
                }
            },
            // else => {
            //     std.log.debug("Implement {s} in execute", .{@tagName(instr)});
            //     return 255;
            // },
        }
    }
    return null;
}

inline fn emptyString(self: *VM) !Value {
    return .{ .string = try self.gpa.dupe(u8, "") };
}

inline fn emptyList(self: *VM) !Value {
    return .{ .list = try self.gpa.dupe(Value, &.{}) };
}

pub fn debugPrint(self: VM) void {
    std.debug.print("Code:\n", .{});
    for (self.code, 0..) |code, idx| {
        std.debug.print("{d:0>2}: ", .{idx});
        switch (code) {
            .load_variable,
            .store_variable,
            .block,
            => |load| std.debug.print("{s}({})\n", .{ @tagName(code), load }),
            .constant => |const_idx| {
                const c = self.constants[const_idx];
                std.debug.print("{s}({}) [", .{ @tagName(code), const_idx });
                c.debugPrint();
                std.debug.print("]\n", .{});
            },
            .loop,
            .cond,
            => |load| std.debug.print("{s}({})\n", .{ @tagName(code), load }),
            else => std.debug.print("{s}\n", .{@tagName(code)}),
        }
    }
    std.debug.print("Blocks [{}]\n", .{self.blocks.len});
    for (self.blocks, 0..) |blk, bidx| {
        std.debug.print("{d:0>2}:\n", .{bidx});
        for (blk, 0..) |code, idx| {
            std.debug.print("  {d:0>2}: ", .{idx});
            switch (code) {
                .load_variable,
                .store_variable,
                .block,
                => |load| std.debug.print("{s}({})\n", .{ @tagName(code), load }),
                .constant => |const_idx| {
                    const c = self.constants[const_idx];
                    std.debug.print("{s}({}) [", .{ @tagName(code), const_idx });
                    c.debugPrint();
                    std.debug.print("]\n", .{});
                },
                .loop,
                .cond,
                => |load| std.debug.print("{s}({})\n", .{ @tagName(code), load }),
                else => std.debug.print("{s}\n", .{@tagName(code)}),
            }
        }
    }
    std.debug.print("Constants [{}]\n", .{self.constants.len});
    for (self.constants, 0..) |constant, idx| {
        std.debug.print("{d:0>2}: ", .{idx});
        switch (constant) {
            .string => |string| std.debug.print("`{s}`\n", .{string}),
            .list => |list| for (list) |value| {
                value.debugPrint();
                std.debug.print(", ", .{});
            },
            inline else => |payload| std.debug.print("{}\n", .{payload}),
        }
    }
}

pub fn debugStackPrint(self: VM) void {
    for (self.stack.items, 0..) |v, idx| {
        std.debug.print("{d:0>2}: ", .{idx});
        v.debugPrint();
        std.debug.print("\n", .{});
    }
}

pub const Value = union(enum) {
    number: isize,
    string: []const u8,
    list: []const Value,
    bool: bool,
    /// index into VM.blocks
    block: u32,
    null: void,

    pub const Type = std.meta.Tag(Value);

    pub fn dupe(self: Value, gpa: Allocator) !Value {
        return switch (self) {
            .number, .bool, .block, .null => self,
            .string => .{ .string = try gpa.dupe(u8, self.string) },
            .list => blk: {
                const new_list = try gpa.alloc(Value, self.list.len);
                for (new_list, self.list) |*nv, v| {
                    nv.* = try v.dupe(gpa);
                }
                break :blk .{ .list = new_list };
            },
        };
    }

    pub fn free(self: Value, gpa: Allocator) void {
        switch (self) {
            .string => gpa.free(self.string),
            .list => |list| {
                for (list) |el| el.free(gpa);
                gpa.free(list);
            },
            else => {},
        }
    }

    pub fn debugPrint(self: Value) void {
        switch (self) {
            .string => |string| std.debug.print("(Value.string)`{s}`", .{string}),
            .list => |list| {
                std.debug.print("(Value.list)[", .{});
                for (list) |value| {
                    value.debugPrint();
                    std.debug.print(", ", .{});
                }
                std.debug.print("]", .{});
            },
            .null => std.debug.print("(Value.null)", .{}),
            inline else => |payload| std.debug.print("(Value.{s}){}", .{ @tagName(self), payload }),
        }
    }

    pub fn dump(self: Value, output: anytype) !void {
        switch (self) {
            .number => |number| try output.print("{}", .{number}),
            .string => |string| {
                try output.writeAll("\"");
                var buff = std.io.bufferedWriter(output);
                var writer = buff.writer();
                for (string) |char| {
                    switch (char) {
                        '\t' => try writer.writeAll("\\t"),
                        '\n' => try writer.writeAll("\\n"),
                        '\r' => try writer.writeAll("\\r"),
                        '\\' => try writer.writeAll("\\\\"),
                        '"' => try writer.writeAll("\\\""),
                        else => try writer.writeByte(char),
                    }
                }
                try buff.flush();
                try output.writeAll("\"");
            },
            .bool => |value| try output.writeAll(if (value) "true" else "false"),
            .block => {},
            .null => try output.writeAll("null"),
            .list => |list| {
                try output.writeAll("[");
                for (list, 0..) |elem, idx| {
                    try elem.dump(output);
                    if (idx != list.len - 1) try output.writeAll(", ");
                }
                try output.writeAll("]");
            },
        }
    }

    pub fn toNumber(self: Value) isize {
        switch (self) {
            .number => |value| return value,
            .null => return 0,
            .bool => |value| return @intFromBool(value),
            .string => |string| {
                if (string.len == 0) return 0;

                var start_idx: usize = 0;
                while (start_idx < string.len and std.ascii.isWhitespace(string[start_idx])) {
                    start_idx += 1;
                }
                var end_idx: usize = start_idx;
                if (string[start_idx] == '-' or string[start_idx] == '+') end_idx += 1;
                while (end_idx < string.len and std.ascii.isDigit(string[end_idx])) {
                    end_idx += 1;
                }
                if (start_idx > 0 and (string[start_idx - 1] == '-' or string[start_idx - 1] == '+')) {
                    start_idx -= 1;
                }

                return std.fmt.parseInt(isize, string[start_idx..end_idx], 10) catch 0;
            },
            .list => |list| return @intCast(list.len),
            .block => return 0,
        }
    }

    pub fn toBool(self: Value) bool {
        switch (self) {
            .bool => |value| return value,
            .null => return false,
            .number => |value| return value != 0,
            .string => |string| return string.len > 0,
            .list => |list| return list.len > 0,
            .block => return false,
        }
    }

    pub fn toString(self: Value, gpa: Allocator) ![]const u8 {
        switch (self) {
            .string => |str| return gpa.dupe(u8, str),
            .null => return gpa.dupe(u8, &.{}),
            .number => |value| return std.fmt.allocPrint(gpa, "{}", .{value}),
            .bool => |value| return if (value) gpa.dupe(u8, "true") else gpa.dupe(u8, "false"),
            .block => return gpa.dupe(u8, &.{}),
            .list => |list| {
                const strings = try gpa.alloc([]const u8, list.len);
                defer gpa.free(strings);
                for (list, strings) |v, *str| {
                    str.* = try v.toString(gpa);
                }
                defer {
                    for (strings) |str| {
                        gpa.free(str);
                    }
                }
                return std.mem.join(gpa, "\n", strings);
            },
        }
    }

    pub fn toList(self: Value, gpa: Allocator) ![]const Value {
        switch (self) {
            .list => |value| return gpa.dupe(Value, value),
            .null => return gpa.dupe(Value, &.{}),
            .number => |value| {
                if (value == 0) {
                    return gpa.dupe(Value, &.{.{ .number = 0 }});
                }
                const digit_count = std.fmt.count("{}", .{@abs(value)});
                const sgn: isize = if (value < 0) -1 else 1;
                var digits = try gpa.alloc(Value, digit_count);
                var number = @abs(value);

                var idx: usize = 0;
                while (number > 0) : (idx += 1) {
                    digits[idx] = .{ .number = sgn * @as(isize, @intCast(number % 10)) };
                    number /= 10;
                }
                std.mem.reverse(Value, digits);

                return digits;
            },
            .bool => |value| {
                if (value) {
                    return gpa.dupe(Value, &.{.{ .bool = true }});
                } else {
                    const list = try gpa.alloc(Value, 0);
                    return list;
                }
            },
            .string => |string| {
                var list = try gpa.alloc(Value, string.len);
                for (string, 0..) |c, idx| {
                    list[idx] = .{ .string = try gpa.dupe(u8, &.{c}) };
                }
                return list;
            },
            .block => return gpa.dupe(Value, &.{}),
        }
    }

    pub fn len(self: Value) Value {
        return .{
            .number = @intCast(switch (self) {
                .list => |value| value.len,
                .null => 0,
                .number => |value| std.fmt.count("{}", .{@abs(value)}),
                .bool => |value| @intFromBool(value),
                .string => |value| value.len,
                .block => 0,
            }),
        };
    }

    pub fn order(self: Value, other: Value, alloc: Allocator) !std.math.Order {
        switch (self) {
            .number => |num1| {
                const num2 = other.toNumber();
                return std.math.order(num1, num2);
            },
            .bool => |bool1| {
                const bool2 = other.toBool();
                if (bool1 == bool2) return .eq;
                if (!bool1 and bool2) return .lt;
                return .gt;
            },
            .block => return .eq,
            .null => return if (other == .null) .eq else .lt,
            .string => |str1| {
                const str2 = try other.toString(alloc);
                defer alloc.free(str2);
                return std.mem.order(u8, str1, str2);
            },
            .list => |lst1| {
                const lst2 = try other.toList(alloc);
                defer alloc.free(lst2);
                const n = @min(lst1.len, lst2.len);
                for (lst1[0..n], lst2[0..n]) |lhs_elem, rhs_elem| {
                    switch (try lhs_elem.order(rhs_elem, alloc)) {
                        .eq => continue,
                        .lt => return .lt,
                        .gt => return .gt,
                    }
                }
                return std.math.order(lst1.len, lst2.len);
            },
        }
    }

    pub fn equals(self: Value, other: Value) bool {
        switch (self) {
            .number => |num1| {
                return switch (other) {
                    .number => |num2| num1 == num2,
                    else => false,
                };
            },
            .bool => |bool1| {
                return switch (other) {
                    .bool => |bool2| bool1 == bool2,
                    else => false,
                };
            },
            .null => return other == .null,
            .block => |b1| {
                return switch (other) {
                    .block => |b2| b1 == b2,
                    else => false,
                };
            },
            .string => |str1| {
                return switch (other) {
                    .string => |str2| std.mem.eql(u8, str1, str2),
                    else => false,
                };
            },
            .list => |lst1| {
                switch (other) {
                    .list => |lst2| {
                        if (lst1.len != lst2.len) return false;
                        for (lst1, lst2) |e1, e2| {
                            if (!e1.equals(e2)) return false;
                        }
                        return true;
                    },
                    else => return false,
                }
            },
        }
    }

    pub fn mutate(self: *Value, new_type: Type, gpa: Allocator) !void {
        if (self.* == new_type) return;
        const old_self = self.*;
        defer old_self.free(gpa);
        switch (new_type) {
            .number => self.* = .{ .number = self.toNumber() },
            .string => self.* = .{ .string = try self.toString(gpa) },
            .list => self.* = .{ .list = try self.toList(gpa) },
            .bool => self.* = .{ .bool = self.toBool() },
            .block => unreachable,
            .null => self.* = .null,
        }
    }
};

pub const Instr = union(enum) {
    true,
    false,
    null,
    empty_list,
    prompt,
    random,
    call,
    quit,
    dump,
    output,
    length,
    not,
    negate,
    ascii,
    box,
    head,
    tail,
    add,
    sub,
    mult,
    div,
    mod,
    exp,
    less,
    greater,
    equal,
    andthen,
    orthen,
    drop,
    dupe,
    nop,
    /// index to jump to
    jump: usize,
    /// index to jump to on falsy
    cond: usize,
    get,
    set,
    /// variable index
    load_variable: u32,
    /// variable index
    store_variable: u32,
    /// block index
    block: u32,
    /// constant index
    constant: u32,
};

const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const build_options = @import("build_options");
const sanitize = build_options.sanitize;

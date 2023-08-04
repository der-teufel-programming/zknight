pub const VM = @This();

constants: []const Value = &.{},
variables: []Value = &.{},
blocks: []const []const Instr = &.{},
code: []const Instr = &.{},
stack: std.ArrayList(Value),
rand: std.rand.Random,
instr_idx: usize = 0,

pub fn init(alloc: Allocator, r: std.rand.Random) VM {
    return .{
        .stack = std.ArrayList(Value).init(alloc),
        .rand = r,
    };
}

pub fn deinit(self: *VM) void {
    for (self.stack.items) |v| {
        switch (v) {
            .list => |list| self.stack.allocator.free(list),
            .string => |str| self.stack.allocator.free(str),
            else => {},
        }
    }
    self.stack.deinit();
}

pub fn execute(self: *VM, output: anytype, input: anytype) !?u8 {
    while (self.instr_idx < self.code.len) : (self.instr_idx += 1) {
        const instr = self.code[self.instr_idx];
        switch (instr) {
            .nop => {},
            .true,
            .false,
            => try self.stack.append(.{ .bool = (instr == .true) }),
            .null => try self.stack.append(.null),
            .empty_list => try self.stack.append(.{ .list = &.{} }),
            .call => {
                const block_idx = self.stack.popOrNull() orelse continue;
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
                var value = self.stack.popOrNull() orelse Value{ .number = 0 };
                return @intCast(value.toNumber());
            },
            .length => {
                var value = self.stack.popOrNull() orelse Value{ .list = &.{} };
                const list = try value.toList(self.stack.allocator);
                defer self.stack.allocator.free(list);
                try self.stack.append(.{ .number = @intCast(list.len) });
            },
            .not => {
                var value = self.stack.popOrNull() orelse Value{ .bool = false };
                try self.stack.append(.{ .bool = !value.toBool() });
            },
            .negate => {
                var value = self.stack.popOrNull() orelse Value{ .number = 0 };
                try self.stack.append(.{ .number = -(value.toNumber()) });
            },
            .ascii => {
                var value = self.stack.popOrNull() orelse Value{ .string = "" };
                var ascii: Value = undefined;
                switch (value) {
                    .number => |number| ascii = .{ .string = &.{@as(u8, @truncate(std.math.absCast(number)))} },
                    .string => |string| ascii = .{ .number = string[0] },
                    else => {},
                }
                try self.stack.append(ascii);
            },
            .box => {
                const value = self.stack.popOrNull() orelse Value{ .number = 0 };
                const new_list = try self.stack.allocator.alloc(Value, 1);
                new_list[0] = value;
                try self.stack.append(Value{ .list = new_list });
            },
            .head => {
                var value = self.stack.popOrNull() orelse Value{ .string = "" };
                var head: Value = undefined;
                switch (value) {
                    .string => |string| head = .{ .string = string[0..1] },
                    .list => |list| head = list[0],
                    else => {},
                }
                try self.stack.append(head);
            },
            .tail => {
                var value = self.stack.popOrNull() orelse Value{ .string = "" };
                var tail: Value = undefined;
                switch (value) {
                    .string => |string| tail = .{ .string = string[1..] },
                    .list => |list| tail = .{ .list = list[1..] },
                    else => {},
                }
                try self.stack.append(tail);
            },
            .add => {
                const arg2 = self.stack.popOrNull() orelse Value{ .number = 0 };
                const arg1 = self.stack.popOrNull() orelse Value{ .number = 0 };

                var result: Value = undefined;
                switch (arg1) {
                    .number => |number| result = .{ .number = number + (arg2.toNumber()) },
                    .string => |string| {
                        const str2 = try arg2.toString(self.stack.allocator);
                        result = .{ .string = try std.mem.concat(self.stack.allocator, u8, &.{ string, str2 }) };
                    },
                    .list => |list| {
                        const list2 = try arg2.toList(self.stack.allocator);
                        defer self.stack.allocator.free(list);
                        defer self.stack.allocator.free(list2);
                        result = .{ .list = try std.mem.concat(self.stack.allocator, Value, &.{ list, list2 }) };
                    },
                    else => {},
                }
                try self.stack.append(result);
            },
            .sub => {
                const arg2 = (self.stack.popOrNull() orelse Value{ .number = 0 }).toNumber();
                const arg1 = (self.stack.popOrNull() orelse Value{ .number = 0 }).toNumber();
                try self.stack.append(.{ .number = arg1 - arg2 });
            },
            .drop => _ = self.stack.popOrNull(),
            .dupe => {
                const value = self.stack.getLastOrNull() orelse Value{ .number = 0 };
                try self.stack.append(try value.dupe(self.stack.allocator));
            },
            .jump => |jump_idx| self.instr_idx = jump_idx,
            .cond => |cond_idx| {
                const condition = (self.stack.popOrNull() orelse Value{ .bool = false });
                if (!condition.toBool()) {
                    self.instr_idx = cond_idx;
                }
            },
            .load_variable => |var_idx| try self.stack.append(try self.variables[var_idx].dupe(self.stack.allocator)),
            .store_variable => |var_idx| self.variables[var_idx] = self.stack.getLast(),
            .block => |blk_idx| try self.stack.append(.{ .block = blk_idx }),
            .constant => |const_idx| try self.stack.append(self.constants[const_idx]),
            .mult => {
                const arg2 = self.stack.popOrNull() orelse Value{ .number = 0 };
                const arg1 = self.stack.popOrNull() orelse Value{ .number = 0 };
                var result: Value = undefined;
                switch (arg1) {
                    .number => |number| result = .{ .number = number * arg2.toNumber() },
                    .string => |string| {
                        const str2 = arg2.toNumber();
                        var value_builder = std.ArrayList([]const u8).init(self.stack.allocator);
                        try value_builder.appendNTimes(string, @intCast(str2));
                        result = .{ .string = try std.mem.concat(self.stack.allocator, u8, try value_builder.toOwnedSlice()) };
                    },
                    .list => |list| {
                        const str2 = arg2.toNumber();
                        var value_builder = std.ArrayList([]const Value).init(self.stack.allocator);
                        try value_builder.appendNTimes(list, @intCast(str2));
                        result = .{ .list = try std.mem.concat(self.stack.allocator, Value, try value_builder.toOwnedSlice()) };
                    },
                    else => {},
                }
                try self.stack.append(result);
            },
            .mod => {
                const arg2 = self.stack.popOrNull() orelse Value{ .number = 0 };
                const arg1 = self.stack.popOrNull() orelse Value{ .number = 0 };
                var result: Value = undefined;
                switch (arg1) {
                    .number => |number| result = .{ .number = std.math.mod(isize, number, arg2.toNumber()) catch return 255 },
                    else => {},
                }
                try self.stack.append(result);
            },
            .div => {
                const arg2 = self.stack.popOrNull() orelse Value{ .number = 0 };
                const arg1 = self.stack.popOrNull() orelse Value{ .number = 0 };
                var result: Value = undefined;
                switch (arg1) {
                    .number => |number| result = .{ .number = std.math.divTrunc(isize, number, arg2.toNumber()) catch 0 },
                    else => {},
                }
                try self.stack.append(result);
            },
            .exp => {
                const arg2 = self.stack.popOrNull() orelse Value{ .number = 0 };
                const arg1 = self.stack.popOrNull() orelse Value{ .number = 0 };
                var result: Value = undefined;
                switch (arg1) {
                    .number => |number1| {
                        const number2 = arg2.toNumber();
                        result = .{ .number = std.math.powi(isize, number1, number2) catch 0 };
                    },
                    .list => |list1| {
                        if (list1.len == 0) {
                            result = .{ .string = try self.stack.allocator.dupe(u8, "") };
                        } else {
                            const string2 = try arg2.toString(self.stack.allocator);
                            defer self.stack.allocator.free(string2);
                            var list_strings = try self.stack.allocator.alloc([]const u8, list1.len);
                            for (list1, 0..) |elem, idx| {
                                list_strings[idx] = try elem.toString(self.stack.allocator);
                            }
                            defer self.stack.allocator.free(list_strings);
                            defer {
                                for (list_strings) |str| {
                                    self.stack.allocator.free(str);
                                }
                            }
                            var res = try std.mem.join(self.stack.allocator, string2, list_strings);
                            result = .{ .string = res };
                        }
                    },
                    else => {},
                }
                try self.stack.append(result);
            },
            .output => {
                const arg = try (self.stack.popOrNull() orelse Value{ .string = "" }).toString(self.stack.allocator);
                defer self.stack.allocator.free(arg);
                const backslash_end = if (arg.len == 0) false else arg[arg.len - 1] == '\\';
                var writer = output.writer();
                if (backslash_end) {
                    try writer.writeAll(arg[0 .. arg.len - 1]);
                } else {
                    try writer.writeAll(arg);
                    try writer.writeByte('\n');
                }
                try output.flush();
                try self.stack.append(.null);
            },
            .dump => {
                const arg = self.stack.getLastOrNull() orelse Value{ .number = 0 };
                var writer = output.writer();
                try arg.dump(writer);
                try output.flush();
            },
            .less => {
                const arg2 = self.stack.popOrNull() orelse Value{ .number = 0 };
                const arg1 = self.stack.popOrNull() orelse Value{ .number = 0 };

                var result: Value = .{ .bool = (try arg1.order(arg2, self.stack.allocator)) == .lt };
                try self.stack.append(result);
            },
            .greater => {
                const arg2 = self.stack.popOrNull() orelse Value{ .number = 0 };
                const arg1 = self.stack.popOrNull() orelse Value{ .number = 0 };

                var result: Value = .{ .bool = (try arg1.order(arg2, self.stack.allocator)) == .gt };
                try self.stack.append(result);
            },
            .equal => {
                const arg2 = self.stack.popOrNull() orelse Value{ .number = 0 };
                const arg1 = self.stack.popOrNull() orelse Value{ .number = 0 };

                var result: Value = .{ .bool = arg1.equals(arg2) };
                try self.stack.append(result);
            },
            .andthen => {
                const arg2 = self.stack.popOrNull() orelse Value{ .number = 0 };
                const arg1 = self.stack.popOrNull() orelse Value{ .number = 0 };

                if (!arg1.toBool()) {
                    try self.stack.append(arg1);
                } else {
                    try self.stack.append(arg2);
                }
            },
            .orthen => {
                const arg2 = self.stack.popOrNull() orelse Value{ .number = 0 };
                const arg1 = self.stack.popOrNull() orelse Value{ .number = 0 };

                if (arg1.toBool()) {
                    try self.stack.append(arg1);
                } else {
                    try self.stack.append(arg2);
                }
            },
            .prompt => {
                var input_buffer = std.ArrayList(u8).init(self.stack.allocator);
                defer input_buffer.deinit();

                var input_stream = input_buffer.writer();
                var was_eof = false;
                input.streamUntilDelimiter(input_stream, '\n', null) catch |err| {
                    switch (err) {
                        error.EndOfStream => was_eof = true,
                        else => return err,
                    }
                };

                if (input_buffer.items.len == 0 and was_eof) {
                    try self.stack.append(.null);
                } else {
                    try self.stack.append(.{ .string = std.mem.trimRight(u8, try input_buffer.toOwnedSlice(), "\r") });
                }
            },
            .random => {
                try self.stack.append(.{ .number = self.rand.intRangeAtMost(isize, 0, std.math.maxInt(isize)) });
            },
            .get => {
                const len: usize = @intCast((self.stack.popOrNull() orelse Value{ .number = 0 }).toNumber());
                const idx: usize = @intCast((self.stack.popOrNull() orelse Value{ .number = 0 }).toNumber());
                const arg = self.stack.popOrNull() orelse Value{ .number = 0 };
                switch (arg) {
                    .list => |list| {
                        const new_list = list[idx..][0..len];
                        try self.stack.append(.{ .list = try self.stack.allocator.dupe(Value, new_list) });
                        self.stack.allocator.free(list);
                    },
                    .string => |string| {
                        const new_string = string[idx..][0..len];
                        try self.stack.append(.{ .string = try self.stack.allocator.dupe(u8, new_string) });
                        self.stack.allocator.free(string);
                    },
                    else => {},
                }
            },
            .set => {
                const new = self.stack.popOrNull() orelse Value{ .number = 0 };
                const len: usize = @intCast((self.stack.popOrNull() orelse Value{ .number = 0 }).toNumber());
                const idx: usize = @intCast((self.stack.popOrNull() orelse Value{ .number = 0 }).toNumber());
                const arg = self.stack.popOrNull() orelse Value{ .number = 0 };
                switch (arg) {
                    .list => |list| {
                        const new_list_one = list[0..idx];
                        const new_list_two = list[idx + len ..];
                        const new_list_ins = try new.toList(self.stack.allocator);
                        var new_list = try self.stack.allocator.alloc(Value, new_list_one.len + new_list_two.len + new_list_ins.len);
                        var nidx: usize = 0;
                        @memcpy(new_list[nidx..][0..new_list_one.len], new_list_one);
                        nidx += new_list_one.len;
                        @memcpy(new_list[nidx..][0..new_list_ins.len], new_list_ins);
                        nidx += new_list_ins.len;
                        @memcpy(new_list[nidx..][0..new_list_two.len], new_list_two);
                        try self.stack.append(.{ .list = new_list });
                        self.stack.allocator.free(list);
                    },
                    .string => |string| {
                        const new_string_one = string[0..idx];
                        const new_string_two = string[idx + len ..];
                        const new_string = try std.mem.join(self.stack.allocator, "", &.{ new_string_one, try new.toString(self.stack.allocator), new_string_two });
                        try self.stack.append(.{ .string = new_string });
                        self.stack.allocator.free(string);
                    },
                    else => {},
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
    bool: bool,
    /// index into VM.blocks
    block: u32,
    null: void,
    list: []const Value,

    pub fn dupe(self: Value, alloc: Allocator) !Value {
        switch (self) {
            .number, .bool, .block, .null => return self,
            .string => {
                var new_string = try alloc.dupe(u8, self.string);
                return .{ .string = new_string };
            },
            .list => {
                var new_list = try alloc.dupe(Value, self.list);
                return .{ .list = new_list };
            },
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

    pub fn toString(self: Value, alloc: Allocator) ![]const u8 {
        switch (self) {
            .string => |str| return alloc.dupe(u8, str),
            .null => return &.{},
            .number => |value| return std.fmt.allocPrint(alloc, "{}", .{value}),
            .bool => |value| return if (value) alloc.dupe(u8, "true") else alloc.dupe(u8, "false"),
            .block => return &.{},
            .list => |list| {
                var strings = try alloc.alloc([]const u8, list.len);
                for (list, 0..) |v, idx| {
                    strings[idx] = try v.toString(alloc);
                }
                return std.mem.join(alloc, "\n", strings);
            },
        }
    }

    pub fn toList(self: Value, alloc: Allocator) ![]const Value {
        switch (self) {
            .list => |value| return value,
            .null => return &.{},
            .number => |value| {
                if (value == 0) {
                    var digits = try alloc.alloc(Value, 1);
                    digits[0] = .{ .number = 0 };
                    return digits;
                }
                const digit_count = std.fmt.count("{}", .{std.math.absCast(value)});
                const sgn: isize = if (value < 0) -1 else 1;
                var digits = try alloc.alloc(Value, digit_count);
                var number = std.math.absCast(value);

                var idx: usize = 0;
                while (number > 0) : (idx += 1) {
                    digits[idx] = .{ .number = sgn * @as(isize, @intCast(number % 10)) };
                    number /= 10;
                }
                std.mem.reverse(Value, digits);

                return digits;
            },
            .bool => |value| {
                var list: []Value = &.{};
                if (value) {
                    list = try alloc.alloc(Value, 1);
                    list[0] = .{ .bool = true };
                } else {
                    list = try alloc.alloc(Value, 0);
                }
                return list;
            },
            .string => |string| {
                var list = try alloc.alloc(Value, string.len);
                for (string, 0..) |c, idx| {
                    var char_str = try alloc.alloc(u8, 1);
                    char_str[0] = c;
                    list[idx] = .{ .string = char_str };
                }
                return list;
            },
            .block => return &.{},
        }
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

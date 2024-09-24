const std = @import("std");
const Allocator = std.mem.Allocator;
const GPA = std.heap.GeneralPurposeAllocator(.{});

const Value = union(enum) {
    number: isize,
    string: []const u8,
    list: []const Value,
    bool: bool,
    block: *const fn (Allocator) anyerror!Value,
    null: void,

    pub const Type = std.meta.Tag(Value);

    inline fn set(self: *Value, gpa: Allocator, new: Value) void {
        self.free(gpa);
        self.* = new;
    }

    inline fn dupe(self: Value, gpa: Allocator) !Value {
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

    inline fn free(self: Value, gpa: Allocator) void {
        switch (self) {
            .string => gpa.free(self.string),
            .list => |list| {
                for (list) |el| el.free(gpa);
                gpa.free(list);
            },
            else => {},
        }
    }

    inline fn dump(self: Value, output: anytype) !void {
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

    inline fn toNumber(self: Value) isize {
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

    inline fn toBool(self: Value) bool {
        switch (self) {
            .bool => |value| return value,
            .null => return false,
            .number => |value| return value != 0,
            .string => |string| return string.len > 0,
            .list => |list| return list.len > 0,
            .block => return false,
        }
    }

    inline fn toString(self: Value, gpa: Allocator) ![]const u8 {
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

    inline fn toList(self: Value, gpa: Allocator) ![]const Value {
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

    inline fn len(self: Value) Value {
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

    inline fn order(self: Value, other: Value, alloc: Allocator) !std.math.Order {
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

    inline fn equals(self: Value, other: Value) bool {
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

inline fn function_at(gpa: Allocator) !Value {
    return .{ .list = try gpa.dupe(Value, &.{}) };
}

inline fn function_P(gpa: Allocator, stdin: anytype) !Value {
    var input_buffer = std.ArrayList(u8).init(gpa);
    defer input_buffer.deinit();

    const input_stream = input_buffer.writer();
    var was_eof = false;
    stdin.streamUntilDelimiter(input_stream, '\n', null) catch |err| {
        switch (err) {
            error.EndOfStream => was_eof = true,
            else => return err,
        }
    };

    if (input_buffer.items.len == 0 and was_eof) {
        return .null;
    } else {
        const trimmed = std.mem.trimRight(u8, input_buffer.items, "\r");
        return .{ .string = try gpa.dupe(u8, trimmed) };
    }
}

inline fn function_R(rand: std.Random) Value {
    return .{ .number = rand.intRangeAtMost(isize, 0, std.math.maxInt(isize)) };
}

inline fn function_colon(v: Value) Value {
    return v;
}

inline fn function_bang(value: Value) Value {
    return .{ .bool = !value.toBool() };
}

inline fn function_tilde(value: Value) Value {
    return .{ .number = -value.toNumber() };
}

inline fn function_comma(gpa: Allocator, value: Value) !Value {
    return .{ .list = try gpa.dupe(Value, &.{value}) };
}

// tail
inline fn function_r_bracket(gpa: Allocator, value: Value) !Value {
    return switch (value) {
        .string => |string| .{ .string = try gpa.dupe(u8, string[1..]) },
        .list => |list| blk: {
            const new_list = try gpa.alloc(Value, list.len - 1);
            for (list[1..], new_list) |val, *v| {
                v.* = try val.dupe(gpa);
            }
            break :blk .{ .list = new_list };
        },
        else => error.BadTail,
    };
}

// head
inline fn function_l_bracket(gpa: Allocator, value: Value) !Value {
    return switch (value) {
        .string => |string| .{ .string = try gpa.dupe(u8, string[0..1]) },
        .list => |list| try list[0].dupe(gpa),
        else => error.BadHead,
    };
}

inline fn function_A(
    gpa: Allocator,
    value: Value,
) Value {
    return switch (value) {
        .number => |number| .{
            .string = try gpa.dupe(u8, &.{@truncate(@abs(number))}),
        },
        .string => |string| .{ .number = string[0] },
        else => error.BadAscii,
    };
}

inline fn function_C(
    gpa: Allocator,
    block: Value,
) !Value {
    return switch (block) {
        .block => |b| b(gpa),
        else => error.BadCall,
    };
}

inline fn function_D(value: Value, output: anytype) !Value {
    const writer = output.writer();
    try value.dump(writer);
    try output.flush();
    return value;
}

inline fn function_L(value: Value) Value {
    return value.len();
}

inline fn function_O(gpa: Allocator, value: Value, output: anytype) !Value {
    const string = try value.toString(gpa);
    defer gpa.free(string);

    const backslash_end = (string.len != 0) and string[string.len - 1] == '\\';
    var writer = output.writer();
    if (backslash_end) {
        try writer.writeAll(string[0 .. string.len - 1]);
    } else {
        try writer.writeAll(string);
        try writer.writeByte('\n');
    }
    try output.flush();
    return .null;
}

inline fn function_Q(value: Value) Value {
    std.process.exit(@truncate(@abs(value.toNumber())));
}

inline fn function_plus(gpa: Allocator, arg1: Value, arg2: Value) !Value {
    switch (arg1) {
        .number => |number| return .{ .number = number + arg2.toNumber() },
        .string => |string| {
            const str2 = try arg2.toString(gpa);
            defer gpa.free(str2);
            return .{ .string = try std.mem.concat(gpa, u8, &.{ string, str2 }) };
        },
        .list => |list| {
            const list2 = try arg2.toList(gpa);
            defer gpa.free(list2);
            const new_list = try gpa.alloc(Value, list.len + list2.len);
            for (new_list[0..list.len], list) |*nv, v| {
                nv.* = try v.dupe(gpa);
            }
            for (new_list[list.len..], list2) |*nv, v| {
                nv.* = try v.dupe(gpa);
            }
            return .{ .list = new_list };
        },
        else => return error.BadAdd,
    }
}

inline fn function_minus(arg1: Value, arg2: Value) !Value {
    if (arg1 == .block or arg2 == .block) return error.BlockNotAllowed;
    if (arg1 != .number) return error.BadSub;

    return .{ .number = arg1.toNumber() - arg2.toNumber() };
}

inline fn function_star(gpa: Allocator, arg1: Value, arg2: Value) !Value {
    if (arg1 == .block or arg2 == .block) return error.BlockNotAllowed;

    switch (arg1) {
        .number => |number| return .{ .number = number * arg2.toNumber() },
        .string => |string| {
            const str2 = arg2.toNumber();
            var value_builder = std.ArrayList([]const u8).init(gpa);
            defer value_builder.deinit();
            try value_builder.appendNTimes(string, @intCast(str2));
            return .{ .string = try std.mem.concat(gpa, u8, value_builder.items) };
        },
        .list => |list| {
            const str2: usize = @intCast(arg2.toNumber());
            const new_list = try gpa.alloc(Value, list.len * str2);
            for (new_list, 0..) |*new, idx| {
                new.* = try list[idx % list.len].dupe(gpa);
            }
            return .{ .list = new_list };
        },
        else => return error.BadMult,
    }
}

inline fn function_slash(arg1: Value, arg2: Value) Value {
    const num2 = arg2.toNumber();
    if (arg1 != .number or num2 == 0) return 255;

    return switch (arg1) {
        .number => |number| .{ .number = std.math.divTrunc(isize, number, num2) catch return error.BadDiv },
        else => error.BadDiv,
    };
}

inline fn function_ampersand(arg1: Value, arg2: Value) Value {
    return if (arg1.toBool()) arg2 else arg1;
}

inline fn function_percent(arg1: Value, arg2: Value) !Value {
    const num2 = arg2.toNumber();
    if (arg1 != .number or num2 == 0) return error.BadMod;
    const num1 = arg1.toNumber();
    if (num1 < 0 or num2 < 0) return error.BadMod;

    return switch (arg1) {
        .number => |number| .{ .number = std.math.mod(isize, number, arg2.toNumber()) catch return error.BadMod },
        else => error.BadMod,
    };
}

inline fn function_caret(gpa: Allocator, arg1: Value, arg2: Value) !Value {
    switch (arg1) {
        .number => |number1| {
            const number2 = arg2.toNumber();

            if (number1 == 0 and number2 < 0) return error.BadExp;

            return .{ .number = std.math.powi(isize, number1, number2) catch 0 };
        },
        .list => |list1| {
            if (list1.len == 0) {
                return .{ .string = try gpa.dupe(u8, &.{}) };
            } else {
                const string2 = try arg2.toString(gpa);
                defer gpa.free(string2);
                var list_strings = try gpa.alloc([]const u8, list1.len);
                defer gpa.free(list_strings);

                for (list1, 0..) |elem, idx| {
                    list_strings[idx] = try elem.toString(gpa);
                }
                defer {
                    for (list_strings) |str| {
                        gpa.free(str);
                    }
                }
                const res = try std.mem.join(gpa, string2, list_strings);
                return .{ .string = res };
            }
        },
        else => return error.BadExp,
    }
}

inline fn function_less(gpa: Allocator, arg1: Value, arg2: Value) !Value {
    return .{ .bool = (try arg1.order(arg2, gpa)) == .lt };
}

inline fn function_greater(gpa: Allocator, arg1: Value, arg2: Value) !Value {
    return .{ .bool = (try arg1.order(arg2, gpa)) == .gt };
}

inline fn function_question_mark(self: Value, other: Value) Value {
    return .{ .bool = self.equals(other) };
}

inline fn function_pipe(arg1: Value, arg2: Value) Value {
    return if (arg1.toBool()) arg1 else arg2;
}

inline fn function_semicolon(_: Value, value: Value) Value {
    return value;
}

inline fn function_G(
    gpa: Allocator,
    len_: Value,
    idx_: Value,
    arg: Value,
) !Value {
    if (len_ == .block or
        idx_ == .block or
        arg == .block)
        return error.BadGet;

    const len: usize = @intCast(len_.toNumber());
    const idx: usize = @intCast(idx_.toNumber());
    switch (arg) {
        .list => |list| {
            const new_list = try gpa.alloc(Value, len);
            for (new_list, list[idx..][0..len]) |*nv, v| {
                nv.* = try v.dupe(gpa);
            }
            return .{ .list = new_list };
        },
        .string => |string| {
            const new_string = string[idx..][0..len];
            return .{ .string = try gpa.dupe(u8, new_string) };
        },
        else => return error.BadGet,
    }
}

inline fn function_S(
    gpa: Allocator,
    new: Value,
    len_: Value,
    idx_: Value,
    arg: Value,
) !Value {
    if (new == .block or
        len_ == .block or
        idx_ == .block or
        arg == .block)
        return error.BadSet;

    const len: usize = @intCast(len_.toNumber());
    const idx: usize = @intCast(idx_.toNumber());
    switch (arg) {
        .list => |list| {
            const new_list_mid = try new.toList(gpa);
            defer gpa.free(new_list_mid);
            const new_len = new_list_mid.len;
            const new_list = try gpa.alloc(
                Value,
                list.len - len + new_len,
            );
            for (new_list[0..idx], list[0..idx]) |*nv, v| {
                nv.* = try v.dupe(gpa);
            }
            for (new_list[idx..][0..new_len], new_list_mid) |*nv, v| {
                nv.* = try v.dupe(gpa);
            }
            for (new_list[idx + new_len ..], list[idx + len ..]) |*nv, v| {
                nv.* = try v.dupe(gpa);
            }
            return .{ .list = new_list };
        },
        .string => |string| {
            const new_string_one = string[0..idx];
            const new_string_two = string[idx + len ..];
            const new_string_mid = try new.toString(gpa);
            defer gpa.free(new_string_mid);
            const new_string = try std.mem.concat(
                gpa,
                u8,
                &.{ new_string_one, new_string_mid, new_string_two },
            );
            return .{ .string = new_string };
        },
        else => return error.BadSet,
    }
}

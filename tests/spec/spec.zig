const std = @import("std");
const Build = std.Build;

pub fn addFunctions(
    b: *Build,
    exe: *Build.Step.Compile,
    test_step: *Build.Step,
) void {
    inline for (&[_][]const u8{
        "nullary",
        "unary",
        "binary",
        "ternary",
        "quaternary",
    }) |name| {
        for (@field(function, name)) |case| {
            const step = b.step(
                b.fmt("{s}-test", .{case.name}),
                b.fmt("Test {s} function", .{case.name}),
            );
            if (std.mem.eql(u8, case.name, "output")) {
                for (case.tests) |test_case| {
                    step.dependOn(addOutputTest(
                        b,
                        exe,
                        test_case.code,
                        test_case.input,
                        test_case.raw_out.?,
                    ));
                }
            } else {
                for (case.tests) |test_case| {
                    step.dependOn(addTest(
                        b,
                        exe,
                        test_case.code,
                        test_case.input,
                        if (test_case.output) |out| out.fmt(b) else null,
                        test_case.exit,
                        test_case.just_run,
                    ));
                }
            }
            test_step.dependOn(step);
            if (std.mem.eql(u8, case.name, "ascii")) {
                addAsciiTests(b, exe, step);
            }
        }
    }
}

pub fn addVariables(
    b: *Build,
    exe: *Build.Step.Compile,
    test_step: *Build.Step,
) void {
    const step = b.step(
        b.fmt("{s}-test", .{variables.name}),
        b.fmt("Test {s} function", .{variables.name}),
    );
    for (variables.tests) |test_case| {
        step.dependOn(addTest(
            b,
            exe,
            test_case.code,
            test_case.input,
            if (test_case.output) |out| out.fmt(b) else null,
            test_case.exit,
            test_case.just_run,
        ));
    }
    test_step.dependOn(step);
}

fn addTest(
    b: *Build,
    exe: *Build.Step.Compile,
    test_code: []const u8,
    test_stdin: ?[]const u8,
    expected_output: ?[]const u8,
    expected_exit: ?u8,
    just_run: bool,
) *Build.Step {
    var run_step = b.addRunArtifact(exe);
    const code = b.fmt("D {s}", .{test_code});
    run_step.addArgs(&.{ "-e", code });
    if (!just_run) {
        if (expected_exit) |exit| {
            run_step.expectExitCode(exit);
        }
        if (expected_output) |out| {
            run_step.expectStdOutEqual(out);
        }
        if (test_stdin) |stdin| {
            run_step.setStdIn(.{ .bytes = stdin });
        }
    }
    return &run_step.step;
}

fn addOutputTest(
    b: *Build,
    exe: *Build.Step.Compile,
    test_code: []const u8,
    test_stdin: ?[]const u8,
    expected_output: []const u8,
) *Build.Step {
    var run_step = b.addRunArtifact(exe);

    run_step.addArgs(&.{ "-e", test_code });

    run_step.expectStdOutEqual(expected_output);
    if (test_stdin) |stdin| {
        run_step.setStdIn(.{ .bytes = stdin });
    }
    return &run_step.step;
}

const TestCase = struct {
    code: []const u8,
    output: ?KnightValue,
    raw_out: ?[]const u8 = null,
    input: ?[]const u8 = null,
    exit: ?u8 = null,
    just_run: bool = false,
};

const KnightValue = union(enum) {
    number: isize,
    string: []const u8,
    list: []const KnightValue,
    bool: bool,
    null,
    block,

    pub fn fmt(v: KnightValue, b: *Build) []const u8 {
        return switch (v) {
            .number => |number| b.fmt("{}", .{number}),
            .string => |string| blk: {
                var sb = std.ArrayList(u8).init(b.allocator);
                defer sb.deinit();
                sb.appendSlice("\"") catch @panic("OOM");
                var writer = sb.writer();
                for (string) |char| {
                    switch (char) {
                        '\t' => writer.writeAll("\\t") catch @panic("OOM"),
                        '\n' => writer.writeAll("\\n") catch @panic("OOM"),
                        '\r' => writer.writeAll("\\r") catch @panic("OOM"),
                        '\\' => writer.writeAll("\\\\") catch @panic("OOM"),
                        '"' => writer.writeAll("\\\"") catch @panic("OOM"),
                        else => writer.writeByte(char) catch @panic("OOM"),
                    }
                }
                sb.appendSlice("\"") catch @panic("OOM");
                break :blk sb.toOwnedSlice() catch @panic("OOM");
            },
            .bool => |value| if (value) "true" else "false",
            .block => unreachable,
            .null => "null",
            .list => |list| blk: {
                var sb = std.ArrayList(u8).init(b.allocator);
                defer sb.deinit();
                sb.append('[') catch @panic("OOM");
                for (list, 0..) |elem, idx| {
                    sb.appendSlice(elem.fmt(b)) catch @panic("OOM");
                    if (idx != list.len - 1) sb.appendSlice(", ") catch @panic("OOM");
                }
                sb.append(']') catch @panic("OOM");
                break :blk sb.toOwnedSlice() catch @panic("OOM");
            },
        };
    }
};

const SpecTest = struct {
    name: []const u8,
    tests: []const TestCase,
    probabilistic: bool = false,
};

const function = struct {
    const nullary = [_]SpecTest{
        .{
            .name = "null",
            .tests = &.{
                .{ .code = "NULL", .output = .null },
            },
        },
        .{
            .name = "true",
            .tests = &.{
                .{ .code = "TRUE", .output = .{ .bool = true } },
            },
        },
        .{
            .name = "false",
            .tests = &.{
                .{ .code = "FALSE", .output = .{ .bool = false } },
            },
        },
        .{
            .name = "empty-list",
            .tests = &.{
                .{ .code = "@", .output = .{ .list = &.{} } },
            },
        },
        .{
            .name = "random",
            .tests = &.{
                .{ .code = " | > 0 RANDOM " ** 100 ++ "FALSE", .output = .{ .bool = false } },
                .{ .code = "? RANDOM RANDOM", .output = .{ .bool = false } },
            },
            .probabilistic = true,
        },
        .{
            .name = "prompt",
            .tests = &.{
                // should read a line from stdin
                .{
                    .code = "PROMPT",
                    .output = .{ .string = "foo" },
                    .input = "foo",
                },
                .{
                    .code = "PROMPT",
                    .output = .{ .string = "foo" },
                    .input = "foo\nbar",
                },
                .{
                    .code = "PROMPT",
                    .output = .{ .string = "foo" },
                    .input = "foo\nbar\nbaz",
                },
                // should strip trailing `\r` and `\r\n`
                .{
                    .code = "PROMPT",
                    .output = .{ .string = "foo" },
                    .input = "foo\n",
                },
                .{
                    .code = "PROMPT",
                    .output = .{ .string = "foo" },
                    .input = "foo\nbar",
                },
                .{
                    .code = "PROMPT",
                    .output = .{ .string = "foo" },
                    .input = "foo\r\nbar",
                },
                // should strip all trailing `\r`s
                .{
                    .code = "PROMPT",
                    .output = .{ .string = "foo" },
                    .input = "foo\r\n",
                },
                .{
                    .code = "PROMPT",
                    .output = .{ .string = "foo" },
                    .input = "foo\r\r\r\r\n",
                },
                .{
                    .code = "PROMPT",
                    .output = .{ .string = "foo" },
                    .input = "foo\r\nhello",
                },
                .{
                    .code = "PROMPT",
                    .output = .{ .string = "foo" },
                    .input = "foo\r\r\r\r\nhello",
                },
                .{
                    .code = "PROMPT",
                    .output = .{ .string = "foo" },
                    .input = "foo\r",
                },
                .{
                    .code = "PROMPT",
                    .output = .{ .string = "foo" },
                    .input = "foo\r\r\r\r",
                },
                // does not strip `\r`s in the middle
                .{
                    .code = "PROMPT",
                    .output = .{ .string = "foo\rhello" },
                    .input = "foo\rhello",
                },
                .{
                    .code = "PROMPT",
                    .output = .{ .string = "foo\rhello" },
                    .input = "foo\rhello\n",
                },
                .{
                    .code = "PROMPT",
                    .output = .{ .string = "foo\rhello" },
                    .input = "foo\rhello\r\n",
                },
                .{
                    .code = "PROMPT",
                    .output = .{ .string = "foo\r\r\r\rhello" },
                    .input = "foo\r\r\r\rhello",
                },
                .{
                    .code = "PROMPT",
                    .output = .{ .string = "foo\r\r\r\rhello" },
                    .input = "foo\r\r\r\rhello\n",
                },
                .{
                    .code = "PROMPT",
                    .output = .{ .string = "foo\r\r\r\rhello" },
                    .input = "foo\r\r\r\rhello\r\n",
                },
                // should be able to read multiple lines
                .{
                    .code = "++++ PROMPT ':' PROMPT ':' PROMPT",
                    .output = .{ .string = "foo:bar:baz" },
                    .input = "foo\nbar\r\nbaz\n",
                },
                // should return an empty string for empty lines
                .{
                    .code = "+ PROMPT PROMPT",
                    .output = .{ .string = "" },
                    .input = "\n\r\nx",
                },
                // should return NULL at EOF
                .{
                    .code = "PROMPT",
                    .output = .null,
                    .input = "",
                },
            },
        },
    };
    const unary = [_]SpecTest{
        // ASCII is also special cased
        .{
            .name = "ascii",
            .tests = &.{
                .{ .code = "ASCII 'HELLO'", .output = .{ .number = 'H' } },
                .{ .code = "ASCII 'neighbour'", .output = .{ .number = 'n' } },
            },
        },
        .{
            .name = "block",
            .tests = &.{},
        },
        .{
            .name = "box",
            .tests = &.{
                // converts normal arguments to a list of just that
                .{
                    .code = ",0",
                    .output = .{
                        .list = &.{.{ .number = 0 }},
                    },
                },
                .{
                    .code = ",1",
                    .output = .{ .list = &.{.{ .number = 1 }} },
                },
                .{
                    .code = ",1234",
                    .output = .{ .list = &.{.{ .number = 1234 }} },
                },
                .{
                    .code = ",~1234",
                    .output = .{ .list = &.{.{ .number = -1234 }} },
                },
                .{
                    .code = ",\"\"",
                    .output = .{ .list = &.{.{ .string = "" }} },
                },
                .{
                    .code = ",\"hello\"",
                    .output = .{ .list = &.{.{ .string = "hello" }} },
                },
                .{
                    .code = ",TRUE",
                    .output = .{ .list = &.{.{ .bool = true }} },
                },
                .{
                    .code = ",FALSE",
                    .output = .{ .list = &.{.{ .bool = false }} },
                },
                .{
                    .code = ",NULL",
                    .output = .{ .list = &.{.null} },
                },
                // also converts lists to just a list of that
                .{
                    .code = ",@",
                    .output = .{
                        .list = &.{
                            .{ .list = &.{} },
                        },
                    },
                },
                .{
                    .code = ",,4",
                    .output = .{
                        .list = &.{
                            .{
                                .list = &.{
                                    .{ .number = 4 },
                                },
                            },
                        },
                    },
                },
                .{
                    .code = ",+@123",
                    .output = .{
                        .list = &.{
                            .{
                                .list = &.{
                                    .{ .number = 1 },
                                    .{ .number = 2 },
                                    .{ .number = 3 },
                                },
                            },
                        },
                    },
                },
            },
        },
        .{
            .name = "call",
            .tests = &.{
                // should run something returned by `BLOCK`
                .{ .code = "CALL BLOCK 12", .output = .{ .number = 12 } },
                .{ .code = "CALL BLOCK \"12\"", .output = .{ .string = "12" } },
                .{ .code = "CALL BLOCK TRUE", .output = .{ .bool = true } },
                .{ .code = "CALL BLOCK FALSE", .output = .{ .bool = false } },
                .{ .code = "CALL BLOCK NULL", .output = .null },
                .{ .code = "CALL BLOCK @", .output = .{ .list = &.{} } },
                .{
                    .code = "; = foo BLOCK bar ; = bar \"twelve\" : CALL foo",
                    .output = .{ .string = "twelve" },
                },
                .{
                    .code = "; = foo BLOCK * x 5 ; = x 3 : CALL foo",
                    .output = .{ .number = 15 },
                },
            },
        },
        .{
            .name = "head",
            .tests = &.{
                //it 'gets the first element of lists
                //# test different types of list construction methods
                .{ .code = "[,1", .output = .{ .number = 1 } },
                .{ .code = "[+,1 ,2", .output = .{ .number = 1 } },
                .{ .code = "[+@123", .output = .{ .number = 1 } },
                .{ .code = "[*,1 4", .output = .{ .number = 1 } },
                .{ .code = "[GET +@123 0 1", .output = .{ .number = 1 } },
                .{ .code = "[SET +@123 0 1 @", .output = .{ .number = 2 } },
                //// gets the first character of strings
                .{ .code = "['a'", .output = .{ .string = "a" } },
                .{ .code = "['abc'", .output = .{ .string = "a" } },
                .{ .code = "[+'abc' 'def'", .output = .{ .string = "a" } },
                .{ .code = "[+'' 'abc'", .output = .{ .string = "a" } },
                .{ .code = "[*'abc' 3", .output = .{ .string = "a" } },
                .{ .code = "[GET 'abc' 0 1", .output = .{ .string = "a" } },
                .{ .code = "[SET 'abc' 0 1 ''", .output = .{ .string = "b" } },
            },
        },
        .{
            .name = "length",
            .tests = &.{
                // returns 0 for NULL
                .{ .code = "LENGTH NULL", .output = .{ .number = 0 } },
                // returns 1 for TRUE and 0 for FALSE
                .{ .code = "LENGTH TRUE", .output = .{ .number = 1 } },
                .{ .code = "LENGTH FALSE", .output = .{ .number = 0 } },
                // returns the amount of digits in an integer
                .{ .code = "LENGTH 0", .output = .{ .number = 1 } },
                .{ .code = "LENGTH 1", .output = .{ .number = 1 } },
                .{ .code = "LENGTH 59", .output = .{ .number = 2 } },
                .{ .code = "LENGTH 1111", .output = .{ .number = 4 } },
                // returns the same length for negative integers
                .{ .code = "LENGTH ~0", .output = .{ .number = 1 } },
                .{ .code = "LENGTH ~1", .output = .{ .number = 1 } },
                .{ .code = "LENGTH ~59", .output = .{ .number = 2 } },
                .{ .code = "LENGTH ~1111", .output = .{ .number = 4 } },
                // Note that since basic Knight is ascii only, there's no difference between bytes and UTF8.
                // returns the amount of chars in strings
                .{ .code = "LENGTH \"\"", .output = .{ .number = 0 } },
                .{ .code = "LENGTH \"foo\"", .output = .{ .number = 3 } },
                .{ .code = "LENGTH \"a man a plan a canal panama\"", .output = .{ .number = 27 } },
                .{ .code = "LENGTH \"and then I questioned\"", .output = .{ .number = 21 } },
                .{ .code = "LENGTH '" ++ "x" ** 100 ++ "'", .output = .{ .number = 100 } },
                // does not coerce its argument to an integer and back
                .{ .code = "LENGTH \"-0\"", .output = .{ .number = 2 } },
                .{ .code = "LENGTH \"49.12\"", .output = .{ .number = 5 } },
                .{ .code = "LENGTH ,\"49.12\"", .output = .{ .number = 1 } },
                // returns the amount of elements in a list
                .{ .code = "LENGTH @", .output = .{ .number = 0 } },
                .{ .code = "LENGTH ,1", .output = .{ .number = 1 } },
                .{ .code = "LENGTH +@123", .output = .{ .number = 3 } },
                .{ .code = "LENGTH +@\"aaa\"", .output = .{ .number = 3 } },
                .{ .code = "LENGTH + (+@\"aaa\") (+@\"bbb\") ", .output = .{ .number = 6 } },
                .{ .code = "LENGTH *,33 100", .output = .{ .number = 100 } },
                .{ .code = "LENGTH GET *,33 100 0 4", .output = .{ .number = 4 } },
                // works with multiline strings.
                .{ .code = "LENGTH 'fooba\nrbaz'", .output = .{ .number = 10 } },
            },
        },
        .{
            .name = "negate",
            .tests = &.{
                // negates its argument
                .{ .code = "~ 1", .output = .{ .number = -1 } },
                .{ .code = "~ 10", .output = .{ .number = -10 } },
                .{ .code = "~ ~12", .output = .{ .number = 12 } },
                .{ .code = "~ (- 0 123)", .output = .{ .number = 123 } },
                .{ .code = "~0", .output = .{ .number = 0 } },
                // converts its argument to an integer
                .{ .code = "~ \"2\"", .output = .{ .number = -2 } },
                .{ .code = "~ \"45\"", .output = .{ .number = -45 } },
                .{ .code = "~ TRUE", .output = .{ .number = -1 } },
                .{ .code = "~ FALSE", .output = .{ .number = 0 } },
                .{ .code = "~ NULL", .output = .{ .number = 0 } },
                .{ .code = "~ +@999", .output = .{ .number = -3 } },
                .{ .code = "~ +@~999", .output = .{ .number = -3 } },
            },
        },
        .{
            .name = "noop",
            .tests = &.{
                // simply returns its argument
                .{ .code = ": 4", .output = .{ .number = 4 } },
                .{ .code = ": \"hi\"", .output = .{ .string = "hi" } },
                .{ .code = ": TRUE", .output = .{ .bool = true } },
                .{ .code = ": FALSE", .output = .{ .bool = false } },
                .{ .code = ": NULL", .output = .null },
                .{ .code = ": @", .output = .{ .list = &.{} } },
            },
        },
        .{
            .name = "not",
            .tests = &.{
                // inverts its argument
                .{ .code = "! FALSE", .output = .{ .bool = true } },
                .{ .code = "! TRUE", .output = .{ .bool = false } },
                // converts its argument to a boolean
                .{ .code = "! \"\"", .output = .{ .bool = true } },
                .{ .code = "! \"0\"", .output = .{ .bool = false } },
                .{ .code = "! \"1\"", .output = .{ .bool = false } },
                .{ .code = "! NULL", .output = .{ .bool = true } },
                .{ .code = "! 0", .output = .{ .bool = true } },
                .{ .code = "! 1", .output = .{ .bool = false } },
                .{ .code = "! @", .output = .{ .bool = true } },
                .{ .code = "! ,@", .output = .{ .bool = false } },
            },
        },
        .{
            .name = "output",
            .tests = &.{
                // just prints a newline with no string' do
                .{ .code = "OUTPUT \"\"", .raw_out = "\n", .output = null },
                // prints normally' do
                .{ .code = "OUTPUT \"1\"", .raw_out = "1\n", .output = null },
                .{ .code = "OUTPUT \"hello world\"", .raw_out = "hello world\n", .output = null },
                // prints newlines correctly' do
                .{ .code = "OUTPUT \"foobar\nbaz\"", .raw_out = "foobar\nbaz\n", .output = null },
                .{ .code = "OUTPUT \"foobar\nbaz\n\"", .raw_out = "foobar\nbaz\n\n", .output = null },
                // wont print a newline with a trailing `\`' do
                .{ .code = "OUTPUT \"\\\"", .raw_out = "", .output = null },
                .{ .code = "OUTPUT \"hello\\\"", .raw_out = "hello", .output = null },
                .{ .code = "OUTPUT \"world\n\\\"", .raw_out = "world\n", .output = null },
                // converts values to a string' do
                .{ .code = "OUTPUT 123", .raw_out = "123\n", .output = null },
                .{ .code = "OUTPUT ~123", .raw_out = "-123\n", .output = null },
                .{ .code = "OUTPUT TRUE", .raw_out = "true\n", .output = null },
                .{ .code = "OUTPUT FALSE", .raw_out = "false\n", .output = null },
                .{ .code = "OUTPUT NULL", .raw_out = "\n", .output = null },
                .{ .code = "OUTPUT @", .raw_out = "\n", .output = null },
                .{ .code = "OUTPUT +@123", .raw_out = "1\n2\n3\n", .output = null },
            },
        },
        .{
            .name = "quit",
            .tests = &.{
                // must quit the process with the given return value
                .{ .code = "QUIT 0", .output = null, .exit = 0 },
                .{ .code = "QUIT 1", .output = null, .exit = 1 },
                .{ .code = "QUIT 2", .output = null, .exit = 2 },
                .{ .code = "QUIT 10", .output = null, .exit = 10 },
                .{ .code = "QUIT 49", .output = null, .exit = 49 },
                .{ .code = "QUIT 123", .output = null, .exit = 123 },
                .{ .code = "QUIT 126", .output = null, .exit = 126 },
                .{ .code = "QUIT 127", .output = null, .exit = 127 },
                // must convert to an integer
                .{ .code = "QUIT \"12\"", .output = null, .exit = 12 },
                // these are slightly counterintuitive, as `QUIT TRUE` will exit with 1, indicating failure.
                .{ .code = "QUIT TRUE", .output = null, .exit = 1 },
                .{ .code = "QUIT FALSE", .output = null, .exit = 0 },
                .{ .code = "QUIT NULL", .output = null, .exit = 0 },
                .{ .code = "QUIT @", .output = null, .exit = 0 },
                .{ .code = "QUIT ,123", .output = null, .exit = 1 },
            },
        },
        .{
            .name = "tail",
            .tests = &.{
                // gets everything but first element of lists
                // test different types of list construction methods
                .{
                    .code = "],1",
                    .output = .{ .list = &.{} },
                },
                .{
                    .code = "]+,1 ,2",
                    .output = .{ .list = &.{.{ .number = 2 }} },
                },
                .{
                    .code = "]+@123",
                    .output = .{
                        .list = &.{
                            .{ .number = 2 },
                            .{ .number = 3 },
                        },
                    },
                },
                .{
                    .code = "]*,1 4",
                    .output = .{
                        .list = &.{
                            .{ .number = 1 },
                            .{ .number = 1 },
                            .{ .number = 1 },
                        },
                    },
                },
                .{
                    .code = "]GET +@123 0 1",
                    .output = .{ .list = &.{} },
                },
                .{
                    .code = "]SET +@123 0 1 @",
                    .output = .{ .list = &.{.{ .number = 3 }} },
                },
                // gets everything but first character of strings
                .{ .code = "]'a'", .output = .{ .string = "" } },
                .{ .code = "]'abc'", .output = .{ .string = "bc" } },
                .{ .code = "]+'abc' 'def'", .output = .{ .string = "bcdef" } },
                .{ .code = "]+'' 'abc'", .output = .{ .string = "bc" } },
                .{ .code = "]*'abc' 3", .output = .{ .string = "bcabcabc" } },
                .{ .code = "]GET 'abc' 0 1", .output = .{ .string = "" } },
                .{ .code = "]SET 'abc' 0 1 ''", .output = .{ .string = "c" } },
            },
        },
    };
    const binary = [_]SpecTest{
        .{
            .name = "add",
            .tests = &.{
                // when the first arg is a string
                // concatenates
                .{ .code = "+ \"112\" \"1a3\"", .output = .{ .string = "1121a3" } },
                .{ .code = "+ \"Plato\" \" Aristotle\"", .output = .{ .string = "Plato Aristotle" } },
                .{ .code = "++ \"Because \" \"why\" \" not?\"", .output = .{ .string = "Because why not?" } },
                // coerces to a string
                .{ .code = "+ \"truth is \" TRUE", .output = .{ .string = "truth is true" } },
                .{ .code = "+ \"falsehood is \" FALSE", .output = .{ .string = "falsehood is false" } },
                .{ .code = "++ \"it is \" NULL \" and void\"", .output = .{ .string = "it is  and void" } },
                .{ .code = "+ \"twelve is \" 12", .output = .{ .string = "twelve is 12" } },
                .{ .code = "+ \"newlines exist:\" +@123", .output = .{ .string = "newlines exist:1\n2\n3" } },
                // can be used to coerce to a string when the lhs is empty
                .{ .code = "+ \"\" TRUE", .output = .{ .string = "true" } },
                .{ .code = "+ \"\" FALSE", .output = .{ .string = "false" } },
                .{ .code = "+ \"\" NULL", .output = .{ .string = "" } },
                .{ .code = "+ \"\" 1234", .output = .{ .string = "1234" } },
                .{ .code = "+ \"\" ~123", .output = .{ .string = "-123" } },
                .{ .code = "+ \"\" +@123", .output = .{ .string = "1\n2\n3" } },
                // a bug from the c impl
                // does not reuse the same integer buffer
                .{ .code = "; = a + \"\" 12 ; = b + \"\" 34 : + a b", .output = .{ .string = "1234" } },
                // when the first arg is an integer
                // adds other integers
                .{ .code = "+ 0 0", .output = .{ .number = 0 } },
                .{ .code = "+ 1 2", .output = .{ .number = 3 } },
                .{ .code = "+ 4 6", .output = .{ .number = 10 } },
                .{ .code = "+ 112 ~1", .output = .{ .number = 111 } },
                .{ .code = "+ 4 13", .output = .{ .number = 17 } },
                .{ .code = "+ 4 ~13", .output = .{ .number = -9 } },
                .{ .code = "+ ~4 13", .output = .{ .number = 9 } },
                .{ .code = "+ ~4 ~13", .output = .{ .number = -17 } },
                // converts other values to integers
                .{ .code = "+ 1 \"2\"", .output = .{ .number = 3 } },
                .{ .code = "+ 4 \"91\"", .output = .{ .number = 95 } },
                .{ .code = "+ 9 TRUE", .output = .{ .number = 10 } },
                .{ .code = "+ 9 FALSE", .output = .{ .number = 9 } },
                .{ .code = "+ 9 NULL", .output = .{ .number = 9 } },
                .{ .code = "+ 5 +@123", .output = .{ .number = 8 } },
                // can be used to coerce to an integer when the lhs is zero
                .{ .code = "+ 0 \"12\"", .output = .{ .number = 12 } },
                .{ .code = "+ 0 TRUE", .output = .{ .number = 1 } },
                .{ .code = "+ 0 FALSE", .output = .{ .number = 0 } },
                .{ .code = "+ 0 NULL", .output = .{ .number = 0 } },
                .{ .code = "+ 0 +@12345", .output = .{ .number = 5 } },
                // evaluates arguments in order
                .{ .code = "+ (= n 45) (- n 42)", .output = .{ .number = 48 } },
                .{ .code = "+ (= n 15) (- n 14)", .output = .{ .number = 16 } },
                .{ .code = "+ (= n 15) (- n 16)", .output = .{ .number = 14 } },
            },
        },
        .{
            .name = "and",
            .tests = &.{
                // returns the lhs if its falsey
                .{ .code = "& 0 QUIT 1", .output = .{ .number = 0 } },
                .{ .code = "& FALSE QUIT 1", .output = .{ .bool = false } },
                .{ .code = "& NULL QUIT 1", .output = .null },
                .{ .code = "& \"\" QUIT 1", .output = .{ .string = "" } },
                .{ .code = "& @ QUIT 1", .output = .{ .list = &.{} } },
                // executes the rhs only if the lhs is truthy
                .{ .code = "; & 1 (= a 1) a", .output = .{ .number = 1 } },
                .{ .code = "; & TRUE (= a 2) a", .output = .{ .number = 2 } },
                .{ .code = "; & \"hi\" (= a 3) a", .output = .{ .number = 3 } },
                .{ .code = "; & \"0\" (= a 4) a", .output = .{ .number = 4 } },
                .{ .code = "; & \"NaN\" (= a 5) a", .output = .{ .number = 5 } },
                .{ .code = "; & ,@ (= a 6) a", .output = .{ .number = 6 } },
                // accepts blocks as the second operand
                .{ .code = "; = a 3 : CALL & 1 BLOCK a", .output = .{ .number = 3 } },
                .{ .code = "; = a 3 : CALL & 1 BLOCK + a 2", .output = .{ .number = 5 } },
            },
        },
        .{
            .name = "assign",
            .tests = &.{
                // assigns to variables' do
                .{ .code = "; = a 12 : a", .output = .{ .number = 12 } },
                // returns its given value
                .{ .code = "= a 12", .output = .{ .number = 12 } },
            },
        },
        .{
            .name = "divide",
            .tests = &.{
                // divides nonzero integers normally
                .{ .code = "/ 1 1", .output = .{ .number = 1 } },
                .{ .code = "/ 10 2", .output = .{ .number = 5 } },
                .{ .code = "/ ~10 2", .output = .{ .number = -5 } },
                .{ .code = "/ 40 ~4", .output = .{ .number = -10 } },
                .{ .code = "/ ~80 ~4", .output = .{ .number = 20 } },
                .{ .code = "/ 13 4", .output = .{ .number = 3 } },
                .{ .code = "/ 13 ~4", .output = .{ .number = -3 } },
                .{ .code = "/ ~13 4", .output = .{ .number = -3 } },
                .{ .code = "/ ~13 ~4", .output = .{ .number = 3 } },
                // rounds downwards
                .{ .code = "/ 4 5", .output = .{ .number = 0 } },
                .{ .code = "/ 10 4", .output = .{ .number = 2 } },
                .{ .code = "/ ~5 3", .output = .{ .number = -1 } },
                .{ .code = "/ ~7 3", .output = .{ .number = -2 } },
                // evaluates arguments in order
                .{ .code = "/ (= n 45) (- n 42)", .output = .{ .number = 15 } },
                .{ .code = "/ (= n 15) (- n 14)", .output = .{ .number = 15 } },
                .{ .code = "/ (= n 15) (- n 16)", .output = .{ .number = -15 } },
                // converts other values to integers
                .{ .code = "/ 15 \"2\"", .output = .{ .number = 7 } },
                .{ .code = "/ 91 \"4\"", .output = .{ .number = 22 } },
                .{ .code = "/ 9 TRUE", .output = .{ .number = 9 } },
                .{ .code = "/ 9 +@12", .output = .{ .number = 4 } },
            },
        },
        .{
            .name = "equals",
            .tests = &.{
                // when the first arg is null
                // equals itself
                .{ .code = "? NULL NULL", .output = .{ .bool = true } },
                // is not equal to other values
                .{ .code = "? NULL FALSE", .output = .{ .bool = false } },
                .{ .code = "? NULL TRUE", .output = .{ .bool = false } },
                .{ .code = "? NULL 0", .output = .{ .bool = false } },
                .{ .code = "? NULL \"\"", .output = .{ .bool = false } },
                .{ .code = "? NULL \"0\"", .output = .{ .bool = false } },
                .{ .code = "? NULL \"NULL\"", .output = .{ .bool = false } },
                .{ .code = "? NULL \"\"", .output = .{ .bool = false } },
                // when the first arg is a boolean
                // only is equal to itself
                .{ .code = "? TRUE TRUE", .output = .{ .bool = true } },
                .{ .code = "? FALSE FALSE", .output = .{ .bool = true } },
                // is not equal to anything else
                .{ .code = "? TRUE 1", .output = .{ .bool = false } },
                .{ .code = "? TRUE \"1\"", .output = .{ .bool = false } },
                .{ .code = "? TRUE \"TRUE\"", .output = .{ .bool = false } },
                .{ .code = "? TRUE \"true\"", .output = .{ .bool = false } },
                .{ .code = "? FALSE 0", .output = .{ .bool = false } },
                .{ .code = "? FALSE \"\"", .output = .{ .bool = false } },
                .{ .code = "? FALSE \"0\"", .output = .{ .bool = false } },
                .{ .code = "? FALSE \"FALSE\"", .output = .{ .bool = false } },
                .{ .code = "? FALSE \"false\"", .output = .{ .bool = false } },
                // when the first arg is an integer
                // is only equal to itself
                .{ .code = "? 0 0", .output = .{ .bool = true } },
                .{ .code = "? ~0 0", .output = .{ .bool = true } },
                .{ .code = "? 1 1", .output = .{ .bool = true } },
                .{ .code = "? ~1 ~1", .output = .{ .bool = true } },
                .{ .code = "? 912 912", .output = .{ .bool = true } },
                .{ .code = "? 123 123", .output = .{ .bool = true } },
                // is not equal to anything else
                .{ .code = "? 0 1", .output = .{ .bool = false } },
                .{ .code = "? 1 0", .output = .{ .bool = false } },
                .{ .code = "? 4 5", .output = .{ .bool = false } },
                .{ .code = "? ~4 4", .output = .{ .bool = false } },
                .{ .code = "? 0 FALSE", .output = .{ .bool = false } },
                .{ .code = "? 0 NULL", .output = .{ .bool = false } },
                .{ .code = "? 0 \"\"", .output = .{ .bool = false } },
                .{ .code = "? 1 TRUE", .output = .{ .bool = false } },
                .{ .code = "? 1 \"1\"", .output = .{ .bool = false } },
                .{ .code = "? 1 \"1a\"", .output = .{ .bool = false } },
                // when the first arg is a string
                // is only equal to itself
                .{ .code = "? \"\" \"\"", .output = .{ .bool = true } },
                .{ .code = "? \"a\" \"a\"", .output = .{ .bool = true } },
                .{ .code = "? \"0\" \"0\"", .output = .{ .bool = true } },
                .{ .code = "? \"1\" \"1\"", .output = .{ .bool = true } },
                .{ .code = "? \"foobar\" \"foobar\"", .output = .{ .bool = true } },
                .{ .code = "? \"this is a test\" \"this is a test\"", .output = .{ .bool = true } },
                .{ .code = "? (+ \"'\" '\"') (+ \"'\" '\"')", .output = .{ .bool = true } },
                // is not equal to other strings
                .{ .code = "? \"\" \" \"", .output = .{ .bool = false } },
                .{ .code = "? \" \" \"\"", .output = .{ .bool = false } },
                .{ .code = "? \"a\" \"A\"", .output = .{ .bool = false } },
                .{ .code = "? \"0\" \"00\"", .output = .{ .bool = false } },
                .{ .code = "? \"1.0\" \"1\"", .output = .{ .bool = false } },
                .{ .code = "? \"1\" \"1.0\"", .output = .{ .bool = false } },
                .{ .code = "? \"0\" \"0x0\"", .output = .{ .bool = false } },
                .{ .code = "? \"is this a test\" \"this is a test\"", .output = .{ .bool = false } },
                // is not equal to equivalent types
                .{ .code = "? \"0\" 0", .output = .{ .bool = false } },
                .{ .code = "? \"1\" 1", .output = .{ .bool = false } },
                .{ .code = "? \"T\" TRUE", .output = .{ .bool = false } },
                .{ .code = "? \"TRUE\" TRUE", .output = .{ .bool = false } },
                .{ .code = "? \"True\" TRUE", .output = .{ .bool = false } },
                .{ .code = "? \"true\" TRUE", .output = .{ .bool = false } },
                .{ .code = "? \"F\" FALSE", .output = .{ .bool = false } },
                .{ .code = "? \"FALSE\" FALSE", .output = .{ .bool = false } },
                .{ .code = "? \"False\" FALSE", .output = .{ .bool = false } },
                .{ .code = "? \"false\" FALSE", .output = .{ .bool = false } },
                .{ .code = "? \"N\" NULL", .output = .{ .bool = false } },
                .{ .code = "? \"NULL\" NULL", .output = .{ .bool = false } },
                .{ .code = "? \"Null\" NULL", .output = .{ .bool = false } },
                .{ .code = "? \"\" NULL", .output = .{ .bool = false } },
                // when the first arg is a list
                // is only equal to itself
                .{ .code = "? @ @", .output = .{ .bool = true } },
                .{ .code = "? ,@ ,@", .output = .{ .bool = true } },
                .{ .code = "? ,'a' +@\"a\"", .output = .{ .bool = true } },
                .{ .code = "? ,0 +@0", .output = .{ .bool = true } },
                .{ .code = "? ,\"1\" ,\"1\"", .output = .{ .bool = true } },
                .{ .code = "? +@\"foobar\" +@\"foobar\"", .output = .{ .bool = true } },
                .{ .code = "? ,TRUE +@TRUE", .output = .{ .bool = true } },
                .{ .code = "? +@123 ++,1,2,3", .output = .{ .bool = true } },
                .{ .code = "? *,2 4 +@2222", .output = .{ .bool = true } },
                .{ .code = "? @ GET *,2 4 0 0", .output = .{ .bool = true } },
                // is not equal to other lists
                .{ .code = "? @ ,1", .output = .{ .bool = false } },
                .{ .code = "? @ ,@", .output = .{ .bool = false } },
                .{ .code = "? ,1 @", .output = .{ .bool = false } },
                .{ .code = "? +@123 +,1,2", .output = .{ .bool = false } },
                // is not equal to equivalent types
                .{ .code = "? @ 0", .output = .{ .bool = false } },
                .{ .code = "? ,1 1", .output = .{ .bool = false } },
                .{ .code = "? @ TRUE", .output = .{ .bool = false } },
                .{ .code = "? ,1 TRUE", .output = .{ .bool = false } },
                .{ .code = "? ,TRUE TRUE", .output = .{ .bool = false } },
                .{ .code = "? @ FALSE", .output = .{ .bool = false } },
                .{ .code = "? ,0 FALSE", .output = .{ .bool = false } },
                .{ .code = "? ,FALSE FALSE", .output = .{ .bool = false } },
                .{ .code = "? @ NULL", .output = .{ .bool = false } },
                .{ .code = "? ,0 NULL", .output = .{ .bool = false } },
                .{ .code = "? ,NULL NULL", .output = .{ .bool = false } },
                .{ .code = "? @ \"\"", .output = .{ .bool = false } },
                .{ .code = "? ,0 \"0\"", .output = .{ .bool = false } },
                .{ .code = "? ,\"\" \"\"", .output = .{ .bool = false } },
                .{ .code = "? ,\"hello\" \"hello\"", .output = .{ .bool = false } },
                .{ .code = "? +@\"hello\" \"hello\"", .output = .{ .bool = false } },
                .{ .code = "? +@\"h\" \"h\"", .output = .{ .bool = false } },
                // evaluates arguments in order
                .{ .code = "? (= n 45) n", .output = .{ .bool = true } },
                .{ .code = "? (= n \"mhm\") n", .output = .{ .bool = true } },
                .{ .code = "? (= n TRUE) n", .output = .{ .bool = true } },
                .{ .code = "? (= n FALSE) n", .output = .{ .bool = true } },
                .{ .code = "? (= n NULL) n", .output = .{ .bool = true } },
            },
        },
        .{
            .name = "exp",
            .tests = &.{
                // when the first argument is an integer
                // raises positive integers correctly
                .{ .code = "^ 1 1", .output = .{ .number = 1 } },
                .{ .code = "^ 1 100", .output = .{ .number = 1 } },
                .{ .code = "^ 2 4", .output = .{ .number = 16 } },
                .{ .code = "^ 5 3", .output = .{ .number = 125 } },
                .{ .code = "^ 15 3", .output = .{ .number = 3375 } },
                .{ .code = "^ 123 2", .output = .{ .number = 15129 } },
                // raises negative positive integers correctly
                .{ .code = "^ ~1 1", .output = .{ .number = -1 } },
                .{ .code = "^ ~1 2", .output = .{ .number = 1 } },
                .{ .code = "^ ~1 3", .output = .{ .number = -1 } },
                .{ .code = "^ ~1 4", .output = .{ .number = 1 } },
                .{ .code = "^ ~1 100", .output = .{ .number = 1 } },
                .{ .code = "^ ~2 4", .output = .{ .number = 16 } },
                .{ .code = "^ ~2 5", .output = .{ .number = -32 } },
                .{ .code = "^ ~5 3", .output = .{ .number = -125 } },
                .{ .code = "^ ~5 4", .output = .{ .number = 625 } },
                .{ .code = "^ ~15 3", .output = .{ .number = -3375 } },
                .{ .code = "^ ~15 4", .output = .{ .number = 50625 } },
                .{ .code = "^ ~123 2", .output = .{ .number = 15129 } },
                .{ .code = "^ ~123 3", .output = .{ .number = -1860867 } },
                // always returns 1 for exponents of 0
                .{ .code = "^ 0 0", .output = .{ .number = 1 } },
                .{ .code = "^ 1 0", .output = .{ .number = 1 } },
                .{ .code = "^ 1 0", .output = .{ .number = 1 } },
                .{ .code = "^ 2 0", .output = .{ .number = 1 } },
                .{ .code = "^ 5 0", .output = .{ .number = 1 } },
                .{ .code = "^ 15 0", .output = .{ .number = 1 } },
                .{ .code = "^ 123 0", .output = .{ .number = 1 } },
                .{ .code = "^ ~1 0", .output = .{ .number = 1 } },
                .{ .code = "^ ~1 0", .output = .{ .number = 1 } },
                .{ .code = "^ ~2 0", .output = .{ .number = 1 } },
                .{ .code = "^ ~5 0", .output = .{ .number = 1 } },
                .{ .code = "^ ~15 0", .output = .{ .number = 1 } },
                .{ .code = "^ ~123 0", .output = .{ .number = 1 } },
                // returns 0 when the base is zero, unless the power is zero
                .{ .code = "^ 0 1", .output = .{ .number = 0 } },
                .{ .code = "^ 0 100", .output = .{ .number = 0 } },
                .{ .code = "^ 0 4", .output = .{ .number = 0 } },
                .{ .code = "^ 0 3", .output = .{ .number = 0 } },
                // converts other values to integers
                .{ .code = "^ 15 \"2\"", .output = .{ .number = 225 } },
                .{ .code = "^ 91 FALSE", .output = .{ .number = 1 } },
                .{ .code = "^ 91 NULL", .output = .{ .number = 1 } },
                .{ .code = "^ 9 TRUE", .output = .{ .number = 9 } },
                .{ .code = "^ 9 +@123", .output = .{ .number = 729 } },
                // when the first argument is a list
                // returns an empty string for empty lists
                .{ .code = "^ @ ''", .output = .{ .string = "" } },
                .{ .code = "^ @ 'hello'", .output = .{ .string = "" } },
                .{ .code = "^ @ TRUE", .output = .{ .string = "" } },
                .{ .code = "^ @ 1234", .output = .{ .string = "" } },
                // returns the stringification of its element for one-length lists
                .{ .code = "^ ,\"hello\" ''", .output = .{ .string = "hello" } },
                .{ .code = "^ ,123 ''", .output = .{ .string = "123" } },
                .{ .code = "^ ,,,,TRUE ''", .output = .{ .string = "true" } },
                .{ .code = "^ ,@ ''", .output = .{ .string = "" } },
                .{ .code = "^ ,,,,,,45 ''", .output = .{ .string = "45" } },
                // returns the list joined by the second argument
                .{ .code = "^ +@123 '-'", .output = .{ .string = "1-2-3" } },
                .{ .code = "^ +@4567 '\n'", .output = .{ .string = "4\n5\n6\n7" } },
                .{ .code = "^ *,'a' 100 'XX'", .output = .{ .string = "a" ++ "XXa" ** 99 } },
                .{
                    .code = "^ *+@'ab' 100 ''",
                    .output = .{ .string = "ab" ** 100 },
                },
                // coerces the second argument to a string
                .{ .code = "^ +@123 0", .output = .{ .string = "10203" } },
                .{ .code = "^ +@4567 TRUE", .output = .{ .string = "4true5true6true7" } },
                .{ .code = "^ *,'a' 100 ,'XX'", .output = .{ .string = "a" ++ "XXa" ** 99 } },
                .{ .code = "^ *+@'ab' 100 NULL", .output = .{ .string = "ab" ** 100 } },
                .{ .code = "^ *+@'ab' 100 @", .output = .{ .string = "ab" ** 100 } },
                // evaluates arguments in order
                .{ .code = "^ (= n 45) (- n 42)", .output = .{ .number = 91125 } },
                .{ .code = "^ (= n 15) (- n 14)", .output = .{ .number = 15 } },
            },
        },
        .{
            .name = "gt",
            .tests = &.{
                // when the first arg is a boolean
                // is only true when TRUTHY and the rhs is falsey
                .{ .code = "> TRUE FALSE", .output = .{ .bool = true } },
                .{ .code = "> TRUE 0", .output = .{ .bool = true } },
                .{ .code = "> TRUE ''", .output = .{ .bool = true } },
                .{ .code = "> TRUE NULL", .output = .{ .bool = true } },
                .{ .code = "> TRUE @", .output = .{ .bool = true } },
                // is false all other times
                .{ .code = "> TRUE TRUE", .output = .{ .bool = false } },
                .{ .code = "> TRUE 1", .output = .{ .bool = false } },
                .{ .code = "> TRUE '1'", .output = .{ .bool = false } },
                .{ .code = "> TRUE ,1", .output = .{ .bool = false } },
                .{ .code = "> FALSE ~1", .output = .{ .bool = false } },
                .{ .code = "> FALSE TRUE", .output = .{ .bool = false } },
                .{ .code = "> FALSE FALSE", .output = .{ .bool = false } },
                .{ .code = "> FALSE 1", .output = .{ .bool = false } },
                .{ .code = "> FALSE '1'", .output = .{ .bool = false } },
                .{ .code = "> FALSE 0", .output = .{ .bool = false } },
                .{ .code = "> FALSE ''", .output = .{ .bool = false } },
                .{ .code = "> FALSE NULL", .output = .{ .bool = false } },
                .{ .code = "> FALSE @", .output = .{ .bool = false } },
                // when the first arg is a string
                // performs lexicographical comparison
                .{ .code = "> 'a' 'aa'", .output = .{ .bool = false } },
                .{ .code = "> 'b' 'aa'", .output = .{ .bool = true } },
                .{ .code = "> 'aa' 'a'", .output = .{ .bool = true } },
                .{ .code = "> 'aa' 'b'", .output = .{ .bool = false } },
                .{ .code = "> 'A' 'AA'", .output = .{ .bool = false } },
                .{ .code = "> 'B' 'AA'", .output = .{ .bool = true } },
                .{ .code = "> 'AA' 'A'", .output = .{ .bool = true } },
                .{ .code = "> 'AA' 'B'", .output = .{ .bool = false } },
                // ensure it obeys ascii
                .{ .code = "> 'a' 'A'", .output = .{ .bool = true } },
                .{ .code = "> 'A' 'a'", .output = .{ .bool = false } },
                .{ .code = "> 'z' 'Z'", .output = .{ .bool = true } },
                .{ .code = "> 'Z' 'z'", .output = .{ .bool = false } },
                .{ .code = "> ':' '9'", .output = .{ .bool = true } },
                .{ .code = "> '1' '0'", .output = .{ .bool = true } },
                // performs it even with integers
                .{ .code = "> '0' '00'", .output = .{ .bool = false } },
                .{ .code = "> '1' '12'", .output = .{ .bool = false } },
                .{ .code = "> '100' '12'", .output = .{ .bool = false } },
                .{ .code = "> '00' '0'", .output = .{ .bool = true } },
                .{ .code = "> '12' '1'", .output = .{ .bool = true } },
                .{ .code = "> '12' '100'", .output = .{ .bool = true } },
                .{ .code = "> '  0' '  00'", .output = .{ .bool = false } },
                .{ .code = "> '  1' '  12'", .output = .{ .bool = false } },
                .{ .code = "> '  100' '  12'", .output = .{ .bool = false } },
                // coerces the RHS to an integer
                .{ .code = "> '0' 1", .output = .{ .bool = false } },
                .{ .code = "> '1' 12", .output = .{ .bool = false } },
                .{ .code = "> '100' 12", .output = .{ .bool = false } },
                .{ .code = "> '00' 0", .output = .{ .bool = true } },
                .{ .code = "> '12' 100", .output = .{ .bool = true } },
                .{ .code = "> '12' 100", .output = .{ .bool = true } },
                .{ .code = "> 'trud' TRUE", .output = .{ .bool = false } },
                .{ .code = "> 'trud' +@TRUE", .output = .{ .bool = false } },
                .{ .code = "> 'true' TRUE", .output = .{ .bool = false } },
                .{ .code = "> 'true' ,TRUE", .output = .{ .bool = false } },
                .{ .code = "> 'truf' TRUE", .output = .{ .bool = true } },
                .{ .code = "> 'truf' +@TRUE", .output = .{ .bool = true } },
                .{ .code = "> 'falsd' FALSE", .output = .{ .bool = false } },
                .{ .code = "> 'falsd' ,FALSE", .output = .{ .bool = false } },
                .{ .code = "> 'false' FALSE", .output = .{ .bool = false } },
                .{ .code = "> 'false' ,FALSE", .output = .{ .bool = false } },
                .{ .code = "> 'faslf' FALSE", .output = .{ .bool = true } },
                .{ .code = "> 'faslf' ,FALSE", .output = .{ .bool = true } },
                .{ .code = "> '' NULL", .output = .{ .bool = false } },
                .{ .code = "> ' ' NULL", .output = .{ .bool = true } },
                .{ .code = "> ' ' @", .output = .{ .bool = true } },
                // when the first arg is an integer
                // performs numeric comparison
                .{ .code = "> 1 1", .output = .{ .bool = false } },
                .{ .code = "> 0 0", .output = .{ .bool = false } },
                .{ .code = "> 12 100", .output = .{ .bool = false } },
                .{ .code = "> 1 2", .output = .{ .bool = false } },
                .{ .code = "> 91 491", .output = .{ .bool = false } },
                .{ .code = "> 100 12", .output = .{ .bool = true } },
                .{ .code = "> 2 1", .output = .{ .bool = true } },
                .{ .code = "> 491 91", .output = .{ .bool = true } },
                .{ .code = "> 4 13", .output = .{ .bool = false } },
                .{ .code = "> 4 ~13", .output = .{ .bool = true } },
                .{ .code = "> ~4 13", .output = .{ .bool = false } },
                .{ .code = "> ~4 ~13", .output = .{ .bool = true } },
                // coerces the RHS to an integer
                .{ .code = "> 0 TRUE", .output = .{ .bool = false } },
                .{ .code = "> 0 '1'", .output = .{ .bool = false } },
                .{ .code = "> 0 '49'", .output = .{ .bool = false } },
                .{ .code = "> ~2 '-1'", .output = .{ .bool = false } },
                .{ .code = "> 1 FALSE", .output = .{ .bool = true } },
                .{ .code = "> 1 NULL", .output = .{ .bool = true } },
                .{ .code = "> 1 '0'", .output = .{ .bool = true } },
                .{ .code = "> 01 ''", .output = .{ .bool = true } },
                .{ .code = "> 0 '-1'", .output = .{ .bool = true } },
                .{ .code = "> ~1 '-2'", .output = .{ .bool = true } },
                .{ .code = "> 0 @", .output = .{ .bool = false } },
                .{ .code = "> 0 ,1", .output = .{ .bool = false } },
                .{ .code = "> 1 @", .output = .{ .bool = true } },
                .{ .code = "> 2 ,1", .output = .{ .bool = true } },
                // when the first arg is a list
                // performs element-by-element comparison
                .{ .code = "> @ @", .output = .{ .bool = false } },
                .{ .code = "> ,1 ,1", .output = .{ .bool = false } },
                .{ .code = "> ,0 ,0", .output = .{ .bool = false } },
                .{ .code = "> +@12 +@100", .output = .{ .bool = true } }, // 0 < 2
                .{ .code = "> +@100 +@12", .output = .{ .bool = false } }, // 2 > 0
                .{ .code = "> +@120 +@12", .output = .{ .bool = true } }, // first one's length is longer
                .{ .code = "> +@12 +@12", .output = .{ .bool = false } },
                .{ .code = "> ,+@120 ,+@12", .output = .{ .bool = true } },
                // coerces the RHS to a list
                .{ .code = "> @ NULL", .output = .{ .bool = false } },
                .{ .code = "> ,1 1", .output = .{ .bool = false } },
                .{ .code = "> ,0 0", .output = .{ .bool = false } },
                .{ .code = "> +@12 100", .output = .{ .bool = true } }, // 0 < 2
                .{ .code = "> +@100 12", .output = .{ .bool = false } }, // 2 > 0
                .{ .code = "> +@120 12", .output = .{ .bool = true } }, // first one's length is longer
                .{ .code = "> +@12 12", .output = .{ .bool = false } },
                .{ .code = "> +@'abc' 'ab'", .output = .{ .bool = true } },
                // evaluates arguments in order
                .{ .code = "> (= n 45) 44", .output = .{ .bool = true } },
                .{ .code = "> (= n 45) 46", .output = .{ .bool = false } },
                .{ .code = "> (= n 'mhm') (+ n 'm')", .output = .{ .bool = false } },
                .{ .code = "> (+ (= n 'mhm') 'm') n", .output = .{ .bool = true } },
                .{ .code = "> (= n TRUE) !n", .output = .{ .bool = true } },
                .{ .code = "> (= n FALSE) !n", .output = .{ .bool = false } },
            },
        },
        .{
            .name = "lt",
            .tests = &.{
                // when the first arg is a boolean
                // is only true when FALSE and the rhs is truthy
                .{ .code = "< FALSE TRUE", .output = .{ .bool = true } },
                .{ .code = "< FALSE 1", .output = .{ .bool = true } },
                .{ .code = "< FALSE '1'", .output = .{ .bool = true } },
                .{ .code = "< FALSE ~1", .output = .{ .bool = true } },
                .{ .code = "< FALSE ,1", .output = .{ .bool = true } },
                // is false all other times
                .{ .code = "< FALSE FALSE", .output = .{ .bool = false } },
                .{ .code = "< FALSE 0", .output = .{ .bool = false } },
                .{ .code = "< FALSE ''", .output = .{ .bool = false } },
                .{ .code = "< FALSE NULL", .output = .{ .bool = false } },
                .{ .code = "< FALSE @", .output = .{ .bool = false } },
                .{ .code = "< TRUE TRUE", .output = .{ .bool = false } },
                .{ .code = "< TRUE FALSE", .output = .{ .bool = false } },
                .{ .code = "< TRUE 1", .output = .{ .bool = false } },
                .{ .code = "< TRUE '1'", .output = .{ .bool = false } },
                .{ .code = "< TRUE 2", .output = .{ .bool = false } },
                .{ .code = "< TRUE ~2", .output = .{ .bool = false } },
                .{ .code = "< TRUE 0", .output = .{ .bool = false } },
                .{ .code = "< TRUE ''", .output = .{ .bool = false } },
                .{ .code = "< TRUE NULL", .output = .{ .bool = false } },
                .{ .code = "< TRUE @", .output = .{ .bool = false } },
                .{ .code = "< TRUE ,1", .output = .{ .bool = false } },
                // when the first arg is a string
                // performs lexicographical comparison
                .{ .code = "< 'a' 'aa'", .output = .{ .bool = true } },
                .{ .code = "< 'b' 'aa'", .output = .{ .bool = false } },
                .{ .code = "< 'aa' 'a'", .output = .{ .bool = false } },
                .{ .code = "< 'aa' 'b'", .output = .{ .bool = true } },
                .{ .code = "< 'A' 'AA'", .output = .{ .bool = true } },
                .{ .code = "< 'B' 'AA'", .output = .{ .bool = false } },
                .{ .code = "< 'AA' 'A'", .output = .{ .bool = false } },
                .{ .code = "< 'AA' 'B'", .output = .{ .bool = true } },
                // ensure it obeys ascii
                .{ .code = "< 'a' 'A'", .output = .{ .bool = false } },
                .{ .code = "< 'A' 'a'", .output = .{ .bool = true } },
                .{ .code = "< 'z' 'Z'", .output = .{ .bool = false } },
                .{ .code = "< 'Z' 'z'", .output = .{ .bool = true } },
                .{ .code = "< '/' '0'", .output = .{ .bool = true } },
                .{ .code = "< '8' '9'", .output = .{ .bool = true } },
                // performs it even with integers
                .{ .code = "< '0' '00'", .output = .{ .bool = true } },
                .{ .code = "< '1' '12'", .output = .{ .bool = true } },
                .{ .code = "< '100' '12'", .output = .{ .bool = true } },
                .{ .code = "< '00' '0'", .output = .{ .bool = false } },
                .{ .code = "< '12' '1'", .output = .{ .bool = false } },
                .{ .code = "< '12' '100'", .output = .{ .bool = false } },
                .{ .code = "< '  0' '  00'", .output = .{ .bool = true } },
                .{ .code = "< '  1' '  12'", .output = .{ .bool = true } },
                .{ .code = "< '  100' '  12'", .output = .{ .bool = true } },
                // coerces the RHS to a string
                .{ .code = "< '0' 1", .output = .{ .bool = true } },
                .{ .code = "< '1' 12", .output = .{ .bool = true } },
                .{ .code = "< '100' 12", .output = .{ .bool = true } },
                .{ .code = "< '00' 0", .output = .{ .bool = false } },
                .{ .code = "< '12' 100", .output = .{ .bool = false } },
                .{ .code = "< '12' 100", .output = .{ .bool = false } },
                .{ .code = "< 'trud' +@TRUE", .output = .{ .bool = true } },
                .{ .code = "< 'trud' TRUE", .output = .{ .bool = true } },
                .{ .code = "< 'true' TRUE", .output = .{ .bool = false } },
                .{ .code = "< 'true' ,TRUE", .output = .{ .bool = false } },
                .{ .code = "< 'truf' TRUE", .output = .{ .bool = false } },
                .{ .code = "< 'truf' +@TRUE", .output = .{ .bool = false } },
                .{ .code = "< 'falsd' FALSE", .output = .{ .bool = true } },
                .{ .code = "< 'falsd' ,FALSE", .output = .{ .bool = true } },
                .{ .code = "< 'false' FALSE", .output = .{ .bool = false } },
                .{ .code = "< 'false' ,FALSE", .output = .{ .bool = false } },
                .{ .code = "< 'faslf' FALSE", .output = .{ .bool = false } },
                .{ .code = "< 'faslf' ,FALSE", .output = .{ .bool = false } },
                .{ .code = "< '' NULL", .output = .{ .bool = false } },
                .{ .code = "< ' ' NULL", .output = .{ .bool = false } },
                .{ .code = "< ' ' @", .output = .{ .bool = false } },
                // when the first arg is an integer
                // performs numeric comparison
                .{ .code = "< 1 1", .output = .{ .bool = false } },
                .{ .code = "< 0 0", .output = .{ .bool = false } },
                .{ .code = "< 12 100", .output = .{ .bool = true } },
                .{ .code = "< 1 2", .output = .{ .bool = true } },
                .{ .code = "< 91 491", .output = .{ .bool = true } },
                .{ .code = "< 100 12", .output = .{ .bool = false } },
                .{ .code = "< 2 1", .output = .{ .bool = false } },
                .{ .code = "< 491 91", .output = .{ .bool = false } },
                .{ .code = "< 4 13", .output = .{ .bool = true } },
                .{ .code = "< 4 ~13", .output = .{ .bool = false } },
                .{ .code = "< ~4 13", .output = .{ .bool = true } },
                .{ .code = "< ~4 ~13", .output = .{ .bool = false } },
                // coerces the RHS to an integer
                .{ .code = "< 0 TRUE", .output = .{ .bool = true } },
                .{ .code = "< 0 '1'", .output = .{ .bool = true } },
                .{ .code = "< 0 '49'", .output = .{ .bool = true } },
                .{ .code = "< ~2 '-1'", .output = .{ .bool = true } },
                .{ .code = "< ~2 @", .output = .{ .bool = true } },
                .{ .code = "< ~2 ,1", .output = .{ .bool = true } },
                .{ .code = "< 0 FALSE", .output = .{ .bool = false } },
                .{ .code = "< 0 NULL", .output = .{ .bool = false } },
                .{ .code = "< 0 '0'", .output = .{ .bool = false } },
                .{ .code = "< 0 '-1'", .output = .{ .bool = false } },
                .{ .code = "< 0 ''", .output = .{ .bool = false } },
                .{ .code = "< 0 @", .output = .{ .bool = false } },
                .{ .code = "< 0 ,1", .output = .{ .bool = true } },
                // when the first arg is a list
                // performs element-by-element comparison
                .{ .code = "< @ @", .output = .{ .bool = false } },
                .{ .code = "< ,1 ,1", .output = .{ .bool = false } },
                .{ .code = "< ,0 ,0", .output = .{ .bool = false } },
                .{ .code = "< +@100 +@12", .output = .{ .bool = true } }, // 0 < 2
                .{ .code = "< +@12 +@100", .output = .{ .bool = false } }, // 2 > 0
                .{ .code = "< +@12 +@120", .output = .{ .bool = true } }, // first one's length is smaller
                .{ .code = "< ,+@12 ,+@120", .output = .{ .bool = true } },
                // coerces the RHS to a list
                .{ .code = "< @ NULL", .output = .{ .bool = false } },
                .{ .code = "< ,1 1", .output = .{ .bool = false } },
                .{ .code = "< ,0 0", .output = .{ .bool = false } },
                .{ .code = "< +@100 12", .output = .{ .bool = true } }, // 0 < 2
                .{ .code = "< +@12 100", .output = .{ .bool = false } }, // 2 > 0
                .{ .code = "< +@12 120", .output = .{ .bool = true } }, // first one's length is smaller
                .{ .code = "< +@'ab' 'abc'", .output = .{ .bool = true } },
                // evaluates arguments in order
                .{ .code = "< (= n 45) 46", .output = .{ .bool = true } },
                .{ .code = "< (= n 45) 44", .output = .{ .bool = false } },
                .{ .code = "< (= n 'mhm') (+ n 'm')", .output = .{ .bool = true } },
                .{ .code = "< (+ (= n 'mhm') 'm') n", .output = .{ .bool = false } },
                .{ .code = "< (= n TRUE) !n", .output = .{ .bool = false } },
                .{ .code = "< (= n FALSE) !n", .output = .{ .bool = true } },
            },
        },
        .{
            .name = "mod",
            .tests = &.{
                // modulos positive bases normally
                .{ .code = "% 1 1", .output = .{ .number = 0 } },
                .{ .code = "% 4 4", .output = .{ .number = 0 } },
                .{ .code = "% 15 1", .output = .{ .number = 0 } },
                .{ .code = "% 123 10", .output = .{ .number = 3 } },
                .{ .code = "% 15 3", .output = .{ .number = 0 } },
                .{ .code = "% 14 3", .output = .{ .number = 2 } },
                .{ .code = "% 3 1234", .output = .{ .number = 3 } },
                // converts other values to integers
                .{ .code = "% 15 \"2\"", .output = .{ .number = 1 } },
                .{ .code = "% 91 \"4\"", .output = .{ .number = 3 } },
                .{ .code = "% 9 TRUE", .output = .{ .number = 0 } },
                .{ .code = "% 9 +@12345", .output = .{ .number = 4 } },
                // evaluates arguments in order
                .{ .code = "% (= n 45) (- n 35)", .output = .{ .number = 5 } },
                .{ .code = "% (= n 17) (- n 7)", .output = .{ .number = 7 } },
                .{ .code = "% (= n 15) (- n 4)", .output = .{ .number = 4 } },
            },
        },
        .{
            .name = "mult",
            .tests = &.{
                // when the first arg is a string
                // duplicates itself with positive integers
                .{ .code = "* \"\" 12", .output = .{ .string = "" } },
                .{ .code = "* \"foo\" 1", .output = .{ .string = "foo" } },
                .{ .code = "* \"a1\" 4", .output = .{ .string = "a1a1a1a1" } },
                .{ .code = "* \"hai\" 8", .output = .{ .string = "haihaihaihaihaihaihaihai" } },
                // returns an empty string when multiplied by zero
                .{ .code = "* \"hi\" 0", .output = .{ .string = "" } },
                .{ .code = "* \"what up?\" 0", .output = .{ .string = "" } },
                // coerces the RHS to an integer
                .{ .code = "* \"foo\" \"3\"", .output = .{ .string = "foofoofoo" } },
                .{ .code = "* \"foo\" TRUE", .output = .{ .string = "foo" } },
                .{ .code = "* \"foo\" NULL", .output = .{ .string = "" } },
                .{ .code = "* \"foo\" FALSE", .output = .{ .string = "" } },
                .{ .code = "* \"foo\" +@123", .output = .{ .string = "foofoofoo" } },
                // when the first arg is a list
                // duplicates itself with positive integers
                .{ .code = "* @ 12", .output = .{ .list = &.{} } },
                .{
                    .code = "* ,1 1",
                    .output = .{ .list = &.{
                        .{ .number = 1 },
                    } },
                },
                .{
                    .code = "* ,\"a1\" 4",
                    .output = .{ .list = &.{
                        .{ .string = "a1" },
                        .{ .string = "a1" },
                        .{ .string = "a1" },
                        .{ .string = "a1" },
                    } },
                },
                .{
                    .code = "* +@12 3",
                    .output = .{ .list = &.{
                        .{ .number = 1 },
                        .{ .number = 2 },
                        .{ .number = 1 },
                        .{ .number = 2 },
                        .{ .number = 1 },
                        .{ .number = 2 },
                    } },
                },
                // returns an empty list when multiplied by zero
                .{ .code = "* ,\"hi\" 0", .output = .{ .list = &.{} } },
                .{ .code = "* ,\"what up?\" 0", .output = .{ .list = &.{} } },
                // coerces the RHS to an integer
                .{
                    .code = "* ,\"foo\" \"3\"",
                    .output = .{ .list = &.{
                        .{ .string = "foo" },
                        .{ .string = "foo" },
                        .{ .string = "foo" },
                    } },
                },
                .{
                    .code = "* ,\"foo\" TRUE",
                    .output = .{ .list = &.{
                        .{ .string = "foo" },
                    } },
                },
                .{ .code = "* ,\"foo\" NULL", .output = .{ .list = &.{} } },
                .{ .code = "* ,\"foo\" FALSE", .output = .{ .list = &.{} } },
                .{
                    .code = "* ,\"foo\" +@123",
                    .output = .{ .list = &.{
                        .{ .string = "foo" },
                        .{ .string = "foo" },
                        .{ .string = "foo" },
                    } },
                },
                // when the first arg is an integer
                // works with integers
                .{ .code = "* 0 0", .output = .{ .number = 0 } },
                .{ .code = "* 1 2", .output = .{ .number = 2 } },
                .{ .code = "* 4 6", .output = .{ .number = 24 } },
                .{ .code = "* 12 ~3", .output = .{ .number = -36 } },
                .{ .code = "* 4 13", .output = .{ .number = 52 } },
                .{ .code = "* 4 ~13", .output = .{ .number = -52 } },
                .{ .code = "* ~4 13", .output = .{ .number = -52 } },
                .{ .code = "* ~4 ~13", .output = .{ .number = 52 } },
                // converts other values to integers
                .{ .code = "* 1 \"-2\"", .output = .{ .number = -2 } },
                .{ .code = "* 91 \"4\"", .output = .{ .number = 364 } },
                .{ .code = "* 9 TRUE", .output = .{ .number = 9 } },
                .{ .code = "* 9 FALSE", .output = .{ .number = 0 } },
                .{ .code = "* 9 NULL", .output = .{ .number = 0 } },
                .{ .code = "* 9 +@123", .output = .{ .number = 27 } },
                // evaluates arguments in order
                .{ .code = "* (= n 45) (- n 42)", .output = .{ .number = 135 } },
                .{ .code = "* (= n 15) (- n 14)", .output = .{ .number = 15 } },
                .{ .code = "* (= n 15) (- n 16)", .output = .{ .number = -15 } },
            },
        },
        .{
            .name = "or",
            .tests = &.{
                // returns the lhs if its truthy
                .{ .code = "| 1 QUIT 1", .output = .{ .number = 1 } },
                .{ .code = "| 2 QUIT 1", .output = .{ .number = 2 } },
                .{ .code = "| TRUE QUIT 1", .output = .{ .bool = true } },
                .{ .code = "| \"hi\" QUIT 1", .output = .{ .string = "hi" } },
                .{ .code = "| \"0\" QUIT 1", .output = .{ .string = "0" } },
                .{ .code = "| \"NaN\" QUIT 1", .output = .{ .string = "NaN" } },
                .{ .code = "| ,1 QUIT 1", .output = .{ .list = &.{
                    .{ .number = 1 },
                } } },
                // executes the rhs only if the lhs is falsey
                .{ .code = "; | 0 (= a 1) a", .output = .{ .number = 1 } },
                .{ .code = "; | FALSE (= a 2) a", .output = .{ .number = 2 } },
                .{ .code = "; | NULL (= a 3) a", .output = .{ .number = 3 } },
                .{ .code = "; | \"\" (= a 4) a", .output = .{ .number = 4 } },
                .{ .code = "; | @ (= a 5) a", .output = .{ .number = 5 } },
                // accepts blocks as the second operand
                .{ .code = "; = a 3 : CALL | 0 BLOCK a", .output = .{ .number = 3 } },
                .{ .code = "; = a 3 : CALL | 0 BLOCK + a 2", .output = .{ .number = 5 } },
            },
        },
        .{
            .name = "sub",
            .tests = &.{
                // subtracts integers normally
                .{ .code = "- 0 0", .output = .{ .number = 0 } },
                .{ .code = "- 1 2", .output = .{ .number = -1 } },
                .{ .code = "- 4 6", .output = .{ .number = -2 } },
                .{ .code = "- 112 ~1", .output = .{ .number = 113 } },
                .{ .code = "- 4 13", .output = .{ .number = -9 } },
                .{ .code = "- 4 ~13", .output = .{ .number = 17 } },
                .{ .code = "- ~4 13", .output = .{ .number = -17 } },
                .{ .code = "- ~4 ~13", .output = .{ .number = 9 } },
                // converts other values to integers
                .{ .code = "- 1 \"2\"", .output = .{ .number = -1 } },
                .{ .code = "- 91 \"45\"", .output = .{ .number = 46 } },
                .{ .code = "- 9 TRUE", .output = .{ .number = 8 } },
                .{ .code = "- 9 FALSE", .output = .{ .number = 9 } },
                .{ .code = "- 9 NULL", .output = .{ .number = 9 } },
                .{ .code = "- 9 +@145", .output = .{ .number = 6 } },
                // evaluates arguments in order
                .{ .code = "- (= n 45) (- 3 n)", .output = .{ .number = 87 } },
                .{ .code = "- (= n 15) (- 14 n)", .output = .{ .number = 16 } },
                .{ .code = "- (= n 15) (- 16 n)", .output = .{ .number = 14 } },
            },
        },
        .{
            .name = "then",
            .tests = &.{
                // executes arguments in order
                .{ .code = "; (= a 3) a", .output = .{ .number = 3 } },
                // returns the second argument
                .{ .code = "; 0 1", .output = .{ .number = 1 } },
                // also works with BLOCK return values
                .{ .code = "CALL ; = a 3 BLOCK a", .output = .{ .number = 3 } },
                // accepts blocks as either argument
                .{ .code = "; (BLOCK QUIT 1) 3", .output = .{ .number = 3 } },
                .{ .code = "CALL ; 3 (BLOCK 4)", .output = .{ .number = 4 } },
            },
        },
        .{
            .name = "while",
            .tests = &.{
                // returns null
                .{ .code = "WHILE 0 0", .output = .null },
                // will not eval the body if the condition is false
                .{ .code = "; WHILE FALSE (QUIT 1) : 12", .output = .{ .number = 12 } },
                // will eval the body until condition is false
                .{
                    .code =
                    \\; = i 0
                    \\; = sum 0
                    \\; WHILE (< i 10)
                    \\  ; = sum + sum i
                    \\  : = i + i 1
                    \\: sum
                    ,
                    .output = .{ .number = 45 },
                },
            },
        },
    };
    const ternary = [_]SpecTest{
        .{
            .name = "if",
            .tests = &.{
                // executes and returns only the correct value
                .{ .code = "IF TRUE 12 (QUIT 1)", .output = .{ .number = 12 } },
                .{ .code = "IF FALSE (QUIT 1) 12", .output = .{ .number = 12 } },
                // executes the condition before the result
                .{ .code = "IF (= a 3) (+ a 9) (QUIT 1)", .output = .{ .number = 12 } },
                // converts values to a boolean
                .{ .code = "IF 123 12 (QUIT 1)", .output = .{ .number = 12 } },
                .{ .code = "IF 0 (QUIT 1) 12 ", .output = .{ .number = 12 } },
                .{ .code = "IF \"123\" 12 (QUIT 1)", .output = .{ .number = 12 } },
                .{ .code = "IF \"0\" 12 (QUIT 1)", .output = .{ .number = 12 } },
                .{ .code = "IF \"\" (QUIT 1) 12", .output = .{ .number = 12 } },
                .{ .code = "IF NULL (QUIT 1) 12", .output = .{ .number = 12 } },
                .{ .code = "IF @ (QUIT 1) 12", .output = .{ .number = 12 } },
                .{ .code = "IF +@0 12 (QUIT 1)", .output = .{ .number = 12 } },
                // accepts blocks as either the second or third argument
                .{ .code = "IF TRUE (BLOCK QUIT 1) (QUIT 1)", .output = null, .just_run = true },
                .{ .code = "IF FALSE (QUIT 1) (BLOCK QUIT 1)", .output = null, .just_run = true },
                // TODO: Test errors
                // does not accept BLOCK values as the condition
                // refute_runs .code = "IF (BLOCK QUIT 0) 0 0"
                // refute_runs .code = "; = a 3 : IF (BLOCK a) 0 0"
                // requires exactly three arguments
                // refute_runs .code = "IF"
                // refute_runs .code = "IF TRUE"
                // refute_runs .code = "IF TRUE 1"
                // .{ .code = "IF TRUE 1 2", .just_run = true },
            },
        },
        .{
            .name = "get",
            .tests = &.{
                // when the first argument is a string
                // returns a substring of the original string
                .{ .code = "GET \"abcd\" 0 1", .output = .{ .string = "a" } },
                .{ .code = "GET \"abcd\" 1 2", .output = .{ .string = "bc" } },
                .{ .code = "GET \"abcd\" 2 2", .output = .{ .string = "cd" } },
                .{ .code = "GET \"abcd\" 3 0", .output = .{ .string = "" } },
                .{ .code = "GET '' 0 0", .output = .{ .string = "" } },
                // converts its arguments to the correct types
                .{ .code = "GET \"foobar\" NULL TRUE", .output = .{ .string = "f" } },
                // when the first argument is a list
                // returns a substring of the original list
                .{
                    .code = "GET +@\"abcd\" 0 1",
                    .output = .{
                        .list = &.{.{ .string = "a" }},
                    },
                },
                .{
                    .code = "GET +@\"abcd\" 1 2",
                    .output = .{
                        .list = &.{
                            .{ .string = "b" },
                            .{ .string = "c" },
                        },
                    },
                },
                .{
                    .code = "GET +@1234 2 2",
                    .output = .{
                        .list = &.{
                            .{ .number = 3 },
                            .{ .number = 4 },
                        },
                    },
                },
                .{ .code = "GET +@1234 3 0", .output = .{ .list = &.{} } },
                .{ .code = "GET @ 0 0", .output = .{ .list = &.{} } },
                // converts its arguments to the correct types
                .{
                    .code = "GET +@\"foobar\" NULL TRUE",
                    .output = .{
                        .list = &.{.{ .string = "f" }},
                    },
                },
            },
        },
    };
    const quaternary = [_]SpecTest{
        .{
            .name = "set",
            .tests = &.{
                // when the first argument is a string
                // can remove substrings
                .{
                    .code = "SET \"abcd\" 0 1 \"\"",
                    .output = .{ .string = "bcd" },
                },
                .{
                    .code = "SET \"abcd\" 1 2 \"\"",
                    .output = .{ .string = "ad" },
                },
                .{
                    .code = "SET \"abcd\" 2 2 \"\"",
                    .output = .{ .string = "ab" },
                },
                .{
                    .code = "SET \"abcd\" 0 3 \"\"",
                    .output = .{ .string = "d" },
                },
                .{
                    .code = "SET \"abc\" 0 3 \"\"",
                    .output = .{ .string = "" },
                },
                // can insert substrings
                .{
                    .code = "SET \"abcd\" 0 0 \"1\"",
                    .output = .{ .string = "1abcd" },
                },
                .{
                    .code = "SET \"abcd\" 4 0 \"12\"",
                    .output = .{ .string = "abcd12" },
                },
                .{
                    .code = "SET \"a\" 1 0 \"12\"",
                    .output = .{ .string = "a12" },
                },
                .{
                    .code = "SET \"\" 0 0 \"12\"",
                    .output = .{ .string = "12" },
                },
                // can replace substrings
                .{
                    .code = "SET \"abcd\" 1 2 \"123\"",
                    .output = .{ .string = "a123d" },
                },
                .{
                    .code = "SET \"abcd\" 2 2 \"4445\"",
                    .output = .{ .string = "ab4445" },
                },
                // converts its arguments to the correct types
                .{
                    .code = "SET '1234' TRUE ,1 FALSE",
                    .output = .{ .string = "1false34" },
                },
                .{
                    .code = "SET 'hello world' TRUE '2' +@123",
                    .output = .{ .string = "h1\n2\n3lo world" },
                },
                // when the first argument is a list
                // can remove sublists
                .{
                    .code = "SET +@\"abcd\" 0 1 @",
                    .output = .{
                        .list = &.{
                            .{ .string = "b" },
                            .{ .string = "c" },
                            .{ .string = "d" },
                        },
                    },
                },
                .{
                    .code = "SET +@\"abcd\" 1 2 @",
                    .output = .{
                        .list = &.{
                            .{ .string = "a" },
                            .{ .string = "d" },
                        },
                    },
                },
                .{
                    .code = "SET +@\"abcd\" 2 2 @",
                    .output = .{
                        .list = &.{
                            .{ .string = "a" },
                            .{ .string = "b" },
                        },
                    },
                },
                .{
                    .code = "SET +@\"abcd\" 0 3 @",
                    .output = .{
                        .list = &.{
                            .{ .string = "d" },
                        },
                    },
                },
                .{
                    .code = "SET +@\"abc\" 0 3 @",
                    .output = .{ .list = &.{} },
                },
                // can insert sublists
                .{
                    .code = "SET +@\"abcd\" 0 0 ,TRUE",
                    .output = .{
                        .list = &.{
                            .{ .bool = true },
                            .{ .string = "a" },
                            .{ .string = "b" },
                            .{ .string = "c" },
                            .{ .string = "d" },
                        },
                    },
                },
                .{
                    .code = "SET +@\"abcd\" 4 0 +@12",
                    .output = .{
                        .list = &.{
                            .{ .string = "a" },
                            .{ .string = "b" },
                            .{ .string = "c" },
                            .{ .string = "d" },
                            .{ .number = 1 },
                            .{ .number = 2 },
                        },
                    },
                },
                .{
                    .code = "SET +@\"a\" 1 0 +@12",
                    .output = .{
                        .list = &.{
                            .{ .string = "a" },
                            .{ .number = 1 },
                            .{ .number = 2 },
                        },
                    },
                },
                .{
                    .code = "SET @ 0 0 +@12",
                    .output = .{
                        .list = &.{
                            .{ .number = 1 },
                            .{ .number = 2 },
                        },
                    },
                },
                // can replace sublists
                .{
                    .code = "SET +@\"abcd\" 1 2 +@123",
                    .output = .{
                        .list = &.{
                            .{ .string = "a" },
                            .{ .number = 1 },
                            .{ .number = 2 },
                            .{ .number = 3 },
                            .{ .string = "d" },
                        },
                    },
                },
                .{
                    .code = "SET +@\"abcd\" 2 2 +@4445",
                    .output = .{
                        .list = &.{
                            .{ .string = "a" },
                            .{ .string = "b" },
                            .{ .number = 4 },
                            .{ .number = 4 },
                            .{ .number = 4 },
                            .{ .number = 5 },
                        },
                    },
                },
                // converts its arguments to the correct types
                .{
                    .code = "SET +@\"abcd\" 0 0 TRUE",
                    .output = .{
                        .list = &.{
                            .{ .bool = true },
                            .{ .string = "a" },
                            .{ .string = "b" },
                            .{ .string = "c" },
                            .{ .string = "d" },
                        },
                    },
                },
                .{
                    .code = "SET +@1234 TRUE '1' FALSE",
                    .output = .{
                        .list = &.{
                            .{ .number = 1 },
                            .{ .number = 3 },
                            .{ .number = 4 },
                        },
                    },
                },
                .{
                    .code = "SET +@'hello world' TRUE '2' 123",
                    .output = .{ .list = &.{
                        .{ .string = "h" },
                        .{ .number = 1 },
                        .{ .number = 2 },
                        .{ .number = 3 },
                        .{ .string = "l" },
                        .{ .string = "o" },
                        .{ .string = " " },
                        .{ .string = "w" },
                        .{ .string = "o" },
                        .{ .string = "r" },
                        .{ .string = "l" },
                        .{ .string = "d" },
                    } },
                },
                .{
                    .code = "SET +@1234 NULL ,3 'yo'",
                    .output = .{ .list = &.{
                        .{ .string = "y" },
                        .{ .string = "o" },
                        .{ .number = 2 },
                        .{ .number = 3 },
                        .{ .number = 4 },
                    } },
                },
            },
        },
    };
};

const knight_encoding: []const u8 = "\t\n\r !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~";

fn addAsciiTests(b: *Build, exe: *Build.Step.Compile, step: *Build.Step) void {
    for (knight_encoding) |c| {
        step.dependOn(addTest(
            b,
            exe,
            b.fmt("ASCII {d}", .{c}),
            null,
            (KnightValue{ .string = &.{c} }).fmt(b),
            null,
            false,
        ));
    }

    for (knight_encoding) |c| {
        if (c == '"') continue;
        step.dependOn(addTest(
            b,
            exe,
            b.fmt("ASCII \"{c}\"", .{c}),
            null,
            (KnightValue{ .number = c }).fmt(b),
            null,
            false,
        ));
    }
    step.dependOn(addTest(
        b,
        exe,
        "ASCII '\"'",
        null,
        (KnightValue{ .number = '"' }).fmt(b),
        null,
        false,
    ));
}

const variables: SpecTest = .{
    .name = "variables",
    .tests = &.{
        // can be assigned to
        .{ .code = "; = a 3 : a", .output = .{ .number = 3 } },

        // can be reassigned
        .{ .code = "; = a 3 ; = a 4 : a", .output = .{ .number = 4 } },

        // can be reassigned using itself
        .{ .code = "; = a 3 ; = a + a 1 : a", .output = .{ .number = 4 } },

        // can have multiple variables
        .{ .code = "; = a 3 ; = b 4 : + a b", .output = .{ .number = 7 } },

        // has all variables as global within blocks
        .{
            .code =
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
            ,
            .output = .{ .list = &.{
                .{ .number = 5 },
                .{ .number = 2 },
                .{ .number = 6 },
                .{ .number = 4 },
                .{ .number = 7 },
                .{ .number = 8 },
            } },
        },
    },
};

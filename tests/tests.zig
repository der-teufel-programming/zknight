const std = @import("std");
const Build = std.Build;

fn addTest(b: *Build, exe: *Build.Step.Compile, test_code: []const u8, test_stdin: ?[]const u8, expected_output: []const u8) *Build.Step {
    var run_step = b.addRunArtifact(exe);
    run_step.addArgs(&.{ "-e", test_code });
    run_step.expectStdOutEqual(expected_output);
    if (test_stdin) |stdin| {
        run_step.setStdIn(.{ .bytes = stdin });
    }
    return &run_step.step;
}

pub fn addTests(b: *Build, exe: *Build.Step.Compile) *Build.Step {
    var tests = b.step("", "");
    for (test_cases) |test_case| {
        const step = addTest(b, exe, test_case.code, test_case.input, test_case.output);
        tests.dependOn(step);
    }
    return tests;
}

const Case = struct {
    code: []const u8,
    output: []const u8,
    input: ?[]const u8,
};

const test_cases = [_]Case{
    makeTest("0", null, "0"),
    makeTest("P", "foo", "\"foo\""),
    makeTest("+ P P", "\n\r\nx", "\"\""),
};

fn makeTest(code: []const u8, input: ?[]const u8, output: []const u8) Case {
    const full_code = "D " ++ code;
    return Case{ .code = full_code, .input = input, .output = output };
}

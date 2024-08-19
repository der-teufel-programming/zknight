const std = @import("std");
const tests = @import("tests/tests.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const sanitize = b.option(
        bool,
        "sanitize",
        "The interpreter will error on some of UB (default true in debug builds)",
    ) orelse (optimize == .Debug);

    const debug = b.option(bool, "debug", "Enable debug printing") orelse (optimize == .Debug);

    const exe = b.addExecutable(.{
        .name = "zknight",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    var opts = b.addOptions();
    opts.addOption(bool, "sanitize", sanitize);
    opts.addOption(bool, "debug", debug);

    exe.root_module.addOptions("build_options", opts);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const test_exe = b.addExecutable(.{
        .name = "zknight",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    var test_opts = b.addOptions();
    test_opts.addOption(bool, "sanitize", true);
    test_opts.addOption(bool, "debug", false);

    test_exe.root_module.addOptions("build_options", test_opts);

    const test_step = b.step("test", "Run unit tests");

    const source_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
    });

    const run_source_tests = b.addRunArtifact(source_tests);
    test_step.dependOn(&run_source_tests.step);

    tests.addTests(b, test_step, test_exe);
    for (examples) |ex| {
        const run_ex = b.addRunArtifact(test_exe);
        ex.addToRun(run_ex);
        test_step.dependOn(&run_ex.step);
    }

    if (b.option(bool, "spec", "Test spec conformance") orelse false) {
        tests.spec.addFunctions(b, test_exe, test_step);
        tests.spec.addVariables(b, test_exe, test_step);
    }
}

const Example = struct {
    name: []const u8,
    input: ?[]const u8 = null,
    expected: ?[]const u8 = null,

    fn path(e: Example, b: *std.Build) std.Build.LazyPath {
        const kn_dep = b.dependency("knight-lang", .{});
        const examples_path = kn_dep.path("examples");
        return examples_path.path(b, e.name);
    }

    pub fn addToRun(e: Example, run: *std.Build.Step.Run) void {
        const b = run.step.owner;
        run.addArg("-f");
        run.addFileArg(e.path(b));
        if (e.input) |inp| {
            run.setStdIn(.{ .bytes = inp });
        }
        if (e.expected) |out| {
            run.expectStdOutEqual(out);
        }
    }
};

const examples: []const Example = &.{
    .{
        .name = "brainfuck.kn",
        .input = "++++++++[>++++[>++>+++>+++>+<<<<-]>+>+>->>+[<]<-]>>.>---.+++++++..+++.>>.<-.<.+++.------.--------.>>+.>++.",
        .expected = "Hello World!\n",
    },
    .{
        .name = "fibonacci.kn",
        .expected = "55\n",
    },
    .{
        .name = "fizzbuzz.kn",
        .expected =
        \\1
        \\2
        \\Buzz
        \\4
        \\Fizz
        \\Buzz
        \\7
        \\8
        \\Buzz
        \\Fizz
        \\11
        \\Buzz
        \\13
        \\14
        \\FizzBuzz
        \\16
        \\17
        \\Buzz
        \\19
        \\Fizz
        \\Buzz
        \\22
        \\23
        \\Buzz
        \\Fizz
        \\26
        \\Buzz
        \\28
        \\29
        \\FizzBuzz
        \\31
        \\32
        \\Buzz
        \\34
        \\Fizz
        \\Buzz
        \\37
        \\38
        \\Buzz
        \\Fizz
        \\41
        \\Buzz
        \\43
        \\44
        \\FizzBuzz
        \\46
        \\47
        \\Buzz
        \\49
        \\Fizz
        \\Buzz
        \\52
        \\53
        \\Buzz
        \\Fizz
        \\56
        \\Buzz
        \\58
        \\59
        \\FizzBuzz
        \\61
        \\62
        \\Buzz
        \\64
        \\Fizz
        \\Buzz
        \\67
        \\68
        \\Buzz
        \\Fizz
        \\71
        \\Buzz
        \\73
        \\74
        \\FizzBuzz
        \\76
        \\77
        \\Buzz
        \\79
        \\Fizz
        \\Buzz
        \\82
        \\83
        \\Buzz
        \\Fizz
        \\86
        \\Buzz
        \\88
        \\89
        \\FizzBuzz
        \\91
        \\92
        \\Buzz
        \\94
        \\Fizz
        \\Buzz
        \\97
        \\98
        \\Buzz
        \\Fizz
        \\
        ,
    },
    // .{
    //     .name = "guessing.kn ",
    // },
    // .{
    //     .name = "knight.kn",
    // },
    .{
        .name = "calculator.kn",
        .input = "2 + 2",
        .expected =
        \\enter an expression in the form 'NUM <op> NUM'
        \\4
        \\
        ,
    },
    .{
        .name = "fibonacci-recursive-stack.kn",
        .expected = "55\n",
    },
    .{
        .name = "helloworld.kn",
        .expected = "Hello, world!\n",
    },
    .{
        .name = "primes.kn",
        .input = "100",
        .expected =
        \\the primes from 2-100 are:
        \\2 3 5 7 11 13 17 19 23 29 31 37 41 43 47 53 59 61 67 71 73 79 83 89 97
        \\
        ,
    },
};

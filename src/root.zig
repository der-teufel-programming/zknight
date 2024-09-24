pub const parser = @import("parser.zig");
pub const Ast = parser.Ast;
pub const analyzer = @import("analyzer.zig");
pub const emit = @import("emit.zig");
pub const Emitter = emit.Emitter;
pub const VM = @import("VM.zig");
pub const options = @import("build_options");
pub const debug = options.debug;

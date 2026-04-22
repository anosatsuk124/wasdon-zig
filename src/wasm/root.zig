//! WASM Core 1 / MVP binary parser — sub-library root.
//!
//! Scope: purely binary-format decoding per docs/w3c_wasm_binary_format_note.md
//! plus `__udon_meta` JSON discovery per docs/spec_udonmeta_conversion.md.
//! Validation, runtime semantics, and Udon lowering live elsewhere.

const std = @import("std");

pub const errors = @import("errors.zig");
pub const reader = @import("reader.zig");
pub const leb128 = @import("leb128.zig");
pub const types = @import("types.zig");
pub const opcode = @import("opcode.zig");
pub const instruction = @import("instruction.zig");
pub const section = @import("section.zig");
pub const module = @import("module.zig");
pub const parser = @import("parser.zig");
pub const const_eval = @import("const_eval.zig");
pub const udon_meta = @import("udon_meta.zig");

pub const Module = module.Module;
pub const parseModule = parser.parseModule;
pub const UdonMeta = udon_meta.UdonMeta;
pub const parseUdonMeta = udon_meta.parse;
pub const findUdonMetaBytes = udon_meta.findMetaBytes;
pub const parseUdonMetaFromModule = udon_meta.parseFromModule;

pub const ParseError = errors.ParseError;
pub const Reader = reader.Reader;
pub const readULEB128 = leb128.readULEB128;
pub const readSLEB128 = leb128.readSLEB128;
pub const Instruction = instruction.Instruction;
pub const decodeInstruction = instruction.decodeInstruction;
pub const decodeExpr = instruction.decodeExpr;

test {
    // Pull in nested-module tests so `zig build test` on this module exercises
    // every file.
    std.testing.refAllDecls(@This());
    _ = reader;
    _ = leb128;
    _ = errors;
    _ = types;
    _ = opcode;
    _ = instruction;
    _ = section;
    _ = module;
    _ = parser;
    _ = const_eval;
    _ = udon_meta;
}

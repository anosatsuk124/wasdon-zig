//! Error set for the WASM Core 1 binary parser.
//!
//! Each error corresponds 1:1 to a malformed-condition enumerated by
//! docs/w3c_wasm_binary_format_note.md (section "List of Conditions That Are
//! Malformed at the Binary-Format Level") or to a low-level I/O boundary.
//! Later phases grow this set; keep it a single source of truth.

pub const ParseError = error{
    UnexpectedEof,

    // LEB128
    LebTooLong,
    LebUnusedBitsNotZero,
    LebOverflow,

    // Types
    InvalidValType,
    MalformedFuncType,
    MalformedLimits,
    MalformedMut,
    InvalidElemType,
    InvalidUtf8Name,
    InvalidBlockType,

    // Instructions
    UnknownOpcode,
    UnknownPrefixedOpcode,
    MalformedReserved,
    UnexpectedEndOpcode,
    UnexpectedElseOpcode,

    // Section framing
    UnknownSectionId,
    SectionSizeMismatch,
    SectionOutOfOrder,
    DuplicateSection,

    // Section payloads
    MalformedImportDesc,
    MalformedExportDesc,
    MalformedElementSegment,
    MalformedDataSegment,
    /// Data segment mode 0x02 with a non-zero memidx: parser sees a
    /// well-formed segment but the translator's single-memory assumption
    /// (see `docs/spec_linear_memory.md`) cannot represent it. Rejected at
    /// parse time so the rest of the pipeline doesn't have to plumb
    /// memidx > 0 through.
    MultiMemoryNotYetSupported,
    /// `funcref` (`0x70`) appears in a position that would require
    /// materializing a first-class function reference (param / result /
    /// local / global). The decoder accepts `funcref` so reference-types
    /// modules round-trip, but the translator has no Udon-side
    /// representation yet — see `docs/w3c_wasm_binary_format_note.md`
    /// "Reference-types `funcref` value type (post-MVP)".
    FuncrefValueTypeNotYetSupported,
    FuncCodeCountMismatch,

    // Module header
    BadMagic,
    BadVersion,

    // Const-expression evaluation (data/element segment offsets, immutable
    // global inits). Anything outside the strict MVP-const subset (a single
    // `i32.const` or a `global.get` that hops to one) returns this.
    NonConstInitExpr,

    // __udon_meta JSON decode
    InvalidUtf8MetaPayload,
    UnsupportedUdonMetaVersion,
    MalformedMeta,
    MissingSyncMode,
    InvalidFieldSyncMode,
    InvalidMemoryPageBounds,
    InvalidBehaviourSyncMode,
    InvalidFieldType,
    InvalidEventKind,
    InvalidSourceKind,
    InvalidUnknownPolicy,

    // General allocator failures propagated from std.mem.Allocator
    OutOfMemory,
};

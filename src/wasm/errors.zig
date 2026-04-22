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
    FuncCodeCountMismatch,

    // Module header
    BadMagic,
    BadVersion,

    // __udon_meta discovery & JSON decode
    NonConstMetaLocator,
    MetaRangeOutOfData,
    MetaSpansMultipleSegments,
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

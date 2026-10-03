//! YAML indexing, validation and navigation for one restricted profile.
//!
//! This module implements the `yaml-basic-1.2.2` grammar and refuses the rest
//! of YAML with `error.Unsupported`: directives, tags, anchors, aliases,
//! explicit `?` keys, block `|` and folded `>` scalars, the reserved `@` and
//! `` ` `` indicators, flow collections where a key is expected, `\N` and the
//! other non-basic escapes, a second `---` document, and any construct that
//! would need a second line to finish. Malformed input inside the profile is
//! `error.Invalid` instead, so the two are distinguishable without parsing.
//! The extended grammar lives in `formats.yaml_extended`, which selects
//! `Profile.extended`.
//!
//! A consumer reaches this module as `simd.formats.yaml`, or by importing
//! `formats/yaml.zig` relatively.
//!
//! `indexYaml` and `validateYaml` read `input` in one call and copy offsets
//! and lengths, so `input` may be released when they return. `buildYamlTape`
//! and `YamlDocument.root` borrow `input`, which must stay alive and
//! unmodified while the document, its cursors and its spans are read. Every
//! allocating entry point takes the caller's allocator; the resident `Parser`
//! allocates nothing and ignores the allocator its `init` is handed.

const std = @import("std");
const simd = @import("../core/simd.zig");
const stage1 = @import("../core/stage1.zig");
const resident = @import("../core/resident.zig");
const source = @import("yaml_source.zig");

const testing = std.testing;
const max_u24: usize = std.math.maxInt(u24);
/// U+FEFF in UTF-8. A byte order mark at the head of a stream, and the one
/// character the shared source check reads only as quoted content.
const bom = "\xef\xbb\xbf";
/// Deepest block and flow nesting this module accepts, in collections. A
/// document that would nest further fails with `error.DepthExceeded` rather
/// than growing a frame stack, because every engine here holds its frames in
/// a fixed `yaml_max_depth` array.
pub const yaml_max_depth: usize = 1024;

/// Named parser profiles. The default remains the restricted basic grammar.
///
/// The tag names the grammar, not a switch this module reads: `basic` is what
/// `profile` selects here, and `extended` names the grammar implemented by
/// `formats.yaml_extended`, which reuses this enum and this module's
/// `profileLabel`.
pub const Profile = enum {
    basic,
    extended,
};

/// The profile this module implements. A sibling module may redeclare its own
/// value of the same type; a caller compares labels, not this binding.
pub const profile: Profile = .basic;
/// `profileLabel(profile)`, for a caller that needs a string next to the
/// profile itself.
pub const profile_label = "yaml-basic-1.2.2";

/// The published label for `selected`, for a corpus or report header. The
/// result is a static string that is never freed.
pub fn profileLabel(selected: Profile) []const u8 {
    return switch (selected) {
        .basic => "yaml-basic-1.2.2",
        .extended => "yaml-extended-e2b-1.2.2",
    };
}

/// The restricted YAML token stream emitted by Stage 1 and retained by Stage 2.
///
/// Block containers use the first source byte of the container and the matching
/// end token uses the last source byte consumed by the container. Scalar and key
/// tokens carry their source span length in the structural index and tape.
pub const YamlTokenKind = enum(u8) {
    document_start,
    document_end,
    mapping_start,
    mapping_end,
    sequence_start,
    sequence_end,
    key,
    scalar,
};

/// YAML errors are deliberately split from allocator and capacity errors. An
/// Invalid input is malformed in the selected profile. Unsupported input is a
/// recognizable YAML feature outside yaml-basic-1.2.2.
pub const YamlError = error{
    Invalid,
    Unsupported,
    DepthExceeded,
};

/// Errors `indexYaml`, `indexYamlImpl` and `scalarIndexYaml` return. They
/// allocate an index, so `error.OutOfMemory` is reachable; `TapeTooLarge` is
/// an unrepresentable offset or span, and the `YamlError` tags are the
/// profile verdicts.
pub const YamlIndexError = std.mem.Allocator.Error || YamlError || error{
    CapacityOverflow,
    InputTooLarge,
    TapeTooLarge,
};

/// Errors `validateYaml` and `validateYamlIndex` return. No `YamlError` tag
/// appears in it: both entry points report a grammar or profile failure as a
/// `YamlDiagnostic`, so only the allocator and sizing tags surface as errors.
pub const YamlValidationError = std.mem.Allocator.Error || error{
    CapacityOverflow,
    InputTooLarge,
    TapeTooLarge,
};

/// Errors `buildYamlTape` returns. It runs the same grammar as `indexYaml`, so
/// the `YamlError` tags reach it directly rather than through a diagnostic.
pub const YamlBuildError = std.mem.Allocator.Error || YamlError || error{
    CapacityOverflow,
    InputTooLarge,
    TapeTooLarge,
};

/// How a diagnostic should be read: `syntax` for malformed input inside the
/// profile, `unsupported` for recognizable YAML outside it, and `invalid_index`
/// for a supplied `YamlStructuralIndex` that does not match a fresh parse.
pub const YamlDiagnosticKind = enum(u8) {
    syntax,
    unsupported,
    invalid_index,
};

/// A source-backed first-failure diagnostic. `snippet` borrows `input`.
///
/// The value is a view, not an owner: every slice in it comes from the `input`
/// the validating entry point was given, so it stays valid only while those
/// bytes do.
pub const YamlDiagnostic = struct {
    /// The verdict. `kind` says how to read it.
    err: YamlError,
    /// One of `YamlDiagnosticKind`.
    kind: YamlDiagnosticKind,
    /// Byte offset into the input, clamped to `input.len`.
    byte_offset: usize,
    /// One-based line number of `byte_offset`, clamped to
    /// `std.math.maxInt(u32)`.
    line: u32,
    /// One-based column of `byte_offset` inside its line, clamped to
    /// `std.math.maxInt(u32)`.
    column: u32,
    /// Up to 16 bytes of the input on each side of `byte_offset`, cut at the
    /// line boundaries. Borrows the input.
    snippet: []const u8,
    /// Offset of `snippet[0]` in the input, so the snippet can be located
    /// with it.
    snippet_start: usize,
};

/// A source span retained by a structural entry. The source bytes remain
/// caller-owned; only offsets and lengths are copied into the index and tape.
pub const YamlSourceSpan = struct {
    start: u32,
    length: u32,
};

/// A format-local structural index. The index owns all three arrays.
///
/// It stores offsets and span lengths only, so the source bytes may be
/// released as soon as the indexer returns. One index owns `indexes`,
/// `kinds` and `lengths` and releases all three in one `deinit`, from the
/// same allocator the indexer was given. Copying an index copies the three
/// slice handles, so a copy is not a second owner and must not be `deinit`'d.
pub const YamlStructuralIndex = struct {
    /// Token offsets of `indexes[0..count]`. Three entries past `count` hold
    /// the sentinels `stage1.StructuralIndex.finish` writes: the input length
    /// twice and then `0`.
    indexes: []u32,
    /// Kind of each of `kinds[0..count]`. Entries past `count` are unused.
    kinds: []YamlTokenKind,
    /// Span length in bytes of each of `lengths[0..count]`. For a container
    /// token this is the semantic length the grammar assigned, not a byte
    /// range the caller may slice.
    lengths: []u32,
    /// Number of tokens written. The arrays are longer than this.
    count: usize,

    /// Releases all three arrays into `allocator`, which must be the allocator
    /// the indexer received. The index is unusable afterward, and a second
    /// call through any copy is a double free.
    pub fn deinit(self: *YamlStructuralIndex, allocator: std.mem.Allocator) void {
        allocator.free(self.indexes);
        allocator.free(self.kinds);
        allocator.free(self.lengths);
        self.* = undefined;
    }

    /// `indexes[0..count]`. Excludes the sentinels, so a caller that reads
    /// offsets sees exactly the tokens.
    pub fn slice(self: *const YamlStructuralIndex) []const u32 {
        return self.indexes[0..self.count];
    }

    /// The offset and length recorded for `token_index`, or `null` when
    /// `token_index` is not below `count`.
    ///
    /// Nothing is read from the source, so the answer cannot be wrong about
    /// the source's current contents. For a `key` or `scalar` the pair is a
    /// real byte range of the input; for a container token it is the grammar's
    /// own extent and only `YamlCursor.sourceSpan` on a `key` or `scalar`
    /// yields bytes.
    pub fn sourceSpan(self: *const YamlStructuralIndex, token_index: usize) ?YamlSourceSpan {
        if (token_index >= self.count) return null;
        return .{
            .start = self.indexes[token_index],
            .length = self.lengths[token_index],
        };
    }
};
/// A compact validated YAML token. Scalar and key payloads are source lengths;
/// container payloads are zero and are interpreted by token kind.
///
/// The fields are public, so a caller may write a word into
/// `YamlDocument.tape`; `YamlDocument.root` re-parses the source and compares
/// every word against it, so a forged word is rejected there rather than read.
pub const YamlTapeWord = packed struct(u64) {
    /// `std.meta.intToEnum(YamlTokenKind, kind)`. Navigation compares it against
    /// the enum rather than converting, so a value no tag has gives
    /// `error.InvalidTapeKind`.
    kind: u8,
    /// Source span length in bytes for a `key` or `scalar`, and `0` for a
    /// container token, whose extent is implied by its position. The tape
    /// rejects a span longer than this width.
    payload: u24,
    /// Source offset of the token: the first byte of a container or document
    /// marker, or the first byte of the span for a `key` or `scalar`.
    offset: u32,

    /// Converts a known-valid tape tag to its public enum. Callers that receive
    /// mutable or external tape words must use the checked navigation methods.
    /// An invalid tag is diagnosed in Debug and ReleaseSafe; ReleaseFast and
    /// ReleaseSmall treat it as unchecked illegal behavior, not a returned error.
    pub fn tapeKind(self: YamlTapeWord) YamlTokenKind {
        return @enumFromInt(self.kind);
    }

    /// `payload` widened to `usize`.
    pub fn sourceLength(self: YamlTapeWord) usize {
        return @intCast(self.payload);
    }
};

fn checkedYamlTapeKind(word: YamlTapeWord) YamlNavigationError!YamlTokenKind {
    return switch (word.kind) {
        @intFromEnum(YamlTokenKind.document_start) => .document_start,
        @intFromEnum(YamlTokenKind.document_end) => .document_end,
        @intFromEnum(YamlTokenKind.mapping_start) => .mapping_start,
        @intFromEnum(YamlTokenKind.mapping_end) => .mapping_end,
        @intFromEnum(YamlTokenKind.sequence_start) => .sequence_start,
        @intFromEnum(YamlTokenKind.sequence_end) => .sequence_end,
        @intFromEnum(YamlTokenKind.key) => .key,
        @intFromEnum(YamlTokenKind.scalar) => .scalar,
        else => error.InvalidTapeKind,
    };
}
fn checkedYamlTokenKind(kind: YamlTokenKind) YamlNavigationError!YamlTokenKind {
    return switch (@intFromEnum(kind)) {
        @intFromEnum(YamlTokenKind.document_start) => .document_start,
        @intFromEnum(YamlTokenKind.document_end) => .document_end,
        @intFromEnum(YamlTokenKind.mapping_start) => .mapping_start,
        @intFromEnum(YamlTokenKind.mapping_end) => .mapping_end,
        @intFromEnum(YamlTokenKind.sequence_start) => .sequence_start,
        @intFromEnum(YamlTokenKind.sequence_end) => .sequence_end,
        @intFromEnum(YamlTokenKind.key) => .key,
        @intFromEnum(YamlTokenKind.scalar) => .scalar,
        else => error.InvalidTapeKind,
    };
}

comptime {
    std.debug.assert(@bitSizeOf(YamlTapeWord) == 64);
    std.debug.assert(@sizeOf(YamlTapeWord) == 8);
}

/// An owned validated YAML tape. `source` is borrowed from the caller.
///
/// One document owns `tape` and releases it in one `deinit`; `source` is never
/// freed here. That source must stay alive and unmodified for as long as the
/// document, any cursor made from it, and any span read through one are used —
/// `root` and `sourceSpan` compare `input` against `source` by pointer and
/// length, so a relocated copy is rejected rather than silently accepted.
/// Copying a document copies the tape handle, so a copy is not a second owner
/// and must not be `deinit`'d.
pub const YamlDocument = struct {
    /// One word per token, in the order the grammar emitted them.
    tape: []YamlTapeWord,
    /// The borrowed source the tape was built from.
    source: []const u8,

    /// Releases `tape` into `allocator`, which must be the allocator
    /// `buildYamlTape` received. The borrowed source is untouched. The
    /// document and every cursor over it are unusable afterward, and a second
    /// call through any copy is a double free.
    pub fn deinit(self: *YamlDocument, allocator: std.mem.Allocator) void {
        allocator.free(self.tape);
        self.* = undefined;
    }

    /// Cursor on the first token, after re-parsing `input` and checking that
    /// the tape matches it exactly.
    ///
    /// `input` must be the same slice `source` names — same pointer and length
    /// — or this returns `error.SourceOutOfBounds`. The check replays the whole
    /// grammar and compares every word's kind, offset and payload, and it
    /// requires the engine to produce no further events, so it costs a full
    /// pass; call it once and walk the cursor. `error.InvalidStructure` when
    /// the tape and the source disagree, and `error.TapeOutOfBounds` for an
    /// empty tape. A profile or grammar failure in `input` surfaces here as
    /// `error.InvalidStructure` too, so this is a "does the tape match" check
    /// rather than a diagnostic; `validateYaml` is the entry point that
    /// distinguishes `error.Invalid` from `error.Unsupported`. The cursor
    /// borrows `self.tape` and `input`, so neither may be released or
    /// `deinit`'d while it is used.
    pub fn root(self: *const YamlDocument, input: []const u8) YamlNavigationError!YamlCursor {
        if (self.tape.len == 0) return error.TapeOutOfBounds;
        if (input.ptr != self.source.ptr or input.len != self.source.len) {
            return error.SourceOutOfBounds;
        }
        var engine = YamlResidentEngine.init();
        engine.reset(input);
        for (self.tape) |word| {
            const kind = try checkedYamlTapeKind(word);
            const offset: usize = @intCast(word.offset);
            if (offset > input.len) return error.SourceOutOfBounds;
            if (kind == .key or kind == .scalar) {
                const length = word.sourceLength();
                if (length > input.len - offset) return error.SourceOutOfBounds;
            }
            const event = (engine.next(engine.consumed) catch return error.InvalidStructure) orelse
                return error.InvalidStructure;
            if (event.kind != kind or event.offset != word.offset or event.raw.len != word.payload) {
                return error.InvalidStructure;
            }
        }
        if ((engine.next(engine.consumed) catch return error.InvalidStructure) != null) {
            return error.InvalidStructure;
        }
        return .{ .tape = self.tape, .input = input };
    }

    /// The source bytes of a `key` or `scalar` token.
    ///
    /// `error.TypeMismatch` for a container token, which has no byte range to
    /// return; `error.TapeOutOfBounds` for `tape_index` at or past the tape
    /// length; `error.InvalidTapeKind` for a word whose `kind` is not a
    /// `YamlTokenKind` tag; and `error.SourceOutOfBounds` when `input` is not
    /// the recorded source or offset and length do not fit it. This checks one
    /// word and does not replay the grammar; `root` is the whole-document
    /// check. The result borrows `input`.
    pub fn sourceSpan(
        self: *const YamlDocument,
        input: []const u8,
        tape_index: usize,
    ) YamlNavigationError![]const u8 {
        if (input.ptr != self.source.ptr or input.len != self.source.len) {
            return error.SourceOutOfBounds;
        }
        if (tape_index >= self.tape.len) return error.TapeOutOfBounds;
        const word = self.tape[tape_index];
        const kind = try checkedYamlTapeKind(word);
        if (kind != .key and kind != .scalar) return error.TypeMismatch;
        const offset: usize = @intCast(word.offset);
        const length = word.sourceLength();
        if (offset > input.len or length > input.len - offset) {
            return error.SourceOutOfBounds;
        }
        return input[offset .. offset + length];
    }
};

/// Failures the YAML tape and cursor methods return.
///
/// `TapeOutOfBounds` for a `tape_index` at or past the tape length and for a
/// cursor past the last word, `SourceOutOfBounds` when `input` is not the
/// document's recorded source or a span does not fit it, `InvalidTapeKind` for
/// a word whose `kind` is not a `YamlTokenKind` tag, `TypeMismatch` when a
/// span is asked for a token that has none, `UnexpectedEnd` when a skipped
/// collection never closes, and `InvalidStructure` when the tape and a fresh
/// parse of the source disagree.
pub const YamlNavigationError = error{
    TapeOutOfBounds,
    SourceOutOfBounds,
    InvalidTapeKind,
    TypeMismatch,
    UnexpectedEnd,
    InvalidStructure,
};

/// A zero-allocation cursor over an owned YAML tape and borrowed source.
///
/// The cursor holds the tape and the source slice `YamlDocument.root` was
/// given, and owns neither: it borrows the document's tape and the caller's
/// `input`, so the document must outlive every cursor over it and must not be
/// `deinit`'d while one is used. A cursor is a plain value, so copying one is
/// free and the copy advances independently. Only `peek` re-checks the word's
/// `kind`; the tape was checked against the source once, in `root`.
pub const YamlCursor = struct {
    /// The document's tape. Borrowed.
    tape: []const YamlTapeWord,
    /// The source slice passed to `YamlDocument.root`. Borrowed.
    input: []const u8,
    /// Index of the next word in `tape`. Equal to `tape.len` once the walk is
    /// exhausted.
    position_index: usize = 0,

    /// The word under the cursor, with its `kind` checked against
    /// `YamlTokenKind`, or `error.TapeOutOfBounds` once the walk is past the
    /// last word.
    pub fn peek(self: *const YamlCursor) YamlNavigationError!YamlTapeWord {
        if (self.position_index >= self.tape.len) return error.TapeOutOfBounds;
        const word = self.tape[self.position_index];
        _ = try checkedYamlTapeKind(word);
        return word;
    }

    /// Validates the word under the cursor and steps past it. Nothing moves
    /// when `peek` fails.
    pub fn advance(self: *YamlCursor) YamlNavigationError!void {
        _ = try self.peek();
        self.position_index += 1;
    }

    /// Index of the next word. Equal to `tape.len` when exhausted.
    pub fn position(self: *const YamlCursor) usize {
        return self.position_index;
    }

    /// The source bytes under the cursor, for a `key` or `scalar`.
    ///
    /// `error.TypeMismatch` for a container or document token, which has no
    /// byte range, and `error.SourceOutOfBounds` when offset and length do not
    /// fit `input`. The result borrows `input` and is invalidated when the
    /// caller writes or releases it.
    pub fn sourceSpan(self: *const YamlCursor) YamlNavigationError![]const u8 {
        const word = try self.peek();
        const kind = try checkedYamlTapeKind(word);
        if (kind != .key and kind != .scalar) return error.TypeMismatch;
        const start: usize = @intCast(word.offset);
        const length = word.sourceLength();
        if (start > self.input.len or length > self.input.len - start) {
            return error.SourceOutOfBounds;
        }
        return self.input[start .. start + length];
    }

    /// `sourceSpan`.
    pub fn span(self: *const YamlCursor) YamlNavigationError![]const u8 {
        return self.sourceSpan();
    }

    /// `sourceSpan`.
    pub fn raw(self: *const YamlCursor) YamlNavigationError![]const u8 {
        return self.sourceSpan();
    }

    /// Skips one complete collection while checking every public tape word.
    /// YAML container end offsets are semantic line ends and need not increase.
    ///
    /// The cursor must be on a `mapping_start` or `sequence_start`, or this
    /// returns `error.TypeMismatch` and does not move. Every word it steps over
    /// has its `kind` checked, and `error.UnexpectedEnd` when the matching end
    /// token never arrives — which a tape from `buildYamlTape` cannot do, so it
    /// marks a hand-built tape. On success the cursor sits after the closing
    /// token of the skipped collection.
    pub fn skipChild(self: *YamlCursor) YamlNavigationError!void {
        const first = try self.peek();
        const first_kind = try checkedYamlTapeKind(first);
        if (first_kind != .mapping_start and first_kind != .sequence_start) {
            return error.TypeMismatch;
        }
        var depth: usize = 1;
        var steps: usize = 0;
        while (depth > 0) {
            if (steps >= self.tape.len or self.position_index + 1 >= self.tape.len) {
                return error.UnexpectedEnd;
            }
            const next_kind = try checkedYamlTapeKind(self.tape[self.position_index + 1]);
            try self.advance();
            steps += 1;
            switch (next_kind) {
                .mapping_start, .sequence_start => depth += 1,
                .mapping_end, .sequence_end => depth -= 1,
                else => {},
            }
        }
    }
};

/// One resident YAML token, borrowed from the document's source.
///
/// The value allocates nothing and owns no bytes: `raw` is a sub-slice of the
/// `input` the document was opened with, and is empty for a container token
/// whose extent is positional.
pub const Event = struct {
    /// Token kind at `offset`.
    kind: YamlTokenKind,
    /// Source offset of the token.
    offset: u32,
    /// Token bytes; empty for a container token. Borrows the document's input.
    raw: []const u8,
};

/// Errors the resident `Parser` family returns.
///
/// This is the shared resident vocabulary and is wider than any one call. The
/// parser holds fixed frame arrays and allocates nothing, so the allocator tags
/// in the set are carried for shape rather than reached; what a walk actually
/// produces is the `YamlError` tags, `resident.Error`'s four tags,
/// `error.InputTooLarge` and `error.CapacityExceeded`.
pub const ResidentError = std.mem.Allocator.Error || YamlError || resident.Error || error{
    CapacityExceeded,
    InputTooLarge,
    CapacityOverflow,
    TapeTooLarge,
};

/// A reusable resident YAML parser: it walks one borrowed document at a time
/// and allocates nothing.
///
/// The parser holds a fixed `yaml_max_depth` block and flow frame array and
/// one document lease; it owns no heap allocation, which is why `init` ignores
/// its `allocator` argument and `deinit` frees nothing. It holds at most one
/// active document — `initOnDemandDocument` returns `error.DocumentActive`
/// while another is open — so it is not threadsafe and its own methods must not
/// be reentered from one another. Copying a parser copies the frame arrays, so
/// a copy is a second parser with its own state and both may be `deinit`'d.
pub const Parser = struct {
    /// Largest `input` accepted, in bytes. `0` means no ceiling beyond the
    /// `std.math.maxInt(u32)` offset limit the events require.
    max_capacity: usize,
    /// The grammar state a walk advances. Its frame arrays are reused by the
    /// next document.
    ///
    /// `EventReader.engine` and `TokenCursor.engine` are pointers to this
    /// field rather than to a copy, so it must stay at the same address for as
    /// long as any walk is open. Copying the parser copies the engine and
    /// gives a second independent walk; the open walks keep using the original.
    engine: YamlResidentEngine,
    /// The single-document lease. Its generation advances on every document, so
    /// a reader held across two documents fails instead of reading the newer
    /// one's tokens.
    state: resident.State = .{},

    /// Builds a parser with no heap storage.
    ///
    /// `allocator` is accepted so a caller can use one parser-construction
    /// shape across formats, and it is discarded: this parser allocates
    /// nothing, stores nothing from it, and must not be paired with a `free`.
    /// `max_capacity` above `std.math.maxInt(u32)` returns
    /// `error.InputTooLarge`.
    pub fn init(_: std.mem.Allocator, max_capacity: usize) ResidentError!Parser {
        if (max_capacity > std.math.maxInt(u32)) return error.InputTooLarge;
        return .{
            .max_capacity = max_capacity,
            .engine = YamlResidentEngine.init(),
        };
    }

    /// Releases nothing and asserts that no document is open.
    ///
    /// The assertion is what diagnoses a missing `OnDemandDocument.deinit`:
    /// Debug and ReleaseSafe trap, ReleaseFast and ReleaseSmall do not. Every
    /// document, `EventReader` and `TokenCursor` made from this parser is
    /// unusable afterward, and a second call is invalid.
    pub fn deinit(self: *Parser) void {
        self.engine.deinit();
        self.state.deinit();
        self.* = undefined;
    }
};

/// A borrowed resident YAML document: one unparsed source plus the lease that
/// keeps the parser's engine current for it.
///
/// The document owns nothing and reaches the parser's engine through its
/// lease. `input` must stay alive and unmodified, and `parser` must outlive
/// the document and must not be `deinit`'d while it is open. Only one walk
/// exists at a time — `eventReader` and `tokenCursor` return
/// `error.FocusAlreadyClaimed` to a second caller — and any walk made from
/// this document returns `error.DocumentReleased` once `deinit` runs or
/// another document is opened.
pub const OnDemandDocument = struct {
    /// The parser whose engine this document drives.
    ///
    /// `eventReader` and `tokenCursor` take `&parser.engine`, so this pointer
    /// and the parser's address must both hold for the document's whole life:
    /// moving or copying the parser leaves these walks on the original, and
    /// `deinit` on the parser while this document is open invalidates them.
    parser: *Parser,
    /// The borrowed source. Every `Event.raw` points into it.
    input: []const u8,
    /// The document lease, released by `deinit`.
    lease: resident.Lease,

    /// Releases the lease, which frees no memory. The document is unusable
    /// afterward, and every walk made from it starts returning
    /// `error.DocumentReleased`.
    pub fn deinit(self: *OnDemandDocument) void {
        self.lease.release();
        self.* = undefined;
    }

    /// A reader over the document's tokens. Claims the document's single
    /// focus, so `error.FocusAlreadyClaimed` when another walk is open; on
    /// that error the existing walk is unaffected. The reader borrows the
    /// parser's engine and `input`, so both must stay live and unmodified while
    /// it is used.
    pub fn eventReader(self: *OnDemandDocument) ResidentError!EventReader {
        return .{
            .engine = &self.parser.engine,
            .input = self.input,
            .guard = try self.lease.claim(),
        };
    }

    /// A cursor over the document's tokens, with the same focus claim and
    /// borrows as `eventReader`.
    pub fn tokenCursor(self: *OnDemandDocument) ResidentError!TokenCursor {
        return .{
            .engine = &self.parser.engine,
            .input = self.input,
            .guard = try self.lease.claim(),
        };
    }
};

/// Opens `input` for a lazy walk on `parser` and returns a document that
/// borrows it.
///
/// Nothing is parsed here: the engine is reset and the first grammar rule runs
/// on the first `EventReader.next`, so a malformed or out-of-profile document
/// is reported by the walk, not by this call. `error.InputTooLarge` past
/// `std.math.maxInt(u32)`, `error.CapacityExceeded` past a nonzero
/// `parser.max_capacity`, and `error.DocumentActive` while another document is
/// open are all decided before the document exists. `input` is not copied: it
/// must stay alive and unmodified while the document and every walk made from
/// it are used.
pub fn initOnDemandDocument(
    parser: *Parser,
    input: []const u8,
) ResidentError!OnDemandDocument {
    if (input.len > std.math.maxInt(u32)) return error.InputTooLarge;
    if (parser.max_capacity != 0 and input.len > parser.max_capacity) {
        return error.CapacityExceeded;
    }
    const lease = try parser.state.begin();
    parser.engine.reset(input);
    return .{
        .parser = parser,
        .input = input,
        .lease = lease,
    };
}
/// A sequential reader over one `OnDemandDocument`'s tokens.
///
/// The reader owns nothing: it borrows the parser's engine and the document's
/// `input`, so both must stay live and unmodified while it is used, and every
/// `Event` it returns borrows that `input`. It holds the document's single
/// focus and position, which a copied reader shares: a copy that lags returns
/// `error.OutOfOrderIteration`, and both return `error.DocumentReleased` once
/// the document closes. The grammar runs as the walk advances, so the first
/// `error.Invalid`, `error.Unsupported` or `error.DepthExceeded` comes from
/// the position that reached it, not from the start of the document.
pub const EventReader = struct {
    /// The parser's grammar state, driven forward by this walk.
    ///
    /// This is a pointer to `Parser.engine`, so it names that field rather than
    /// a copy and must keep naming it: replacing it, or moving the parser, takes
    /// this walk off the grammar state the document's lease covers. The engine's
    /// `consumed` count and this reader's `guard` position must advance together
    /// through `next` and `skip`; `next` passes the guard position to the
    /// engine, which reports `error.Invalid` at any other value, so advancing
    /// `consumed` by hand is reported rather than obeyed.
    engine: *YamlResidentEngine,
    /// The document's borrowed source; every `Event.raw` points into it.
    input: []const u8,
    /// The document focus and position. Copies of a reader share it.
    guard: resident.Guard,

    /// The next `Event` and the position past it, or `null` at the end of the
    /// document. The position does not move on an error or at the end.
    ///
    /// `error.DocumentReleased`, `error.OutOfOrderIteration`, the `YamlError`
    /// tags and `error.InputTooLarge` are what a walk can return; the parser
    /// allocates nothing, so no allocator tag reaches here.
    pub fn next(self: *EventReader) ResidentError!?Event {
        try self.guard.check();
        const event = try self.engine.next(self.guard.expected_position);
        if (event) |value| {
            try self.guard.advance();
            return value;
        }
        return null;
    }

    /// The next `Event` without consuming it, or `null` at the end, with the
    /// same errors as `next`.
    pub fn peek(self: *const EventReader) ResidentError!?Event {
        try self.guard.check();
        return self.engine.peek(self.guard.expected_position);
    }

    /// Consumes one whole collection and leaves the reader after it.
    ///
    /// A `mapping_start` or `sequence_start` walks to its matching end token;
    /// any other first token is consumed on its own. An exhausted document is
    /// not an error and consumes nothing. `error.Invalid` when a collection
    /// ends without its closing token, which a well-formed document cannot do,
    /// so it marks a document whose events were produced out of order. The
    /// reader is left where the walk stopped.
    pub fn skip(self: *EventReader) ResidentError!void {
        const first = try self.next() orelse return;
        var depth: usize = switch (first.kind) {
            .mapping_start, .sequence_start => 1,
            else => 0,
        };
        while (depth > 0) {
            const event = try self.next() orelse return error.Invalid;
            switch (event.kind) {
                .mapping_start, .sequence_start => depth += 1,
                .mapping_end, .sequence_end => depth -= 1,
                else => {},
            }
        }
    }
};

/// A sequential cursor over one `OnDemandDocument`'s tokens.
///
/// It borrows exactly what `EventReader` borrows and reports the same
/// staleness and grammar errors. `advance` is `next`; both names exist so a
/// caller can use the cursor or the reader spelling without translating.
pub const TokenCursor = struct {
    /// The parser's grammar state, driven forward by this walk. The borrow and
    /// the `consumed`/`guard` position invariant `EventReader.engine` carries
    /// apply here unchanged, because this cursor drives the same engine through
    /// the same checks.
    engine: *YamlResidentEngine,
    /// The document's borrowed source; every `Event.raw` points into it.
    input: []const u8,
    /// The document focus and position. Copies of a cursor share it.
    guard: resident.Guard,

    /// The next `Event` and the position past it, or `null` at the end, with
    /// the same errors as `EventReader.next`.
    pub fn next(self: *TokenCursor) ResidentError!?Event {
        try self.guard.check();
        const event = try self.engine.next(self.guard.expected_position);
        if (event) |value| {
            try self.guard.advance();
            return value;
        }
        return null;
    }

    /// `next`.
    pub fn advance(self: *TokenCursor) ResidentError!?Event {
        return self.next();
    }

    /// `EventReader.peek`.
    pub fn peek(self: *const TokenCursor) ResidentError!?Event {
        try self.guard.check();
        return self.engine.peek(self.guard.expected_position);
    }

    /// `EventReader.skip`, run over this cursor's position.
    ///
    /// The walk runs on a temporary reader and its position is copied back
    /// only when `skip` succeeds, so on any error this cursor keeps the
    /// position it had on entry and the events consumed by the attempt are not
    /// reachable through it. Open a new document on the parser rather than
    /// retrying this call after a failure.
    pub fn skipChild(self: *TokenCursor) ResidentError!void {
        var reader: EventReader = .{
            .engine = self.engine,
            .input = self.input,
            .guard = self.guard,
        };
        try reader.skip();
        self.guard = reader.guard;
    }
};

/// SIMD candidate metadata used by the YAML line and punctuation scanners.
/// The metadata is ephemeral: it borrows no input and is discarded after one
/// index pass. Scalar callers intentionally bypass it.
///
/// Reachable through `YamlResidentEngine.metadata`, which is a borrowed
/// optional pointer rather than a value. Only the newline array is reachable
/// through it: that array is owned by whoever built this value and freed by
/// its `deinit`, so a consumer that reads it borrows it and must neither free
/// it nor outlive it.
const YamlLexicalMetadata = struct {
    allocator: std.mem.Allocator,
    newline_offsets: []u32,

    fn init(comptime vlen: usize, allocator: std.mem.Allocator, input: []const u8) !YamlLexicalMetadata {
        var newlines = std.ArrayList(u32).empty;
        errdefer newlines.deinit(allocator);

        var windows = simd.windows(u8, vlen, ' ', input);
        var base_offset: usize = 0;
        while (windows.next()) |vector| {
            const valid_count = @min(vlen, input.len - base_offset);
            const valid = simd.validMask(vlen, valid_count);
            const newline_mask = simd.matchByte(vlen, vector, '\n') & valid;

            var indexes: [vlen]u32 = undefined;
            const newline_count = simd.extractBitIndexesChecked(
                @TypeOf(newline_mask),
                newline_mask,
                base_offset,
                &indexes,
            ) catch return error.CapacityOverflow;
            try newlines.appendSlice(allocator, indexes[0..newline_count]);
            base_offset += vlen;
        }

        const newline_offsets = try newlines.toOwnedSlice(allocator);
        return .{
            .allocator = allocator,
            .newline_offsets = newline_offsets,
        };
    }

    fn deinit(self: *YamlLexicalMetadata) void {
        self.allocator.free(self.newline_offsets);
        self.* = undefined;
    }

    fn nextNewline(self: *const YamlLexicalMetadata, cursor: *usize, from: usize) ?usize {
        while (cursor.* < self.newline_offsets.len and
            @as(usize, self.newline_offsets[cursor.*]) < from)
        {
            cursor.* += 1;
        }
        if (cursor.* >= self.newline_offsets.len) return null;
        return @intCast(self.newline_offsets[cursor.*]);
    }
};

/// One latched verdict with the position it was found at.
///
/// Reachable through `YamlResidentEngine.diagnostic`, which is `null` while
/// the walk is clean. `offset` is clamped to the end of the input, and
/// `kind` is `.syntax` or `.unsupported` derived from `err`, so a consumer
/// reading the field learns where the walk stopped and how to read it. The
/// value owns nothing and a copy is a second name for the same verdict.
const Failure = struct {
    err: YamlError,
    kind: YamlDiagnosticKind,
    offset: usize,
};

const Line = struct {
    start: usize,
    content_start: usize,
    content_end: usize,
    next: usize,
    indent: usize,
};

const ParseContext = enum {
    block_value,
    block_key,
    flow_key,
    flow_value,
};

/// The token kind a plain or quoted scalar in `context` emits. A key slot is
/// a key wherever it sits, block or flow, and every other slot is a scalar.
fn slotKind(context: ParseContext) YamlTokenKind {
    return if (context == .block_key or context == .flow_key) .key else .scalar;
}

const YamlParser = struct {
    allocator: std.mem.Allocator,
    input: []const u8,
    lines: []const Line,
    index: *YamlStructuralIndex,
    failure: *?Failure,
    line_cursor: usize = 0,
    /// Open block and flow frames together. `enterFrame` is the only writer, so
    /// the two stacks cannot each spend a whole budget of their own.
    depth: usize = 0,

    const Self = YamlParser;

    fn fail(self: *Self, err: YamlError, kind: YamlDiagnosticKind, offset: usize) YamlError {
        if (self.failure.* == null) {
            self.failure.* = .{
                .err = err,
                .kind = kind,
                .offset = @min(offset, self.input.len),
            };
        }
        return err;
    }

    fn emit(
        self: *Self,
        kind: YamlTokenKind,
        offset: usize,
        length: usize,
    ) YamlIndexError!void {
        if (offset > self.input.len) {
            return self.fail(error.Invalid, .invalid_index, self.input.len);
        }
        if (length > std.math.maxInt(u32)) {
            return self.fail(error.Invalid, .invalid_index, offset);
        }
        if (length > max_u24) {
            return error.TapeTooLarge;
        }
        if (self.index.count >= self.index.indexes.len - stage1_sentinel_count) {
            return error.CapacityOverflow;
        }
        self.index.indexes[self.index.count] = @intCast(offset);
        self.index.kinds[self.index.count] = kind;
        self.index.lengths[self.index.count] = @intCast(length);
        self.index.count += 1;
    }

    fn nextMeaningful(self: *const Self, from: usize) ?usize {
        var cursor = from;
        while (cursor < self.lines.len) : (cursor += 1) {
            const line = self.lines[cursor];
            if (line.content_start >= line.content_end) continue;
            if (self.input[line.content_start] == '#') continue;
            return cursor;
        }
        return null;
    }

    fn parseDocument(self: *Self) YamlIndexError!void {
        const first = self.nextMeaningful(0) orelse {
            return self.fail(error.Invalid, .syntax, self.input.len);
        };

        var has_end_marker = false;
        var root_indent: usize = self.lines[first].indent;
        var first_content = first;

        if (self.isDocumentMarker(first, "---")) {
            try self.emit(.document_start, self.lines[first].content_start, 3);
            first_content = self.nextMeaningful(first + 1) orelse {
                return self.fail(error.Invalid, .syntax, self.lines[first].next);
            };
            if (self.isDocumentMarker(first_content, "---")) {
                return self.fail(error.Unsupported, .unsupported, self.lines[first_content].content_start);
            }
            if (self.isDocumentMarker(first_content, "...")) {
                return self.fail(error.Invalid, .syntax, self.lines[first_content].content_start);
            }
            if (self.isDirective(first_content)) {
                return self.fail(error.Unsupported, .unsupported, self.lines[first_content].content_start);
            }
            root_indent = self.lines[first_content].indent;
        } else if (self.isDocumentMarker(first, "...")) {
            return self.fail(error.Invalid, .syntax, self.lines[first].content_start);
        }

        if (self.isDirective(first_content)) {
            return self.fail(error.Unsupported, .unsupported, self.lines[first_content].content_start);
        }

        self.line_cursor = first_content;
        try self.parseBlock(root_indent);

        while (self.nextMeaningful(self.line_cursor)) |next_index| {
            const line = self.lines[next_index];
            if (self.isDocumentMarker(next_index, "...")) {
                if (has_end_marker) {
                    return self.fail(error.Unsupported, .unsupported, line.content_start);
                }
                has_end_marker = true;
                try self.emit(.document_end, line.content_start, 3);
                self.line_cursor = next_index + 1;
                break;
            }
            if (self.isDocumentMarker(next_index, "---")) {
                return self.fail(error.Unsupported, .unsupported, line.content_start);
            }
            if (self.isDirective(next_index)) {
                return self.fail(error.Unsupported, .unsupported, line.content_start);
            }
            if (line.indent > root_indent) {
                return self.fail(error.Unsupported, .unsupported, line.content_start);
            }
            return self.fail(error.Invalid, .syntax, line.content_start);
        }

        if (has_end_marker) {
            if (self.nextMeaningful(self.line_cursor)) |remaining| {
                return self.fail(error.Unsupported, .unsupported, self.lines[remaining].content_start);
            }
        }
    }

    fn isDirective(self: *const Self, line_index: usize) bool {
        const line = self.lines[line_index];
        return line.indent == 0 and line.content_start < line.content_end and
            self.input[line.content_start] == '%';
    }

    fn isDocumentMarker(self: *const Self, line_index: usize, marker: []const u8) bool {
        const line = self.lines[line_index];
        if (line.indent != 0) return false;
        const start = line.content_start;
        const end = trimCommentEnd(self.input, start, line.content_end);
        if (end - start < marker.len or
            !std.mem.eql(u8, self.input[start..][0..marker.len], marker))
        {
            return false;
        }
        if (end == start + marker.len) return true;
        const tail = self.input[start + marker.len .. end];
        for (tail) |byte| {
            if (byte != ' ') return false;
        }
        return true;
    }

    /// Charges one open frame, block or flow, against the single depth budget.
    ///
    /// Block collections and flow collections share this counter, because a
    /// document that nests both spends one budget and `yaml_max_depth` names
    /// the total nesting any route allows. `YamlResidentEngine.pushBlock` and
    /// `pushFlow` already test `block_len + flow_len` the same way.
    fn enterFrame(self: *Self, offset: usize) YamlIndexError!void {
        if (self.depth >= yaml_max_depth) {
            return self.fail(error.DepthExceeded, .syntax, offset);
        }
        self.depth += 1;
    }

    /// Parses the block collection or the inline value at `indent`.
    ///
    /// The budget is charged by `parseBlockMapping` and `parseBlockSequence`
    /// rather than here, because only those open a block frame. An inline
    /// value at the document root opens none, which is what
    /// `YamlResidentEngine.pushBlock` counts as well.
    fn parseBlock(self: *Self, indent: usize) YamlIndexError!void {
        const current = self.nextMeaningful(self.line_cursor) orelse {
            return self.fail(error.Invalid, .syntax, self.input.len);
        };
        const line = self.lines[current];
        if (line.indent < indent) {
            return self.fail(error.Invalid, .syntax, line.content_start);
        }
        if (line.indent > indent) {
            return self.fail(error.Unsupported, .unsupported, line.content_start);
        }
        self.line_cursor = current;

        if (isSequenceEntry(self.input, line.content_start, line.content_end)) {
            return self.parseBlockSequence(indent);
        }
        if (findBlockColon(self.input, line.content_start, line.content_end) != null) {
            return self.parseBlockMapping(indent);
        }
        if (startsUnsupportedConstruct(self.input, line.content_start, line.content_end)) {
            return self.fail(error.Unsupported, .unsupported, line.content_start);
        }
        try self.parseInlineValue(
            line.content_start,
            trimCommentEnd(self.input, line.content_start, line.content_end),
            .block_value,
        );
        self.line_cursor = current + 1;
    }

    fn parseBlockMapping(self: *Self, indent: usize) YamlIndexError!void {
        try self.enterFrame(self.input.len);
        defer self.depth -= 1;
        const first = self.nextMeaningful(self.line_cursor) orelse {
            return self.fail(error.Invalid, .syntax, self.input.len);
        };
        const start_offset = self.lines[first].content_start;
        try self.emit(.mapping_start, start_offset, 0);
        var end_offset = start_offset;

        while (self.nextMeaningful(self.line_cursor)) |current| {
            const line = self.lines[current];
            if (self.isDocumentMarker(current, "---") or self.isDocumentMarker(current, "...")) {
                break;
            }
            if (line.indent < indent) break;
            if (line.indent > indent) {
                return self.fail(error.Unsupported, .unsupported, line.content_start);
            }
            if (isSequenceEntry(self.input, line.content_start, line.content_end)) {
                return self.fail(error.Invalid, .syntax, line.content_start);
            }
            const visible_end = trimCommentEnd(self.input, line.content_start, line.content_end);
            const colon = findBlockColon(self.input, line.content_start, visible_end) orelse {
                return self.fail(error.Invalid, .syntax, line.content_start);
            };
            if (colon == line.content_start) {
                return self.fail(error.Invalid, .syntax, colon);
            }

            const key_end = trimSpaces(self.input, line.content_start, colon);
            try self.parseInlineValue(line.content_start, key_end, .block_key);
            // The key is the token `parseInlineValue` just emitted, so the
            // index holds at least that one entry. `DepthStack.peek` in
            // `src/core/stage2.zig` proves its own depth the same way.
            std.debug.assert(self.index.count > 0);
            self.index.kinds[self.index.count - 1] = .key;

            var value_start = colon + 1;
            while (value_start < visible_end and self.input[value_start] == ' ') : (value_start += 1) {}
            if (value_start < visible_end) {
                if (startsUnsupportedConstruct(self.input, value_start, visible_end)) {
                    return self.fail(error.Unsupported, .unsupported, value_start);
                }
                if (isSequenceEntry(self.input, value_start, visible_end)) {
                    return self.fail(error.Unsupported, .unsupported, value_start);
                }
                try self.parseInlineValue(value_start, visible_end, .block_value);
                self.line_cursor = current + 1;
                if (self.nextMeaningful(self.line_cursor)) |next_index| {
                    if (self.lines[next_index].indent > indent) {
                        return self.fail(error.Unsupported, .unsupported, self.lines[next_index].content_start);
                    }
                }
            } else {
                self.line_cursor = current + 1;
                if (self.nextMeaningful(self.line_cursor)) |next_index| {
                    const next_line = self.lines[next_index];
                    if (next_line.indent > indent) {
                        self.line_cursor = next_index;
                        try self.parseBlock(next_line.indent);
                    } else {
                        try self.emit(.scalar, colon + 1, 0);
                    }
                } else {
                    try self.emit(.scalar, colon + 1, 0);
                }
            }
            end_offset = line.content_end;
        }

        try self.emit(.mapping_end, end_offset, 0);
    }

    fn parseBlockSequence(self: *Self, indent: usize) YamlIndexError!void {
        try self.enterFrame(self.input.len);
        defer self.depth -= 1;
        const first = self.nextMeaningful(self.line_cursor) orelse {
            return self.fail(error.Invalid, .syntax, self.input.len);
        };
        const start_offset = self.lines[first].content_start;
        try self.emit(.sequence_start, start_offset, 0);
        var end_offset = start_offset;

        while (self.nextMeaningful(self.line_cursor)) |current| {
            const line = self.lines[current];
            if (self.isDocumentMarker(current, "---") or self.isDocumentMarker(current, "...")) {
                break;
            }
            if (line.indent < indent) break;
            if (line.indent > indent) {
                return self.fail(error.Unsupported, .unsupported, line.content_start);
            }
            if (!isSequenceEntry(self.input, line.content_start, line.content_end)) break;

            var value_start = line.content_start + 1;
            while (value_start < line.content_end and self.input[value_start] == ' ') : (value_start += 1) {}
            const visible_end = trimCommentEnd(self.input, value_start, line.content_end);
            if (value_start < visible_end) {
                if (findBlockColon(self.input, value_start, visible_end) != null) {
                    return self.fail(error.Unsupported, .unsupported, value_start);
                }
                if (startsUnsupportedConstruct(self.input, value_start, visible_end)) {
                    return self.fail(error.Unsupported, .unsupported, value_start);
                }
                try self.parseInlineValue(value_start, visible_end, .block_value);
                self.line_cursor = current + 1;
                if (self.nextMeaningful(self.line_cursor)) |next_index| {
                    if (self.lines[next_index].indent > indent) {
                        return self.fail(error.Unsupported, .unsupported, self.lines[next_index].content_start);
                    }
                }
            } else {
                self.line_cursor = current + 1;
                if (self.nextMeaningful(self.line_cursor)) |next_index| {
                    const next_line = self.lines[next_index];
                    if (next_line.indent > indent) {
                        self.line_cursor = next_index;
                        try self.parseBlock(next_line.indent);
                    } else {
                        try self.emit(.scalar, line.content_end, 0);
                    }
                } else {
                    try self.emit(.scalar, line.content_end, 0);
                }
            }
            end_offset = line.content_end;
        }

        try self.emit(.sequence_end, end_offset, 0);
    }

    fn parseInlineValue(
        self: *Self,
        start: usize,
        end: usize,
        context: ParseContext,
    ) YamlIndexError!void {
        if (start > end or end > self.input.len) {
            return self.fail(error.Invalid, .syntax, start);
        }
        if (start == end) {
            try self.emit(.scalar, start, 0);
            return;
        }
        var inline_parser: InlineParser = .{
            .owner = self,
            .start = start,
            .pos = start,
            .end = end,
            .context = context,
        };
        try inline_parser.parseValue(slotKind(context));
        inline_parser.skipSpaces();
        if (inline_parser.pos != end) {
            return self.fail(error.Invalid, .syntax, inline_parser.pos);
        }
    }
};

const InlineParser = struct {
    owner: *YamlParser,
    start: usize,
    pos: usize,
    end: usize,
    context: ParseContext,
    const Self = InlineParser;

    fn fail(self: *Self, err: YamlError, kind: YamlDiagnosticKind, offset: usize) YamlError {
        return self.owner.fail(err, kind, offset);
    }

    fn skipSpaces(self: *Self) void {
        while (self.pos < self.end and self.owner.input[self.pos] == ' ') : (self.pos += 1) {}
    }
    fn failUnclosed(self: *Self, offset: usize) YamlError {
        if (self.end < self.owner.input.len and
            (self.owner.input[self.end] == '\n' or self.owner.input[self.end] == '\r'))
        {
            return self.fail(error.Unsupported, .unsupported, offset);
        }
        return self.fail(error.Invalid, .syntax, offset);
    }

    /// Whether the plain scalar at `start` opens a construct outside the
    /// profile, so the slot it sits in has to refuse it.
    ///
    /// Every slot that can hold a plain scalar answers to
    /// `startsUnsupportedConstruct`. A flow key waits for the `:` that gives
    /// it a value, because a key the flow never completes is a source error
    /// and a source error outranks a profile error.
    fn unsupportedInSlot(self: *Self, start: usize) bool {
        if (!startsUnsupportedConstruct(self.owner.input, start, self.end)) return false;
        if (self.context != .flow_key) return true;
        var scan = start;
        while (scan < self.end) : (scan += 1) {
            const byte = self.owner.input[scan];
            if (byte == ':') return true;
            if (byte == ',' or byte == ']' or byte == '}') return false;
        }
        return false;
    }

    /// Parses the value at `pos` and emits it as `kind`. `context` selects the
    /// plain scalar rules and the token the slot emits.
    fn parseValue(self: *Self, kind: YamlTokenKind) YamlIndexError!void {
        self.skipSpaces();
        if (self.pos >= self.end) {
            return self.fail(error.Invalid, .syntax, self.pos);
        }
        switch (self.owner.input[self.pos]) {
            '[' => {
                if (self.context == .block_key or self.context == .flow_key) {
                    return self.fail(error.Unsupported, .unsupported, self.pos);
                }
                try self.parseFlowSequence();
            },
            '{' => {
                if (self.context == .block_key or self.context == .flow_key) {
                    return self.fail(error.Unsupported, .unsupported, self.pos);
                }
                try self.parseFlowMapping();
            },
            '\'', '"' => try self.parseQuoted(kind),
            else => {
                if (self.unsupportedInSlot(self.pos)) {
                    return self.fail(error.Unsupported, .unsupported, self.pos);
                }
                try self.parsePlain(kind);
            },
        }
    }

    /// Flow frames are charged to `YamlParser.enterFrame`, so a flow collection
    /// nested inside a block collection spends the same budget and neither
    /// stack can reach `yaml_max_depth` on its own.
    fn parseFlowSequence(self: *Self) YamlIndexError!void {
        try self.owner.enterFrame(self.pos);
        defer self.owner.depth -= 1;
        const open = self.pos;
        self.pos += 1;
        try self.owner.emit(.sequence_start, open, 0);
        self.skipSpaces();
        if (self.pos < self.end and self.owner.input[self.pos] == ']') {
            const close = self.pos;
            self.pos += 1;
            try self.owner.emit(.sequence_end, close, 0);
            return;
        }

        while (true) {
            if (self.pos >= self.end) {
                return self.failUnclosed(open);
            }
            const previous_context = self.context;
            self.context = .flow_value;
            try self.parseValue(.scalar);
            self.context = previous_context;
            self.skipSpaces();
            if (self.pos >= self.end) {
                return self.failUnclosed(open);
            }
            switch (self.owner.input[self.pos]) {
                ',' => {
                    self.pos += 1;
                    self.skipSpaces();
                    if (self.pos >= self.end or self.owner.input[self.pos] == ']') {
                        return self.fail(error.Invalid, .syntax, self.pos);
                    }
                },
                ']' => {
                    const close = self.pos;
                    self.pos += 1;
                    try self.owner.emit(.sequence_end, close, 0);
                    return;
                },
                else => return self.fail(error.Invalid, .syntax, self.pos),
            }
        }
    }

    fn parseFlowMapping(self: *Self) YamlIndexError!void {
        try self.owner.enterFrame(self.pos);
        defer self.owner.depth -= 1;
        const open = self.pos;
        self.pos += 1;
        try self.owner.emit(.mapping_start, open, 0);
        self.skipSpaces();
        if (self.pos < self.end and self.owner.input[self.pos] == '}') {
            const close = self.pos;
            self.pos += 1;
            try self.owner.emit(.mapping_end, close, 0);
            return;
        }

        while (true) {
            if (self.pos >= self.end) {
                return self.failUnclosed(open);
            }
            self.context = .flow_key;
            try self.parseValue(slotKind(self.context));
            self.skipSpaces();
            if (self.pos >= self.end or self.owner.input[self.pos] != ':') {
                return self.fail(error.Invalid, .syntax, self.pos);
            }
            self.pos += 1;
            self.skipSpaces();
            if (self.pos >= self.end or self.owner.input[self.pos] == ',' or self.owner.input[self.pos] == '}') {
                try self.owner.emit(.scalar, self.pos, 0);
            } else {
                self.context = .flow_value;
                try self.parseValue(.scalar);
            }
            self.skipSpaces();
            if (self.pos >= self.end) {
                return self.failUnclosed(open);
            }
            switch (self.owner.input[self.pos]) {
                ',' => {
                    self.pos += 1;
                    self.skipSpaces();
                    if (self.pos >= self.end or self.owner.input[self.pos] == '}') {
                        return self.fail(error.Invalid, .syntax, self.pos);
                    }
                },
                '}' => {
                    const close = self.pos;
                    self.pos += 1;
                    try self.owner.emit(.mapping_end, close, 0);
                    return;
                },
                else => return self.fail(error.Invalid, .syntax, self.pos),
            }
        }
    }

    fn parseQuoted(self: *Self, kind: YamlTokenKind) YamlIndexError!void {
        const quote = self.owner.input[self.pos];
        const start = self.pos;
        self.pos += 1;
        if (quote == '\'') {
            while (self.pos < self.end) {
                const byte = self.owner.input[self.pos];
                if (byte == '\'') {
                    if (self.pos + 1 < self.end and self.owner.input[self.pos + 1] == '\'') {
                        self.pos += 2;
                        continue;
                    }
                    self.pos += 1;
                    try self.owner.emit(kind, start, self.pos - start);
                    return;
                }
                self.pos += 1;
            }
            return self.failUnclosed(start);
        }

        while (self.pos < self.end) {
            const byte = self.owner.input[self.pos];
            if (byte == '"') {
                self.pos += 1;
                try self.owner.emit(kind, start, self.pos - start);
                return;
            }
            if (byte == '\\') {
                const escape_offset = self.pos;
                self.pos += 1;
                if (self.pos >= self.end) return self.failUnclosed(escape_offset);
                const escape = self.owner.input[self.pos];
                switch (escape) {
                    '"', '\\', '/', 'b', 'f', 'n', 'r', 't' => self.pos += 1,
                    'u' => {
                        self.pos += 1;
                        if (self.pos < self.end and self.owner.input[self.pos] == '{') {
                            return self.fail(error.Unsupported, .unsupported, escape_offset);
                        }
                        if (self.end - self.pos < 4) {
                            return self.fail(error.Invalid, .syntax, escape_offset);
                        }
                        var hex_count: usize = 0;
                        while (hex_count < 4) : (hex_count += 1) {
                            if (!isHex(self.owner.input[self.pos + hex_count])) {
                                return self.fail(error.Invalid, .syntax, self.pos + hex_count);
                            }
                        }
                        self.pos += 4;
                    },
                    else => return self.fail(error.Unsupported, .unsupported, escape_offset),
                }
            } else {
                self.pos += 1;
            }
        }
        return self.failUnclosed(start);
    }

    fn parsePlain(self: *Self, kind: YamlTokenKind) YamlIndexError!void {
        const start = self.pos;
        while (self.pos < self.end) {
            const byte = self.owner.input[self.pos];
            if (self.context == .flow_key and byte == ':') break;
            if ((self.context == .flow_value or self.context == .flow_key) and
                (byte == ',' or byte == ']' or byte == '}')) break;
            if (byte == ':' and self.context != .flow_key and
                (self.pos + 1 == self.end or self.owner.input[self.pos + 1] == ' ' or
                    self.owner.input[self.pos + 1] == '#'))
            {
                return self.fail(error.Unsupported, .unsupported, self.pos);
            }
            if (byte == '#' and self.pos > start and self.owner.input[self.pos - 1] == ' ') break;
            if (byte == '\t') return self.fail(error.Invalid, .syntax, self.pos);
            if (byte == '&' or byte == '*' or byte == '!') {
                // The indicator is unsupported as the scalar's first byte and
                // after a space. `pos` only ever advances from `start`, so
                // these two tests are exactly those two places.
                if (self.pos > start) {
                    if (self.owner.input[self.pos - 1] == ' ') {
                        return self.fail(error.Unsupported, .unsupported, self.pos);
                    }
                } else {
                    return self.fail(error.Unsupported, .unsupported, self.pos);
                }
            }
            self.pos += 1;
        }
        const value_end = trimSpaces(self.owner.input, start, self.pos);
        if (value_end == start) return self.fail(error.Invalid, .syntax, start);
        try self.owner.emit(kind, start, value_end - start);
        self.pos = value_end;
    }
};

const stage1_sentinel_count = 3;

/// Builds the Stage 1 structural index for `input` at the default vector
/// width.
///
/// `input` is read and not retained, so it may be released when this returns.
/// `error.Invalid` and `error.Unsupported` are the profile verdicts and
/// `error.InputTooLarge` an offset past `u32`; each is decided without
/// publishing an index, and on any error the caller owns nothing. The returned
/// index owns three arrays.
pub fn indexYaml(
    allocator: std.mem.Allocator,
    input: []const u8,
) YamlIndexError!YamlStructuralIndex {
    return indexYamlImpl(simd.default_vector_len, allocator, input);
}

/// Builds a yaml-basic-1.2.2 structural index. vlen controls the SIMD
/// metadata scan; scalar parsing remains the independent oracle.
pub fn indexYamlImpl(
    comptime vlen: usize,
    allocator: std.mem.Allocator,
    input: []const u8,
) YamlIndexError!YamlStructuralIndex {
    if (input.len > std.math.maxInt(u32)) return error.InputTooLarge;
    var metadata = try YamlLexicalMetadata.init(vlen, allocator, input);
    defer metadata.deinit();
    return parseYamlIndex(allocator, input, null, &metadata);
}

/// `indexYaml` without the SIMD candidate scan: the same tokens, produced by
/// the scalar parser alone.
///
/// This is the independent oracle the vectorized path is checked against, so
/// it is the entry point a caller uses to settle a disagreement. The
/// ownership, error and residue contract is the one `indexYaml` documents.
pub fn scalarIndexYaml(
    allocator: std.mem.Allocator,
    input: []const u8,
) YamlIndexError!YamlStructuralIndex {
    return scalarParseYamlIndex(allocator, input, null);
}

fn scalarParseYamlIndex(
    allocator: std.mem.Allocator,
    input: []const u8,
    external_failure: ?*?Failure,
) YamlIndexError!YamlStructuralIndex {
    var local_failure: ?Failure = null;
    const failure: *?Failure = external_failure orelse &local_failure;
    try validateYamlInput(input, failure);
    var lines = std.ArrayList(Line).empty;
    defer lines.deinit(allocator);
    try collectLines(allocator, input, &lines, failure);
    const token_capacity = tokenCapacity(input.len) catch return error.CapacityOverflow;
    var indexes = try stage1.StructuralIndex.init(allocator, token_capacity);
    errdefer indexes.deinit(allocator);
    const kinds = try allocator.alloc(YamlTokenKind, token_capacity);
    errdefer allocator.free(kinds);
    const lengths = try allocator.alloc(u32, token_capacity);
    errdefer allocator.free(lengths);
    var result: YamlStructuralIndex = .{
        .indexes = indexes.indexes,
        .kinds = kinds,
        .lengths = lengths,
        .count = 0,
    };
    var parser: YamlParser = .{
        .allocator = allocator,
        .input = input,
        .lines = lines.items,
        .index = &result,
        .failure = failure,
    };
    try parser.parseDocument();
    var final_index: stage1.StructuralIndex = .{
        .indexes = result.indexes,
        .count = result.count,
    };
    try final_index.finish(input.len);
    return result;
}

fn parseYamlIndex(
    allocator: std.mem.Allocator,
    input: []const u8,
    external_failure: ?*?Failure,
    metadata: ?*const YamlLexicalMetadata,
) YamlIndexError!YamlStructuralIndex {
    var source_failure: ?Failure = null;
    validateYamlSource(input, &source_failure) catch |err| {
        if (external_failure) |target| target.* = source_failure;
        return err;
    };
    const token_capacity = tokenCapacity(input.len) catch return error.CapacityOverflow;
    var indexes = try stage1.StructuralIndex.init(allocator, token_capacity);
    errdefer indexes.deinit(allocator);
    const kinds = try allocator.alloc(YamlTokenKind, token_capacity);
    errdefer allocator.free(kinds);
    const lengths = try allocator.alloc(u32, token_capacity);
    errdefer allocator.free(lengths);

    var result: YamlStructuralIndex = .{
        .indexes = indexes.indexes,
        .kinds = kinds,
        .lengths = lengths,
        .count = 0,
    };
    var engine = YamlResidentEngine.init();
    engine.resetWithMetadata(input, metadata);
    while (true) {
        const event = engine.next(result.count) catch |err| {
            if (external_failure) |target| {
                if (engine.diagnostic) |reason| target.* = reason;
            }
            return switch (err) {
                error.Invalid => error.Invalid,
                error.Unsupported => error.Unsupported,
                error.DepthExceeded => error.DepthExceeded,
                error.InputTooLarge => error.InputTooLarge,
                error.CapacityOverflow => error.CapacityOverflow,
                error.TapeTooLarge => error.TapeTooLarge,
            };
        };
        const value = event orelse break;
        if (result.count >= result.indexes.len - stage1_sentinel_count) {
            return error.CapacityOverflow;
        }
        result.indexes[result.count] = value.offset;
        result.kinds[result.count] = value.kind;
        // `validateYamlSource` refused any input longer than `maxInt(u32)` and
        // every span is a slice of that input, so the length is representable.
        result.lengths[result.count] = @intCast(value.raw.len);
        result.count += 1;
    }

    var final_index: stage1.StructuralIndex = .{
        .indexes = result.indexes,
        .count = result.count,
    };
    try final_index.finish(input.len);
    return result;
}

fn tokenCapacity(input_len: usize) !usize {
    const doubled = std.math.mul(usize, input_len, 2) catch return error.CapacityOverflow;
    return std.math.add(usize, doubled, 8) catch return error.CapacityOverflow;
}
fn validateTapeInputCapacity(input_len: usize) !void {
    const token_capacity = tokenCapacity(input_len) catch return error.CapacityOverflow;
    if (token_capacity > std.math.maxInt(usize) - stage1_sentinel_count) {
        return error.CapacityOverflow;
    }
    if (token_capacity > std.math.maxInt(u32)) return error.InputTooLarge;
}

/// The shared character check for one line of a source, against the context
/// the lines above it left behind.
///
/// `state` is the caller's and is carried from line to line, so an open quote,
/// a block scalar header and a token that began on an earlier line all reach
/// this line and a quote on it is read where a scalar can really start. The
/// offsets it reports are relative to `line`; a caller with a document behind
/// it adds the line's own offset.
fn validateYamlSourceLine(
    state: *source.SourceState,
    line: []const u8,
    has_newline: bool,
    failure: *?Failure,
) error{ Invalid, InputTooLarge }!void {
    if (line.len > std.math.maxInt(u32)) return error.InputTooLarge;
    if (source.failureOffsetInLine(state, line, has_newline)) |offset| {
        failure.* = .{ .err = error.Invalid, .kind = .syntax, .offset = offset };
        return error.Invalid;
    }
}

/// The line framing this profile refuses: a break that is not part of a CRLF,
/// and a tab where a line expects its indentation. `start` is the first byte
/// of the line that is content rather than a document byte order mark.
fn validateYamlLineFraming(
    line: []const u8,
    start: usize,
    failure: *?Failure,
) error{Invalid}!void {
    var indentation = true;
    for (line[start..], start..) |byte, offset| {
        if ((byte == '\r' and (offset + 1 == line.len or line[offset + 1] != '\n')) or
            (indentation and byte == '\t'))
        {
            failure.* = .{ .err = error.Invalid, .kind = .syntax, .offset = offset };
            return error.Invalid;
        }
        if (byte == '\n') {
            indentation = true;
        } else if (byte != ' ') {
            indentation = false;
        }
    }
}

fn validateYamlInput(
    input: []const u8,
    failure: *?Failure,
) error{ Invalid, InputTooLarge }!void {
    const invalid_offset = try source.failureOffset(input);
    if (invalid_offset) |offset| {
        failure.* = .{ .err = error.Invalid, .kind = .syntax, .offset = offset };
        return error.Invalid;
    }
}

fn validateYamlInputImpl(
    comptime vlen: usize,
    input: []const u8,
    failure: *?Failure,
) error{ Invalid, InputTooLarge }!void {
    const invalid_offset = try source.failureOffsetImpl(vlen, input);
    if (invalid_offset) |offset| {
        failure.* = .{ .err = error.Invalid, .kind = .syntax, .offset = offset };
        return error.Invalid;
    }
}

fn validateYamlInputScalar(
    input: []const u8,
    failure: *?Failure,
) error{ Invalid, InputTooLarge }!void {
    const invalid_offset = try source.failureOffsetScalarFrom(input, 0);
    if (invalid_offset) |offset| {
        failure.* = .{ .err = error.Invalid, .kind = .syntax, .offset = offset };
        return error.Invalid;
    }
}

/// The shared source check over a complete input: the characters it can read,
/// then the framing of the lines they make. The character walk reads the whole
/// source at once, so a quote that spans lines and a block scalar body are read
/// with the lines around them, and a caller that reads the same source one line
/// at a time reaches the same verdict.
fn validateYamlSource(input: []const u8, failure: *?Failure) error{ Invalid, InputTooLarge }!void {
    try validateYamlInput(input, failure);
    const start: usize = if (std.mem.startsWith(u8, input, bom)) bom.len else 0;
    try validateYamlLineFraming(input, start, failure);
}

fn collectLines(
    allocator: std.mem.Allocator,
    input: []const u8,
    lines: *std.ArrayList(Line),
    failure: *?Failure,
) YamlIndexError!void {
    var offset: usize = if (input.len >= 3 and input[0] == 0xef and input[1] == 0xbb and input[2] == 0xbf) 3 else 0;
    while (offset < input.len) {
        const line_start = offset;
        var content_end: usize = offset;
        while (content_end < input.len and input[content_end] != '\n' and
            input[content_end] != '\r') : (content_end += 1)
        {}
        var next: usize = content_end;
        if (content_end < input.len and input[content_end] == '\r') {
            if (content_end + 1 >= input.len or input[content_end + 1] != '\n') {
                failure.* = .{ .err = error.Invalid, .kind = .syntax, .offset = content_end };
                return error.Invalid;
            }
            next = content_end + 2;
        } else if (content_end < input.len) {
            next = content_end + 1;
        }

        var content_start = line_start;
        while (content_start < content_end and input[content_start] == ' ') : (content_start += 1) {}
        const indent = content_start - line_start;
        if (content_start < content_end and input[content_start] == '\t') {
            failure.* = .{ .err = error.Invalid, .kind = .syntax, .offset = content_start };
            return error.Invalid;
        }
        try lines.append(allocator, .{
            .start = line_start,
            .content_start = content_start,
            .content_end = content_end,
            .next = next,
            .indent = indent,
        });
        offset = next;
    }
    if (input.len == 0 or (input.len > 0 and input[input.len - 1] == '\n')) {
        try lines.append(allocator, .{
            .start = input.len,
            .content_start = input.len,
            .content_end = input.len,
            .next = input.len,
            .indent = 0,
        });
    }
}

fn trimSpaces(input: []const u8, start: usize, end: usize) usize {
    var result = end;
    while (result > start and input[result - 1] == ' ') : (result -= 1) {}
    return result;
}

fn trimCommentEnd(
    input: []const u8,
    start: usize,
    end: usize,
) usize {
    var quote: u8 = 0;
    var flow_depth: usize = 0;
    var index = start;
    while (index < end) : (index += 1) {
        const byte = input[index];
        if (quote == '\'') {
            if (byte == '\'' and index + 1 < end and input[index + 1] == '\'') {
                index += 1;
            } else if (byte == '\'') {
                quote = 0;
            }
            continue;
        }
        if (quote == '"') {
            if (byte == '\\') index += 1 else if (byte == '"') quote = 0;
            continue;
        }
        if (byte == '\'' or byte == '"') {
            quote = byte;
            continue;
        }
        if (byte == '[' or byte == '{') flow_depth += 1;
        if (byte == ']' or byte == '}') flow_depth -|= 1;
        if (byte == '#' and flow_depth == 0) {
            // A comment starts the scalar or follows a space; `index` only
            // advances from `start`, so the two tests below are those cases.
            if (index > start) {
                if (input[index - 1] == ' ') return trimSpaces(input, start, index);
            } else {
                return trimSpaces(input, start, index);
            }
        }
    }
    return trimSpaces(input, start, end);
}

fn findBlockColon(
    input: []const u8,
    start: usize,
    end: usize,
) ?usize {
    var quote: u8 = 0;
    var flow_depth: usize = 0;
    var index = start;
    while (index < end) : (index += 1) {
        const byte = input[index];
        if (quote == '\'') {
            if (byte == '\'' and index + 1 < end and input[index + 1] == '\'')
                index += 1
            else if (byte == '\'')
                quote = 0;
            continue;
        }
        if (quote == '"') {
            if (byte == '\\') index += 1 else if (byte == '"') quote = 0;
            continue;
        }
        if (byte == '\'' or byte == '"') {
            quote = byte;
            continue;
        }
        if (byte == '[' or byte == '{') {
            flow_depth += 1;
            continue;
        }
        if (byte == ']' or byte == '}') {
            flow_depth -|= 1;
            continue;
        }
        if (byte == '#' and flow_depth == 0) {
            if (index > start) {
                if (input[index - 1] == ' ') break;
            } else {
                break;
            }
        }
        if (byte == ':' and flow_depth == 0) {
            if (index + 1 == end or input[index + 1] == ' ' or input[index + 1] == '#' or
                input[index + 1] == '[' or input[index + 1] == '{') return index;
        }
    }
    return null;
}

fn isSequenceEntry(input: []const u8, start: usize, end: usize) bool {
    if (start >= end or input[start] != '-') return false;
    if (start + 1 == end) return true;
    return input[start + 1] == ' ' or input[start + 1] == '#';
}

/// Whether the byte at `start` opens a construct outside `yaml-basic-1.2.2`.
///
/// This is the one first-byte rule for plain scalars. Every slot that can hold
/// one answers to it, a flow key included, through `unsupportedInSlot`.
/// Quoting the byte is how a caller spells it as data, and both parsers answer
/// to a quote before they reach here.
fn startsUnsupportedConstruct(input: []const u8, start: usize, end: usize) bool {
    if (start >= end) return false;
    return switch (input[start]) {
        '%', '!', '&', '*', '?', '|', '>', '@', '`' => true,
        else => false,
    };
}

fn isHex(byte: u8) bool {
    return (byte >= '0' and byte <= '9') or (byte >= 'a' and byte <= 'f') or
        (byte >= 'A' and byte <= 'F');
}

fn yamlDiagnosticAtKind(
    input: []const u8,
    err: YamlError,
    kind: YamlDiagnosticKind,
    byte_offset: usize,
) YamlDiagnostic {
    const offset = @min(byte_offset, input.len);
    var line_start: usize = 0;
    var line_number: usize = 1;
    var scan: usize = 0;
    while (scan < offset) : (scan += 1) {
        if (input[scan] == '\n') {
            line_start = scan + 1;
            line_number += 1;
        }
    }
    var line_end = offset;
    while (line_end < input.len and input[line_end] != '\n' and input[line_end] != '\r') : (line_end += 1) {}
    const snippet_start = @max(line_start, offset -| 16);
    const snippet_end = @min(line_end, std.math.add(usize, offset, 16) catch input.len);
    return .{
        .err = err,
        .kind = kind,
        .byte_offset = offset,
        .line = @intCast(@min(line_number, std.math.maxInt(u32))),
        .column = @intCast(@min(offset - line_start + 1, std.math.maxInt(u32))),
        .snippet = input[snippet_start..snippet_end],
        .snippet_start = snippet_start,
    };
}

/// Creates a source-backed YAML diagnostic with syntax classification.
///
/// Allocates nothing and cannot fail. `byte_offset` is clamped to `input.len`,
/// so an offset past the input reports the end of input rather than reading out
/// of bounds, and the returned `byte_offset` is the clamped value. The result
/// borrows `input` and is invalidated when the caller writes or releases it.
/// The kind is always `.syntax`, which is right for a `YamlError.Invalid` and
/// understates a caller-supplied `Unsupported`; the validating entry points
/// set the kind themselves.
pub fn yamlDiagnosticAt(input: []const u8, err: YamlError, byte_offset: usize) YamlDiagnostic {
    return yamlDiagnosticAtKind(input, err, .syntax, byte_offset);
}

/// Parses `input` as `yaml-basic-1.2.2` and returns the first failure, or
/// `null` when the document is inside the profile.
///
/// Allocates an index from `allocator` and releases it before returning;
/// `input` is not retained. A profile or grammar failure comes back as a
/// `YamlDiagnostic` with `kind` `.syntax` or `.unsupported`, so no `YamlError`
/// tag is returned as an error; only `error.OutOfMemory`,
/// `error.CapacityOverflow`, `error.InputTooLarge` and `error.TapeTooLarge`
/// are. The diagnostic's `snippet` borrows `input` and nothing else.
pub fn validateYaml(
    allocator: std.mem.Allocator,
    input: []const u8,
) YamlValidationError!?YamlDiagnostic {
    var failure: ?Failure = null;
    var index = parseYamlIndex(allocator, input, &failure, null) catch |err| {
        switch (err) {
            error.Invalid, error.Unsupported, error.DepthExceeded => {
                if (failure) |reason| {
                    return yamlDiagnosticAtKind(input, reason.err, reason.kind, reason.offset);
                }
                return yamlDiagnosticAt(input, switch (err) {
                    error.Invalid => error.Invalid,
                    error.Unsupported => error.Unsupported,
                    error.DepthExceeded => error.DepthExceeded,
                    else => unreachable,
                }, 0);
            },
            error.OutOfMemory => return error.OutOfMemory,
            error.CapacityOverflow => return error.CapacityOverflow,
            error.InputTooLarge => return error.InputTooLarge,
            error.TapeTooLarge => return error.TapeTooLarge,
            else => unreachable,
        }
    };
    defer index.deinit(allocator);
    return null;
}

/// Checks a copied or externally supplied `YamlStructuralIndex` against a
/// fresh parse of `input`.
///
/// Allocates a second index from `allocator` and releases it before
/// returning. A supplied index that does not match comes back as a
/// `YamlDiagnostic` with `kind` `.invalid_index` — never as an error tag — and
/// a grammar or profile failure in `input` as `.syntax` or `.unsupported`.
/// Only `error.OutOfMemory`, `error.CapacityOverflow`, `error.InputTooLarge`
/// and `error.TapeTooLarge` are returned as errors.
///
/// Checks run in this order and stop at the first failure: the `u32` input
/// ceiling as `error.InputTooLarge`, then `count` against the three arrays and
/// the three sentinel entries as `.invalid_index`, then every entry's kind,
/// offset and length against `input` as `.invalid_index`, then a fresh parse
/// whose own failure is reported first, and finally a token-by-token
/// comparison whose mismatch is reported at the offending offset.
pub fn validateYamlIndex(
    allocator: std.mem.Allocator,
    input: []const u8,
    structural_index: *const YamlStructuralIndex,
) YamlValidationError!?YamlDiagnostic {
    if (input.len > std.math.maxInt(u32)) return error.InputTooLarge;
    const source_count = std.math.add(usize, structural_index.count, stage1_sentinel_count) catch {
        return yamlDiagnosticAtKind(input, error.Invalid, .invalid_index, input.len);
    };
    if (source_count > structural_index.indexes.len or
        structural_index.count > structural_index.kinds.len or
        structural_index.count > structural_index.lengths.len)
    {
        return yamlDiagnosticAtKind(input, error.Invalid, .invalid_index, input.len);
    }
    // The `InputTooLarge` ceiling above is what makes this representable.
    const sentinel: u32 = @intCast(input.len);
    if (structural_index.indexes[structural_index.count] != sentinel or
        structural_index.indexes[structural_index.count + 1] != sentinel or
        structural_index.indexes[structural_index.count + 2] != 0)
    {
        return yamlDiagnosticAtKind(input, error.Invalid, .invalid_index, input.len);
    }
    for (0..structural_index.count) |token_index| {
        const offset: usize = @intCast(structural_index.indexes[token_index]);
        const length: usize = @intCast(structural_index.lengths[token_index]);
        _ = checkedYamlTokenKind(structural_index.kinds[token_index]) catch {
            return yamlDiagnosticAtKind(input, error.Invalid, .invalid_index, offset);
        };
        if (offset > input.len or length > input.len - offset) {
            return yamlDiagnosticAtKind(input, error.Invalid, .invalid_index, @min(offset, input.len));
        }
    }

    var failure: ?Failure = null;
    var expected = parseYamlIndex(allocator, input, &failure, null) catch |err| {
        switch (err) {
            error.Invalid, error.Unsupported, error.DepthExceeded => {
                if (failure) |reason| {
                    return yamlDiagnosticAtKind(input, reason.err, reason.kind, reason.offset);
                }
                if (err == error.Invalid) return yamlDiagnosticAt(input, error.Invalid, 0);
                if (err == error.Unsupported) return yamlDiagnosticAt(input, error.Unsupported, 0);
                return yamlDiagnosticAt(input, error.DepthExceeded, 0);
            },
            error.OutOfMemory => return error.OutOfMemory,
            error.CapacityOverflow => return error.CapacityOverflow,
            error.TapeTooLarge => return error.TapeTooLarge,
            else => unreachable,
        }
    };
    defer expected.deinit(allocator);

    if (expected.count != structural_index.count) {
        const offset = if (structural_index.count < structural_index.indexes.len)
            @as(usize, @intCast(
                structural_index.indexes[@min(structural_index.count, structural_index.indexes.len - 1)],
            ))
        else
            input.len;
        return yamlDiagnosticAtKind(input, error.Invalid, .invalid_index, offset);
    }
    for (0..expected.count) |token_index| {
        if (expected.indexes[token_index] != structural_index.indexes[token_index] or
            expected.kinds[token_index] != structural_index.kinds[token_index] or
            expected.lengths[token_index] != structural_index.lengths[token_index])
        {
            return yamlDiagnosticAtKind(
                input,
                error.Invalid,
                .invalid_index,
                @intCast(structural_index.indexes[token_index]),
            );
        }
    }
    return null;
}

/// Parses `input` as `yaml-basic-1.2.2` and returns the tape its events
/// produce.
///
/// The resident events are the tape authority here: no structural index is
/// materialized, so the tape is built in one pass. `error.Invalid` and
/// `error.Unsupported` are the profile verdicts and are returned directly
/// rather than through a diagnostic; `error.DepthExceeded` is nesting past
/// `yaml_max_depth`, `error.TapeTooLarge` an unrepresentable offset or span,
/// and `error.InputTooLarge` a document `u32` offsets cannot address. On any
/// failure the caller owns nothing. On success it owns one tape allocation
/// released by `YamlDocument.deinit`, and it borrows `input`, which must stay
/// alive and unmodified.
pub fn buildYamlTape(
    allocator: std.mem.Allocator,
    input: []const u8,
) YamlBuildError!YamlDocument {
    var source_failure: ?Failure = null;
    validateYamlSource(input, &source_failure) catch |err| {
        return switch (err) {
            error.Invalid => error.Invalid,
            error.InputTooLarge => error.InputTooLarge,
        };
    };
    try validateTapeInputCapacity(input.len);

    // Resident events are the tape authority; avoid materializing structural arrays.
    var tape = try std.ArrayList(YamlTapeWord).initCapacity(allocator, @min(input.len, 64));
    errdefer tape.deinit(allocator);

    var engine = YamlResidentEngine.init();
    engine.resetValidated(input);
    while (true) {
        const event = engine.next(tape.items.len) catch |err| {
            return switch (err) {
                error.Invalid => error.Invalid,
                error.Unsupported => error.Unsupported,
                error.DepthExceeded => error.DepthExceeded,
                error.InputTooLarge => error.InputTooLarge,
                error.CapacityOverflow => error.CapacityOverflow,
                error.TapeTooLarge => error.TapeTooLarge,
            };
        };
        const value = event orelse break;
        // `emit` rejects any longer span with `error.TapeTooLarge` before the
        // event is published, so the payload length is representable.
        try tape.append(allocator, .{
            .kind = @intFromEnum(value.kind),
            .payload = @intCast(value.raw.len),
            .offset = value.offset,
        });
    }

    const owned_tape = try tape.toOwnedSlice(allocator);
    return .{ .tape = owned_tape, .source = input };
}

/// One open block collection in the resident engine's inline stack.
///
/// `end_offset` is the absolute source offset the matching end token will be
/// emitted at, not a length, and `indent` is the block's indentation column.
/// The value owns nothing and is written by `pushBlock` before `block_len`
/// exposes it, so no slot above `block_len` has ever been initialized.
const StreamFrame = struct {
    kind: YamlTokenKind,
    indent: usize,
    end_offset: usize,
};

/// An empty value the last line left behind, awaiting a nested child line or
/// its own resolution as a `scalar` token.
///
/// `offset` is the absolute source offset that token will carry and `indent`
/// the column a following line must exceed to nest under it. The value owns
/// nothing, and `YamlResidentEngine.pending_empty` is `null` when no line has
/// left one pending.
const StreamPendingEmpty = struct {
    offset: usize,
    indent: usize,
};

fn streamMarker(line: []const u8, start: usize, end: usize, marker: []const u8) bool {
    if (end - start < marker.len) return false;
    if (!std.mem.eql(u8, line[start .. start + marker.len], marker)) return false;
    for (line[start + marker.len .. end]) |byte| {
        if (byte != ' ') return false;
    }
    return true;
}

/// A bounded-line YAML Stage 1 indexer. Completed lines are parsed and
/// discarded; only the unfinished line, the source context the lines above
/// leave behind, the stack, and the output offsets remain.
///
/// `data` is never retained: every byte is copied into the unfinished line or
/// consumed with its line before `feed` returns, so a caller may reuse or
/// release the chunk on return. The indexer stores the `allocator` it was
/// given; `deinit` releases every array it owns and is the only release. One
/// indexer is one document until `reset`.
///
/// A grammar or profile failure found on a line is latched rather than
/// returned: `feed` keeps consuming, records no further tokens, and `finish`
/// reports the latched verdict. An `error.Invalid` anywhere in the document
/// wins over an `error.Unsupported` found earlier; two `Unsupported` verdicts
/// keep the first. A failure that is not one of the three grammar tags —
/// allocation failure and the sizing tags — is returned from `feed` or
/// `finish` and leaves the indexer mid-document; `reset` is then the only
/// supported recovery.
pub const YamlStreamIndexer = struct {
    /// Retained. Every array this indexer owns, and every later growth of
    /// them, comes from this allocator, and `deinit` frees into it. It must
    /// stay valid and unmodified for the indexer's whole lifetime.
    allocator: std.mem.Allocator,
    /// Bytes of the unfinished line, cleared as each completed line is
    /// consumed. A line may not exceed `max_u24` bytes; its capacity is
    /// retained across `reset`.
    pending_line: std.ArrayList(u8) = .empty,
    /// Token offsets recorded so far. `finish` appends the three sentinels
    /// and transfers this buffer to the taken index.
    index_offsets: std.ArrayList(u32) = .empty,
    /// One kind per real token offset; sentinel offsets have no kind entries.
    index_kinds: std.ArrayList(YamlTokenKind) = .empty,
    /// Token span lengths, one per offset. `finish` transfers this buffer to
    /// the taken index.
    index_lengths: std.ArrayList(u32) = .empty,
    /// The finished index. `null` until a successful `finish`, and again after
    /// `take`.
    index: ?YamlStructuralIndex = null,
    /// The grammar state a windowed walk advances. Each completed line is
    /// offered to it as a window, so it never holds more than one line.
    engine: YamlResidentEngine,
    /// Source offset of `pending_line.items[0]`.
    pending_start: usize = 0,
    /// What the shared source check carries from one line to the next: the
    /// open quote, the block scalar header whose body the next line may be,
    /// and the flow collections the lines above opened. `processLine` feeds it
    /// every completed line, whether or not the grammar still wants the line,
    /// and `reset` returns it to a document that has not been read. It is
    /// bounded by one line, so the indexer never holds more source than the
    /// unfinished line it already keeps.
    source_state: source.SourceState = .{},
    /// Bytes accepted so far. `finish` writes it as the trailing sentinel.
    input_len: usize = 0,
    /// Set by a successful `finish`. A later `feed` returns
    /// `error.AlreadyFinished` and `finish` becomes a no-op.
    finished: bool = false,
    /// The latched verdict, or `null` while the document is still clean.
    /// `feed` never clears it and `reset` is the only way to.
    failure: ?FinishError = null,
    const Self = YamlStreamIndexer;

    /// `init`'s failures. `error.InputTooLarge` when `chunk_len` exceeds
    /// `std.math.maxInt(u32)`, decided before any allocation, and
    /// `error.OutOfMemory` from the unfinished-line reservation, which leaves
    /// the caller owning nothing. This indexer refuses nothing of its own
    /// beyond that reservation.
    pub const InitError = std.mem.Allocator.Error || error{
        CapacityOverflow,
        InputTooLarge,
    };
    /// `feed`'s failures. `error.AlreadyFinished`, `error.CapacityOverflow`,
    /// `error.InputTooLarge`, `error.TapeTooLarge` and `error.OutOfMemory` are
    /// all reachable here; the three `YamlError` tags are carried for shape,
    /// because a grammar or profile verdict found on a completed line is
    /// latched in `failure` and returned by `finish` rather than by `feed`.
    /// `feed` states which of these leave the chunk re-feedable and which
    /// leave it partly consumed.
    pub const FeedError = std.mem.Allocator.Error || YamlError || error{
        AlreadyFinished,
        CapacityOverflow,
        InputTooLarge,
        TapeTooLarge,
    };
    /// `finish`'s failures: the latched verdict in `failure` returned as-is,
    /// `error.Invalid` for a trailing `'\r'`, and the sizing and allocator tags
    /// from the final walk and the array hand-off. `error.AlreadyFinished` is
    /// absent because `finish` is a no-op once it has succeeded, and
    /// `finish` states what each residue leaves behind.
    pub const FinishError = std.mem.Allocator.Error || YamlError || error{
        CapacityOverflow,
        InputTooLarge,
        TapeTooLarge,
    };
    /// `feedFrom`'s failures: every tag of `FeedError` and `FinishError`, plus
    /// `std.Io.Reader.ShortError`, which is the reader's short-read set rather
    /// than a tag and contributes exactly one of them, `error.ReadFailed`.
    /// The other tag `reader.fill` can return, `error.EndOfStream`, is
    /// consumed here and runs `finish` instead of reaching the caller.
    pub const FeedFromError = FeedError || FinishError || std.Io.Reader.ShortError;

    /// Allocates the unfinished-line buffer at `chunk_len` bytes and stores
    /// `allocator` for the indexer's lifetime.
    ///
    /// `chunk_len` is an initial capacity only: the line buffer grows to the
    /// longest line up to `max_u24` bytes, and a `chunk_len` above that is
    /// clamped rather than rejected. `chunk_len` above
    /// `std.math.maxInt(u32)` returns `error.InputTooLarge` before any
    /// allocation. The token arrays start empty and grow during `feed`. On
    /// `error.OutOfMemory` the reservation is released and the caller owns
    /// nothing.
    pub fn init(allocator: std.mem.Allocator, chunk_len: usize) InitError!YamlStreamIndexer {
        if (chunk_len > std.math.maxInt(u32)) return error.InputTooLarge;
        var pending_line = std.ArrayList(u8).empty;
        try pending_line.ensureTotalCapacity(allocator, @min(chunk_len, max_u24));
        return .{
            .allocator = allocator,
            .pending_line = pending_line,
            .engine = YamlResidentEngine.init(),
        };
    }
    /// Releases every array the indexer still owns into `self.allocator`,
    /// including a finished index not yet taken.
    ///
    /// An index already returned by `take` is unaffected and stays owned by
    /// the caller. The indexer is unusable afterward, and a second call is a
    /// double free.
    pub fn deinit(self: *Self) void {
        if (self.index) |*index| index.deinit(self.allocator);
        self.pending_line.deinit(self.allocator);
        self.index_offsets.deinit(self.allocator);
        self.index_kinds.deinit(self.allocator);
        self.index_lengths.deinit(self.allocator);
        self.engine.deinit();
        self.* = undefined;
    }

    /// Bytes of the unfinished line currently retained. This is the memory a
    /// caller must expect the indexer to hold between `feed` calls; it is `0`
    /// at a line boundary and after `finish`.
    pub fn retainedByteCount(self: *const Self) usize {
        return self.pending_line.items.len;
    }

    fn appendToken(self: *Self, kind: YamlTokenKind, offset: usize, length: usize) FinishError!void {
        if (offset > std.math.maxInt(u32)) return error.InputTooLarge;
        if (length > std.math.maxInt(u32)) return error.TapeTooLarge;
        if (length > max_u24) return error.TapeTooLarge;
        try self.index_offsets.append(self.allocator, @intCast(offset));
        errdefer _ = self.index_offsets.pop();
        try self.index_kinds.append(self.allocator, kind);
        errdefer _ = self.index_kinds.pop();
        try self.index_lengths.append(self.allocator, @intCast(length));
    }

    fn appendEngineEvents(self: *Self) FinishError!void {
        while (true) {
            const event = self.engine.next(self.engine.consumed) catch |err| switch (err) {
                error.Invalid => return error.Invalid,
                error.Unsupported => return error.Unsupported,
                error.DepthExceeded => return error.DepthExceeded,
                error.InputTooLarge => return error.InputTooLarge,
                error.CapacityOverflow => return error.CapacityOverflow,
                error.TapeTooLarge => return error.TapeTooLarge,
            };
            const value = event orelse break;
            try self.appendToken(value.kind, value.offset, value.raw.len);
        }
    }
    /// Reads one completed line against the source context the lines above left
    /// behind, then hands it to the grammar as a window.
    ///
    /// The source check runs on every line, including the ones after a latched
    /// verdict, so a document that is invalid anywhere is invalid as a whole
    /// and `error.Invalid` still wins over the `error.Unsupported` a block
    /// scalar header latched earlier. The context moves with the lines whether
    /// or not the grammar takes them, so the check on the last line of a
    /// document reads the same document as the check over all of it.
    fn processLine(self: *Self, has_newline: bool) FinishError!void {
        var line = self.pending_line.items;
        if (line.len > 0 and line[line.len - 1] == '\r') {
            if (!has_newline) return error.Invalid;
            line = line[0 .. line.len - 1];
        }
        // The document byte order mark is the head of the stream and not
        // content, so it is the one U+FEFF no line has to read as anything.
        // Every other one is left to the check below, which reads it against
        // the quote, the comment and the block body the lines above left: a
        // U+FEFF at the head of a line is quoted content only where the line
        // above ended inside a quoted scalar.
        const bom_len: usize = if (self.pending_start == 0 and
            std.mem.startsWith(u8, line, bom))
            bom.len
        else
            0;
        var source_failure: ?Failure = null;
        try validateYamlSourceLine(
            &self.source_state,
            line[bom_len..],
            has_newline,
            &source_failure,
        );
        try validateYamlLineFraming(line, bom_len, &source_failure);
        if (self.failure != null) return;
        try self.engine.beginWindow(line, self.pending_start, has_newline);
        try self.appendEngineEvents();
        self.engine.suspendWindow();
        try self.appendEngineEvents();
    }

    /// Adds bytes to the current document, one line at a time.
    ///
    /// `error.AlreadyFinished` after a successful `finish`.
    /// `error.CapacityOverflow` when the running length overflows and
    /// `error.InputTooLarge` past `std.math.maxInt(u32)` are decided before
    /// any byte of `data` is consumed, so the same chunk may be fed again.
    /// A grammar or profile verdict on a completed line is latched in
    /// `failure` instead of returned, and `feed` keeps consuming; see the type
    /// comment for the precedence between them.
    ///
    /// `error.TapeTooLarge` when a single line would pass `max_u24` bytes, and
    /// `error.OutOfMemory` from the line buffer or a token array, are both
    /// raised part-way through `data`: the bytes before the failure are
    /// consumed and recorded and the rest of the chunk is not, so the chunk
    /// must not be fed again. `error.CapacityOverflow` and `error.InputTooLarge`
    /// from inside the walk leave the same residue. `reset` is the only
    /// supported recovery from any of them.
    pub fn feed(self: *Self, data: []const u8) FeedError!void {
        if (self.finished) return error.AlreadyFinished;
        const new_len = std.math.add(usize, self.input_len, data.len) catch return error.CapacityOverflow;
        if (new_len > std.math.maxInt(u32)) return error.InputTooLarge;
        for (data) |byte| {
            if (byte == '\n') {
                self.processLine(true) catch |err| switch (err) {
                    error.Invalid, error.Unsupported, error.DepthExceeded => {
                        if (self.failure == null or err == error.Invalid) self.failure = err;
                    },
                    else => return err,
                };
                self.pending_line.clearRetainingCapacity();
                self.input_len += 1;
                self.pending_start = self.input_len;
            } else {
                if (self.pending_line.items.len >= max_u24) return error.TapeTooLarge;
                try self.pending_line.append(self.allocator, byte);
                self.input_len += 1;
            }
        }
    }

    /// Drains `reader` into `feed` and calls `finish` at end of stream.
    ///
    /// `reader` is not retained: it and the provider behind it must stay live
    /// for the duration of the call, and this indexer stores no `std.Io`.
    /// The call may block according to the reader's implementation. Provider
    /// failures return `error.ReadFailed`; cancellation can reach this call
    /// through that provider failure channel, not a separate cancellation tag.
    /// `error.EndOfStream` is consumed and runs `finish` instead.
    ///
    /// An error from `feed` propagates before `reader.toss`, so the reader
    /// still holds the chunk that failed and the residue is the one `feed`
    /// documents. An error from `reader.fill` leaves every buffered byte
    /// already consumed and fed, and the caller may still call `finish`.
    pub fn feedFrom(self: *Self, reader: *std.Io.Reader) FeedFromError!void {
        while (true) {
            const buffered = reader.buffered();
            if (buffered.len > 0) {
                try self.feed(buffered);
                reader.toss(buffered.len);
                continue;
            }
            reader.fill(1) catch |err| switch (err) {
                error.EndOfStream => return self.finish(),
                error.ReadFailed => return error.ReadFailed,
            };
        }
    }

    /// Consumes the final unterminated line, closes the walk and transfers the
    /// three token arrays into a finished index. Repeated calls do nothing.
    ///
    /// A latched grammar verdict is returned as-is, before any index is
    /// built. A trailing `'\r'` is `error.Invalid`. On success `take` becomes
    /// legal and `feed` returns `error.AlreadyFinished`.
    ///
    /// Allocation failure can leave advanced grammar state and partial arrays.
    /// Transferred buffers are released on error; untaken lists retain their
    /// buffers, so `deinit` remains valid. A failure during hand-off can empty
    /// one or two lists before a later transfer fails. Use `reset` to recover;
    /// do not retry `finish` or take the partial index.
    pub fn finish(self: *Self) FinishError!void {
        if (self.finished) return;
        if (self.pending_line.items.len > 0) {
            if (self.pending_line.items[self.pending_line.items.len - 1] == '\r') return error.Invalid;
            try self.processLine(false);
            self.pending_line.clearRetainingCapacity();
        }
        if (self.failure) |err| return err;
        self.engine.endWindow(true);
        try self.appendEngineEvents();
        const sentinel: u32 = @intCast(self.input_len);
        try self.index_offsets.append(self.allocator, sentinel);
        try self.index_offsets.append(self.allocator, sentinel);
        try self.index_offsets.append(self.allocator, 0);

        const indexes = try self.index_offsets.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(indexes);
        const kinds = try self.index_kinds.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(kinds);
        const lengths = try self.index_lengths.toOwnedSlice(self.allocator);
        self.index = .{
            .indexes = indexes,
            .kinds = kinds,
            .lengths = lengths,
            .count = kinds.len,
        };
        self.finished = true;
    }

    /// Returns the finished index without copying, moving all three arrays to
    /// the caller.
    ///
    /// Requires a successful `finish` and no prior `take` since the last `reset`.
    /// Both preconditions are asserted: Debug and ReleaseSafe diagnose a
    /// violation; ReleaseFast and ReleaseSmall treat it as unchecked illegal
    /// behavior. A second `take` does not return an empty index.
    /// Ownership of the arrays leaves the indexer with this call; `deinit`
    /// afterwards frees only what it still holds. The result's `count` is the
    /// number of tokens and its `indexes` carries the three trailing
    /// sentinels, as `YamlStructuralIndex` documents.
    pub fn take(self: *Self) YamlStructuralIndex {
        std.debug.assert(self.finished);
        std.debug.assert(self.index != null);
        const result = self.index.?;
        self.index = null;
        return result;
    }

    /// Starts a new document, retaining every reusable capacity.
    ///
    /// This is the only recovery from an errored `feed` or `finish`, including
    /// a failed hand-off in `finish`: a finished index not yet taken is
    /// released here, the line buffer and the three token arrays are cleared
    /// without shrinking, the engine is reset, the counters return to zero, the
    /// source context returns to a document that has not been read and the
    /// latched verdict is cleared. It is valid before or after `finish` and
    /// after `take`.
    pub fn reset(self: *Self) void {
        if (self.index) |*index| index.deinit(self.allocator);
        self.index = null;
        self.pending_line.clearRetainingCapacity();
        self.index_offsets.clearRetainingCapacity();
        self.index_kinds.clearRetainingCapacity();
        self.index_lengths.clearRetainingCapacity();
        self.engine.reset(&.{});
        self.pending_start = 0;
        self.source_state = .{};
        self.input_len = 0;
        self.finished = false;
        self.failure = null;
    }
};

/// What the resident engine still owes the line it is holding.
///
/// `.initial` is the default a line starts in, before any byte of it has been
/// classified; `.done` is the terminal phase and is the only one that leaves
/// the line consumed. The other tags name the construct the line opened and
/// what the engine expects next, so a consumer reading
/// `YamlResidentEngine.line.?.phase` learns which continuation step the next
/// `next` will take.
const ResidentLinePhase = enum {
    initial,
    scalar,
    sequence_value,
    mapping_key,
    mapping_value,
    flow,
    done,
    document_start,
    document_end,
};

/// One line the resident engine holds, borrowed from the engine's `input`.
///
/// `start`, `end`, `content_start` and `visible_end` are offsets into that
/// `input`, so a windowed walk reports the same line at different offsets from
/// a whole-input walk; `end` is the one the grammar turns into an absolute
/// source offset by adding the engine's `input_base`. `colon` is `null` when
/// the line has no block mapping colon. The value owns nothing, copies with no
/// teardown, and `YamlResidentEngine.line` is `null` between lines and at the
/// end of a document.
const ResidentLine = struct {
    start: usize,
    end: usize,
    content_start: usize,
    visible_end: usize,
    indent: usize,
    bom_prefix: usize,
    sequence: bool,
    colon: ?usize,
    value_start: usize = 0,
    key_end: usize = 0,
    phase: ResidentLinePhase = .initial,
};

/// Whether a flow frame is a `[...]` sequence or a `{...}` mapping, which is
/// what decides its closing delimiter and whether a `:` is legal inside it.
const ResidentFlowKind = enum {
    sequence,
    mapping,
};

/// What the flow frame's next byte must be. The `_after_comma` tags are the
/// same expectations as their base tags, reached once a separator has been
/// consumed; `after_value` is the state in which only `,` or the closing
/// delimiter is legal.
const ResidentFlowExpect = enum {
    value,
    value_after_comma,
    key,
    key_after_comma,
    colon,
    map_value,
    after_value,
};

/// One open flow collection in the resident engine's inline stack.
///
/// `open_offset` is the offset of the `[` or `{` within the engine's current
/// `input`, not an absolute source offset. The value owns nothing and is
/// written by `pushFlow` before `flow_len` exposes it.
const ResidentFlowFrame = struct {
    kind: ResidentFlowKind,
    open_offset: usize,
    expect: ResidentFlowExpect,
};

/// The span a scalar parse produced, in offsets relative to the engine's
/// current `input`. `next` is where the scalar walk stopped, not a span
/// endpoint, so `start + length` and `next` need not agree.
const ResidentSpan = struct {
    start: usize,
    length: usize,
    next: usize,
};

/// The failures the resident grammar can report: the three profile verdicts
/// plus an unrepresentable offset or span and a position addition that
/// overflows. It is what every `YamlResidentEngine` step returns, and it is
/// narrower than the published `ResidentError` that a walk widens it into.
const YamlEngineError = YamlError || error{
    InputTooLarge,
    TapeTooLarge,
    CapacityOverflow,
};

/// A resumable YAML grammar cursor. It retains only source positions,
/// bounded collection frames, and one event. It never constructs a tape or a
/// semantic token list before the caller asks for the next event.
///
/// The type is published through the fields that hold it rather than by name:
/// `Parser.engine`, `EventReader.engine`, `TokenCursor.engine` and
/// `YamlStreamIndexer.engine` all have this type, so a consumer that reaches
/// one of those fields reads and writes every field here. It allocates nothing
/// and owns no bytes: `input` is the borrowed source it was reset with and
/// `metadata` a borrowed optional newline index. Its two frame arrays are
/// inline and fixed at `yaml_max_depth`, so a copy is a full second cursor
/// with its own state and needs no teardown, and no address has to stay
/// stable, because a walk borrows its parser's engine in place rather than a
/// copy of it. Nothing here synchronizes and no method calls back into caller
/// code.
///
/// Its methods are the grammar's own steps, not an entry point a caller is
/// expected to drive. `EventReader.next`, `TokenCursor.next` and the walk
/// behind `YamlStreamIndexer.feed` and `finish` are the supported ways to
/// advance one, and each checks its own position before the grammar sees it:
/// a consumer that advances `consumed` or writes the borrowed source by hand
/// desynchronizes the walk from its guard rather than reaching the grammar.
const YamlResidentEngine = struct {
    input: []const u8 = &.{},
    input_base: usize = 0,
    source_pos: usize = 0,
    metadata: ?*const YamlLexicalMetadata = null,
    metadata_cursor: usize = 0,
    // Complete-input callers set this only after validateYamlSource succeeds.
    source_checked: bool = false,
    // The source context `prepareLine` reads each line against, for a walk
    // over a complete input. A windowed walk keeps its context in the caller
    // that owns the lines, which is `YamlStreamIndexer.source_state`.
    source_state: source.SourceState = .{},
    line: ?ResidentLine = null,
    close_pending: usize = 0,
    resolve_pending: ?usize = null,
    nested_from_empty: bool = false,
    // SAFETY: every frame is written by `pushBlock` before `block_len` exposes
    // it, so no slot is read while uninitialized.
    block_frames: [yaml_max_depth]StreamFrame = undefined,
    block_len: usize = 0,
    pending_empty: ?StreamPendingEmpty = null,
    // SAFETY: every frame is written by `pushFlow` before `flow_len` exposes
    // it, so no slot is read while uninitialized.
    flow_frames: [yaml_max_depth]ResidentFlowFrame = undefined,
    flow_len: usize = 0,
    flow_pos: usize = 0,
    flow_end: usize = 0,
    window_mode: bool = false,
    window_complete: bool = true,
    window_eof: bool = false,
    window_has_newline: bool = false,
    event: ?Event = null,
    consumed: usize = 0,
    saw_root: bool = false,
    root_done: bool = false,
    root_indent: usize = 0,
    document_started: bool = false,
    document_ended: bool = false,
    done: bool = false,
    failed: ?YamlError = null,
    diagnostic: ?Failure = null,

    const Self = YamlResidentEngine;

    fn init() Self {
        return .{};
    }

    fn deinit(self: *Self) void {
        self.* = undefined;
    }

    fn reset(self: *Self, input: []const u8) void {
        self.* = .{
            .input = input,
        };
    }

    /// Use only after validateYamlSource on a complete input.
    fn resetValidated(self: *Self, input: []const u8) void {
        self.* = .{
            .input = input,
            .source_checked = true,
        };
    }

    fn resetWithMetadata(
        self: *Self,
        input: []const u8,
        metadata: ?*const YamlLexicalMetadata,
    ) void {
        self.resetValidated(input);
        self.metadata = metadata;
    }

    /// Offers one completed line as the window the walk advances. The caller
    /// has read the line against the source context it carries, because only
    /// the caller knows the lines above it; see `prepareWindow`.
    fn beginWindow(
        self: *Self,
        input: []const u8,
        input_base: usize,
        has_newline: bool,
    ) YamlEngineError!void {
        if (self.line != null or self.flow_len != 0) return self.record(error.Invalid);
        self.input = input;
        self.input_base = input_base;
        self.source_checked = false;
        self.source_pos = input.len;
        self.window_mode = true;
        self.window_complete = false;
        self.window_eof = false;
        self.window_has_newline = has_newline;
        self.diagnostic = null;
        try self.prepareWindow();
    }
    fn endWindow(self: *Self, eof: bool) void {
        self.window_complete = true;
        self.window_eof = eof;
    }

    fn suspendWindow(self: *Self) void {
        self.window_complete = true;
        self.window_eof = false;
    }

    /// Reads the line the caller offers as a window.
    ///
    /// The caller has already read the window against the source context it
    /// carries, because only the caller knows the lines above it; see
    /// `YamlStreamIndexer.processLine`. What is left here is the grammar's own
    /// reading of one line.
    fn prepareWindow(self: *Self) YamlEngineError!void {
        const end = self.input.len;
        const bom_prefix: usize = if (self.input_base == 0 and end >= bom.len and
            self.input[0] == 0xef and self.input[1] == 0xbb and self.input[2] == 0xbf)
            bom.len
        else
            0;
        var content_start = bom_prefix;
        while (content_start < end and self.input[content_start] == ' ') : (content_start += 1) {}
        if (content_start < end and self.input[content_start] == '\t') {
            return self.record(error.Invalid);
        }
        if (content_start == end or self.input[content_start] == '#') return;
        const visible_end = trimCommentEnd(self.input, content_start, end);
        if (visible_end <= content_start) return;
        var line: ResidentLine = .{
            .start = 0,
            .end = self.input_base + end,
            .content_start = content_start,
            .visible_end = visible_end,
            .indent = content_start - bom_prefix,
            .bom_prefix = bom_prefix,
            .sequence = isSequenceEntry(self.input, content_start, visible_end),
            .colon = findBlockColon(self.input, content_start, visible_end),
        };
        if (line.indent == 0 and streamMarker(self.input, content_start, visible_end, "---")) {
            line.phase = .document_start;
            self.close_pending = 0;
            self.resolve_pending = null;
        } else if (line.indent == 0 and streamMarker(self.input, content_start, visible_end, "...")) {
            line.phase = .document_end;
            self.close_pending = self.block_len;
            if (self.pending_empty) |pending| {
                self.resolve_pending = pending.offset;
                self.pending_empty = null;
            }
        } else {
            self.nested_from_empty = if (self.pending_empty) |pending|
                line.indent > pending.indent
            else
                false;
            if (self.pending_empty) |pending| {
                if (!self.nested_from_empty) self.resolve_pending = pending.offset;
                self.pending_empty = null;
            }
            self.close_pending = 0;
            var frame_index = self.block_len;
            while (frame_index > 0 and
                self.block_frames[frame_index - 1].indent > line.indent)
            {
                self.close_pending += 1;
                frame_index -= 1;
            }
        }
        self.line = line;
    }

    fn record(self: *Self, err: YamlError) YamlEngineError {
        if (!self.window_mode and !self.source_checked) {
            var source_failure: ?Failure = null;
            validateYamlSource(self.input, &source_failure) catch |source_err| switch (source_err) {
                error.Invalid => {
                    self.diagnostic = source_failure;
                    self.failed = error.Invalid;
                    return error.Invalid;
                },
                error.InputTooLarge => return error.InputTooLarge,
            };
        }
        const local_offset = if (self.flow_len > 0)
            self.flow_pos
        else if (self.line) |line|
            line.content_start
        else
            self.source_pos;
        const offset = std.math.add(usize, self.input_base, local_offset) catch self.input_base;
        const input_end = std.math.add(usize, self.input_base, self.input.len) catch offset;
        self.diagnostic = .{
            .err = err,
            .kind = if (err == error.Unsupported) .unsupported else .syntax,
            .offset = @min(offset, input_end),
        };
        self.failed = err;
        return err;
    }

    fn emit(self: *Self, kind: YamlTokenKind, offset: usize, length: usize) YamlEngineError!void {
        if (offset > self.input.len or length > self.input.len - offset) {
            return self.record(error.Invalid);
        }
        const absolute = std.math.add(usize, self.input_base, offset) catch return error.InputTooLarge;
        if (absolute > std.math.maxInt(u32)) return error.InputTooLarge;
        if (length > std.math.maxInt(u32)) return error.TapeTooLarge;
        if (length > max_u24) return error.TapeTooLarge;
        self.event = .{
            .kind = kind,
            .offset = @intCast(absolute),
            .raw = if (length == 0) &.{} else self.input[offset .. offset + length],
        };
    }
    fn emitAbsolute(self: *Self, kind: YamlTokenKind, offset: usize) YamlEngineError!void {
        if (offset > std.math.maxInt(u32)) return error.InputTooLarge;
        self.event = .{
            .kind = kind,
            .offset = @intCast(offset),
            .raw = &.{},
        };
    }

    fn failUnclosed(self: *Self, offset: usize) YamlEngineError {
        _ = offset;
        const end = self.currentLineEnd();
        if ((self.window_mode and self.window_has_newline and end == self.input.len) or
            (end < self.input.len and (self.input[end] == '\n' or self.input[end] == '\r')))
        {
            return self.record(error.Unsupported);
        }
        return self.record(error.Invalid);
    }

    fn prepareLine(self: *Self) YamlEngineError!bool {
        while (self.source_pos < self.input.len) {
            const start = self.source_pos;
            const newline = if (self.metadata) |lex|
                lex.nextNewline(&self.metadata_cursor, start)
            else if (std.mem.findScalar(u8, self.input[start..], '\n')) |relative|
                start + relative
            else
                null;
            const has_newline = newline != null;
            var end: usize = newline orelse self.input.len;
            const line_next = if (has_newline) end + 1 else end;
            self.window_has_newline = has_newline;
            if (end > start and self.input[end - 1] == '\r') {
                end -= 1;
            }
            if (!self.source_checked) {
                var scan = start;
                while (scan < end) : (scan += 1) {
                    if (self.input[scan] == '\r') return self.record(error.Invalid);
                }
                if (!has_newline and end < self.input.len) return self.record(error.Invalid);
            }

            const bom_prefix: usize = if (start == 0 and end >= bom.len and
                self.input[0] == 0xef and self.input[1] == 0xbb and self.input[2] == 0xbf)
                bom.len
            else
                0;
            if (!self.source_checked) {
                // Read against the lines above rather than against this slice
                // alone: an open quote and a block scalar body both belong to
                // the source, and this is the same check a walk over the whole
                // input reached from `validateYamlSource`.
                var failure: ?Failure = null;
                validateYamlSourceLine(
                    &self.source_state,
                    self.input[start + bom_prefix .. end],
                    has_newline,
                    &failure,
                ) catch |err| switch (err) {
                    error.Invalid => return self.record(error.Invalid),
                    error.InputTooLarge => return error.InputTooLarge,
                };
            }
            var content_start = start + bom_prefix;
            while (content_start < end and self.input[content_start] == ' ') : (content_start += 1) {}
            if (!self.source_checked and content_start < end and self.input[content_start] == '\t') {
                return self.record(error.Invalid);
            }
            self.source_pos = line_next;
            const visible_end = trimCommentEnd(self.input, content_start, end);
            if (visible_end <= content_start) continue;

            var line: ResidentLine = .{
                .start = start,
                .end = end,
                .content_start = content_start,
                .visible_end = visible_end,
                .bom_prefix = bom_prefix,
                .indent = content_start - start - bom_prefix,
                .sequence = isSequenceEntry(self.input, content_start, visible_end),
                .colon = findBlockColon(self.input, content_start, visible_end),
            };
            if (line.indent == 0 and streamMarker(self.input, content_start, visible_end, "---")) {
                line.phase = .document_start;
                self.close_pending = 0;
                self.resolve_pending = null;
            } else if (line.indent == 0 and streamMarker(self.input, content_start, visible_end, "...")) {
                line.phase = .document_end;
                self.close_pending = self.block_len;
                if (self.pending_empty) |pending| {
                    self.resolve_pending = pending.offset;
                    self.pending_empty = null;
                }
            } else {
                self.nested_from_empty = if (self.pending_empty) |pending|
                    line.indent > pending.indent
                else
                    false;
                if (self.pending_empty) |pending| {
                    if (!self.nested_from_empty) {
                        self.resolve_pending = pending.offset;
                    }
                    self.pending_empty = null;
                }
                self.close_pending = 0;
                var frame_index = self.block_len;
                while (frame_index > 0 and
                    self.block_frames[frame_index - 1].indent > line.indent)
                {
                    self.close_pending += 1;
                    frame_index -= 1;
                }
            }
            self.line = line;
            return true;
        }
        return false;
    }

    fn pushBlock(self: *Self, kind: YamlTokenKind, indent: usize, end_offset: usize) YamlEngineError!void {
        if (self.block_len + self.flow_len >= yaml_max_depth) return self.record(error.DepthExceeded);
        self.block_frames[self.block_len] = .{
            .kind = kind,
            .indent = indent,
            .end_offset = end_offset,
        };
        self.block_len += 1;
    }

    fn blockEndKind(kind: YamlTokenKind) ?YamlTokenKind {
        return switch (kind) {
            .mapping_start => .mapping_end,
            .sequence_start => .sequence_end,
            else => null,
        };
    }

    fn pushFlow(self: *Self, kind: ResidentFlowKind, open: usize) YamlEngineError!void {
        if (self.block_len + self.flow_len >= yaml_max_depth) return self.record(error.DepthExceeded);
        self.flow_frames[self.flow_len] = .{
            .kind = kind,
            .open_offset = open,
            .expect = if (kind == .sequence) .value else .key,
        };
        self.flow_len += 1;
        self.flow_pos = open + 1;
    }

    fn parseQuoted(self: *Self, start: usize, end: usize, kind: YamlTokenKind) YamlEngineError!ResidentSpan {
        _ = kind;
        const quote = self.input[start];
        var pos = start + 1;
        if (quote == '\'') {
            while (pos < end) {
                if (self.input[pos] == '\'') {
                    if (pos + 1 < end and self.input[pos + 1] == '\'') {
                        pos += 2;
                        continue;
                    }
                    pos += 1;
                    return .{ .start = start, .length = pos - start, .next = pos };
                }
                pos += 1;
            }
            return self.failUnclosed(start);
        }

        while (pos < end) {
            const byte = self.input[pos];
            if (byte == '"') {
                pos += 1;
                return .{ .start = start, .length = pos - start, .next = pos };
            }
            if (byte == '\\') {
                const escape_offset = pos;
                pos += 1;
                if (pos >= end) return self.failUnclosed(escape_offset);
                switch (self.input[pos]) {
                    '"', '\\', '/', 'b', 'f', 'n', 'r', 't' => pos += 1,
                    'u' => {
                        pos += 1;
                        if (pos < end and self.input[pos] == '{') {
                            return self.record(error.Unsupported);
                        }
                        if (end - pos < 4) return self.record(error.Invalid);
                        var hex: usize = 0;
                        while (hex < 4) : (hex += 1) {
                            if (!isHex(self.input[pos + hex])) return self.record(error.Invalid);
                        }
                        pos += 4;
                    },
                    else => return self.record(error.Unsupported),
                }
            } else {
                pos += 1;
            }
        }
        return self.failUnclosed(start);
    }

    fn parsePlain(
        self: *Self,
        start: usize,
        end: usize,
        context: ParseContext,
        kind: YamlTokenKind,
    ) YamlEngineError!ResidentSpan {
        var pos = start;
        while (pos < end) {
            const byte = self.input[pos];
            if (context == .flow_key and byte == ':') break;
            if ((context == .flow_value or context == .flow_key) and
                (byte == ',' or byte == ']' or byte == '}'))
            {
                break;
            }
            if (byte == ':' and context != .flow_key and
                (pos + 1 == end or self.input[pos + 1] == ' ' or self.input[pos + 1] == '#'))
            {
                return self.record(error.Unsupported);
            }
            if (byte == '#' and pos > start and self.input[pos - 1] == ' ') break;
            if (byte == '\t') return self.record(error.Invalid);
            if (byte == '&' or byte == '*' or byte == '!') {
                if (pos > start) {
                    if (self.input[pos - 1] == ' ') return self.record(error.Unsupported);
                } else {
                    return self.record(error.Unsupported);
                }
            }
            pos += 1;
        }
        const value_end = trimSpaces(self.input, start, pos);
        if (value_end == start) return self.record(error.Invalid);
        _ = kind;
        return .{ .start = start, .length = value_end - start, .next = value_end };
    }

    /// Whether the plain scalar at `start` opens a construct outside the
    /// profile, so the slot it sits in has to refuse it.
    ///
    /// Every slot that can hold a plain scalar answers to
    /// `startsUnsupportedConstruct`. A flow key waits for the `:` that gives
    /// it a value, because a key the flow never completes is a source error
    /// and a source error outranks a profile error.
    fn unsupportedInSlot(self: *Self, start: usize, end: usize, context: ParseContext) bool {
        if (!startsUnsupportedConstruct(self.input, start, end)) return false;
        if (context != .flow_key) return true;
        var scan = start;
        while (scan < end) : (scan += 1) {
            const byte = self.input[scan];
            if (byte == ':') return true;
            if (byte == ',' or byte == ']' or byte == '}') return false;
        }
        return false;
    }

    fn parseScalar(
        self: *Self,
        start: usize,
        end: usize,
        context: ParseContext,
        kind: YamlTokenKind,
    ) YamlEngineError!ResidentSpan {
        if (start >= end) return self.record(error.Invalid);
        return switch (self.input[start]) {
            '\'', '"' => self.parseQuoted(start, end, kind),
            '[', '{' => self.record(error.Unsupported),
            else => if (self.unsupportedInSlot(start, end, context))
                self.record(error.Unsupported)
            else
                self.parsePlain(start, end, context, kind),
        };
    }

    fn stepFlow(self: *Self) YamlEngineError!void {
        if (self.flow_len == 0) return self.record(error.Invalid);
        const frame_index = self.flow_len - 1;
        var frame = &self.flow_frames[frame_index];
        while (self.flow_pos < self.flow_end and self.input[self.flow_pos] == ' ') : (self.flow_pos += 1) {}
        if (self.flow_pos >= self.flow_end) {
            if (frame.expect == .colon or frame.expect == .value_after_comma or frame.expect == .key_after_comma) {
                return self.record(error.Invalid);
            }
            return self.failUnclosed(frame.open_offset);
        }
        const byte = self.input[self.flow_pos];

        switch (frame.expect) {
            .value, .value_after_comma => {
                if (byte == ']' and frame.expect == .value) {
                    const close = self.flow_pos;
                    self.flow_pos += 1;
                    self.flow_len -= 1;
                    if (self.flow_len == 0) {
                        if (self.flow_pos != self.currentLineEnd()) return self.record(error.Invalid);
                        if (self.line) |*line| line.phase = .done;
                    }
                    return self.emit(.sequence_end, close, 0);
                }
                if (byte == ']' or byte == ',') return self.record(error.Invalid);
                if (byte == '[' or byte == '{') {
                    frame.expect = .after_value;
                    const open = self.flow_pos;
                    try self.pushFlow(if (byte == '[') .sequence else .mapping, open);
                    return self.emit(if (byte == '[') .sequence_start else .mapping_start, open, 0);
                }
                const span = try self.parseScalar(self.flow_pos, self.flow_end, .flow_value, .scalar);
                self.flow_pos = span.next;
                frame.expect = .after_value;
                return self.emit(.scalar, span.start, span.length);
            },
            .after_value => {
                if (byte == ',') {
                    self.flow_pos += 1;
                    frame.expect = if (frame.kind == .sequence) .value_after_comma else .key_after_comma;
                    return;
                }
                const expected: u8 = if (frame.kind == .sequence) ']' else '}';
                if (byte != expected) return self.record(error.Invalid);
                const close = self.flow_pos;
                self.flow_pos += 1;
                self.flow_len -= 1;
                if (self.flow_len == 0) {
                    if (self.flow_pos != self.currentLineEnd()) return self.record(error.Invalid);
                    if (self.line) |*line| line.phase = .done;
                }
                return self.emit(
                    if (frame.kind == .sequence) .sequence_end else .mapping_end,
                    close,
                    0,
                );
            },
            .key, .key_after_comma => {
                if (byte == '}' and frame.expect == .key) {
                    const close = self.flow_pos;
                    self.flow_pos += 1;
                    self.flow_len -= 1;
                    if (self.flow_len == 0) {
                        if (self.flow_pos != self.currentLineEnd()) return self.record(error.Invalid);
                        if (self.line) |*line| line.phase = .done;
                    }
                    return self.emit(.mapping_end, close, 0);
                }
                if (byte == '}' or byte == ',') return self.record(error.Invalid);
                const span = try self.parseScalar(self.flow_pos, self.flow_end, .flow_key, .key);
                self.flow_pos = span.next;
                frame.expect = .colon;
                return self.emit(.key, span.start, span.length);
            },
            .colon => {
                if (byte != ':') return self.record(error.Invalid);
                self.flow_pos += 1;
                frame.expect = .map_value;
                return;
            },
            .map_value => {
                if (byte == ',' or byte == '}') {
                    frame.expect = .after_value;
                    return self.emit(.scalar, self.flow_pos, 0);
                }
                if (byte == '[' or byte == '{') {
                    frame.expect = .after_value;
                    const open = self.flow_pos;
                    try self.pushFlow(if (byte == '[') .sequence else .mapping, open);
                    return self.emit(if (byte == '[') .sequence_start else .mapping_start, open, 0);
                }
                const span = try self.parseScalar(self.flow_pos, self.flow_end, .flow_value, .scalar);
                self.flow_pos = span.next;
                frame.expect = .after_value;
                return self.emit(.scalar, span.start, span.length);
            },
        }
    }

    fn currentLineEnd(self: *const Self) usize {
        return if (self.line) |line| line.visible_end else self.flow_end;
    }

    fn startLineFlow(self: *Self, line: *ResidentLine, start: usize) YamlEngineError!void {
        if (start >= line.visible_end) return self.record(error.Invalid);
        const byte = self.input[start];
        if (byte != '[' and byte != '{') return self.record(error.Invalid);
        line.phase = .flow;
        self.line = line.*;
        self.flow_end = line.visible_end;
        if (self.block_len > 0) {
            self.block_frames[self.block_len - 1].end_offset = line.end;
        }
        const open = start;
        try self.pushFlow(if (byte == '[') .sequence else .mapping, open);
        return self.emit(if (byte == '[') .sequence_start else .mapping_start, open, 0);
    }

    fn stepLine(self: *Self) YamlEngineError!void {
        var line = self.line orelse return self.record(error.Invalid);
        if (self.resolve_pending) |offset| {
            self.resolve_pending = null;
            return self.emitAbsolute(.scalar, offset);
        }
        if (self.close_pending > 0) {
            self.close_pending -= 1;
            self.block_len -= 1;
            if (self.block_len == 0) self.root_done = true;
            const frame = self.block_frames[self.block_len];
            const end_kind = blockEndKind(frame.kind) orelse return self.record(error.Invalid);
            return self.emitAbsolute(end_kind, frame.end_offset);
        }
        switch (line.phase) {
            .document_start => {
                if (line.indent != 0) return self.record(error.Invalid);
                if (self.document_started or self.saw_root) return self.record(error.Unsupported);
                self.document_started = true;
                line.phase = .done;
                self.line = line;
                return self.emit(.document_start, line.content_start, 3);
            },
            .document_end => {
                if (!self.saw_root or self.document_ended) return self.record(error.Invalid);
                self.document_ended = true;
                self.root_done = true;
                line.phase = .done;
                self.line = line;
                return self.emit(.document_end, line.content_start, 3);
            },
            .done => {
                self.line = null;
                return;
            },
            .flow => {
                self.line = line;
                return self.record(error.Invalid);
            },
            .scalar => {
                const span = try self.parseScalar(
                    line.value_start,
                    line.visible_end,
                    .block_value,
                    .scalar,
                );
                if (span.next != line.visible_end) return self.record(error.Invalid);
                line.phase = .done;
                self.line = line;
                return self.emit(.scalar, span.start, span.length);
            },
            .initial => {},
            .sequence_value => {},
            .mapping_key => {},
            .mapping_value => {},
        }

        if (self.document_ended) return self.record(error.Unsupported);
        if (self.block_len > 0 and !line.sequence) {
            const frame = self.block_frames[self.block_len - 1];
            if (frame.kind == .sequence_start and frame.indent == line.indent) {
                self.block_len -= 1;
                if (self.block_len == 0) self.root_done = true;
                return self.emitAbsolute(.sequence_end, frame.end_offset);
            }
        }
        if (self.block_len == 0 and line.indent == 0 and
            line.content_start < line.visible_end and self.input[line.content_start] == '%')
        {
            return self.record(error.Unsupported);
        }
        if (!self.saw_root) self.root_indent = line.indent;
        if (self.root_done and self.block_len == 0) {
            return self.record(if (line.indent > self.root_indent) error.Unsupported else error.Invalid);
        }
        if (self.block_len == 0 and startsUnsupportedConstruct(self.input, line.content_start, line.visible_end)) {
            return self.record(error.Unsupported);
        }
        if (self.block_len > 0 and line.indent > self.block_frames[self.block_len - 1].indent and
            !self.nested_from_empty)
        {
            return self.record(error.Unsupported);
        }

        if (!line.sequence and line.colon == null) {
            if (self.block_len != 0 and !self.nested_from_empty) {
                if (line.indent > self.block_frames[self.block_len - 1].indent) {
                    return self.record(error.Unsupported);
                }
                return self.record(error.Invalid);
            }
            line.value_start = line.content_start;
            line.phase = .scalar;
            self.saw_root = true;
            if (self.block_len == 0) self.root_done = true;
            self.line = line;
            if (line.value_start < line.visible_end and
                (self.input[line.value_start] == '[' or self.input[line.value_start] == '{'))
            {
                return self.startLineFlow(&line, line.value_start);
            }
            return;
        }

        if (line.sequence) {
            if (self.block_len == 0 or self.block_frames[self.block_len - 1].indent < line.indent) {
                if (self.block_len > 0 and !self.nested_from_empty) {
                    return self.record(error.Unsupported);
                }
                try self.pushBlock(.sequence_start, line.indent, line.end);
                line.phase = .sequence_value;
                self.saw_root = true;
                self.line = line;
                return self.emit(.sequence_start, line.content_start, 0);
            }
            if (self.block_frames[self.block_len - 1].kind != .sequence_start) {
                return self.record(error.Invalid);
            }
            line.phase = .sequence_value;
        } else if (line.colon != null) {
            if (self.block_len == 0 or self.block_frames[self.block_len - 1].indent < line.indent) {
                if (self.block_len > 0 and !self.nested_from_empty) {
                    return self.record(error.Unsupported);
                }
                try self.pushBlock(.mapping_start, line.indent, line.end);
                line.phase = .mapping_key;
                self.saw_root = true;
                self.line = line;
                return self.emit(.mapping_start, line.content_start, 0);
            }
            if (self.block_frames[self.block_len - 1].kind != .mapping_start) {
                return self.record(error.Invalid);
            }
            line.phase = .mapping_key;
        }
        self.line = line;
        return;
    }

    /// The innermost open block frame. Every phase that reaches a continuation
    /// step was set by a step that had a frame open, so the stack is never empty
    /// here; the same proof `DepthStack.peek` makes about its own depth.
    fn topBlockFrame(self: *Self) *StreamFrame {
        std.debug.assert(self.block_len > 0);
        return &self.block_frames[self.block_len - 1];
    }

    fn stepLineContinuation(self: *Self) YamlEngineError!void {
        var line = self.line orelse return self.record(error.Invalid);
        switch (line.phase) {
            .sequence_value => {
                const start = line.content_start + 1 +
                    whileSpaces(self.input, line.content_start + 1, line.visible_end);
                line.value_start = start;
                line.visible_end = trimCommentEnd(self.input, start, line.visible_end);
                if (start >= line.visible_end) {
                    self.pending_empty = .{ .offset = line.end, .indent = line.indent };
                    self.topBlockFrame().end_offset = line.end;
                    self.saw_root = true;
                    line.phase = .done;
                    self.line = line;
                    return;
                }
                if (startsUnsupportedConstruct(self.input, start, line.visible_end)) {
                    return self.record(error.Unsupported);
                }
                if (findBlockColon(self.input, start, line.visible_end) != null) {
                    return self.record(error.Unsupported);
                }
                if (self.input[start] == '[' or self.input[start] == '{') {
                    self.line = line;
                    return self.startLineFlow(&line, start);
                }
                const span = try self.parseScalar(start, line.visible_end, .block_value, .scalar);
                if (span.next != line.visible_end) return self.record(error.Invalid);
                self.topBlockFrame().end_offset = line.end;
                line.phase = .done;
                self.line = line;
                return self.emit(.scalar, span.start, span.length);
            },
            .mapping_key => {
                const colon = line.colon orelse return self.record(error.Invalid);
                const key_end = trimSpaces(self.input, line.content_start, colon);
                if (key_end == line.content_start) return self.record(error.Invalid);
                const span = try self.parseScalar(
                    line.content_start,
                    key_end,
                    .block_key,
                    .key,
                );
                if (span.next != key_end) return self.record(error.Invalid);
                line.key_end = key_end;
                line.phase = .mapping_value;
                self.line = line;
                return self.emit(.key, span.start, span.length);
            },
            .mapping_value => {
                const colon = line.colon orelse return self.record(error.Invalid);
                var start = colon + 1;
                while (start < line.visible_end and self.input[start] == ' ') : (start += 1) {}
                line.value_start = start;
                if (start >= line.visible_end) {
                    self.pending_empty = .{ .offset = self.input_base + colon + 1, .indent = line.indent };
                    self.topBlockFrame().end_offset = line.end;
                    self.saw_root = true;
                    line.phase = .done;
                    self.line = line;
                    return;
                }
                if (startsUnsupportedConstruct(self.input, start, line.visible_end)) {
                    return self.record(error.Unsupported);
                }
                if (self.input[start] == '[' or self.input[start] == '{') {
                    self.line = line;
                    return self.startLineFlow(&line, start);
                }
                if (isSequenceEntry(self.input, start, line.visible_end)) {
                    return self.record(error.Unsupported);
                }
                const span = try self.parseScalar(start, line.visible_end, .block_value, .scalar);
                if (span.next != line.visible_end) return self.record(error.Invalid);
                self.topBlockFrame().end_offset = line.end;
                line.phase = .done;
                self.line = line;
                return self.emit(.scalar, span.start, span.length);
            },
            else => return,
        }
    }

    fn finish(self: *Self) YamlEngineError!void {
        if (self.pending_empty) |pending| {
            self.pending_empty = null;
            return self.emitAbsolute(.scalar, pending.offset);
        }
        if (!self.saw_root) return self.record(error.Invalid);
        if (self.block_len > 0) {
            self.block_len -= 1;
            const frame = self.block_frames[self.block_len];
            const end_kind = blockEndKind(frame.kind) orelse return self.record(error.Invalid);
            if (self.block_len == 0) self.root_done = true;
            return self.emitAbsolute(end_kind, frame.end_offset);
        }
        self.done = true;
    }
    fn produce(self: *Self) YamlEngineError!void {
        while (self.event == null and !self.done) {
            if (self.failed) |err| return err;
            if (self.flow_len > 0) {
                try self.stepFlow();
                continue;
            }
            if (self.line != null) {
                const phase = self.line.?.phase;
                if (phase == .sequence_value or phase == .mapping_key or phase == .mapping_value) {
                    try self.stepLineContinuation();
                } else {
                    try self.stepLine();
                }
                continue;
            }
            if (self.window_mode) {
                if (!self.window_complete or !self.window_eof) return;
                try self.finish();
                continue;
            }
            if (try self.prepareLine()) continue;
            try self.finish();
        }
    }

    fn peek(self: *Self, expected: usize) YamlEngineError!?Event {
        if (expected != self.consumed) return error.Invalid;
        try self.produce();
        return self.event;
    }
    fn next(self: *Self, expected: usize) YamlEngineError!?Event {
        if (expected != self.consumed) return error.Invalid;
        try self.produce();
        if (self.event) |event| {
            self.event = null;
            self.consumed += 1;
            return event;
        }
        return null;
    }
};

/// `YamlStreamIndexer.init` for a caller that would only name this
/// constructor. The returned value owns the arrays it allocated and is
/// released by `YamlStreamIndexer.deinit`; `chunk_len` is an initial capacity
/// only, and the allocator must outlive the returned indexer.
pub fn initStreamIndexer(
    allocator: std.mem.Allocator,
    chunk_len: usize,
) YamlStreamIndexer.InitError!YamlStreamIndexer {
    return YamlStreamIndexer.init(allocator, chunk_len);
}

fn whileSpaces(line: []const u8, start: usize, end: usize) usize {
    var count: usize = 0;
    while (start + count < end and line[start + count] == ' ') : (count += 1) {}
    return count;
}
// StructuralIndex reserves three terminal entries. Keep this local constant so
// the YAML index never depends on JSON Stage 2 storage or dialects.

// ------------------------------ tests ----------------------------------
fn expectYamlFailureEqual(expected: ?Failure, actual: ?Failure) !void {
    if (expected) |expected_value| {
        const actual_value = actual orelse return error.ExpectedYamlFailure;
        try testing.expectEqual(expected_value.err, actual_value.err);
        try testing.expectEqual(expected_value.kind, actual_value.kind);
        try testing.expectEqual(expected_value.offset, actual_value.offset);
    } else {
        try testing.expect(actual == null);
    }
}

fn expectYamlInputValidationEqual(input: []const u8) !void {
    var expected_failure: ?Failure = null;
    validateYamlInputScalar(input, &expected_failure) catch |expected_error| {
        inline for ([_]usize{ 4, 16, 32, 64 }) |vector_len| {
            var actual_failure: ?Failure = null;
            try testing.expectError(
                expected_error,
                validateYamlInputImpl(vector_len, input, &actual_failure),
            );
            try expectYamlFailureEqual(expected_failure, actual_failure);
        }
        return;
    };

    inline for ([_]usize{ 4, 16, 32, 64 }) |vector_len| {
        var actual_failure: ?Failure = null;
        try validateYamlInputImpl(vector_len, input, &actual_failure);
        try expectYamlFailureEqual(expected_failure, actual_failure);
    }
}

fn expectYamlTapeMatchesIndexAndResident(input: []const u8) !void {
    var index = try indexYaml(testing.allocator, input);
    defer index.deinit(testing.allocator);
    var tape_document = try buildYamlTape(testing.allocator, input);
    defer tape_document.deinit(testing.allocator);
    try testing.expectEqual(index.count, tape_document.tape.len);

    var parser = try Parser.init(testing.allocator, 0);
    defer parser.deinit();
    var resident_document = try initOnDemandDocument(&parser, input);
    defer resident_document.deinit();
    var reader = try resident_document.eventReader();

    for (tape_document.tape, 0..) |word, token_index| {
        try testing.expectEqual(index.indexes[token_index], word.offset);
        try testing.expectEqual(index.kinds[token_index], word.tapeKind());
        try testing.expectEqual(
            @as(usize, @intCast(index.lengths[token_index])),
            word.sourceLength(),
        );

        const event = (try reader.next()) orelse return error.UnexpectedEnd;
        try testing.expectEqual(word.tapeKind(), event.kind);
        try testing.expectEqual(word.offset, event.offset);
        try testing.expectEqual(word.sourceLength(), event.raw.len);
    }
    try testing.expectEqual(null, try reader.next());

    var cursor = try tape_document.root(input);
    for (tape_document.tape) |expected_word| {
        try testing.expectEqual(expected_word, try cursor.peek());
        try cursor.advance();
    }
    try testing.expectEqual(tape_document.tape.len, cursor.position());
}

test "YAML direct tape matches index and resident event order" {
    const inputs = [_][]const u8{
        "plain",
        "mapping:\n" ++
            "  empty:\n" ++
            "  nested:\n" ++
            "    -\n" ++
            "    - value\n",
        "root: {plain: [one, 'two''s', \"three\\u0033\"], empty:}\n",
        "\xef\xbb\xbf--- # start\r\n" ++
            "key: value\r\n" ++
            "... # end\r\n",
    };
    for (inputs) |input| {
        try expectYamlTapeMatchesIndexAndResident(input);
    }
}

test "YAML printable ASCII validation matches scalar at vector boundaries" {
    var input: [2 * 64 + 8]u8 = undefined;
    inline for ([_]usize{ 4, 16, 32, 64 }) |boundary| {
        const input_len = boundary + 4;
        @memset(input[0..input_len], 'a');
        try expectYamlInputValidationEqual(input[0..input_len]);

        for ([_]usize{ boundary - 1, boundary, boundary + 1 }) |offset| {
            @memset(input[0..input_len], 'a');
            input[offset] = '\n';
            try expectYamlInputValidationEqual(input[0..input_len]);

            input[offset] = '\t';
            try expectYamlInputValidationEqual(input[0..input_len]);

            input[offset] = 0x1f;
            try expectYamlInputValidationEqual(input[0..input_len]);

            input[offset] = 0x7f;
            try expectYamlInputValidationEqual(input[0..input_len]);
        }

        @memset(input[0..input_len], 'a');
        input[boundary - 1] = 0xc3;
        input[boundary] = 0xa9;
        try expectYamlInputValidationEqual(input[0..input_len]);

        @memset(input[0..input_len], 'a');
        input[boundary - 1] = 0xc3;
        var utf8_failure: ?Failure = null;
        try testing.expectError(
            error.Invalid,
            validateYamlInputImpl(boundary, input[0..input_len], &utf8_failure),
        );
        try testing.expectEqual(boundary - 1, utf8_failure.?.offset);
        try expectYamlInputValidationEqual(input[0..input_len]);

        @memset(input[0..input_len], 'a');
        input[boundary - 1 .. boundary + 2].* = .{ 0xef, 0xbb, 0xbf };
        var bom_failure: ?Failure = null;
        try testing.expectError(
            error.Invalid,
            validateYamlInputImpl(boundary, input[0..input_len], &bom_failure),
        );
        try testing.expectEqual(boundary - 1, bom_failure.?.offset);
        try expectYamlInputValidationEqual(input[0..input_len]);
    }

    @memset(input[0..], 'a');
    input[0..3].* = .{ 0xef, 0xbb, 0xbf };
    try expectYamlInputValidationEqual(input[0..]);
}

test "YAML input validity retains precedence over indentation errors" {
    var input: [72]u8 = undefined;
    @memset(input[0..], 'a');
    input[0] = '\t';
    input[64] = 0x7f;

    var failure: ?Failure = null;
    try testing.expectError(error.Invalid, validateYamlSource(&input, &failure));
    try testing.expectEqual(@as(usize, 64), failure.?.offset);

    input[64] = 0xc0;
    input[65] = 0x80;
    failure = null;
    try testing.expectError(error.Invalid, validateYamlSource(&input, &failure));
    try testing.expectEqual(@as(usize, 64), failure.?.offset);

    input[64] = 'a';
    input[65] = 'a';
    failure = null;
    try testing.expectError(error.Invalid, validateYamlSource(&input, &failure));
    try testing.expectEqual(@as(usize, 0), failure.?.offset);

    failure = null;
    try testing.expectError(
        error.Invalid,
        validateYamlSource("\xef\xbb\xbf\tkey: value\n", &failure),
    );
    try testing.expectEqual(@as(usize, 3), failure.?.offset);
}

test "YAML accepts one document with block mapping and nested sequence" {
    const input =
        "---\n" ++
        "name: Ada\n" ++
        "items:\n" ++
        "  - one\n" ++
        "  - 'two' # trailing comment\n" ++
        "...\n";
    var index = try indexYaml(testing.allocator, input);
    defer index.deinit(testing.allocator);
    try testing.expect(index.count > 0);
    try testing.expectEqual(YamlTokenKind.document_start, index.kinds[0]);
    try testing.expectEqual(YamlTokenKind.document_end, index.kinds[index.count - 1]);

    var document = try buildYamlTape(testing.allocator, input);
    defer document.deinit(testing.allocator);
    try testing.expectEqual(index.count, document.tape.len);
    var cursor = try document.root(input);
    try testing.expectEqual(YamlTokenKind.document_start, (try cursor.peek()).tapeKind());
}

test "YAML accepts flow collections and conservative quoted scalars" {
    const input = "root: {plain: [one, 'two', \"three\\u0033\"]}";
    var document = try buildYamlTape(testing.allocator, input);
    defer document.deinit(testing.allocator);
    var cursor = try document.root(input);
    var saw_mapping = false;
    while (cursor.position() < document.tape.len) {
        const word = try cursor.peek();
        if (word.tapeKind() == .mapping_start) saw_mapping = true;
        try cursor.advance();
    }
    try testing.expect(saw_mapping);
}

test "YAML accepts CRLF, comments, and a leading BOM" {
    const input = "\xef\xbb\xbf--- # start\r\nkey: value\r\n... # end\r\n";
    var index = try indexYaml(testing.allocator, input);
    defer index.deinit(testing.allocator);
    try testing.expect(index.count >= 4);
}

test "YAML reports malformed in-profile syntax as Invalid" {
    try testing.expectError(error.Invalid, buildYamlTape(testing.allocator, "a: [one,]"));
    try testing.expectError(error.Invalid, buildYamlTape(testing.allocator, "a: [one"));
    try testing.expectError(error.Invalid, buildYamlTape(testing.allocator, "a: b\nc: [x] trailing"));
}

test "YAML reports profile-external constructs as Unsupported" {
    try testing.expectError(error.Unsupported, buildYamlTape(testing.allocator, "%YAML 1.2\na: b"));
    try testing.expectError(error.Unsupported, buildYamlTape(testing.allocator, "- a: b"));
    try testing.expectError(error.Unsupported, buildYamlTape(testing.allocator, "a: - item"));
    try testing.expectError(error.Unsupported, buildYamlTape(testing.allocator, "a: | \n  text"));
    try testing.expectError(error.Unsupported, buildYamlTape(testing.allocator, "a: \"\\N\""));
    try testing.expectError(error.Unsupported, buildYamlTape(testing.allocator, "a: !tag value"));
    try testing.expectError(error.Unsupported, buildYamlTape(testing.allocator, "a: &anchor value"));
    try testing.expectError(error.Unsupported, buildYamlTape(testing.allocator, "a: *anchor"));
    try testing.expectError(error.Unsupported, buildYamlTape(testing.allocator, "---\na: b\n---\nc: d"));
}

test "YAML rejects invalid UTF-8 and unsupported line endings" {
    try testing.expectError(error.Invalid, buildYamlTape(testing.allocator, "\xc0\x80"));
    try testing.expectError(error.Invalid, buildYamlTape(testing.allocator, "a: b\rc: d"));
}

test "YAML diagnostics preserve source line and column" {
    const input = "ok: yes\ninvalid: [one,]\n";
    const result = try validateYaml(testing.allocator, input);
    try testing.expect(result != null);
    const diagnostic = result.?;
    try testing.expectEqual(error.Invalid, diagnostic.err);
    try testing.expectEqual(@as(u32, 2), diagnostic.line);
    try testing.expect(diagnostic.column > 1);
    try testing.expect(std.mem.startsWith(u8, diagnostic.snippet, "invalid:"));
}

test "YAML SIMD widths have identical structural output" {
    const input = "root:\n  - one\n  - {two: 'three'}\n";
    var scalar = try indexYamlImpl(16, testing.allocator, input);
    defer scalar.deinit(testing.allocator);
    var width32 = try indexYamlImpl(32, testing.allocator, input);
    defer width32.deinit(testing.allocator);
    var width64 = try indexYamlImpl(64, testing.allocator, input);
    defer width64.deinit(testing.allocator);
    try testing.expectEqualSlices(u32, scalar.slice(), width32.slice());
    try testing.expectEqualSlices(u32, scalar.slice(), width64.slice());
    try testing.expectEqualSlices(YamlTokenKind, scalar.kinds[0..scalar.count], width32.kinds[0..width32.count]);
    try testing.expectEqualSlices(YamlTokenKind, scalar.kinds[0..scalar.count], width64.kinds[0..width64.count]);
    try testing.expectEqualSlices(u32, scalar.lengths[0..scalar.count], width32.lengths[0..width32.count]);
    try testing.expectEqualSlices(u32, scalar.lengths[0..scalar.count], width64.lengths[0..width64.count]);
}

test "YAML stream indexer matches one-shot output" {
    const input = "a: [one, two]\nb: 'three'\n";
    var expected = try indexYaml(testing.allocator, input);
    defer expected.deinit(testing.allocator);
    var stream = try YamlStreamIndexer.init(testing.allocator, 1);
    defer stream.deinit();
    for (input, 0..) |_, offset| {
        try stream.feed(input[offset .. offset + 1]);
    }
    try stream.finish();
    var actual = stream.take();
    defer actual.deinit(testing.allocator);
    try testing.expectEqualSlices(u32, expected.slice(), actual.slice());
    try testing.expectEqualSlices(YamlTokenKind, expected.kinds[0..expected.count], actual.kinds[0..actual.count]);
}

fn checkYamlIndexAllocationFailure(allocator: std.mem.Allocator) !void {
    const input = "name: Ada\nitems:\n  - one\n  - two\n";
    var index = try indexYaml(allocator, input);
    defer index.deinit(allocator);
}

fn checkYamlValidationAllocationFailure(allocator: std.mem.Allocator) !void {
    const input = "name: Ada\nitems:\n  - one\n  - two\n";
    _ = try validateYaml(allocator, input);
}

fn checkYamlValidationIndexAllocationFailure(allocator: std.mem.Allocator) !void {
    const input = "name: Ada\nitems:\n  - one\n  - two\n";
    var index = try indexYaml(allocator, input);
    defer index.deinit(allocator);
    _ = try validateYamlIndex(allocator, input, &index);
}

fn checkYamlTapeAllocationFailure(allocator: std.mem.Allocator) !void {
    const input = "name: Ada\nitems:\n  - one\n  - two\n";
    var document = try buildYamlTape(allocator, input);
    defer document.deinit(allocator);
}

fn checkYamlStreamAllocationFailure(allocator: std.mem.Allocator) !void {
    const input = "name: Ada\nitems:\n  - one\n  - two\n";
    var stream = try YamlStreamIndexer.init(allocator, 1);
    defer stream.deinit();
    try stream.feed(input);
    try stream.finish();
    var index = stream.take();
    defer index.deinit(allocator);
}

test "YAML index and tape operations propagate allocation failure without leaks" {
    try testing.checkAllAllocationFailures(
        testing.allocator,
        checkYamlIndexAllocationFailure,
        .{},
    );
    try testing.checkAllAllocationFailures(
        testing.allocator,
        checkYamlValidationAllocationFailure,
        .{},
    );
    try testing.checkAllAllocationFailures(
        testing.allocator,
        checkYamlValidationIndexAllocationFailure,
        .{},
    );
    try testing.checkAllAllocationFailures(
        testing.allocator,
        checkYamlTapeAllocationFailure,
        .{},
    );
}

test "YAML stream operations propagate allocation failure without leaks" {
    try testing.checkAllAllocationFailures(
        testing.allocator,
        checkYamlStreamAllocationFailure,
        .{},
    );
}

fn expectYamlIndexEqual(
    expected: *const YamlStructuralIndex,
    actual: *const YamlStructuralIndex,
) !void {
    try testing.expectEqual(expected.count, actual.count);
    try testing.expectEqualSlices(u32, expected.slice(), actual.slice());
    try testing.expectEqualSlices(
        YamlTokenKind,
        expected.kinds[0..expected.count],
        actual.kinds[0..actual.count],
    );
    try testing.expectEqualSlices(
        u32,
        expected.lengths[0..expected.count],
        actual.lengths[0..actual.count],
    );
}

test "YAML nested block and flow transitions retain semantic offsets" {
    const input =
        "---\n" ++
        "root:\n" ++
        "  child:\n" ++
        "    - {name: one, empty:}\n" ++
        "tail: done\n" ++
        "...\n";
    var index = try indexYaml(testing.allocator, input);
    defer index.deinit(testing.allocator);

    var saw_non_monotonic_end = false;
    for (1..index.count) |token_index| {
        const kind = index.kinds[token_index];
        if ((kind == .mapping_end or kind == .sequence_end) and
            index.indexes[token_index] < index.indexes[token_index - 1])
        {
            saw_non_monotonic_end = true;
        }
    }
    try testing.expect(saw_non_monotonic_end);

    var document = try buildYamlTape(testing.allocator, input);
    defer document.deinit(testing.allocator);
    var cursor = try document.root(input);
    try cursor.advance();
    try cursor.skipChild();
    try testing.expectEqual(YamlTokenKind.mapping_end, (try cursor.peek()).tapeKind());
    try cursor.advance();
    try testing.expectEqual(YamlTokenKind.document_end, (try cursor.peek()).tapeKind());
    try cursor.advance();
    try testing.expectError(error.TapeOutOfBounds, cursor.peek());
}

test "YAML empty entries dedents and end marker retain eager parity" {
    const input =
        "mapping:\n" ++
        "  empty:\n" ++
        "  nested:\n" ++
        "    -\n" ++
        "    - value\n" ++
        "tail:\n" ++
        "...\n";
    var index = try indexYaml(testing.allocator, input);
    defer index.deinit(testing.allocator);
    try testing.expect((try validateYamlIndex(
        testing.allocator,
        input,
        &index,
    )) == null);

    var empty_count: usize = 0;
    for (0..index.count) |token_index| {
        if (index.kinds[token_index] == .scalar and
            index.lengths[token_index] == 0)
        {
            empty_count += 1;
        }
    }
    try testing.expectEqual(@as(usize, 3), empty_count);
}

test "YAML profile keeps unsupported multiline and property constructs" {
    const unsupported = [_][]const u8{
        "%YAML 1.2\na: b\n",
        "? complex\n: value\n",
        "a: &anchor value\n",
        "a: *anchor\n",
        "a: !tag value\n",
        "a: |\n  literal\n",
        "a: >\n  folded\n",
        "a: [one\n  two]\n",
        "a: \"first\n  second\"\n",
    };
    for (unsupported) |input| {
        try testing.expectError(error.Unsupported, scalarIndexYaml(testing.allocator, input));
        try testing.expectError(
            error.Unsupported,
            buildYamlTape(testing.allocator, input),
        );
    }
}

test "YAML scalar oracle agrees with every supported SIMD width" {
    const input =
        "\xef\xbb\xbf---\r\n" ++
        "root:\r\n" ++
        "  - {plain: one, quoted: 'two''s'} # comment\r\n" ++
        "  - [three, \"four\\u0034\"]\r\n" ++
        "...\r\n";
    var scalar = try scalarIndexYaml(testing.allocator, input);
    defer scalar.deinit(testing.allocator);

    inline for (.{ 4, 5, 7, 16, 32, 64 }) |vector_len| {
        var vector = try indexYamlImpl(vector_len, testing.allocator, input);
        defer vector.deinit(testing.allocator);
        try expectYamlIndexEqual(&scalar, &vector);
    }
}

test "YAML resident reader is lazy borrowed guarded and reusable" {
    const input = "ok: yes\nbad: [one,]\n";
    var parser = try Parser.init(testing.allocator, 0);
    defer parser.deinit();

    var document = try initOnDemandDocument(&parser, input);
    var reader = try document.eventReader();
    const start = (try reader.next()) orelse return error.MissingEvent;
    try testing.expectEqual(YamlTokenKind.mapping_start, start.kind);
    try testing.expectEqual(@as(usize, 0), start.raw.len);
    var stale = reader;
    const key = (try reader.next()) orelse return error.MissingEvent;
    try testing.expectEqual(YamlTokenKind.key, key.kind);
    try testing.expectEqualStrings("ok", key.raw);
    try testing.expect(key.raw.ptr == input.ptr);
    try testing.expectError(error.OutOfOrderIteration, stale.next());
    const scalar = (try reader.next()) orelse return error.MissingEvent;
    try testing.expectEqual(YamlTokenKind.scalar, scalar.kind);
    try testing.expectEqualStrings("yes", scalar.raw);
    try testing.expect(scalar.raw.ptr == input.ptr + 4);
    try testing.expectError(error.FocusAlreadyClaimed, document.tokenCursor());

    var saw_invalid = false;
    while (true) {
        const event = reader.next() catch |err| {
            try testing.expectEqual(error.Invalid, err);
            saw_invalid = true;
            break;
        };
        if (event == null) break;
    }
    try testing.expect(saw_invalid);

    document.deinit();
    try testing.expectError(error.DocumentReleased, reader.next());

    var reused = try initOnDemandDocument(&parser, "next: value\n");
    defer reused.deinit();
    var cursor = try reused.tokenCursor();
    try cursor.skipChild();
    try testing.expect((try cursor.peek()) == null);
}

test "YAML direct tape preserves u24 span rejection" {
    const input = try testing.allocator.alloc(u8, max_u24 + 1);
    defer testing.allocator.free(input);
    @memset(input, 'a');
    try testing.expectError(error.TapeTooLarge, buildYamlTape(testing.allocator, input));

    var parser = try Parser.init(testing.allocator, 0);
    defer parser.deinit();
    var document = try initOnDemandDocument(&parser, input);
    defer document.deinit();
    var reader = try document.eventReader();
    try testing.expectError(error.TapeTooLarge, reader.next());
}

test "YAML resident parser enforces capacity and depth limits" {
    var fixed = try Parser.init(testing.allocator, 4);
    defer fixed.deinit();
    try testing.expectError(
        error.CapacityExceeded,
        initOnDemandDocument(&fixed, "five\n"),
    );

    var input = std.ArrayList(u8).empty;
    defer input.deinit(testing.allocator);
    for (0..yaml_max_depth + 1) |_| {
        try input.append(testing.allocator, '[');
    }
    try input.append(testing.allocator, 'x');
    for (0..yaml_max_depth + 1) |_| {
        try input.append(testing.allocator, ']');
    }
    try testing.expectError(
        error.DepthExceeded,
        indexYaml(testing.allocator, input.items),
    );
    try testing.expectError(
        error.DepthExceeded,
        buildYamlTape(testing.allocator, input.items),
    );
}

test "YAML tape cursor rejects source mismatch and forged public words" {
    const input = "key: value\n";
    var document = try buildYamlTape(testing.allocator, input);
    defer document.deinit(testing.allocator);

    try testing.expectError(
        error.SourceOutOfBounds,
        document.root("key: other\n"),
    );
    const saved_kind = document.tape[0].kind;
    document.tape[0].kind = 255;
    try testing.expectError(error.InvalidTapeKind, document.root(input));
    document.tape[0].kind = saved_kind;

    const saved_offset = document.tape[1].offset;
    document.tape[1].offset = @intCast(input.len + 1);
    try testing.expectError(error.SourceOutOfBounds, document.root(input));
    document.tape[1].offset = saved_offset;
}

test "YAML stream consumes completed lines across bytewise boundaries" {
    const input =
        "\xef\xbb\xbf---\r\n" ++
        "root:\r\n" ++
        "  - \"quoted\"\r\n" ++
        "  - {empty:, value: yes}\r\n" ++
        "...\r\n";
    var expected = try indexYaml(testing.allocator, input);
    defer expected.deinit(testing.allocator);

    var stream = try initStreamIndexer(testing.allocator, 1);
    defer stream.deinit();
    for (input, 0..) |_, offset| {
        try stream.feed(input[offset .. offset + 1]);
        try testing.expect(stream.retainedByteCount() <= "  - {empty:, value: yes}\r".len);
    }
    try stream.finish();
    var actual = stream.take();
    defer actual.deinit(testing.allocator);
    try expectYamlIndexEqual(&expected, &actual);
}

test "YAML stream feedFrom discards large completed-line input" {
    var input = std.ArrayList(u8).empty;
    defer input.deinit(testing.allocator);
    for (0..4096) |_| {
        try input.appendSlice(testing.allocator, "key: value\n");
    }

    var reader = std.Io.Reader.fixed(input.items);
    var stream = try initStreamIndexer(testing.allocator, 7);
    defer stream.deinit();
    try stream.feedFrom(&reader);
    try testing.expectEqual(@as(usize, 0), stream.retainedByteCount());
    var actual = stream.take();
    defer actual.deinit(testing.allocator);

    var expected = try indexYaml(testing.allocator, input.items);
    defer expected.deinit(testing.allocator);
    try expectYamlIndexEqual(&expected, &actual);
}

fn checkYamlResidentAllocationFailure(allocator: std.mem.Allocator) !void {
    var parser = try Parser.init(allocator, 0);
    defer parser.deinit();
    var document = try initOnDemandDocument(&parser, "root: [one, two]\n");
    defer document.deinit();
    var reader = try document.eventReader();
    while (try reader.next()) |_| {}
}

test "YAML resident storage propagates allocation failure without leaks" {
    try testing.checkAllAllocationFailures(
        testing.allocator,
        checkYamlResidentAllocationFailure,
        .{},
    );
}

test "refAllDecls" {
    testing.refAllDecls(@This());
}

test "YAML indented markers and sequence comments retain scalar spans" {
    for ([_][]const u8{ " ---\n", " ...\r\n", "-##\n" }) |input| {
        var expected = try scalarIndexYaml(testing.allocator, input);
        defer expected.deinit(testing.allocator);
        var actual = try indexYaml(testing.allocator, input);
        defer actual.deinit(testing.allocator);
        try expectYamlIndexEqual(&expected, &actual);
        var stream = try YamlStreamIndexer.init(testing.allocator, 1);
        defer stream.deinit();
        for (0..input.len) |offset| try stream.feed(input[offset..][0..1]);
        try stream.finish();
        var streamed = stream.take();
        defer streamed.deinit(testing.allocator);
        try expectYamlIndexEqual(&expected, &streamed);
        var parser = try Parser.init(testing.allocator, 0);
        defer parser.deinit();
        var document = try initOnDemandDocument(&parser, input);
        defer document.deinit();
        var reader = try document.eventReader();
        for (0..expected.count) |position| {
            const event = (try reader.next()) orelse return error.UnexpectedEnd;
            try testing.expectEqual(expected.kinds[position], event.kind);
            try testing.expectEqual(expected.indexes[position], event.offset);
            try testing.expectEqual(expected.lengths[position], event.raw.len);
        }
        try testing.expectEqual(null, try reader.next());
    }
}

test "YAML source and flow errors retain profile precedence" {
    const inputs = [_][]const u8{
        "*\n\tbad",
        "{?",
        "'unfinished \r\n",
        "[one,\r\n",
        "key:\n%YAML 1.2\n",
    };
    for (inputs) |input| {
        try testing.expectError(error.Invalid, scalarIndexYaml(testing.allocator, input));
        try testing.expectError(error.Invalid, indexYaml(testing.allocator, input));
        var stream = try YamlStreamIndexer.init(testing.allocator, 1);
        defer stream.deinit();
        for (0..input.len) |offset| try stream.feed(input[offset..][0..1]);
        try testing.expectError(error.Invalid, stream.finish());
        var parser = try Parser.init(testing.allocator, 0);
        defer parser.deinit();
        var document = try initOnDemandDocument(&parser, input);
        defer document.deinit();
        var reader = try document.eventReader();
        var failed = false;
        for (0..input.len * 3 + 3) |_| {
            const event = reader.next() catch |err| {
                try testing.expectEqual(error.Invalid, err);
                try testing.expectError(error.Invalid, reader.next());
                failed = true;
                break;
            };
            if (event == null) break;
        }
        try testing.expect(failed);
    }
}

test "YAML owned root rejects forged scalar spans" {
    const input = "key: value";
    var document = try buildYamlTape(testing.allocator, input);
    defer document.deinit(testing.allocator);
    document.tape[2].payload = 0;
    try testing.expectError(error.InvalidStructure, document.root(input));
}

/// Drives every yaml-basic route from one input: the validating entry point,
/// the independent scalar oracle, the vectorized index at each supported
/// width, the eager tape, the resident walk and the stream indexer.
/// `expected` is the error every route has to report, or `null` when every
/// route has to accept `input`. A route that accepts where the others refuse,
/// or the reverse, fails here rather than in the profile of the caller that
/// happened to use it first.
fn expectYamlEveryRouteVerdict(input: []const u8, expected: ?YamlError) !void {
    if (expected) |expected_error| {
        const diagnostic = (try validateYaml(testing.allocator, input)) orelse
            return error.ExpectedYamlDiagnostic;
        try testing.expectEqual(expected_error, diagnostic.err);
        if (expected_error == error.Unsupported) {
            try testing.expectEqual(YamlDiagnosticKind.unsupported, diagnostic.kind);
        }
        try testing.expectError(expected_error, scalarIndexYaml(testing.allocator, input));
        inline for (.{ 4, 16, 32, 64 }) |vector_len| {
            try testing.expectError(expected_error, indexYamlImpl(vector_len, testing.allocator, input));
        }
        try testing.expectError(expected_error, buildYamlTape(testing.allocator, input));
    } else {
        try testing.expect((try validateYaml(testing.allocator, input)) == null);
        var oracle = try scalarIndexYaml(testing.allocator, input);
        defer oracle.deinit(testing.allocator);
        inline for (.{ 4, 16, 32, 64 }) |vector_len| {
            var indexed = try indexYamlImpl(vector_len, testing.allocator, input);
            defer indexed.deinit(testing.allocator);
            try testing.expectEqual(oracle.count, indexed.count);
        }
        var tape = try buildYamlTape(testing.allocator, input);
        defer tape.deinit(testing.allocator);
        try testing.expectEqual(oracle.count, tape.tape.len);
    }

    var parser = try Parser.init(testing.allocator, 0);
    defer parser.deinit();
    var document = try initOnDemandDocument(&parser, input);
    defer document.deinit();
    var reader = try document.eventReader();
    var resident_refused = false;
    while (true) {
        const event = reader.next() catch |err| {
            if (expected) |expected_error| try testing.expectEqual(expected_error, err);
            resident_refused = true;
            break;
        };
        if (event == null) break;
    }
    try testing.expectEqual(expected != null, resident_refused);

    var stream = try initStreamIndexer(testing.allocator, 1);
    defer stream.deinit();
    for (input, 0..) |_, offset| try stream.feed(input[offset..][0..1]);
    if (expected) |expected_error| {
        try testing.expectError(expected_error, stream.finish());
    } else {
        try stream.finish();
        var streamed = stream.take();
        defer streamed.deinit(testing.allocator);
        try testing.expect(streamed.count > 0);
    }
}

/// Builds `flow_depth` flow sequences nested over one scalar, with no block
/// frame above them. `buffer` has to hold `2 + 2 * flow_depth` bytes.
fn yamlFlowOnlySource(buffer: []u8, flow_depth: usize) []const u8 {
    @memset(buffer[0..flow_depth], '[');
    buffer[flow_depth] = 'x';
    @memset(buffer[flow_depth + 1 .. 1 + 2 * flow_depth], ']');
    buffer[1 + 2 * flow_depth] = '\n';
    return buffer[0 .. 2 + 2 * flow_depth];
}

/// Builds `a: ` followed by `flow_depth` flow sequences nested over one
/// scalar, so the document nests one block mapping plus `flow_depth` flow
/// frames. `buffer` has to hold `5 + 2 * flow_depth` bytes.
fn yamlBlockWrappedFlowSource(buffer: []u8, flow_depth: usize) []const u8 {
    @memcpy(buffer[0..3], "a: ");
    @memset(buffer[3 .. 3 + flow_depth], '[');
    buffer[3 + flow_depth] = 'x';
    @memset(buffer[4 + flow_depth .. 4 + flow_depth * 2], ']');
    buffer[4 + flow_depth * 2] = '\n';
    return buffer[0 .. 5 + flow_depth * 2];
}

test "parser audit: Y04 flow keys reject reserved and out-of-profile indicators" {
    // A flow mapping key is a plain scalar, so its first byte answers to the
    // same reserved-indicator rule a block key already answers to.
    const reserved = [_][]const u8{
        "{@: 1}\n",
        "{`: 1}\n",
        "{%: 1}\n",
        "{?: 1}\n",
        "{|: 1}\n",
        "{>: 1}\n",
        "{a: 1, @: 2}\n",
    };
    for (reserved) |input| {
        try expectYamlEveryRouteVerdict(input, error.Unsupported);
    }

    // Quoting is how a caller spells any of those bytes as data, and it keeps
    // working in the first key slot and after a comma.
    const quoted = [_][]const u8{
        "{\"@\": 1}\n",
        "{\"`\": 1}\n",
        "{\"%\": 1}\n",
        "{\"?\": 1}\n",
        "{\"|\": 1}\n",
        "{\">\": 1}\n",
        "{a: 1, \"@\": 2}\n",
    };
    for (quoted) |input| {
        try expectYamlEveryRouteVerdict(input, null);
    }

    // The block key and flow value slots already refused the same bytes, so
    // this is one rule rather than three.
    try expectYamlEveryRouteVerdict("@: 1\n", error.Unsupported);
    try expectYamlEveryRouteVerdict("[@]\n", error.Unsupported);
    try expectYamlEveryRouteVerdict("root: {a: b, \"c\": [d, e]}\n", null);
}

test "parser audit: Y06 scalar oracle spends one combined block and flow depth budget" {
    var buffer: [5 + 2 * yaml_max_depth]u8 = undefined;

    // A block mapping around 1023 flow sequences nests 1024 levels, which is
    // the ceiling every route shares.
    try expectYamlEveryRouteVerdict(
        yamlBlockWrappedFlowSource(buffer[0..], yaml_max_depth - 1),
        null,
    );

    // One sequence more nests 1025 levels. The oracle kept a separate budget
    // for block and flow nesting and accepted this; production counts both
    // frame stacks together and refuses it.
    try expectYamlEveryRouteVerdict(
        yamlBlockWrappedFlowSource(buffer[0..], yaml_max_depth),
        error.DepthExceeded,
    );

    // A bare flow sequence reaches the same 1024 levels with no block frame
    // above it, and stays inside the budget.
    try expectYamlEveryRouteVerdict(yamlFlowOnlySource(buffer[0..], yaml_max_depth), null);
}

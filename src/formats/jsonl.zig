//! JSON Lines: one strict RFC 8259 JSON value per LF-terminated record.
//!
//! Reachable as `simd.formats.jsonl`. Records are split on LF bytes that fall
//! outside a quoted string, a record made only of spaces, tabs, and CR is
//! skipped, and a CR before the LF stays in the record source. Nothing here
//! rewrites bytes or decodes values: every span handed back points into the
//! caller's input, and value-level reading belongs to `simd.json_value`. Line
//! and block comments are not JSONL; those are `simd.formats.jsonc`.
//!
//! Zig has no private fields, so every struct field below is readable and
//! writable by a consumer; the comments name what a write would break.
//!
//! Nothing here synchronizes concurrent access, so a caller that shares one
//! parser, document, or reader across threads serializes it itself.
//!
//! Four routes reach records, and they differ in what stays resident.
//!
//! Eager: `buildJsonlTape` owns every record tape at once in a
//! `JsonlDocument`, and `validateJsonl` reports the first defect in global
//! coordinates without building a tape. Both allocate one structural index and
//! release it before returning, and both keep `input` alive for whatever they
//! hand back.
//!
//! Reused lazy: `Parser` owns one index buffer, `initOnDemandDocument` leases
//! it for a whole document, and `eventReader` or `tokenCursor` walks that
//! document one event at a time. Release the reader's owning document with
//! `deinit()`, then the parser with `deinit()`.
//!
//! Reused per record: `TapeRecordParser` keeps one structural index and one
//! high-water record tape, `iterate` borrows a source under a document lease,
//! and `TapeRecordIterator.next` validates one record at a time.
//!
//! Streaming: `initStreamIndexer` produces one global index in `.jsonl` mode,
//! where a record-separator LF outside a string is itself a structural offset.
const std = @import("std");
const simd = @import("../core/simd.zig");
const json_lexical = @import("../core/json_lexical.zig");
const stage1 = @import("../core/stage1.zig");
const stream = @import("../core/stream.zig");
const resident = @import("../core/resident.zig");
const stage2 = @import("../core/stage2.zig");

/// Chunk-fed Stage 1 indexer pinned to the JSONL dialect in `.jsonl` mode.
///
/// `.jsonl` mode is what makes an LF outside a quoted string a structural
/// offset, so the finished index carries record boundaries as well as JSON
/// structure; the dialect stays `.json` because every record is validated as
/// strict RFC 8259.
///
/// The wrapper fixes the mode and dialect; the caller supplies the allocator,
/// whose interface this indexer stores. That backing state must outlive both
/// `indexer.deinit()` and the `index.deinit(allocator)` that releases an index
/// moved out by `take`, because both free into it. Chunk bytes are borrowed
/// only for the duration of each `feed` call.
///
/// The error set is `stream.StreamIndexer.InitError`, which
/// `stream.StreamIndexer.init` defines; it includes `error.InvalidOptions` for
/// a mode and dialect pair this wrapper never forms.
pub fn initStreamIndexer(
    allocator: std.mem.Allocator,
    chunk_len: usize,
) stream.StreamIndexer.InitError!stream.StreamIndexer {
    return stream.StreamIndexer.init(
        allocator,
        chunk_len,
        stream.Options{ .dialect = .json, .mode = .jsonl },
    );
}

/// One validated JSONL record, owned tape plus caller-backed source.
///
/// `document` owns one tape; `deinit` releases it exactly once with the
/// allocator `buildJsonlTape` was given, and a copy names that same tape
/// rather than becoming a second owner. `source` borrows the input
/// `JsonlDocument` also borrows, so that input must outlive the record, its
/// cursors, and every raw slice they return. A cursor made here cannot cross
/// a record boundary: the tape it walks holds this record's words only.
pub const JsonlRecord = struct {
    /// Borrows `JsonlDocument.input`; released with the caller's input, not
    /// here.
    source: []const u8,
    /// Half-open start of this record in `JsonlDocument.input`.
    source_start: usize,
    /// Half-open end in that input, excluding the terminating LF and covering
    /// the CR that precedes it.
    source_end: usize,
    /// Owned tape for this record alone, released by `deinit`.
    document: stage2.Document,

    /// Creates a cursor over this record's tape and its borrowed source.
    ///
    /// This record and the input behind `source` must both outlive the cursor.
    /// Errors are `stage2.NavigationError`.
    pub fn root(self: *const JsonlRecord) stage2.NavigationError!stage2.TapeCursor {
        return self.document.root(self.source);
    }

    /// Equivalent to `root`.
    pub fn cursor(self: *const JsonlRecord) stage2.NavigationError!stage2.TapeCursor {
        return self.root();
    }

    /// Releases this record's tape and nothing else.
    ///
    /// The allocator given to `buildJsonlTape` must be the one passed here, and
    /// the borrowed `source` is untouched. The record is unusable afterwards
    /// and a second call is a double free.
    pub fn deinit(self: *JsonlRecord, allocator: std.mem.Allocator) void {
        self.document.deinit(allocator);
        self.* = undefined;
    }
};

/// An owned collection of independently validated JSONL records.
///
/// `input` is borrowed and `records` is owned: the document owns one tape per
/// record plus the record array, and `deinit` releases all of them exactly
/// once with the allocator `buildJsonlTape` was given. `input` must outlive
/// the document, every record, and every cursor and raw slice reached through
/// them. Blank records are absent from `records`, so its length is the number
/// of accepted records and a record ordinal indexes it directly.
pub const JsonlDocument = struct {
    /// Whole input, borrowed from the caller; must outlive this document.
    input: []const u8,
    /// Record array in input order; each entry owns its own tape.
    records: []JsonlRecord,

    /// The record at `index`, or `null` when `index` is out of range.
    ///
    /// The pointer aliases `records`, so it is invalidated by `deinit` and
    /// must not outlive it.
    pub fn record(self: *const JsonlDocument, index: usize) ?*const JsonlRecord {
        if (index >= self.records.len) return null;
        return &self.records[index];
    }

    /// A cursor over the record at `index`, or `error.PositionOutOfBounds`
    /// when `index` is out of range.
    ///
    /// The cursor borrows this document's `input` and that record's tape, so
    /// both must outlive it; further errors are `stage2.NavigationError`.
    pub fn cursor(
        self: *const JsonlDocument,
        index: usize,
    ) stage2.NavigationError!stage2.TapeCursor {
        const record_value = self.record(index) orelse return error.PositionOutOfBounds;
        return record_value.root();
    }

    /// Releases every record tape and the record array.
    ///
    /// The allocator given to `buildJsonlTape` must be the one passed here, and
    /// the borrowed `input` is untouched. The document is unusable afterwards
    /// and a second call is a double free.
    pub fn deinit(self: *JsonlDocument, allocator: std.mem.Allocator) void {
        for (self.records) |*record_value| {
            record_value.deinit(allocator);
        }
        allocator.free(self.records);
        self.* = undefined;
    }
};

/// The first JSONL defect, in both record-local and global coordinates.
///
/// Every field is a plain value except `snippet`, which borrows the input the
/// diagnostic was produced from, so the whole struct costs nothing to keep.
pub const JsonlDiagnostic = struct {
    /// Ordinal of the failing record among the nonblank records, matching what
    /// `TapeRecordIterator.recordCount` reports when that record is reached.
    record_index: usize,
    /// Half-open start of the failing record in the input.
    source_start: usize,
    /// Half-open end in the input, excluding the record's terminating LF.
    source_end: usize,
    err: stage2.Error,
    /// Offset of the defect in the whole input, never within the record.
    byte_offset: usize,
    /// 1-based line number in the whole input.
    line: u32,
    /// 1-based column number within that line.
    column: u32,
    /// Borrowed slice of the input around `byte_offset`.
    snippet: []const u8,
    /// Offset of `snippet` within the input.
    snippet_start: usize,
};

/// What one JSONL event reports.
///
/// `record_start` and `record_end` are framing events this module synthesizes;
/// the remaining tags are the tape kinds `stage2.TokenReader` produces, with
/// `.key` naming an object key rather than a `.string` value.
pub const EventKind = enum {
    record_start,
    record_end,
    object_start,
    object_end,
    array_start,
    array_end,
    key,
    string,
    number,
    true_literal,
    false_literal,
    null_literal,
};

/// One JSONL event: its kind, its global position, and a borrowed source span.
///
/// `raw` is never copied, so it stays valid exactly as long as the input it
/// points into. `EventReader` and `TokenCursor` report end of input with
/// `null` rather than an event.
pub const Event = struct {
    /// Which event this is.
    kind: EventKind,
    /// Ordinal of the record this event belongs to.
    record_index: u32,
    /// Offset of the event in the whole input. For `.key` and `.string` it
    /// names the opening quote, for `.record_start` the first byte of the
    /// record, and for `.record_end` the byte after it.
    offset: u32,
    /// Borrowed source span, as `stage2.ParsedToken` defines it: the whole
    /// record for `.record_start`, empty at `offset` for `.record_end`, and
    /// the still-escaped content between the quotes for `.key` and `.string`.
    raw: []const u8,
};

/// A reusable structural index for one JSONL source at a time.
///
/// The parser owns its index buffer and borrows nothing: `input` reaches it
/// only through `initOnDemandDocument`, which leases the buffer and the single
/// active-document slot. Because the slot is held for a live document, the
/// buffer cannot be resized under it, so a document's offsets keep their
/// address. One document is active at a time and `initOnDemandDocument`
/// reports `error.DocumentActive` while another is live.
pub const Parser = struct {
    /// Failures of `init`: `error.OutOfMemory`,
    /// `error.CapacityOverflow`, and `error.InputTooLarge` when
    /// `max_capacity` exceeds the `u32` offset boundary.
    pub const InitError = std.mem.Allocator.Error || error{
        CapacityOverflow,
        InputTooLarge,
    };

    /// The caller's allocator, borrowed and never released by this type.
    allocator: std.mem.Allocator,
    /// Owns the reserved index buffer; the two fields below are views into it.
    storage: resident.IndexBuffer(void, false),
    /// The whole reserved buffer, sentinels included. It is assigned from
    /// `storage` whenever a document is prepared and never read back inside
    /// this module, so a consumer holding it across the next
    /// `initOnDemandDocument` holds a stale slice.
    indexes: []u32,
    /// Index slots currently reserved, excluding the three sentinels.
    capacity: usize,
    /// Capacity `init` reserved up front; `0` means grow on demand.
    max_capacity: usize,
    /// Lease state for the one active document.
    state: resident.State = .{},

    /// Reserves one index buffer for `max_capacity` structural offsets.
    ///
    /// A `max_capacity` of `0` reserves nothing and lets each document grow
    /// the buffer on demand up to the `u32` offset boundary; any non-zero
    /// value becomes a fixed ceiling that `initOnDemandDocument` enforces with
    /// `error.CapacityExceeded`.
    pub fn init(allocator: std.mem.Allocator, max_capacity: usize) InitError!Parser {
        if (max_capacity > std.math.maxInt(u32)) return error.InputTooLarge;

        var parser: Parser = .{
            .allocator = allocator,
            .storage = resident.IndexBuffer(void, false).init(allocator),
            .indexes = &.{},
            .capacity = 0,
            .max_capacity = max_capacity,
        };
        errdefer parser.storage.deinit();

        if (max_capacity != 0) {
            try parser.storage.reserve(max_capacity);
            parser.indexes = parser.storage.indexes;
            parser.capacity = parser.storage.capacity;
        }
        return parser;
    }

    /// Releases the index buffer; the allocator passed to `init` is not
    /// released.
    ///
    /// Every document built from this parser must be released first. That is a
    /// `std.debug.assert`: Debug and ReleaseSafe diagnose a still-active
    /// document, while ReleaseFast and ReleaseSmall treat it as unchecked
    /// illegal behavior. A second call is a double free.
    pub fn deinit(self: *Parser) void {
        std.debug.assert(!self.state.active);
        self.state.deinit();
        self.storage.deinit();
        self.* = undefined;
    }

    fn prepare(self: *Parser, input: []const u8) ![]const u32 {
        if (self.state.active) return error.DocumentActive;
        if (input.len > std.math.maxInt(u32)) return error.InputTooLarge;
        if (self.max_capacity != 0 and input.len > self.max_capacity) {
            return error.CapacityExceeded;
        }

        try self.storage.reserve(input.len);
        self.indexes = self.storage.indexes;
        self.capacity = self.storage.capacity;

        const output = self.storage.indexes[0 .. self.storage.indexes.len - sentinel_count];
        const count = try indexJsonlInto(simd.default_vector_len, output, input);
        try self.storage.finish(count, input.len);
        return self.storage.indexes[0..count];
    }
};

/// Builds a lazily readable document over `parser`'s reusable index buffer.
///
/// The document borrows `input` and the parser's buffer, so `input` and
/// `parser` must outlive it, every event and cursor it produces, and every raw
/// span those hand back. `OnDemandDocument.deinit` ends the lease and must run
/// before the next document and before `parser.deinit`. Storage is reserved
/// before the scan, so an error return leaves the parser holding the capacity
/// it grew to and takes no lease.
///
/// Fails with `error.DocumentActive` while another document is live,
/// `error.CapacityExceeded` when `input` exceeds a non-zero `max_capacity`,
/// `error.InputTooLarge` past the `u32` offset boundary, and
/// `error.OutOfMemory` or `error.CapacityOverflow` when the buffer cannot be
/// reserved.
pub fn initOnDemandDocument(
    parser: *Parser,
    input: []const u8,
) !OnDemandDocument {
    const indexes = try parser.prepare(input);
    const lease = try parser.state.begin();
    return .{
        .parser = parser,
        .input = input,
        .indexes = indexes,
        .lease = lease,
    };
}

/// A JSONL document leased over a `Parser`'s index buffer.
///
/// The document owns no allocation: it holds a pointer to the parser, borrows
/// the source, and borrows the parser's index storage, so `deinit` releases the
/// lease and nothing else and `parser` and `input` must outlive the document and
/// everything reached through it. The lease check compares a finite `u64`
/// generation counter that wraps back to `1`, which detects a released or
/// superseded document but proves nothing about storage liveness; keeping
/// `parser` and `input` alive is the caller's obligation, and the same holds
/// for every guard a reader takes from it.
///
/// Copies name the same lease and parser state. Releasing one ends the lease
/// for all copies; release through another unpoisoned copy is harmless. Do not
/// reuse the value `deinit` overwrites. Keep `parser` alive and unmoved, and keep
/// this document unmoved while a reader or cursor holds a pointer to it.
///
/// One reader at a time: `eventReader` and `tokenCursor` claim the document's
/// single focus, neither has a `deinit`, and the claim is held until this
/// document's `deinit` runs.
pub const OnDemandDocument = struct {
    /// The parser that owns the index buffer backing `indexes`.
    parser: *Parser,
    /// Whole input, borrowed from the caller; must outlive this document.
    input: []const u8,
    /// Structural offsets of `input`, borrowed from `parser.storage`.
    indexes: []const u32,
    /// The active-document lease, released by `deinit`.
    lease: resident.Lease,

    /// Releases the lease; no allocation is freed and `input` is untouched.
    ///
    /// A second call is invalid, and any reader taken from this document
    /// reports `error.DocumentReleased` afterwards.
    pub fn deinit(self: *OnDemandDocument) void {
        self.lease.release();
        self.* = undefined;
    }

    /// A lazy `EventReader` walking this document one event at a time.
    ///
    /// Claims the single focus: `error.FocusAlreadyClaimed` when a reader or
    /// cursor already holds it. A retained, unpoisoned copy whose lease was
    /// released returns `error.DocumentReleased`; the deinitialized value itself
    /// is invalid. The reader has no teardown; its claim ends with the lease.
    pub fn eventReader(self: *OnDemandDocument) !EventReader {
        const guard = try self.lease.claim();
        return EventReader.init(self, guard);
    }

    /// A lazy `TokenCursor` walking this document one token at a time.
    ///
    /// Claims the single focus: `error.FocusAlreadyClaimed` when a reader or
    /// cursor already holds it. A retained, unpoisoned copy whose lease was
    /// released returns `error.DocumentReleased`; the deinitialized value itself
    /// is invalid. The cursor has no teardown; its claim ends with the lease.
    pub fn tokenCursor(self: *OnDemandDocument) !TokenCursor {
        const guard = try self.lease.claim();
        return TokenCursor.init(self, guard);
    }
};

/// Failures of `TapeRecordParser.init`: `error.OutOfMemory`,
/// `error.CapacityOverflow`, `error.InputTooLarge` when `input_capacity_max`
/// exceeds the `u32` offset boundary, and `error.TapeTooLarge` when
/// `tape_capacity_max` does.
pub const TapeRecordInitError = std.mem.Allocator.Error || error{
    CapacityOverflow,
    InputTooLarge,
    TapeTooLarge,
};

/// Failures shared by the reusable record path.
///
/// `error.CapacityExceeded` is a configured ceiling, `error.OutOfMemory` a real
/// allocation failure, `error.CapacityOverflow`, `error.InputTooLarge`, and
/// `error.TapeTooLarge` report an input or tape the shared storage cannot
/// represent, `error.InvalidStructuralIndex` reports offsets that no longer
/// describe their input, the `resident.Error` tags come from the lease and
/// focus checks, and the `stage2.NavigationError` tags come from tape
/// navigation.
pub const TapeRecordError = std.mem.Allocator.Error || resident.Error ||
    stage2.NavigationError || error{
    CapacityExceeded,
    CapacityOverflow,
    InputTooLarge,
    TapeTooLarge,
    InvalidStructuralIndex,
};

/// One `TapeRecordIterator.next` outcome.
///
/// `.record` borrows the parser's shared tape and stays valid until the next
/// call; `.diagnostic` is a self-contained value and ends the iteration. The
/// two are mutually exclusive, so a caller never has to inspect both.
pub const TapeRecordResult = union(enum) {
    /// A validated record borrowed from the parser's tape.
    record: TapeRecord,
    /// The first defect, in global coordinates.
    diagnostic: JsonlDiagnostic,
};

/// Configuration for the reusable strict-LF JSONL record parser.
///
/// A zero limit means that the corresponding resource may grow to the checked
/// u32 boundary. Tape capacity is measured in `stage2.TapeWord` values. The
/// two limits are checked at different times: the input limit when `iterate`
/// is called and the tape limit while `next` builds a record.
pub const TapeRecordOptions = struct {
    /// Largest accepted input, in bytes. `0` leaves the `u32` offset boundary
    /// as the only limit. A longer input fails `iterate` with
    /// `error.CapacityExceeded`.
    input_capacity_max: usize = 0,
    /// Largest record tape, in `stage2.TapeWord` values. `0` leaves the `u32`
    /// offset boundary as the only limit. A record needing more fails `next`
    /// with `error.CapacityExceeded` and leaves the high-water tape unchanged.
    tape_capacity_max: usize = 0,
};

/// A reusable parser for sequential, strict-LF JSONL records.
///
/// The parser owns the global structural index and one high-water tape. Source
/// bytes are borrowed from the caller. A record and every cursor made from it
/// become invalid when the iterator advances, is deinitialized, or the parser
/// resets; stale use reports an error instead of returning a wrong tape.
///
/// `deinit` is the single owner release and a second call is a double free; a
/// copy names the same allocations and is not a second owner. While an
/// iterator, record, or cursor exists the parser must stay alive and at its
/// address, because each of those stores a pointer to it and `deinit` poisons
/// what they point at.
///
/// The staleness check is a finite `u64` record generation that wraps back to
/// `1`, paired with the finite `resident.Lease` generation. Together they
/// detect a record, cursor, or iterator from a superseded document; neither
/// proves that the parser or its storage is still alive, so keeping the parser
/// alive and unmoved remains the caller's obligation.
///
/// One lease at a time: `iterate` reports `error.DocumentActive` while one is
/// live.
pub const TapeRecordParser = struct {
    /// The caller's allocator, borrowed and never released by this type.
    allocator: std.mem.Allocator,
    /// The limits `init` was given.
    options: TapeRecordOptions,
    /// Owns the global structural index buffer.
    storage: resident.IndexBuffer(void, false),
    /// Owns the high-water record tape, reallocated only when a larger record
    /// needs it.
    tape_storage: []stage2.TapeWord,
    /// Tape words belonging to the record currently handed out.
    tape_len: usize = 0,
    /// Reusable record validator; `null` until a defect needs one.
    reader: ?stage2.TokenReader = null,
    /// Lease state for the one active iterator.
    state: resident.State = .{},
    /// Bumped by `reset` and by every iterator advance, so records from an
    /// earlier one are rejected.
    record_generation: u64 = 0,
    /// Whole input borrowed from the active `iterate`; `&.{}` when idle.
    input: []const u8 = &.{},

    /// Failures of `init`.
    pub const InitError = TapeRecordInitError;

    /// Records both limits and reserves the structural index up front when
    /// `input_capacity_max` is non-zero.
    ///
    /// A zero `input_capacity_max` reserves nothing and lets each `iterate`
    /// grow the buffer to its input. The limits themselves are checked here,
    /// before any allocation.
    pub fn init(
        allocator: std.mem.Allocator,
        options: TapeRecordOptions,
    ) InitError!TapeRecordParser {
        if (options.input_capacity_max > std.math.maxInt(u32)) {
            return error.InputTooLarge;
        }
        if (options.tape_capacity_max > std.math.maxInt(u32)) {
            return error.TapeTooLarge;
        }

        var parser: TapeRecordParser = .{
            .allocator = allocator,
            .options = options,
            .storage = resident.IndexBuffer(void, false).init(allocator),
            .tape_storage = &.{},
        };
        errdefer parser.storage.deinit();

        if (options.input_capacity_max != 0) {
            try parser.storage.reserve(options.input_capacity_max);
            parser.storage.count = 0;
        }
        return parser;
    }

    /// Releases the index buffer and the high-water tape; the allocator
    /// passed to `init` is not released.
    ///
    /// Any active iterator, record, and cursor is invalidated first and the
    /// lease is dropped without error, so deinitializing under a live iterator
    /// is allowed. The parser is unusable afterwards.
    pub fn deinit(self: *TapeRecordParser) void {
        self.releaseLease();
        self.state.deinit();
        self.storage.deinit();
        if (self.tape_storage.len != 0) {
            self.allocator.free(self.tape_storage);
        }
        self.* = undefined;
    }

    /// Invalidates all borrowed records and releases the active iterator.
    ///
    /// The reserved capacities are kept and the next `iterate` starts a fresh
    /// document. A record or cursor from before the reset then reports
    /// `error.DocumentReleased`, while a copied iterator that only fell behind
    /// reports `error.OutOfOrderIteration`.
    pub fn reset(self: *TapeRecordParser) void {
        self.releaseLease();
        self.storage.count = 0;
        self.tape_len = 0;
        self.reader = null;
        self.input = &.{};
        self.nextRecordGeneration();
    }

    /// The high-water tape capacity, in `stage2.TapeWord` values.
    ///
    /// It starts at `0` and only grows, so it tracks the largest record seen
    /// across every document. A record refused by `tape_capacity_max` leaves
    /// it unchanged.
    pub fn tapeCapacity(self: *const TapeRecordParser) usize {
        return self.tape_storage.len;
    }

    /// Structural index slots currently reserved, excluding the three
    /// sentinels.
    ///
    /// This is storage bookkeeping, not a byte budget: it is the larger of any
    /// up-front `input_capacity_max` reservation and every input length
    /// `iterate` has reserved for.
    pub fn inputCapacity(self: *const TapeRecordParser) usize {
        return self.storage.capacity;
    }

    /// Indexes `input` and returns an iterator over its records under a new
    /// document lease.
    ///
    /// The input is borrowed: it must outlive the iterator, every record it
    /// returns, every cursor made from those, and every raw span they hand
    /// back. On success the previous document's records and cursors are
    /// invalidated, because their generation no longer matches.
    ///
    /// Structural storage is reserved before indexing, so a call that then
    /// fails still leaves the parser resized and takes no lease.
    ///
    /// Fails with `error.DocumentActive` while a lease is live,
    /// `error.CapacityExceeded` when `input` exceeds a non-zero
    /// `input_capacity_max`, `error.InputTooLarge` past the `u32` offset
    /// boundary, and `error.OutOfMemory` or `error.CapacityOverflow` when the
    /// buffer cannot be reserved.
    pub fn iterate(
        self: *TapeRecordParser,
        input: []const u8,
    ) (TapeRecordError || error{DocumentActive})!TapeRecordIterator {
        if (self.state.active) return error.DocumentActive;
        if (input.len > std.math.maxInt(u32)) return error.InputTooLarge;
        if (self.options.input_capacity_max != 0 and
            input.len > self.options.input_capacity_max)
        {
            return error.CapacityExceeded;
        }

        try self.storage.reserve(input.len);
        const count = indexJsonlInto(
            simd.default_vector_len,
            self.storage.indexes[0 .. self.storage.indexes.len - sentinel_count],
            input,
        ) catch |err| switch (err) {
            error.InputTooLarge => return error.InputTooLarge,
            error.CapacityExceeded => return error.CapacityExceeded,
            error.NonContiguousInput => unreachable,
        };
        try self.storage.finish(count, input.len);
        self.input = input;
        self.tape_len = 0;
        self.nextRecordGeneration();

        const lease = try self.state.begin();
        errdefer lease.release();
        const guard = try lease.claim();
        return .{
            .parser = self,
            .lease = lease,
            .guard = guard,
            .record_iterator = RecordIterator.init(
                input,
                self.storage.indexes[0..self.storage.count],
            ),
        };
    }

    fn releaseLease(self: *TapeRecordParser) void {
        self.state.active = false;
        self.state.claimed = false;
        self.state.position = 0;
    }

    fn nextRecordGeneration(self: *TapeRecordParser) void {
        self.record_generation = if (self.record_generation == std.math.maxInt(u64))
            1
        else
            self.record_generation + 1;
    }

    fn invalidateRecord(self: *TapeRecordParser) void {
        self.tape_len = 0;
        self.nextRecordGeneration();
    }

    fn checkRecord(
        self: *const TapeRecordParser,
        lease: resident.Lease,
        generation: u64,
    ) TapeRecordError!void {
        try lease.check();
        if (self.record_generation != generation) {
            return error.OutOfOrderIteration;
        }
    }

    fn recordView(
        self: *TapeRecordParser,
        source: []const u8,
        view: stage2.IndexView,
        record_range: RecordRange,
        record_index: usize,
        lease: resident.Lease,
        generation: u64,
    ) TapeRecordError!TapeRecordResult {
        var tape_allocator: TapeReuseAllocator = .{ .parser = self };
        const document = stage2.buildTapeView(
            tape_allocator.allocator(),
            source,
            view,
            .json,
        ) catch |err| switch (err) {
            error.OutOfMemory => {
                if (tape_allocator.denied) return error.CapacityExceeded;
                return error.OutOfMemory;
            },
            error.TapeTooLarge => return error.TapeTooLarge,
            error.InvalidStructuralIndex => return error.InvalidStructuralIndex,
            else => {
                const diagnostic = try self.validateRecord(source, view);
                if (diagnostic) |value| {
                    return .{ .diagnostic = globalRecordDiagnostic(
                        self.input,
                        record_range,
                        record_index,
                        value,
                    ) };
                }
                return error.InvalidStructuralIndex;
            },
        };
        self.tape_len = document.tape.len;
        return .{
            .record = .{
                .parser = self,
                .lease = lease,
                .generation = generation,
                .record_index = record_index,
                .source = source,
                .source_start = record_range.source_start,
                .source_end = record_range.source_end,
                .tape_start = 0,
                .tape_end = document.tape.len,
            },
        };
    }
    fn validateRecord(
        self: *TapeRecordParser,
        source: []const u8,
        view: stage2.IndexView,
    ) TapeRecordError!?stage2.Diagnostic {
        // Reader setup only checks the index view; next() reports syntax failures.
        var reader = if (self.reader) |*existing| blk: {
            existing.reset(source, view, .json) catch |err| return @errorCast(err);
            break :blk existing;
        } else blk: {
            self.reader = stage2.TokenReader.init(source, view, .json) catch |err| return @errorCast(err);
            break :blk &self.reader.?;
        };
        while (true) {
            const token = reader.next() catch |err| {
                if (err == error.TapeTooLarge) return error.TapeTooLarge;
                if (err == error.InvalidStructuralIndex) {
                    return error.InvalidStructuralIndex;
                }
                return stage2.diagnosticAt(
                    source,
                    @errorCast(err),
                    reader.failure_offset,
                );
            };
            if (token == null) return null;
        }
    }
};

const TapeReuseAllocator = struct {
    parser: *TapeRecordParser,
    denied: bool = false,

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = std.mem.Allocator.noResize,
        .remap = std.mem.Allocator.noRemap,
        .free = std.mem.Allocator.noFree,
    };

    fn allocator(self: *TapeReuseAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn alloc(
        context: *anyopaque,
        byte_len: usize,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) ?[*]u8 {
        const self: *TapeReuseAllocator = @ptrCast(@alignCast(context));
        if (byte_len % @sizeOf(stage2.TapeWord) != 0) return null;
        const word_count = byte_len / @sizeOf(stage2.TapeWord);
        if (self.parser.options.tape_capacity_max != 0 and
            word_count > self.parser.options.tape_capacity_max)
        {
            self.denied = true;
            return null;
        }

        if (word_count <= self.parser.tape_storage.len and word_count != 0) {
            return @ptrCast(self.parser.tape_storage.ptr);
        }
        if (word_count == 0) return null;

        const byte_ptr = self.parser.allocator.rawAlloc(
            byte_len,
            alignment,
            return_address,
        ) orelse return null;
        const tape_ptr: [*]stage2.TapeWord = @ptrCast(@alignCast(byte_ptr));
        const new_storage = tape_ptr[0..word_count];
        const old_storage = self.parser.tape_storage;
        self.parser.tape_storage = new_storage;
        if (old_storage.len != 0) {
            self.parser.allocator.rawFree(
                @as([*]u8, @ptrCast(old_storage.ptr))[0 .. old_storage.len * @sizeOf(stage2.TapeWord)],
                .of(stage2.TapeWord),
                return_address,
            );
        }
        return byte_ptr;
    }
};

/// A borrowed reusable JSONL record: a window into the shared high-water tape
/// plus the record's source span.
///
/// The record owns nothing. `source` borrows the input given to `iterate`, and
/// `tape_start`..`tape_end` index the parser's shared tape, which the next
/// `next` call invalidates and which a larger record reallocates. Copies are
/// not independent: every accessor re-checks the lease, the record generation,
/// the source identity, and the current tape bounds, and reports an error
/// rather than reading a stale tape.
pub const TapeRecord = struct {
    /// The parser owning the shared tape and the lease state.
    parser: *TapeRecordParser,
    /// The document lease this record was produced under.
    lease: resident.Lease,
    /// Record generation at production; see `TapeRecordParser`.
    generation: u64,
    /// Ordinal of this record among the accepted records.
    record_index: usize,
    /// Borrowed record bytes from the input given to `iterate`.
    source: []const u8,
    /// Half-open start of this record in that input.
    source_start: usize,
    /// Half-open end in that input, excluding the terminating LF.
    source_end: usize,
    /// Half-open range in `parser.tape_storage`; always starts at `0`,
    /// because the high-water tape is reused from its beginning.
    tape_start: usize,
    /// One past this record's last tape word.
    tape_end: usize,

    /// A checked cursor over this record's tape and source.
    ///
    /// The cursor borrows the shared tape, so it is invalidated exactly like
    /// the record. Before any navigation it re-checks the lease and
    /// generation, then the source identity and tape bounds, and reports
    /// `error.DocumentReleased`, `error.OutOfOrderIteration`,
    /// `error.SourceOutOfBounds`, or `error.TapeOutOfBounds`; only then does it
    /// raise the `stage2.NavigationError` tags `stage2.Document.root` defines.
    pub fn root(self: *const TapeRecord) TapeRecordError!TapeRecordCursor {
        try self.check();
        const words = self.parser.tape_storage[self.tape_start..self.tape_end];
        const document: stage2.Document = .{ .tape = words, .dialect = .json };
        const base_cursor = try document.root(self.source);
        return .{
            .parser = self.parser,
            .lease = self.lease,
            .generation = self.generation,
            .cursor = base_cursor,
        };
    }

    /// Equivalent to `root`.
    pub fn cursor(self: *const TapeRecord) TapeRecordError!TapeRecordCursor {
        return self.root();
    }

    /// This record's tape words, checked against the lease, the generation, the
    /// source identity, and the current tape bounds.
    ///
    /// The slice aliases the parser's high-water tape, so the next `next` call
    /// and any later record that grows that tape both invalidate it. The
    /// failure tags are the four named on `root`.
    pub fn tapeWords(self: *const TapeRecord) TapeRecordError![]const stage2.TapeWord {
        try self.check();
        return self.parser.tape_storage[self.tape_start..self.tape_end];
    }

    fn check(self: *const TapeRecord) TapeRecordError!void {
        try self.parser.checkRecord(self.lease, self.generation);

        if (self.source_start > self.source_end or
            self.source_end > self.parser.input.len)
        {
            return error.SourceOutOfBounds;
        }
        const expected_source = self.parser.input[self.source_start..self.source_end];
        if (expected_source.ptr != self.source.ptr or
            expected_source.len != self.source.len)
        {
            return error.SourceOutOfBounds;
        }

        if (self.tape_start > self.tape_end or
            self.tape_end > self.parser.tape_len or
            self.tape_end > self.parser.tape_storage.len)
        {
            return error.TapeOutOfBounds;
        }
    }
};

/// A checked cursor over a borrowed reusable record tape.
///
/// Every method re-checks the lease and record generation before reading, so a
/// cursor kept across an iterator advance reports
/// `error.OutOfOrderIteration` and one kept past a reset, an iterator
/// `deinit`, or a parser `deinit` reports `error.DocumentReleased`. Positions,
/// skipping, and raw slices are the ones `stage2.TapeCursor` documents; the
/// raw slices borrow the record source and stay valid as long as that input
/// does.
///
/// A cursor is an independent position over the shared tape rather than a view
/// of a separate one: copies do not interfere, each keeps the position it was
/// copied at, no stable address is required, and every copy is still checked
/// against the same lease and generation.
pub const TapeRecordCursor = struct {
    /// The parser owning the shared tape.
    parser: *TapeRecordParser,
    /// The lease the originating record was produced under.
    lease: resident.Lease,
    /// Record generation the originating record was produced at.
    generation: u64,
    /// The cursor over this record's tape words.
    cursor: stage2.TapeCursor,

    /// The tape word at this position; see `stage2.TapeCursor.peek`.
    pub fn peek(self: *const TapeRecordCursor) TapeRecordError!stage2.TapeWord {
        try self.check();
        return self.cursor.peek();
    }

    /// Moves to the next tape word; see `stage2.TapeCursor.advance`.
    pub fn advance(self: *TapeRecordCursor) TapeRecordError!void {
        try self.check();
        try self.cursor.advance();
    }

    /// Skips the scalar or container subtree at this position; see
    /// `stage2.TapeCursor.skipValue`.
    pub fn skipValue(self: *TapeRecordCursor) TapeRecordError!void {
        try self.check();
        try self.cursor.skipValue();
    }

    /// The tape index at this position, or a check failure first.
    pub fn position(self: *const TapeRecordCursor) TapeRecordError!usize {
        try self.check();
        return self.cursor.position();
    }

    /// The element count of the container at this position; see
    /// `stage2.TapeCursor.containerCount`.
    pub fn containerCount(self: *const TapeRecordCursor) TapeRecordError!u32 {
        try self.check();
        return self.cursor.containerCount();
    }

    /// A second checked cursor at the container's opening word; see
    /// `stage2.TapeCursor.matchingStart`.
    pub fn matchingStart(self: *const TapeRecordCursor) TapeRecordError!TapeRecordCursor {
        try self.check();
        return .{
            .parser = self.parser,
            .lease = self.lease,
            .generation = self.generation,
            .cursor = try self.cursor.matchingStart(),
        };
    }

    /// The still-escaped string or key content, or the complete scalar source,
    /// borrowed from the record; see `stage2.TapeCursor.rawValue`.
    pub fn rawValue(self: *const TapeRecordCursor) TapeRecordError![]const u8 {
        try self.check();
        return self.cursor.rawValue();
    }

    fn check(self: *const TapeRecordCursor) TapeRecordError!void {
        try self.parser.checkRecord(self.lease, self.generation);
    }
};

/// A checked iterator over one JSONL document's records.
///
/// The iterator holds the document lease and the single focus, and `deinit`
/// releases both. At most one record is current: `next` invalidates the
/// previous record and every cursor made from it before it builds the next.
pub const TapeRecordIterator = struct {
    /// The parser owning the shared tape and the structural index.
    parser: *TapeRecordParser,
    /// The document lease taken by `iterate`.
    lease: resident.Lease,
    /// The single-focus, ordered-access guard over that lease.
    guard: resident.Guard,
    /// Walks the global structural offsets, skipping blank records.
    record_iterator: RecordIterator,
    /// Accepted records returned so far; a `.diagnostic` does not count.
    record_index: usize = 0,
    /// Set once `next` has returned `null` or failed; no row is left to read.
    finished: bool = false,

    /// The next record, the first defect, or `null` at end of input.
    ///
    /// The lease and generation are checked before anything else, so a copy of
    /// this iterator that fell behind reports `error.OutOfOrderIteration`
    /// instead of silently skipping a record.
    ///
    /// A `.record` result borrows the shared tape and is valid until the next
    /// call, so keep only one record and its cursors at a time. A
    /// `.diagnostic` result is a self-contained value and ends the iteration:
    /// this and every later call return `null`. An error return ends it the
    /// same way, and the tag is not repeated — only the lease and generation
    /// checks still report on a stale copy.
    pub fn next(self: *TapeRecordIterator) TapeRecordError!?TapeRecordResult {
        try self.guard.check();
        if (self.finished) return null;
        try self.guard.advance();
        self.parser.invalidateRecord();

        const record_range = self.record_iterator.next() catch |err| {
            self.finished = true;
            return err;
        } orelse {
            self.finished = true;
            return null;
        };
        const record_source =
            self.parser.input[record_range.source_start..record_range.source_end];
        const view = stage2.IndexView.init(
            record_source,
            self.parser.storage.indexes[record_range.index_start..record_range.index_end],
            @intCast(record_range.source_start),
        ) catch |err| {
            self.finished = true;
            return err;
        };

        const generation = self.parser.record_generation;
        const result = self.parser.recordView(
            record_source,
            view,
            record_range,
            self.record_index,
            self.lease,
            generation,
        ) catch |err| {
            self.finished = true;
            return err;
        };
        switch (result) {
            .diagnostic => self.finished = true,
            .record => self.record_index += 1,
        }
        return result;
    }

    /// Accepted records returned so far.
    ///
    /// On a `.diagnostic` result this is the failing record's ordinal, which
    /// matches `JsonlDiagnostic.record_index`.
    pub fn recordCount(self: *const TapeRecordIterator) usize {
        return self.record_index;
    }

    /// Invalidates the current record, releases the lease, and drops the focus.
    ///
    /// A stale iterator's `deinit` is ignored rather than releasing a newer
    /// lease, so this is safe on every path while the parser is still alive.
    /// After `TapeRecordParser.deinit` the lease it holds points at released
    /// storage, so no method here may be called at all. The iterator is
    /// unusable once this returns and a second call is invalid.
    pub fn deinit(self: *TapeRecordIterator) void {
        if (self.guard.check()) |_| {
            self.parser.invalidateRecord();
            self.lease.release();
        } else |_| {}
        self.* = undefined;
    }
};

fn globalRecordDiagnostic(
    input: []const u8,
    record_range: RecordRange,
    record_index: usize,
    local: stage2.Diagnostic,
) JsonlDiagnostic {
    const record_len = record_range.source_end - record_range.source_start;
    const global_offset = record_range.source_start + @min(local.byte_offset, record_len);
    const global = stage2.diagnosticAt(input, local.err, global_offset);
    return .{
        .record_index = record_index,
        .source_start = record_range.source_start,
        .source_end = record_range.source_end,
        .err = global.err,
        .byte_offset = global.byte_offset,
        .line = global.line,
        .column = global.column,
        .snippet = global.snippet,
        .snippet_start = global.snippet_start,
    };
}

/// The record a JSONL reader is currently inside, reached through `active`.
///
/// Owns nothing. `source` borrows the caller's original document bytes; `view`
/// borrows offsets from the parser's index storage. Clearing `active` does not
/// free either buffer. Keep the source alive and unchanged, and do not use the
/// view after parser reuse, storage replacement or deinitialization.
/// Copies retain those same borrows and independent value fields. Neither
/// copying nor modifying a snapshot moves the reader that produced it.
const ActiveRecord = struct {
    /// The record's byte and index bounds.
    range: RecordRange,
    /// The record's bytes, borrowed from the reader's document input.
    source: []const u8,
    /// The record's structural offsets, borrowed from the parser's storage.
    view: stage2.IndexView,
};

/// A lazy event walk over one `OnDemandDocument`.
///
/// The reader stores a pointer to the document and reaches the source and the
/// parser's index storage only through it, so `document` must stay alive and
/// unmoved for as long as the reader is used. The reader itself holds the
/// document's single focus and an ordered-access guard: a copy left behind
/// reports `error.OutOfOrderIteration` while the copy that advanced keeps
/// going, and use after the document's `deinit` reports
/// `error.DocumentReleased`. Nothing stores a pointer to the reader, so its own
/// address need not be stable.
///
/// There is no `deinit`: the focus is released when the `OnDemandDocument` is
/// released.
///
/// The first failure is latched, so every later call returns the same tag
/// without reading more input. Events borrow the document's `input` and stay
/// valid as long as it does.
pub const EventReader = struct {
    /// The leased document being walked. It borrows the source and the parser's
    /// index storage; the reader owns no part of either.
    document: *OnDemandDocument,
    /// The single-focus, ordered-access guard over the document's lease.
    guard: resident.Guard,
    /// Walks the global structural offsets, skipping blank records.
    record_iterator: RecordIterator,
    /// The record currently being read, or `null` between records.
    active: ?ActiveRecord = null,
    /// Reusable token reader for the active record.
    reader: ?stage2.TokenReader = null,
    /// Ordinal of the record being read.
    record_index: usize = 0,
    /// Event buffered by `peek` and returned by the next `next`.
    cache: ?Event = null,
    /// Set once the document has been read to its end.
    cache_eof: bool = false,
    /// The first failure, latched for every later call.
    failure: ?stage2.ReaderError = null,
    /// Global offset reached by the most recent token read, or by the latched
    /// failure.
    failure_offset: usize = 0,
    /// Global byte position reached by the most recent token read.
    byte_position: usize = 0,
    /// Position in the structural index reached by the most recent token read.
    structural_position: usize = 0,

    fn init(document: *OnDemandDocument, guard: resident.Guard) EventReader {
        return .{
            .document = document,
            .guard = guard,
            .record_iterator = RecordIterator.init(document.input, document.indexes),
        };
    }

    /// The next event, or `null` at end of input.
    ///
    /// Each event returned consumes the focus position, so a caller must read
    /// in order; an event buffered by `peek` is returned first.
    pub fn next(self: *EventReader) !?Event {
        try self.guard.check();
        if (self.failure) |err| return err;
        if (self.cache) |event| {
            self.cache = null;
            try self.guard.advance();
            return event;
        }
        if (self.cache_eof) return null;

        const event = self.readNext() catch |err| {
            self.failure = err;
            return err;
        };
        if (event) |value| {
            try self.guard.advance();
            return value;
        }
        self.cache_eof = true;
        return null;
    }

    /// The next event without consuming it, or `null` at end of input.
    ///
    /// The event is buffered and returned by the next `next`, so repeated
    /// `peek` calls report the same event.
    pub fn peek(self: *EventReader) !?Event {
        try self.guard.check();
        if (self.failure) |err| return err;
        if (self.cache) |event| return event;
        if (self.cache_eof) return null;

        const event = self.readNext() catch |err| {
            self.failure = err;
            return err;
        };
        if (event) |value| {
            self.cache = value;
            return value;
        }
        self.cache_eof = true;
        return null;
    }

    /// Consumes the next event, or the whole subtree or record it opens.
    ///
    /// Returns `error.UnexpectedEnd` when the input ends inside a container or
    /// a record.
    pub fn skip(self: *EventReader) !void {
        const first = try self.next() orelse return;
        switch (first.kind) {
            .record_start => {
                while (true) {
                    const event = try self.next() orelse return error.UnexpectedEnd;
                    if (event.kind == .record_end) break;
                }
            },
            .object_start, .array_start => {
                var depth: usize = 1;
                while (depth > 0) {
                    const event = try self.next() orelse return error.UnexpectedEnd;
                    switch (event.kind) {
                        .object_start, .array_start => depth += 1,
                        .object_end, .array_end => depth -= 1,
                        else => {},
                    }
                }
            },
            else => {},
        }
    }

    fn readNext(self: *EventReader) stage2.ReaderError!?Event {
        if (self.active == null) {
            const range = try self.record_iterator.next() orelse return null;
            const source = self.document.input[range.source_start..range.source_end];
            const view = stage2.IndexView.init(
                source,
                self.document.indexes[range.index_start..range.index_end],
                @intCast(range.source_start),
            ) catch return error.InvalidStructuralIndex;
            if (self.reader) |*existing| {
                try existing.reset(source, view, .json);
            } else {
                self.reader = try stage2.TokenReader.init(source, view, .json);
            }
            self.active = .{
                .range = range,
                .source = source,
                .view = view,
            };
            return .{
                .kind = .record_start,
                .record_index = @intCast(self.record_index),
                .offset = @intCast(range.source_start),
                .raw = source,
            };
        }

        const active = &self.active.?;
        // `self.active` is only set together with `self.reader`, so reaching
        // here with a live record means the reader exists too.
        const reader = if (self.reader) |*value| value else return error.InvalidStructuralIndex;
        const parsed = reader.next() catch |err| {
            self.failure_offset = active.range.source_start + reader.failure_offset;
            self.byte_position = active.range.source_start + reader.byte_position;
            self.structural_position = reader.structural_position;
            return err;
        };
        if (parsed) |token| {
            self.failure_offset = active.range.source_start + reader.failure_offset;
            self.byte_position = active.range.source_start + reader.byte_position;
            self.structural_position = reader.structural_position;
            return parsedTokenEvent(token, active.range, self.record_index);
        }
        const range = active.range;
        self.active = null;
        self.record_index += 1;
        return .{
            .kind = .record_end,
            .record_index = @intCast(self.record_index - 1),
            .offset = @intCast(range.source_end),
            .raw = self.document.input[range.source_end..range.source_end],
        };
    }
};

/// A lazy token walk over one `OnDemandDocument`.
///
/// The cursor stores a pointer to the document and reaches the source and the
/// parser's index storage only through it, so `document` must stay alive and
/// unmoved for as long as the cursor is used. It holds the document's single
/// focus and an ordered-access guard with the same copy, release, and
/// latched-failure rules `EventReader` documents, and nothing stores a pointer
/// to the cursor, so its own address need not be stable.
///
/// It has no `deinit`: the focus is released when the `OnDemandDocument` is
/// released.
pub const TokenCursor = struct {
    /// The leased document being walked. It borrows the source and the parser's
    /// index storage; the cursor owns no part of either.
    document: *OnDemandDocument,
    /// The single-focus, ordered-access guard over the document's lease.
    guard: resident.Guard,
    /// Walks the global structural offsets, skipping blank records.
    record_iterator: RecordIterator,
    /// The record currently being read, or `null` between records.
    active: ?ActiveRecord = null,
    /// Reusable token reader for the active record.
    reader: ?stage2.TokenReader = null,
    /// Ordinal of the record being read.
    record_index: usize = 0,
    /// Event buffered by `peek` and returned by the next `advance`.
    cache: ?Event = null,
    /// Set once the document has been read to its end.
    cache_eof: bool = false,
    /// The first failure, latched for every later call.
    failure: ?stage2.ReaderError = null,
    /// Global offset reached by the most recent token read, or by the latched
    /// failure.
    failure_offset: usize = 0,
    /// Global byte position reached by the most recent token read.
    byte_position: usize = 0,
    /// Position in the structural index reached by the most recent token read.
    structural_position: usize = 0,

    fn init(document: *OnDemandDocument, guard: resident.Guard) TokenCursor {
        return .{
            .document = document,
            .guard = guard,
            .record_iterator = RecordIterator.init(document.input, document.indexes),
        };
    }

    /// The next event without consuming it, or `null` at end of input.
    ///
    /// The event is buffered and returned by the next `advance`, so repeated
    /// `peek` calls report the same event.
    pub fn peek(self: *TokenCursor) !?Event {
        try self.guard.check();
        if (self.failure) |err| return err;
        if (self.cache) |token| return token;
        if (self.cache_eof) return null;

        const token = self.readNext() catch |err| {
            self.failure = err;
            return err;
        };
        if (token) |value| {
            self.cache = value;
            return value;
        }
        self.cache_eof = true;
        return null;
    }

    /// The next event and consumes it, or `null` at end of input.
    ///
    /// An event buffered by `peek` is returned first, and the focus advances
    /// exactly once either way.
    pub fn advance(self: *TokenCursor) !?Event {
        try self.guard.check();
        if (self.failure) |err| return err;
        if (self.cache) |token| {
            self.cache = null;
            try self.guard.advance();
            return token;
        }
        if (self.cache_eof) return null;

        const token = self.readNext() catch |err| {
            self.failure = err;
            return err;
        };
        if (token) |value| {
            try self.guard.advance();
            return value;
        }
        self.cache_eof = true;
        return null;
    }

    /// Consumes the next event, or the whole subtree or record it opens.
    ///
    /// A `.record_end` event is consumed and returns. Returns
    /// `error.UnexpectedEnd` when the input ends inside a container or a
    /// record.
    pub fn skipChild(self: *TokenCursor) !void {
        const first = try self.advance() orelse return;
        switch (first.kind) {
            .record_start => {
                while (try self.advance()) |event| {
                    if (event.kind == .record_end) return;
                }
                return error.UnexpectedEnd;
            },
            .record_end => return,
            .object_start, .array_start => {
                var depth: usize = 1;
                while (depth > 0) {
                    const token = try self.advance() orelse return error.UnexpectedEnd;
                    switch (token.kind) {
                        .object_start, .array_start => depth += 1,
                        .object_end, .array_end => depth -= 1,
                        else => {},
                    }
                }
            },
            else => {},
        }
    }

    fn readNext(self: *TokenCursor) stage2.ReaderError!?Event {
        if (self.active == null) {
            const range = try self.record_iterator.next() orelse return null;
            const source = self.document.input[range.source_start..range.source_end];
            const view = stage2.IndexView.init(
                source,
                self.document.indexes[range.index_start..range.index_end],
                @intCast(range.source_start),
            ) catch return error.InvalidStructuralIndex;
            if (self.reader) |*existing| {
                try existing.reset(source, view, .json);
            } else {
                self.reader = try stage2.TokenReader.init(source, view, .json);
            }
            self.active = .{
                .range = range,
                .source = source,
                .view = view,
            };
            return .{
                .kind = .record_start,
                .record_index = @intCast(self.record_index),
                .offset = @intCast(range.source_start),
                .raw = source,
            };
        }

        const active = &self.active.?;
        // `self.active` is only set together with `self.reader`, so reaching
        // here with a live record means the reader exists too.
        const reader = if (self.reader) |*value| value else return error.InvalidStructuralIndex;
        const parsed = reader.next() catch |err| {
            self.failure_offset =
                active.range.source_start + reader.failure_offset;
            self.byte_position =
                active.range.source_start + reader.byte_position;
            self.structural_position = reader.structural_position;
            return err;
        };
        if (parsed) |token| {
            self.failure_offset =
                active.range.source_start + reader.failure_offset;
            self.byte_position =
                active.range.source_start + reader.byte_position;
            self.structural_position = reader.structural_position;
            return parsedTokenEvent(token, active.range, self.record_index);
        }

        const range = active.range;
        self.active = null;
        self.record_index += 1;
        return .{
            .kind = .record_end,
            .record_index = @intCast(self.record_index - 1),
            .offset = @intCast(range.source_end),
            .raw = self.document.input[range.source_end..range.source_end],
        };
    }
};

fn parsedTokenEvent(
    token: stage2.ParsedToken,
    range: RecordRange,
    record_index: usize,
) Event {
    const local_offset: usize = @intCast(token.word.offset);
    const kind: EventKind = switch (token.word.tapeKind()) {
        .object_start => .object_start,
        .object_end => .object_end,
        .array_start => .array_start,
        .array_end => .array_end,
        .key => .key,
        .string => .string,
        .number => .number,
        .true_literal => .true_literal,
        .false_literal => .false_literal,
        .null_literal => .null_literal,
    };
    return .{
        .kind = kind,
        .record_index = @intCast(record_index),
        .offset = @intCast(range.source_start + local_offset),
        .raw = token.raw,
    };
}

/// Builds an owned validated tape for every nonblank JSONL record.
///
/// The returned `JsonlDocument` owns the record array and one tape per record
/// and stores no allocator, so the caller releases all of them once with
/// `document.deinit(allocator)` while that backing is still alive. `input` is
/// only borrowed and must outlive the document, its records, and their cursors
/// and raw slices. No error path leaves the caller owning anything. Stage 1
/// failures other than `error.OutOfMemory` arrive as `error.TapeTooLarge`, as
/// in the other JSON-family builders.
pub fn buildJsonlTape(
    allocator: std.mem.Allocator,
    input: []const u8,
) stage2.BuildError!JsonlDocument {
    var structural_index = indexJsonl(allocator, input) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return error.TapeTooLarge;
    };
    defer structural_index.deinit(allocator);

    var records = std.ArrayList(JsonlRecord).empty;
    errdefer {
        for (records.items) |*record_value| {
            record_value.deinit(allocator);
        }
        records.deinit(allocator);
    }

    var record_iterator = RecordIterator.init(input, structural_index.slice());
    while (try record_iterator.next()) |record_range| {
        const record_source = input[record_range.source_start..record_range.source_end];
        const base_offset: u32 = @intCast(record_range.source_start);
        const view = try stage2.IndexView.init(
            record_source,
            structural_index.slice()[record_range.index_start..record_range.index_end],
            base_offset,
        );
        var document = try stage2.buildTapeView(allocator, record_source, view, .json);
        records.append(allocator, .{
            .source = record_source,
            .source_start = record_range.source_start,
            .source_end = record_range.source_end,
            .document = document,
        }) catch |err| {
            document.deinit(allocator);
            return err;
        };
    }

    return .{
        .input = input,
        .records = try records.toOwnedSlice(allocator),
    };
}

/// Validates nonblank JSONL records and returns the first global diagnostic.
///
/// Allocates one structural index and releases it before returning, so a
/// successful call leaves nothing to release and builds no tape. `null` means
/// every record is valid strict RFC 8259 JSON; a returned `JsonlDiagnostic`
/// borrows `input` for its `snippet` and reports global byte, line, and column
/// positions plus the failing record's ordinal and span. Stage 1 failures
/// arrive as `error.TapeTooLarge`, as in `buildJsonlTape`.
pub fn validateJsonl(
    allocator: std.mem.Allocator,
    input: []const u8,
) stage2.ValidationError!?JsonlDiagnostic {
    var structural_index = indexJsonl(allocator, input) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return error.TapeTooLarge;
    };
    defer structural_index.deinit(allocator);

    var record_iterator = RecordIterator.init(input, structural_index.slice());
    var record_index: usize = 0;
    while (try record_iterator.next()) |record_range| : (record_index += 1) {
        const record_source = input[record_range.source_start..record_range.source_end];
        const base_offset: u32 = @intCast(record_range.source_start);
        const view = try stage2.IndexView.init(
            record_source,
            structural_index.slice()[record_range.index_start..record_range.index_end],
            base_offset,
        );
        const diagnostic = try stage2.validateView(record_source, view, .json);
        if (diagnostic) |local| {
            const global_offset = record_range.source_start + @min(
                local.byte_offset,
                record_range.source_end - record_range.source_start,
            );
            const global = stage2.diagnosticAt(input, local.err, global_offset);
            return .{
                .record_index = record_index,
                .source_start = record_range.source_start,
                .source_end = record_range.source_end,
                .err = global.err,
                .byte_offset = global.byte_offset,
                .line = global.line,
                .column = global.column,
                .snippet = global.snippet,
                .snippet_start = global.snippet_start,
            };
        }
    }
    return null;
}

/// Bounds of one JSONL record, reached through `active.range`.
///
/// Every field is a count: `source_start` and `source_end` are byte offsets
/// into the document input and `index_start` and `index_end` are slot positions
/// in the global structural index, both ranges half-open. The type owns nothing
/// and points at nothing; a value read out of `active` is a snapshot, and the
/// ranges the walk produces later are unrelated to it. Copies are independent
/// values with no stable address required, and writing one changes nothing for
/// the reader that produced it.
const RecordRange = struct {
    /// Byte offset of the record's first byte in the document input.
    source_start: usize,
    /// Byte offset one past the record's last byte, excluding its LF.
    source_end: usize,
    /// Slot index of the record's first structural offset.
    index_start: usize,
    /// Slot index one past the record's last structural offset.
    index_end: usize,
};

/// The positional walk over one document's structural offsets, reached through
/// `record_iterator`.
///
/// The type owns nothing: `input` is the borrowed source and `offsets` are
/// borrowed from the parser's index storage, both handed over by the reader
/// that holds the walk. Records are cut at the LF bytes `offsets` contains and
/// at any trailing remainder that has no LF; a run made only of spaces, tabs,
/// and CR is skipped rather than yielded, and `finished` marks that no record
/// is left.
///
/// Position fields count bytes or index slots and default to `0`. Copies walk
/// independently from the copied position over the same borrowed data; neither
/// advances the other. No stable address is required.
const RecordIterator = struct {
    /// Whole borrowed source the offsets index into.
    input: []const u8,
    /// Structural offsets, borrowed from the parser's index storage.
    offsets: []const u32,
    /// Byte offset where the next record would start.
    source_start: usize = 0,
    /// Slot index where the next record's offsets would start.
    index_start: usize = 0,
    /// Offset slot already consumed by the walk.
    offset_position: usize = 0,
    /// Set once the walk has yielded its last record or run out of input.
    finished: bool = false,

    fn init(input: []const u8, offsets: []const u32) RecordIterator {
        return .{ .input = input, .offsets = offsets };
    }

    fn next(self: *RecordIterator) !?RecordRange {
        while (true) {
            if (self.offset_position < self.offsets.len) {
                const offset_position = self.offset_position;
                const offset: usize = @intCast(self.offsets[offset_position]);
                self.offset_position += 1;
                if (offset >= self.input.len) continue;
                if (self.input[offset] != '\n') continue;

                const record: RecordRange = .{
                    .source_start = self.source_start,
                    .source_end = offset,
                    .index_start = self.index_start,
                    .index_end = offset_position,
                };
                self.source_start = offset + 1;
                self.index_start = self.offset_position;
                if (isBlankRecord(self.input[record.source_start..record.source_end])) {
                    continue;
                }
                return record;
            }

            if (self.finished or self.source_start >= self.input.len) {
                self.finished = true;
                return null;
            }

            const record: RecordRange = .{
                .source_start = self.source_start,
                .source_end = self.input.len,
                .index_start = self.index_start,
                .index_end = self.offset_position,
            };
            self.finished = true;
            if (isBlankRecord(self.input[record.source_start..record.source_end])) {
                return null;
            }
            return record;
        }
    }
};

fn isBlankRecord(source: []const u8) bool {
    for (source) |byte| {
        switch (byte) {
            ' ', '\t', '\r' => {},
            else => return false,
        }
    }
    return true;
}

const testing = std.testing;
const sentinel_count: usize = 3;

/// Owns the absolute `u32` offsets of every JSONL structural byte, atom start,
/// and record-separator LF in `input`, plus the three trailing sentinel slots.
///
/// The result owns its allocation and is released once with
/// `index.deinit(allocator)`; it holds no bytes of `input`, which may be
/// released as soon as this returns. A copy names the same allocation and is
/// not a second owner. Fails with `error.OutOfMemory`,
/// `error.CapacityOverflow`, or `error.InputTooLarge` when `input` exceeds the
/// `u32` offset boundary.
pub fn indexJsonl(
    allocator: std.mem.Allocator,
    input: []const u8,
) !stage1.StructuralIndex {
    return indexJsonlImpl(simd.default_vector_len, allocator, input);
}

/// Emits JSONL structural offsets directly into caller-owned storage.
///
/// The returned count excludes sentinels. `out` is unchanged beyond that
/// prefix. Record-separator LF bytes are emitted only outside quoted strings.
/// The checked sink reports `error.CapacityExceeded` the moment `out` is full,
/// so on that error `out` holds an unknown-length prefix of the offsets and
/// no count is returned; discard or recompute it rather than read a partial
/// result. `error.InputTooLarge` when `input` exceeds the `u32` offset
/// boundary. `vlen` is the SIMD width and must be at least 4.
pub fn indexJsonlInto(
    comptime vlen: usize,
    out: []u32,
    input: []const u8,
) !usize {
    if (input.len > std.math.maxInt(u32)) return error.InputTooLarge;

    var sink: IndexSink = .{ .out = out };
    var lexical_state: json_lexical.State = .{};
    try json_lexical.feed(
        vlen,
        .jsonl,
        &lexical_state,
        input,
        0,
        &sink,
    );
    try json_lexical.finish(.jsonl, &lexical_state, &sink);
    return sink.count;
}

/// `indexJsonl` at an explicit SIMD width.
///
/// `vlen` is the bytes-per-vector width the scanner and the bit-index
/// extractor are instantiated at, and must be at least 4. Ownership, the
/// sentinel slots, and the errors are `indexJsonl`'s.
pub fn indexJsonlImpl(
    comptime vlen: usize,
    allocator: std.mem.Allocator,
    input: []const u8,
) !stage1.StructuralIndex {
    var indexes = try stage1.StructuralIndex.init(allocator, input.len);
    errdefer indexes.deinit(allocator);

    indexes.count = indexJsonlInto(
        vlen,
        indexes.indexes[0 .. indexes.indexes.len - sentinel_count],
        input,
    ) catch |err| switch (err) {
        error.CapacityExceeded, error.NonContiguousInput => unreachable,
        error.InputTooLarge => return error.InputTooLarge,
    };
    try indexes.finish(input.len);
    return indexes;
}

const IndexSink = struct {
    out: []u32,
    count: usize = 0,

    pub fn appendOffset(self: *IndexSink, offset: usize) !void {
        if (offset > std.math.maxInt(u32)) return error.InputTooLarge;
        if (self.count >= self.out.len) return error.CapacityExceeded;

        self.out[self.count] = @intCast(offset);
        self.count += 1;
    }

    pub fn appendMask(
        self: *IndexSink,
        comptime T: type,
        mask: T,
        base_offset: usize,
    ) !void {
        if (self.count > self.out.len) return error.CapacityExceeded;
        const appended = try simd.extractBitIndexesChecked(
            T,
            mask,
            base_offset,
            self.out[self.count..],
        );
        self.count += appended;
    }
};

fn scalarIndexJsonl(
    allocator: std.mem.Allocator,
    input: []const u8,
) !stage1.StructuralIndex {
    var result = try stage1.StructuralIndex.init(allocator, input.len);
    errdefer result.deinit(allocator);

    var in_string = false;
    var backslash_run_length: usize = 0;
    var prev_in_atom = false;
    for (input, 0..) |byte, index| {
        const unescaped_quote = byte == '"' and backslash_run_length % 2 == 0;
        if (unescaped_quote) {
            if (!in_string) {
                result.indexes[result.count] = @intCast(index);
                result.count += 1;
            }
            in_string = !in_string;
        }

        if (!in_string) {
            if (isStructuralByte(byte) or byte == '\n') {
                result.indexes[result.count] = @intCast(index);
                result.count += 1;
            } else if (isAtomByte(byte) and !prev_in_atom) {
                result.indexes[result.count] = @intCast(index);
                result.count += 1;
            }
        }

        prev_in_atom = !in_string and byte != '"' and
            !isStructuralByte(byte) and !isWhitespaceByte(byte);
        if (byte == '\\') {
            backslash_run_length += 1;
        } else {
            backslash_run_length = 0;
        }
    }

    try result.finish(input.len);
    return result;
}

fn isWhitespaceByte(byte: u8) bool {
    return switch (byte) {
        ' ', '\t', '\n', '\r' => true,
        else => false,
    };
}

fn isStructuralByte(byte: u8) bool {
    return switch (byte) {
        '{', '}', '[', ']', ':', ',' => true,
        else => false,
    };
}

fn isAtomByte(byte: u8) bool {
    return switch (byte) {
        '-', 't', 'f', 'n', '0'...'9' => true,
        else => false,
    };
}

fn expectValidIndexes(input_length: usize, indexes: []const u32) !void {
    try testing.expect(indexes.len <= input_length);
    for (indexes, 0..) |index, position| {
        const index_usize: usize = @intCast(index);
        try testing.expect(index_usize < input_length);
        if (position > 0) {
            try testing.expect(indexes[position - 1] < index);
        }
    }
}

fn expectMatchesScalar(input: []const u8) !void {
    return expectMatchesScalarAtWidth(simd.default_vector_len, input);
}

fn expectMatchesScalarAtWidth(
    comptime vlen: usize,
    input: []const u8,
) !void {
    var expected = try scalarIndexJsonl(testing.allocator, input);
    defer expected.deinit(testing.allocator);
    try expectValidIndexes(input.len, expected.slice());

    var actual = try indexJsonlImpl(vlen, testing.allocator, input);
    defer actual.deinit(testing.allocator);

    try testing.expectEqualSlices(u32, expected.slice(), actual.slice());
    try expectValidIndexes(input.len, actual.slice());
}

test "indexJsonlImpl matches scalar at 16, 32, and 64 byte widths for record boundaries" {
    const boundary_lengths = [_]usize{
        0, 1, 14, 15, 16, 17, 30, 31, 32, 33, 62, 63, 64, 65, 66,
    };

    inline for ([_]usize{ 16, 32, 64 }) |width| {
        for (boundary_lengths) |length| {
            var boundary_input: [66]u8 = @splat(' ');
            if (length > 0) {
                boundary_input[length - 1] = '\n';
            }
            try expectMatchesScalarAtWidth(width, boundary_input[0..length]);
        }

        var input: [width * 3 + 5]u8 = @splat(' ');
        input[0] = '{';
        input[1] = '0';
        input[2] = '}';
        input[width - 1] = '\n';
        input[width] = '[';
        input[width + 1] = '1';
        input[width + 2] = ']';
        input[2 * width - 1] = '\n';
        input[2 * width] = '"';
        input[2 * width + 1] = '\n';
        input[2 * width + 2] = '"';
        input[2 * width + 3] = ':';
        input[2 * width + 4] = '2';
        input[3 * width] = '\n';
        input[3 * width + 1] = '{';
        input[3 * width + 2] = '}';
        try expectMatchesScalarAtWidth(width, &input);
    }
}

test "indexJsonlImpl matches scalar at 16, 32, and 64 byte widths for string backslash boundaries" {
    const boundary_lengths = [_]usize{
        0, 1, 14, 15, 16, 17, 30, 31, 32, 33, 62, 63, 64, 65, 66,
    };

    inline for ([_]usize{ 16, 32, 64 }) |width| {
        for (boundary_lengths) |length| {
            var boundary_input: [66]u8 = @splat(' ');
            if (length > 0) {
                boundary_input[0] = '[';
            }
            if (length > 1) {
                boundary_input[1] = '"';
            }
            if (length > 2) {
                boundary_input[length - 1] = '"';
            }
            try expectMatchesScalarAtWidth(width, boundary_input[0..length]);
        }

        var run_length: usize = 1;
        while (run_length <= width + 2) : (run_length += 1) {
            var input: [width * 4 + 8]u8 = @splat(' ');
            input[0] = '[';
            input[1] = '"';
            const run_start = width - 1;
            const quote_offset = run_start + run_length;
            for (run_start..quote_offset) |offset| {
                input[offset] = '\\';
            }

            input[quote_offset] = '"';
            var next_offset = quote_offset + 1;
            if (run_length % 2 != 0) {
                input[next_offset] = '"';
                next_offset += 1;
            }
            input[next_offset] = '0';
            input[next_offset + 1] = ']';
            input[next_offset + 2] = '\n';
            try expectMatchesScalarAtWidth(width, input[0 .. next_offset + 3]);
        }

        for ([_]usize{ width - 1, width }) |quote_offset| {
            for (0..10) |backslash_run_length| {
                var input: [width * 2 + 8]u8 = @splat(' ');
                input[0] = '[';
                input[1] = '"';
                const run_start = quote_offset - backslash_run_length;
                for (run_start..quote_offset) |offset| {
                    input[offset] = '\\';
                }

                input[quote_offset] = '"';
                var next_offset = quote_offset + 1;
                if (backslash_run_length % 2 != 0) {
                    input[next_offset] = '"';
                    next_offset += 1;
                }
                input[next_offset] = '0';
                input[next_offset + 1] = ']';
                input[next_offset + 2] = '\n';
                try expectMatchesScalarAtWidth(width, input[0 .. next_offset + 3]);
            }
        }
    }
}

test "indexJsonl handles empty lines, CRLF, and trailing newlines" {
    const cases = [_][]const u8{
        "",
        "\n",
        "\n\n\n",
        "\r\n",
        "\r\n\n",
        "{\"a\":0}\r\n{\"b\":-0}\n\n",
        " \r\n\t\n",
    };

    for (cases) |input| {
        try expectMatchesScalar(input);
    }
}

test "indexJsonl distinguishes newlines inside and outside strings" {
    const input = "{\"text\":\"first\nsecond\r\nthird\"}\r\n\n{\"n\":1}\n";
    try expectMatchesScalar(input);

    var index = try indexJsonl(testing.allocator, input);
    defer index.deinit(testing.allocator);
    try expectValidIndexes(input.len, index.slice());

    const expected = [_]u32{ 0, 1, 7, 8, 29, 31, 32, 33, 34, 37, 38, 39, 40 };
    try testing.expectEqualSlices(u32, &expected, index.slice());
}

test "indexJsonl handles degenerate records and numeric atom starts" {
    const cases = [_][]const u8{
        "\"\"",
        "\"",
        "'",
        "{",
        "}",
        "[",
        "]",
        ":",
        ",",
        "-123.45e+6\n0\r\n-0\n1E10",
    };

    for (cases) |input| {
        try expectMatchesScalar(input);
    }

    const numeric_input = "-123.45e+6\n0\r\n-0\n1E10";
    var index = try indexJsonl(testing.allocator, numeric_input);
    defer index.deinit(testing.allocator);
    try expectValidIndexes(numeric_input.len, index.slice());
}

test "indexJsonl handles alternating backslash runs around chunk boundaries" {
    const boundary_offsets = [_]usize{ 62, 63, 64, 65 };

    for (boundary_offsets) |run_start| {
        for (1..130) |run_length| {
            var input: [260]u8 = @splat(' ');
            input[0] = '[';
            input[1] = '"';
            for (run_start..run_start + run_length) |offset| {
                input[offset] = '\\';
            }

            const quote_offset = run_start + run_length;
            input[quote_offset] = '"';
            var next_offset = quote_offset + 1;
            if (run_length % 2 != 0) {
                input[next_offset] = '"';
                next_offset += 1;
            }
            input[next_offset] = '0';
            input[next_offset + 1] = ']';
            input[next_offset + 2] = '\n';
            try expectMatchesScalar(input[0 .. next_offset + 3]);
        }
    }

    for (boundary_offsets) |quote_offset| {
        for (0..10) |run_length| {
            var input: [100]u8 = @splat(' ');
            input[0] = '[';
            input[1] = '"';
            const run_start = quote_offset - run_length;
            for (run_start..quote_offset) |offset| {
                input[offset] = '\\';
            }

            input[quote_offset] = '"';
            var next_offset = quote_offset + 1;
            if (run_length % 2 != 0) {
                input[next_offset] = '"';
                next_offset += 1;
            }
            input[next_offset] = '0';
            input[next_offset + 1] = ']';
            input[next_offset + 2] = '\n';
            try expectMatchesScalar(input[0 .. next_offset + 3]);
        }
    }
}

test "indexJsonl preserves unterminated string state at boundary EOFs" {
    const lengths = [_]usize{ 62, 63, 64, 65, 66 };
    for (lengths) |length| {
        var input: [66]u8 = @splat(' ');
        input[0] = '"';
        input[length - 1] = '\n';
        try expectMatchesScalar(input[0..length]);
    }
}

test "indexJsonl indexes record boundaries and opening quotes" {
    const input = "{\"a\":1}\n{\"b\":2}\n";
    const expected = [_]u32{ 0, 1, 4, 5, 6, 7, 8, 9, 12, 13, 14, 15 };

    var index = try indexJsonl(testing.allocator, input);
    defer index.deinit(testing.allocator);

    try testing.expectEqualSlices(u32, &expected, index.slice());
    try expectValidIndexes(input.len, index.slice());
}

test "indexJsonl emits one start for each complete numeric atom" {
    const input = "1.2\n3e4\n-5.6e-7\n";
    const expected = [_]u32{ 0, 3, 4, 7, 8, 15 };

    var index = try indexJsonl(testing.allocator, input);
    defer index.deinit(testing.allocator);
    try testing.expectEqualSlices(u32, &expected, index.slice());
    try expectValidIndexes(input.len, index.slice());
}

test "indexJsonl ignores newlines inside strings" {
    try expectMatchesScalar("{\"text\":\"first\nsecond\"}\n{\"n\":null}\n");
}

test "indexJsonl matches scalar reference across SIMD chunks" {
    var input: [132]u8 = @splat(' ');
    input[0] = '[';
    input[1] = '"';
    input[63] = '\\';
    input[64] = '"';
    input[92] = '"';
    input[93] = ']';
    input[94] = '\n';
    input[95] = '{';
    input[96] = '"';
    input[97] = 'n';
    input[98] = '"';
    input[99] = ':';
    input[100] = '0';
    input[101] = '}';
    input[102] = '\n';
    try expectMatchesScalar(&input);
}

test "indexJsonl differential adversarial byte matrix" {
    const alphabet = [_]u8{
        '{',  '}',  '[', ']', ':', ',', '"', '\\', '-', 't', 'f', 'n',

        '0',  '1',  '2', '3', '4', '5', '6', '7',  '8', '9', ' ', '\t',
        '\r', '\n', '.', '+', '/', 'a', 'x',
    };
    const boundary_lengths = [_]usize{
        0, 1, 14, 15, 16, 17, 30, 31, 32, 33, 62, 63, 64, 65, 66,
    };

    inline for ([_]usize{ 16, 32, 64 }) |vlen| {
        var state: u64 = 0xbb67ae8584caa73b;
        var input: [257]u8 = undefined;

        for (0..512) |case_index| {
            const length = if (case_index < boundary_lengths.len)
                boundary_lengths[case_index]
            else
                @as(usize, @intCast(state % 258));

            for (0..length) |offset| {
                state = state *% 0x9e3779b97f4a7c15 +% 0xbb67ae8584caa73b;
                const alphabet_index: usize = @intCast(state % @as(u64, alphabet.len));
                input[offset] = alphabet[alphabet_index];
            }
            try expectMatchesScalarAtWidth(vlen, input[0..length]);
        }
    }
}
test "indexJsonlInto emits the same global offsets as the owned adapter" {
    const input = "{\"a\":\"line\nvalue\"}\r\n2";
    var expected = try indexJsonl(testing.allocator, input);
    defer expected.deinit(testing.allocator);

    var output: [64]u32 = undefined;
    const count = try indexJsonlInto(16, output[0..], input);
    try testing.expectEqual(expected.count, count);
    try testing.expectEqualSlices(u32, expected.slice(), output[0..count]);
}

test "buildJsonlTape keeps records independently cursorable" {
    const input = "{\"a\":1}\n2\nfalse\n";
    var document = try buildJsonlTape(testing.allocator, input);
    defer document.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 3), document.records.len);
    try testing.expectEqualStrings(input[0..7], document.records[0].source);
    try testing.expectEqualStrings(input[8..9], document.records[1].source);
    try testing.expectEqualStrings(input[10..15], document.records[2].source);
    try testing.expectEqual(@as(usize, 0), document.records[0].source_start);
    try testing.expectEqual(@as(usize, 7), document.records[0].source_end);
    try testing.expectEqual(@as(usize, 8), document.records[1].source_start);
    try testing.expectEqual(@as(usize, 9), document.records[1].source_end);

    var object_cursor = try document.records[0].root();
    try testing.expectEqual(stage2.TapeKind.object_start, (try object_cursor.peek()).tapeKind());
    try object_cursor.advance();
    try testing.expectEqualStrings(
        "a",
        try object_cursor.rawValue(),
    );
    try testing.expect(
        (try object_cursor.rawValue()).ptr == input.ptr + 2,
    );

    var number_cursor = try document.records[1].cursor();
    try testing.expectEqual(stage2.TapeKind.number, (try number_cursor.peek()).tapeKind());
    try testing.expectEqualStrings("2", try number_cursor.rawValue());
    try number_cursor.skipValue();
    try testing.expectEqual(document.records[1].document.tape.len, number_cursor.position());
    try testing.expectError(error.PositionOutOfBounds, number_cursor.peek());

    var false_cursor = try document.cursor(2);
    try testing.expectEqual(stage2.TapeKind.false_literal, (try false_cursor.peek()).tapeKind());
    try testing.expectEqualStrings("false", try false_cursor.rawValue());
}
test "buildJsonlTape preserves all multi-record boundaries and indexes" {
    const input = "{\"a\":[1,2]}\n42\n{\"b\":{\"c\":true}}\nnull\n";
    const expected_sources = [_][]const u8{
        "{\"a\":[1,2]}",
        "42",
        "{\"b\":{\"c\":true}}",
        "null",
    };
    const expected_starts = [_]usize{ 0, 12, 15, 32 };
    const expected_ends = [_]usize{ 11, 14, 31, 36 };
    const expected_kinds = [_]stage2.TapeKind{
        .object_start,
        .number,
        .object_start,
        .null_literal,
    };

    var document = try buildJsonlTape(testing.allocator, input);
    defer document.deinit(testing.allocator);

    try testing.expectEqual(expected_sources.len, document.records.len);
    for (document.records, 0..) |*record_value, index| {
        try testing.expectEqualStrings(expected_sources[index], record_value.source);
        try testing.expectEqual(expected_starts[index], record_value.source_start);
        try testing.expectEqual(expected_ends[index], record_value.source_end);

        var cursor = try record_value.root();
        try testing.expectEqual(expected_kinds[index], (try cursor.peek()).tapeKind());
    }

    var number_cursor = try document.records[1].root();
    try testing.expectEqualStrings("42", try number_cursor.rawValue());
    var null_cursor = try document.records[3].root();
    try testing.expectEqualStrings("null", try null_cursor.rawValue());
    try testing.expect((try validateJsonl(testing.allocator, input)) == null);
}

test "buildJsonlTape skips blank and trailing records while retaining CR" {
    const input = " \r\n\n{\"a\":1}\r\n2\r\n\n";
    var document = try buildJsonlTape(testing.allocator, input);
    defer document.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), document.records.len);
    try testing.expectEqualStrings("{\"a\":1}\r", document.records[0].source);
    try testing.expectEqualStrings("2\r", document.records[1].source);
    try testing.expectEqual(@as(usize, 4), document.records[0].source_start);
    try testing.expectEqual(@as(usize, 13), document.records[1].source_start);

    var empty_document = try buildJsonlTape(testing.allocator, "");
    defer empty_document.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), empty_document.records.len);
}

test "validateJsonl does not split a quoted LF into two records" {
    const input = "{\"text\":\"first\nsecond\"}\n{}\n";
    const quoted_lf = std.mem.indexOfScalar(u8, input, '\n') orelse return error.ExpectedJsonlByte;
    const diagnostic = (try validateJsonl(testing.allocator, input)) orelse return error.ExpectedJsonlDiagnostic;

    try testing.expectEqual(@as(usize, 0), diagnostic.record_index);
    try testing.expectEqual(@as(usize, 0), diagnostic.source_start);
    try testing.expect(diagnostic.source_end > quoted_lf);
    try testing.expectEqual(error.InvalidEscape, diagnostic.err);
    try testing.expectEqual(quoted_lf, diagnostic.byte_offset);
    try testing.expectEqual(@as(u32, 1), diagnostic.line);
    try testing.expectEqual(@as(u32, @intCast(quoted_lf + 1)), diagnostic.column);
}

test "validateJsonl reports later record errors in global coordinates" {
    const input = "{}\n  [1,]\n{}\n";
    const close_bracket = std.mem.indexOfScalar(u8, input, ']') orelse return error.ExpectedJsonlByte;
    const diagnostic = (try validateJsonl(testing.allocator, input)) orelse return error.ExpectedJsonlDiagnostic;

    try testing.expectEqual(@as(usize, 1), diagnostic.record_index);
    try testing.expectEqual(@as(usize, 3), diagnostic.source_start);
    try testing.expectEqual(close_bracket + 1, diagnostic.source_end);
    try testing.expectEqual(error.TrailingComma, diagnostic.err);
    try testing.expectEqual(close_bracket, diagnostic.byte_offset);
    try testing.expectEqual(@as(u32, 2), diagnostic.line);
    try testing.expectEqual(@as(u32, 6), diagnostic.column);
    try testing.expect(
        diagnostic.snippet.ptr == input.ptr + diagnostic.snippet_start,
    );
}

test "JSONL resident events stay lazy with global record spans" {
    const input = "1\n[2,]\n";
    var parser = try Parser.init(testing.allocator, 0);
    defer parser.deinit();

    var document = try initOnDemandDocument(&parser, input);
    defer document.deinit();
    var reader = try document.eventReader();

    const first_start = (try reader.next()) orelse return error.ExpectedJsonlEvent;
    try testing.expectEqual(EventKind.record_start, first_start.kind);
    try testing.expectEqual(@as(u32, 0), first_start.record_index);
    try testing.expectEqual(@as(u32, 0), first_start.offset);
    try testing.expect(first_start.raw.ptr == input.ptr);

    const first_value = (try reader.peek()) orelse return error.ExpectedJsonlEvent;
    try testing.expectEqual(EventKind.number, first_value.kind);
    try testing.expectEqual(first_value, (try reader.peek()).?);
    try testing.expectEqual(@as(u32, 0), first_value.offset);
    try testing.expect(first_value.raw.ptr == input.ptr);
    try testing.expectEqualStrings("1", first_value.raw);
    _ = (try reader.next()) orelse return error.ExpectedJsonlEvent;

    const first_end = (try reader.next()) orelse return error.ExpectedJsonlEvent;
    try testing.expectEqual(EventKind.record_end, first_end.kind);
    try testing.expectEqual(@as(u32, 1), first_end.offset);
    try testing.expectEqual(@as(usize, 0), first_end.raw.len);

    const second_start = (try reader.next()) orelse return error.ExpectedJsonlEvent;
    try testing.expectEqual(EventKind.record_start, second_start.kind);
    try testing.expectEqual(@as(u32, 1), second_start.record_index);
    try testing.expectEqual(@as(u32, 2), second_start.offset);
    try testing.expectEqualStrings("[2,]", second_start.raw);

    try testing.expectEqual(EventKind.array_start, (try reader.next()).?.kind);
    try testing.expectEqual(EventKind.number, (try reader.next()).?.kind);
    try testing.expectError(error.TrailingComma, reader.next());
}

test "JSONL resident peeks retain malformed array errors" {
    const input = "[,]";

    {
        var parser = try Parser.init(testing.allocator, 0);
        defer parser.deinit();
        var document = try initOnDemandDocument(&parser, input);
        defer document.deinit();
        var reader = try document.eventReader();

        try testing.expectEqual(EventKind.record_start, (try reader.next()).?.kind);
        try testing.expectEqual(EventKind.array_start, (try reader.next()).?.kind);
        try testing.expectError(error.UnexpectedToken, reader.peek());
        try testing.expectError(error.UnexpectedToken, reader.next());
    }

    {
        var parser = try Parser.init(testing.allocator, 0);
        defer parser.deinit();
        var document = try initOnDemandDocument(&parser, input);
        defer document.deinit();
        var cursor = try document.tokenCursor();

        try testing.expectEqual(EventKind.record_start, (try cursor.advance()).?.kind);
        try testing.expectEqual(EventKind.array_start, (try cursor.advance()).?.kind);
        try testing.expectError(error.UnexpectedToken, cursor.peek());
        try testing.expectError(error.UnexpectedToken, cursor.advance());
    }
}

test "JSONL resident token cursor emits boundaries and skips one record" {
    const input = "{\"a\":[1,true]}\nnull";
    var parser = try Parser.init(testing.allocator, 0);
    defer parser.deinit();

    var document = try initOnDemandDocument(&parser, input);
    defer document.deinit();
    var cursor = try document.tokenCursor();

    const first = (try cursor.peek()) orelse return error.ExpectedJsonlEvent;
    try testing.expectEqual(EventKind.record_start, first.kind);
    try testing.expectEqual(first, (try cursor.peek()).?);
    try testing.expectEqual(@as(u32, 0), first.offset);
    try cursor.skipChild();

    const second_start = (try cursor.advance()) orelse return error.ExpectedJsonlEvent;
    try testing.expectEqual(EventKind.record_start, second_start.kind);
    try testing.expectEqual(@as(u32, @intCast(input.len - 4)), second_start.offset);

    const second = (try cursor.advance()) orelse return error.ExpectedJsonlEvent;
    try testing.expectEqual(EventKind.null_literal, second.kind);
    try testing.expectEqualStrings("null", second.raw);
    try testing.expectEqual(@as(u32, @intCast(input.len - 4)), second.offset);

    const second_end = (try cursor.advance()) orelse return error.ExpectedJsonlEvent;
    try testing.expectEqual(EventKind.record_end, second_end.kind);
    try testing.expectEqual(@as(u32, @intCast(input.len)), second_end.offset);
    try testing.expect((try cursor.advance()) == null);
}

test "JSONL resident focus detects copies release and parser reuse" {
    const input = "true\n";
    var parser = try Parser.init(testing.allocator, 0);
    defer parser.deinit();

    var document = try initOnDemandDocument(&parser, input);
    var reader = try document.eventReader();
    var copied = reader;
    _ = try reader.next();
    try testing.expectError(error.OutOfOrderIteration, copied.peek());
    document.deinit();
    try testing.expectError(error.DocumentReleased, reader.next());

    var reused = try initOnDemandDocument(&parser, input);
    defer reused.deinit();
    var reused_reader = try reused.eventReader();
    try testing.expectEqual(EventKind.record_start, (try reused_reader.next()).?.kind);
}

test "JSONL resident capacity rejects oversized borrowed sources" {
    var parser = try Parser.init(testing.allocator, 3);
    defer parser.deinit();

    try testing.expectError(
        error.CapacityExceeded,
        initOnDemandDocument(&parser, "1\n2\n"),
    );
}

fn checkJsonlResidentAllocation(allocator: std.mem.Allocator) !void {
    var parser = try Parser.init(allocator, 0);
    defer parser.deinit();

    var document = try initOnDemandDocument(&parser, "{\"a\":1}\n");
    document.deinit();
}

test "JSONL resident parser handles allocator failure without leaks" {
    try testing.checkAllAllocationFailures(
        testing.allocator,
        checkJsonlResidentAllocation,
        .{},
    );
}

test "refAllDecls" {
    testing.refAllDecls(@This());
    _ = simd;
}

fn expectJsonlStreamIndexEqual(
    expected: *const stage1.StructuralIndex,
    actual: *const stage1.StructuralIndex,
) !void {
    try testing.expectEqual(expected.count, actual.count);
    try testing.expectEqualSlices(
        u32,
        expected.indexes[0 .. expected.count + 3],
        actual.indexes[0 .. actual.count + 3],
    );
}

fn feedJsonlStream(
    input: []const u8,
    split: usize,
    chunk_len: usize,
) !stage1.StructuralIndex {
    var indexer = try initStreamIndexer(testing.allocator, chunk_len);
    defer indexer.deinit();

    try indexer.feed(input[0..split]);
    try indexer.feed("");
    try indexer.feed(input[split..]);
    try indexer.finish();
    try indexer.finish();
    return indexer.take();
}

test "JSONL stream wrapper matches one-shot at every partition and byte feed" {
    const input =
        "{\"a\":1}\n{\"b\":\"line\nvalue\"}\r\n[true,false]\n";
    var expected = try indexJsonl(testing.allocator, input);
    defer expected.deinit(testing.allocator);

    for (0..input.len + 1) |split| {
        var actual = try feedJsonlStream(input, split, 3);
        defer actual.deinit(testing.allocator);
        try expectJsonlStreamIndexEqual(&expected, &actual);
    }

    var byte_indexer = try initStreamIndexer(testing.allocator, 1);
    defer byte_indexer.deinit();
    for (input) |byte| {
        try byte_indexer.feed(&.{byte});
    }
    try byte_indexer.finish();
    var byte_actual = byte_indexer.take();
    defer byte_actual.deinit(testing.allocator);
    try expectJsonlStreamIndexEqual(&expected, &byte_actual);
}

test "JSONL stream wrapper reset and finish lifecycle restart offsets" {
    const first_input = "1\n2\n";
    const second_input = "{\"x\":true}\n";
    var indexer = try initStreamIndexer(testing.allocator, 2);
    defer indexer.deinit();

    try indexer.feed(first_input);
    try indexer.finish();
    try indexer.finish();
    try testing.expectError(error.AlreadyFinished, indexer.feed("0"));
    var first = indexer.take();
    defer first.deinit(testing.allocator);

    indexer.reset();
    try indexer.feed(second_input[0..4]);
    try indexer.feed(second_input[4..]);
    try indexer.finish();
    var second = indexer.take();
    defer second.deinit(testing.allocator);

    var expected_first = try indexJsonl(testing.allocator, first_input);
    defer expected_first.deinit(testing.allocator);
    var expected_second = try indexJsonl(testing.allocator, second_input);
    defer expected_second.deinit(testing.allocator);
    try expectJsonlStreamIndexEqual(&expected_first, &first);
    try expectJsonlStreamIndexEqual(&expected_second, &second);
}

//! On-demand traversal of JSON-family input over a parser-owned structural
//! index.
//!
//! A `Parser` owns one reusable array of `u32` offsets and borrows the source
//! bytes it indexes. A `Document` borrows both and hands out exactly one
//! `TokenCursor` or one `EventReader` at a time. Nothing here copies source
//! bytes or materializes values: tokens and events carry slices of the
//! caller's `input`, so that buffer must stay alive and unmodified until the
//! document is released. Release the `Document` before building the next one
//! or calling `Parser.deinit`.
//!
//! No entry point performs I/O or retains a `std.Io` capability: every call
//! runs to completion on the calling thread over memory the caller already
//! holds, so no call blocks and none can report `error.Canceled`.
//!
//! This module owns the traversal model only. `stage1.zig` produces structural
//! indexes, `stage2.zig` owns the grammar, dialect rules, and validation, and
//! the format modules in `src/formats/` build the index and choose the dialect.

const std = @import("std");
const stage1 = @import("stage1.zig");
const stage2 = @import("stage2.zig");

const testing = std.testing;

/// The container nesting `TokenCursor` enforces on itself.
///
/// An opening brace or bracket that would nest deeper than this reports
/// `error.DepthExceeded`. `EventReader` is bounded by `stage2.max_depth`
/// instead, which carries the same value.
pub const max_depth: usize = 1024;
const sentinel_count: usize = 3;

/// Shared failure vocabulary; `Parser.init` returns the narrower `InitError`.
///
/// The set is one shared vocabulary. The `stage2.Error` tags reach a caller
/// through `EventReader` reading the document's bytes, the capacity and index
/// tags come from document construction, and the lifecycle tags come from the
/// single-document and single-focus checks. `DuplicateKey`,
/// `IncorrectType`, `NoSuchField`, `NumberError`, and `StringError` are
/// declared here and produced by no path in this package, so an exhaustive
/// `switch` needs an arm that no input reaches.
pub const Error = std.mem.Allocator.Error || error{
    CapacityOverflow,
    CapacityExceeded,
    DocumentActive,
    DocumentReleased,
    DuplicateKey,
    EmptyDocument,
    FocusAlreadyClaimed,
    FocusLost,
    IncorrectType,
    InputTooLarge,
    InvalidEscape,
    InvalidNumber,
    InvalidStructuralIndex,
    InvalidUtf8,
    NoSuchField,
    NumberError,
    OutOfOrderIteration,
    RootNotSingular,
    StringError,
    TapeTooLarge,
    TrailingComma,
    UnexpectedEnd,
    UnexpectedToken,
    UnclosedArray,
    UnclosedObject,
    UnterminatedString,
    DepthExceeded,
};

/// The failures `Parser.init` reports: allocation failure, a `max_capacity`
/// above the `u32` index bound, and a token count whose sum with the three
/// sentinel slots overflows `usize`.
pub const InitError = std.mem.Allocator.Error || error{
    CapacityOverflow,
    InputTooLarge,
};

/// Reusable structural-index storage and the single-document state a `Document`
/// reads through.
///
/// A `Parser` owns `indexes`, one allocation taken from the `allocator` given
/// to `init` and released by exactly one `deinit`. It borrows nothing else: the
/// source bytes reach it through each document. The `allocator` is stored, not
/// owned, and every field of this struct is reachable and writable, so it must
/// still be the same allocator with the same backing state when `deinit` runs.
///
/// The value must stay at a stable address while a `Document` is live, because
/// `Document.parser` and every cursor and reader hold a `*Parser`. Copying a
/// `Parser` copies the handle to that one allocation rather than creating a
/// second owner, and a copied parser must not be `deinit`'d.
///
/// One `Parser` permits one `Document` at a time; the second reports
/// `error.DocumentActive` until the first is released. Releasing that document
/// makes the parser reusable for a different input, and the next document may
/// reallocate `indexes`.
///
/// Nothing here is synchronized: a parser is used by the calling thread only.
/// No method calls back into caller code, so nothing reenters a parser while
/// one of its methods runs.
pub const Parser = struct {
    /// The allocator `indexes` came from and is released through.
    allocator: std.mem.Allocator,
    /// `capacity` token offsets followed by three sentinel slots, the last two
    /// holding `input.len` and the last holding `0`. Growth replaces the whole
    /// allocation, so this slice and any slice taken from it are valid only
    /// until the next document on this parser, which may move them.
    indexes: []u32,
    /// Token offsets `indexes` can hold, excluding the three sentinel slots.
    /// `max_capacity` from `init`, and the high-water mark reached by growth
    /// since.
    capacity: usize,
    /// Whether a document larger than `capacity` may grow `indexes`. `true`
    /// when `init` received `max_capacity == 0`, so the parser sizes itself to
    /// each document; `false` fixes the capacity, and an input that does not
    /// fit reports `error.CapacityExceeded`.
    grow_on_demand: bool,
    /// The Stage 2 reader over the current document's borrowed input and
    /// indexes. Rebound by every document and blank by `init`.
    token_reader: stage2.TokenReader,
    /// The generation the current document was built with, `0` before any.
    /// Advanced by wrapping addition and reset to `1` on overflow, so a
    /// document's identity is finite: after `2^64 - 1` further documents a
    /// stale handle matches a live generation again. This check is a guard
    /// against ordinary reuse, not a proof that the bytes a stale handle names
    /// are still allocated.
    generation: u64 = 0,
    /// Whether a document currently holds this parser.
    document_active: bool = false,
    /// Which cursor or reader holds the document's single focus, `.none` when
    /// it is unclaimed. The focus is released by `Document.deinit` or by
    /// building the next document, never by dropping a cursor or reader.
    focus: Focus = .none,
    /// The token read ahead by `EventReader.peek` and not yet consumed by
    /// `next`, or `null`. Cleared by `Document.deinit` and by the next document.
    event_cached: ?stage2.ParsedToken = null,
    /// The event position `EventReader.next` has delivered, `0` before any.
    /// Advanced by wrapping addition and reset to `1` on overflow, with the
    /// same finite reuse bound as `generation`.
    event_epoch: u64 = 0,
    /// The token position the focused cursor has consumed, and the position a
    /// copied cursor is compared against.
    position_index: usize = 0,
    /// Container nesting depth as tracked by `TokenCursor.advance`, bounded by
    /// `max_depth`. `EventReader` keeps its own depth inside the Stage 2
    /// reader and does not read this field.
    depth: usize = 0,

    /// Allocates `indexes` for `max_capacity` offsets plus the three sentinel
    /// slots and returns the parser.
    ///
    /// `max_capacity == 0` selects growth on demand and allocates only the
    /// sentinel slots; a nonzero value fixes the capacity and every later
    /// document that does not fit reports `error.CapacityExceeded`.
    /// `error.InputTooLarge` bounds `max_capacity` by the `u32` offset range,
    /// and `error.CapacityOverflow` covers the addition of the sentinel slots.
    ///
    /// On any error the caller owns nothing: the only allocation is the one
    /// this call makes, and it fails before the parser exists.
    pub fn init(allocator: std.mem.Allocator, max_capacity: usize) InitError!Parser {
        if (max_capacity > std.math.maxInt(u32)) return error.InputTooLarge;
        const index_capacity = std.math.add(
            usize,
            max_capacity,
            sentinel_count,
        ) catch return error.CapacityOverflow;

        const indexes = try allocator.alloc(u32, index_capacity);
        // An empty input with no global offsets satisfies every check in
        // `IndexView.init`: the length bound, the `base_offset + limit` sum, and
        // the monotonicity loop, which has no elements to inspect. `InitError`
        // cannot carry `IndexView.Error` without widening this error set, so an
        // unexpected failure is reported rather than propagated.
        const empty_view = stage2.IndexView.init(&.{}, &.{}, 0) catch |err| {
            std.debug.panic(
                "empty IndexView.init failed: {s}",
                .{@errorName(err)},
            );
        };
        // `TokenReader.init` only validates the view against its input, and both
        // are empty with a zero base offset, so `ReaderError` is unreachable
        // here for the same reason as above.
        const empty_reader = stage2.TokenReader.init(&.{}, empty_view, .json) catch |err| {
            std.debug.panic(
                "empty TokenReader.init failed: {s}",
                .{@errorName(err)},
            );
        };
        return .{
            .allocator = allocator,
            .indexes = indexes,
            .capacity = max_capacity,
            .grow_on_demand = max_capacity == 0,
            .token_reader = empty_reader,
        };
    }

    /// Releases `indexes` and leaves the parser unusable.
    ///
    /// Exactly one `deinit` per `Parser`; a copy reached twice frees the same
    /// bytes twice. The `allocator` is not released. `std.debug.assert`
    /// requires that no document is live, so the violation is diagnosed in
    /// Debug and ReleaseSafe and is unchecked illegal behavior in ReleaseFast
    /// and ReleaseSmall; releasing the document first is the caller's
    /// obligation, and `Document.deinit` is what satisfies it.
    pub fn deinit(self: *Parser) void {
        std.debug.assert(!self.document_active);
        self.allocator.free(self.indexes);
        self.* = undefined;
    }

    fn ensureCapacity(self: *Parser, input_length: usize, index_count: usize) Error!void {
        var required_capacity = input_length;
        if (index_count > required_capacity) required_capacity = index_count;
        if (required_capacity <= self.capacity) return;
        if (!self.grow_on_demand) return error.CapacityExceeded;

        const index_capacity = std.math.add(
            usize,
            required_capacity,
            sentinel_count,
        ) catch return error.CapacityOverflow;
        const indexes = try self.allocator.alloc(u32, index_capacity);

        self.allocator.free(self.indexes);
        self.indexes = indexes;
        self.capacity = required_capacity;
    }

    /// Reserves parser-owned structural storage for one document and returns
    /// the writable slot range that excludes the three sentinel slots.
    ///
    /// The slice is `indexes` itself, not a copy: it is valid until the next
    /// document on this parser, and growth moves it. Filling it and calling
    /// `completeDocument` or `completeDialectDocument` with the number of slots
    /// written is the intended sequence; `input` is borrowed to size the
    /// request and is not retained here.
    ///
    /// `error.DocumentActive` while a document is live, `error.InputTooLarge`
    /// for an input above the `u32` offset range, `error.CapacityExceeded` when
    /// a fixed-capacity parser cannot hold it, and `error.CapacityOverflow` or
    /// `error.OutOfMemory` while growing. Every failure leaves the parser
    /// inactive and reusable with `indexes`, `capacity`, and every traversal
    /// field exactly as they were.
    pub fn prepareDocument(self: *Parser, input: []const u8) Error![]u32 {
        if (self.document_active) return error.DocumentActive;
        if (input.len > std.math.maxInt(u32)) return error.InputTooLarge;
        try self.ensureCapacity(input.len, input.len);
        return self.indexes[0 .. self.indexes.len - sentinel_count];
    }

    /// Completes a strict-JSON document from offsets the caller filled into the
    /// slice `prepareDocument` returned.
    ///
    /// `token_count` is how many of those slots were written; the three sentinel
    /// slots are written here. The offsets are validated against `input` for
    /// range and strict ascent before the document exists, and the Stage 2
    /// reader is rebound over them with the `.json` dialect. On success the
    /// parser holds this document until `Document.deinit` and one focus is
    /// claimable from it.
    ///
    /// `error.DocumentActive` while a document is live, `error.InvalidStructuralIndex`
    /// for a `token_count` above `input.len` or for an offset out of range,
    /// repeated, or leaving no room for the sentinel slots, and the capacity and
    /// allocation tags of `prepareDocument`. On failure the parser is inactive
    /// and reusable, and no partial document exists.
    pub fn completeDocument(
        self: *Parser,
        input: []const u8,
        token_count: usize,
    ) Error!Document {
        return self.completeOwnedDocument(input, token_count, .json);
    }

    /// Completes a JSONC or JSON5 document from offsets the caller filled into
    /// the slice `prepareDocument` returned.
    ///
    /// Identical to `completeDocument` except that the Stage 2 reader accepts
    /// `dialect` instead of `.json`, so the same offsets and the same
    /// validation run under that grammar. `.json` is accepted here as well and
    /// is the same call `completeDocument` makes.
    pub fn completeDialectDocument(
        self: *Parser,
        input: []const u8,
        token_count: usize,
        dialect: stage2.Dialect,
    ) Error!Document {
        return self.completeOwnedDocument(input, token_count, dialect);
    }

    fn completeOwnedDocument(
        self: *Parser,
        input: []const u8,
        token_count: usize,
        dialect: stage2.Dialect,
    ) Error!Document {
        if (self.document_active) return error.DocumentActive;
        if (input.len > std.math.maxInt(u32)) return error.InputTooLarge;
        try self.ensureCapacity(input.len, token_count);
        return self.finishOwnedDocument(input, token_count, dialect);
    }

    /// Completes a strict-JSON document by copying a finished
    /// `stage1.StructuralIndex` into the parser's own storage.
    ///
    /// `structural_index` is borrowed for the call and is neither retained nor
    /// freed; it may be released as soon as this returns. Copying it costs one
    /// `u32` copy of `count + 3` entries and no allocation unless the parser
    /// has to grow. Its offsets and sentinel slots are validated against
    /// `input`, copied into the parser's storage, and validated there again by
    /// the same completion path `completeDocument` uses. `input` is borrowed
    /// and must stay alive and unmodified until `Document.deinit`.
    ///
    /// `error.InvalidStructuralIndex` when `structural_index.count` exceeds
    /// `input.len`, when an offset is out of range, repeated, or not the
    /// sentinel values, plus `error.DocumentActive`,
    /// `error.InputTooLarge`, `error.CapacityExceeded`,
    /// `error.CapacityOverflow`, and `error.OutOfMemory` on the same conditions
    /// as `completeDocument`. On failure the parser is inactive and reusable.
    pub fn initDocument(
        self: *Parser,
        input: []const u8,
        structural_index: *const stage1.StructuralIndex,
    ) Error!Document {
        if (self.document_active) return error.DocumentActive;
        if (input.len > std.math.maxInt(u32)) return error.InputTooLarge;
        if (structural_index.count > input.len) return error.InvalidStructuralIndex;
        try self.ensureCapacity(input.len, structural_index.count);

        try validateStructuralIndex(input, structural_index);
        const source_count = std.math.add(
            usize,
            structural_index.count,
            sentinel_count,
        ) catch return error.InvalidStructuralIndex;
        if (source_count > self.indexes.len) {
            return error.InvalidStructuralIndex;
        }

        @memcpy(
            self.indexes[0..source_count],
            structural_index.indexes[0..source_count],
        );
        return self.finishOwnedDocument(input, structural_index.count, .json);
    }

    /// Equivalent to `initDocument`.
    pub fn iterate(
        self: *Parser,
        input: []const u8,
        structural_index: *const stage1.StructuralIndex,
    ) Error!Document {
        return self.initDocument(input, structural_index);
    }

    fn finishOwnedDocument(
        self: *Parser,
        input: []const u8,
        token_count: usize,
        dialect: stage2.Dialect,
    ) Error!Document {
        if (token_count > input.len) return error.InvalidStructuralIndex;
        const source_count = std.math.add(
            usize,
            token_count,
            sentinel_count,
        ) catch return error.InvalidStructuralIndex;
        if (source_count > self.indexes.len) {
            return error.InvalidStructuralIndex;
        }

        if (input.len > std.math.maxInt(u32)) return error.InputTooLarge;
        const sentinel: u32 = @intCast(input.len);
        self.indexes[token_count..][0..sentinel_count].* = .{
            sentinel,
            sentinel,
            0,
        };
        try validateIndexes(input, self.indexes, token_count);

        const view = try stage2.IndexView.init(input, self.indexes[0..token_count], 0);
        try self.token_reader.reset(input, view, dialect);
        self.focus = .none;
        self.event_cached = null;
        self.event_epoch = 0;
        self.position_index = 0;
        self.depth = 0;

        self.generation +%= 1;
        if (self.generation == 0) self.generation = 1;
        self.document_active = true;

        return .{
            .parser = self,
            .input = input,
            .indexes = self.indexes[0..source_count],
            .token_count = token_count,
            .generation = self.generation,
            .dialect = dialect,
            .index_view = view,
        };
    }
};

/// The single traversal focus one document lends out at a time.
///
/// The name is not exported, but `Parser.focus` and `TokenCursor.owner` are
/// fields of this type, so `@TypeOf` recovers the type and every tag below.
/// `.none` is the unclaimed state and the value `Document.deinit` restores.
/// A cursor and a reader claiming the same document reports
/// `error.FocusAlreadyClaimed`, and the winner reports `error.FocusLost` once
/// the field no longer names it.
const Focus = enum {
    none,
    /// Held by a `TokenCursor`, which compares the parser's `focus` against
    /// this value on every call that reads or advances.
    cursor,
    /// Held by an `EventReader`, which compares the parser's `focus` against
    /// this value on every call that reads or advances.
    event_reader,
};

/// Equivalent to `Parser.initDocument`.
pub fn initDocument(
    parser: *Parser,
    input: []const u8,
    structural_index: *const stage1.StructuralIndex,
) Error!Document {
    return parser.initDocument(input, structural_index);
}

/// One live JSON-family document over parser-owned indexes and borrowed source.
///
/// A `Document` owns nothing itself. It borrows the `Parser` it was built on,
/// the `input` slice the caller supplied, and that parser's `indexes`, and it
/// must stay at a stable address while a `TokenCursor` or `EventReader` from it
/// is live, because both hold a `*Document`. `input` must also stay alive and
/// unmodified until the document is released: every `Event` and `Token` reads
/// through it.
///
/// One parser holds one document at a time. `deinit` releases the parser's
/// claim rather than any memory, so a stale copy of a released document cannot
/// close the document that replaced it. Copies are not independent owners:
/// `deinit` on either copy releases the same claim.
///
/// The document can serve either a raw token cursor or an event reader, not
/// both at once, and one focus is claimable at a time. Nothing here is
/// synchronized.
pub const Document = struct {
    /// The parser that owns the indexes and holds the document's generation,
    /// focus, and reader. Must outlive this document and stay at a stable
    /// address.
    parser: *Parser,
    /// The caller's source bytes, borrowed and never copied. Every raw span an
    /// `Event` or `Token` reports is a slice of it, so it must stay alive and
    /// unmodified until this document is released.
    input: []const u8,
    /// The parser's index slots for this document: `token_count` offsets
    /// followed by the three sentinel slots. Borrowed from `Parser.indexes`,
    /// so it is invalidated by `Parser.deinit` and by the growth a later
    /// document can do, which can only happen once this document is released.
    indexes: []const u32,
    /// Number of real offsets in `indexes`, excluding the three sentinel slots.
    token_count: usize,
    /// The parser generation this document was created with. Compared before
    /// every cursor and reader operation; it is a finite reuse check, not a
    /// proof that the `input` a stale handle names is still live.
    generation: u64,
    /// The grammar the document was completed with, and the one its
    /// `EventReader` enforces.
    dialect: stage2.Dialect,
    /// The checked Stage 2 view over `indexes[0..token_count]`, borrowed from
    /// them.
    index_view: stage2.IndexView,

    /// Releases this document's claim on its parser and leaves the value
    /// unusable.
    ///
    /// Nothing is freed: `input` belongs to the caller and `indexes` belongs to
    /// the parser, which stays usable and reuses that storage for its next
    /// document. The parser is marked inactive, its focus and traversal state
    /// are cleared, and every cursor and reader from this document reports
    /// `error.DocumentReleased` from then on.
    ///
    /// The release is generation-guarded: a document left over from an earlier
    /// generation clears nothing, so it cannot release a newer document. It is
    /// still one statement per value, because this value is left undefined and
    /// a second `deinit` on it reads undefined memory. A copy taken before this
    /// call is not left undefined, but it no longer names a live document, so
    /// its own `deinit` clears nothing. Release before building the next
    /// document and before `Parser.deinit`.
    ///
    /// A raw span already taken from `input` is unaffected by this call and
    /// stays readable for as long as the caller keeps that buffer alive and
    /// unmodified; only the traversal through this document expires.
    pub fn deinit(self: *Document) void {
        if (self.parser.document_active and self.parser.generation == self.generation) {
            self.parser.document_active = false;
            self.parser.focus = .none;
            self.parser.event_cached = null;
            self.parser.event_epoch = 0;
            self.parser.position_index = 0;
            self.parser.depth = 0;
        }
        self.* = undefined;
    }

    /// Claims the document's focus for a raw token cursor and returns it.
    ///
    /// The cursor reads `indexes` and `input` directly and enforces no grammar,
    /// so it reports structural bytes and their offsets as the indexer recorded
    /// them. `error.DocumentReleased` if this document is no longer the parser's
    /// live one and `error.FocusAlreadyClaimed` while a cursor or reader already
    /// holds the focus.
    ///
    /// The focus is not released by dropping the cursor; only `deinit` on this
    /// document or the next document on the parser releases it.
    pub fn tokenCursor(self: *Document) Error!TokenCursor {
        try self.claimFocus(.cursor);
        return .{
            .document = self,
            .parser = self.parser,
            .generation = self.generation,
            .expected_position = self.parser.position_index,
            .owner = .cursor,
        };
    }

    /// Claims the document's focus for a validating event reader and returns
    /// it.
    ///
    /// Equivalent to `EventReader.init`, and reports the same
    /// `error.DocumentReleased` and `error.FocusAlreadyClaimed`. The focus is
    /// released only by `deinit` here or by the next document on the parser.
    pub fn eventReader(self: *Document) Error!EventReader {
        return EventReader.init(self);
    }

    fn ensureAlive(self: *const Document) Error!void {
        if (!self.parser.document_active) return error.DocumentReleased;
        if (self.parser.generation != self.generation) return error.DocumentReleased;
    }

    fn claimFocus(self: *Document, focus: Focus) Error!void {
        try self.ensureAlive();
        if (self.parser.focus != .none) return error.FocusAlreadyClaimed;
        self.parser.focus = focus;
    }
};

/// One raw index entry: where the structural token starts and the byte there.
///
/// `byte` is the source byte at `offset`, which for a structural index is one
/// of `{`, `}`, `[`, `]`, `:`, `,`, an atom's first byte, or an opening quote.
/// It is not decoded or classified; a `Token` allocates nothing and owns
/// nothing.
pub const Token = struct {
    /// Byte offset of the token's first byte in `Document.input`, and strictly
    /// below that input's length.
    offset: u32,
    byte: u8,
};

/// A forward-only cursor over one document's structural indexes.
///
/// The cursor borrows the document and owns no allocation. It holds the focus
/// its document lent it and shares the parser's position counter, so a copy
/// made before an `advance` is out of order the moment either copy advances.
/// Every call checks that the document is still live, that the focus is still
/// the cursor's, and that the shared position has not moved;
/// `error.DocumentReleased`, `error.FocusLost`, and `error.OutOfOrderIteration`
/// report those three conditions. Those checks are a guard against ordinary
/// reuse and are finite: the generation they compare repeats after `2^64 - 1`
/// documents, and passing them says nothing about whether the borrowed `input`
/// is still live.
///
/// Nothing here is synchronized: a cursor is used by the calling thread only.
/// No method calls back into caller code.
pub const TokenCursor = struct {
    /// The document this cursor reads through. Must stay alive and at a stable
    /// address while the cursor is used.
    document: *Document,
    /// The document's parser, which holds the shared position, depth, and
    /// focus.
    parser: *Parser,
    /// The parser generation at claim time, compared on every call.
    generation: u64,
    /// The index position this cursor expects the shared position to hold. A
    /// copy taken before an `advance` keeps the older value and reports
    /// `error.OutOfOrderIteration`.
    expected_position: usize,
    /// The focus this cursor claimed, checked on every call.
    owner: Focus,
    /// The token at the current position without consuming it, or `null` when
    /// the position is at `token_count`.
    ///
    /// Repeats without side effects, so it may be called to inspect the same
    /// entry twice. `error.OutOfOrderIteration` also covers a position past
    /// `token_count`, which only a caller that wrote `expected_position`
    /// directly can produce, alongside the release, focus, and shared-position
    /// checks. The token borrows `input` and carries no allocation.
    ///
    /// The `const` receiver is shallow: it does not stop a copy of this cursor
    /// or the parser behind it from advancing.
    pub fn peek(self: *const TokenCursor) Error!?Token {
        try self.ensureFocused();
        if (self.expected_position > self.document.token_count) {
            return error.OutOfOrderIteration;
        }
        if (self.expected_position == self.document.token_count) return null;

        const offset = self.document.indexes[self.expected_position];
        return .{
            .offset = offset,
            .byte = self.document.input[@intCast(offset)],
        };
    }

    /// Consumes the token at the current position and returns it, or `null`
    /// when the position is at `token_count`.
    ///
    /// Consuming a `{` or `[` deepens the shared nesting depth and a `}` or
    /// `]` shallows it, which is what `skipChild` and `max_depth` are measured
    /// against. `error.DepthExceeded` is reported before the entry is consumed,
    /// so a rejected `advance` leaves the position where it was; so does
    /// `error.UnexpectedToken` for a closing byte with no open container.
    /// Everything `peek` reports applies here too.
    pub fn advance(self: *TokenCursor) Error!?Token {
        const token = try self.peek() orelse return null;
        try self.applyDepth(token.byte);
        self.expected_position += 1;
        self.parser.position_index = self.expected_position;
        return token;
    }

    /// The current index position as a `u32`, for a caller that needs it as a
    /// number rather than a token.
    ///
    /// No error, no allocation, and no check: it reads `expected_position`
    /// whatever state the document or focus is in, including after release.
    pub inline fn position(self: *const TokenCursor) u32 {
        return @intCast(self.expected_position);
    }

    /// The structural offset `delta` positions from the current one, without
    /// consuming anything.
    ///
    /// A negative `delta` looks back. The sentinel slots are addressable, so a
    /// delta that reaches past the last real token reports `input.len` for the
    /// first two and `0` for the third, and only a target outside `indexes`
    /// reports `error.UnexpectedEnd`. Everything `peek` reports applies.
    pub fn peekIndex(self: *const TokenCursor, delta: i32) Error!u32 {
        const position_index = try self.positionAt(delta);
        return self.document.indexes[position_index];
    }

    /// The byte distance from the entry `delta` positions from the current one
    /// to the entry after it, without consuming anything.
    ///
    /// At the last real entry the following sentinel makes this the distance
    /// to the end of the input. At the sentinel slots themselves the first two
    /// both hold `input.len`, so the distance is `0`; the slot before them
    /// pairs an offset with the trailing `0` and reports
    /// `error.InvalidStructuralIndex`, and the last slot has no following entry
    /// and reports `error.UnexpectedEnd`. Everything `peek` reports applies.
    pub fn peekLength(self: *const TokenCursor, delta: i32) Error!u32 {
        const position_index = try self.positionAt(delta);
        if (position_index + 1 >= self.document.indexes.len) {
            return error.UnexpectedEnd;
        }
        const start = self.document.indexes[position_index];
        const end = self.document.indexes[position_index + 1];
        if (end < start) return error.InvalidStructuralIndex;
        return end - start;
    }

    /// Consumes entries until the shared nesting depth is back at or below
    /// `parent_depth`.
    ///
    /// `parent_depth` is the depth the caller observed for the container it is
    /// inside, so `0` skips to the end of the whole document and `1` skips the
    /// child of a top-level container. The call is a no-op when the depth has
    /// already returned to that value. `error.UnexpectedToken` for a negative
    /// `parent_depth` and `error.UnexpectedEnd` when the entries run out
    /// before the depth closes; entries already consumed stay consumed.
    /// Everything `peek` reports applies here too.
    pub fn skipChild(self: *TokenCursor, parent_depth: i32) Error!void {
        try self.ensureFocused();
        if (parent_depth < 0) return error.UnexpectedToken;
        const parent_depth_usize: usize = @intCast(parent_depth);
        if (self.parser.depth <= parent_depth_usize) return;

        var steps: usize = 0;
        while (self.parser.depth > parent_depth_usize) {
            if (steps >= self.document.token_count) return error.UnexpectedEnd;
            _ = try self.advance() orelse return error.UnexpectedEnd;
            steps += 1;
        }
    }

    fn ensureFocused(self: *const TokenCursor) Error!void {
        if (!self.parser.document_active) return error.DocumentReleased;
        if (self.parser.generation != self.generation) return error.DocumentReleased;
        if (self.parser.focus != self.owner) return error.FocusLost;
        if (self.parser.position_index != self.expected_position) {
            return error.OutOfOrderIteration;
        }
    }

    fn positionAt(self: *const TokenCursor, delta: i32) Error!usize {
        try self.ensureFocused();
        const position_signed: i64 = @intCast(self.expected_position);
        const target = position_signed + @as(i64, @intCast(delta));
        if (target < 0) return error.UnexpectedEnd;
        const position_index: usize = @intCast(target);
        if (position_index >= self.document.indexes.len) return error.UnexpectedEnd;
        return position_index;
    }

    fn applyDepth(self: *TokenCursor, byte: u8) Error!void {
        switch (byte) {
            '{', '[' => {
                if (self.parser.depth >= max_depth) return error.DepthExceeded;
                self.parser.depth += 1;
            },
            '}', ']' => {
                if (self.parser.depth == 0) return error.UnexpectedToken;
                self.parser.depth -= 1;
            },
            else => {},
        }
    }
};

/// One validated event pulled from a document by an `EventReader`.
///
/// Every payload is a slice of the document's `input`: a `key` and a `string`
/// are the raw bytes the token spans — between the quotes, or the identifier
/// itself for an unquoted JSON5 key — and still carry their escapes, and a
/// `number` is the raw literal text. Nothing is decoded, copied, or converted
/// here, so a payload stays readable for as long as the caller keeps that
/// buffer alive and unmodified, including after the document is released and
/// its parser reused; what expires at release is the traversal, not the bytes.
/// `object_start`, `object_end`, `array_start`, `array_end`, and `null` carry
/// no payload, and `bool` carries the literal's value rather than its text.
pub const Event = union(enum) {
    object_start,
    object_end,
    array_start,
    array_end,
    key: []const u8,
    string: []const u8,
    number: []const u8,
    bool: bool,
    null,
};

/// A forward-only validating reader over one document's events.
///
/// The reader holds the focus its document lent it, borrows the document and
/// its parser, and allocates nothing: every event is a slice of the caller's
/// source. Dropping it releases neither the focus nor the document;
/// `Document.deinit` does both.
///
/// Events arrive in source order from the document's Stage 2 reader, so a
/// grammar failure anywhere in the document surfaces at the event that reached
/// it and the events before it have already been delivered. A copy taken
/// before a `next` is out of order the moment either copy advances, because
/// both are compared against the parser's shared event epoch. Every call
/// checks the document is live, the focus is the reader's, and the shared
/// epoch has not moved, reporting `error.DocumentReleased`,
/// `error.FocusLost`, and `error.OutOfOrderIteration`. Those checks are
/// finite — the generation repeats after `2^64 - 1` documents — and they say
/// nothing about whether the borrowed `input` is still live.
///
/// Nothing here is synchronized: a reader is used by the calling thread only.
/// No method calls back into caller code, so nothing reenters a reader while
/// one of its methods runs.
pub const EventReader = struct {
    /// The document this reader reads through. Must stay alive and at a stable
    /// address while the reader is used.
    document: *Document,
    /// The document's parser, which holds the shared epoch, the cached token,
    /// the Stage 2 reader, and the focus.
    parser: *Parser,
    /// The parser generation at claim time, compared on every call.
    generation: u64,
    /// The event position this reader expects the shared epoch to hold. A copy
    /// taken before a `next` keeps the older value and reports
    /// `error.OutOfOrderIteration`.
    expected_epoch: u64,
    /// Claims the document's focus and returns a reader positioned before its
    /// first event.
    ///
    /// `Document.eventReader` is the same call. `error.DocumentReleased` if the
    /// document is no longer live and `error.FocusAlreadyClaimed` while a
    /// cursor or reader already holds the focus.
    pub fn init(document: *Document) Error!EventReader {
        try document.claimFocus(.event_reader);
        return .{
            .document = document,
            .parser = document.parser,
            .generation = document.generation,
            .expected_epoch = document.parser.event_epoch,
        };
    }

    /// The next event and consumes it, or `null` when the document's grammar
    /// is exhausted.
    ///
    /// A token already read by `peek` is delivered first, so `peek` then `next`
    /// yields the same event. Consuming an event advances the shared epoch and
    /// invalidates a copy of this reader.
    ///
    /// A grammar failure comes from the Stage 2 reader, which latches it: the
    /// same tag is returned by every later `next`, `peek`, and `skip` until a
    /// new document is built on this parser. The events delivered before the
    /// failure stay delivered, and the epoch does not advance on a failed call,
    /// so the same call fails the same way. Alongside those tags this reports
    /// `error.DocumentReleased`, `error.FocusLost`, and
    /// `error.OutOfOrderIteration`.
    pub fn next(self: *EventReader) Error!?Event {
        const token = try self.nextParsed() orelse return null;
        const event = try eventFromToken(token);
        self.advanceEpoch();
        return event;
    }

    /// The next event without consuming it, or `null` when the document's
    /// grammar is exhausted.
    ///
    /// The token read ahead is held in the parser's `event_cached`, so repeated
    /// peeks return the same event and the following `next` delivers it. The
    /// `const` receiver is shallow: it writes through the parser's reachable
    /// `event_cached` field and is not a promise of immutability. Errors and
    /// their latch are the ones `next` reports.
    pub fn peek(self: *const EventReader) Error!?Event {
        try self.ensureFocused();
        if (self.parser.event_cached == null) {
            self.parser.event_cached = try self.parser.token_reader.next();
        }
        const token = self.parser.event_cached orelse return null;
        const value = try eventFromToken(token);
        return value;
    }

    /// Consumes the next event, and through it the rest of its value when that
    /// event opens a container.
    ///
    /// A scalar, key, or closing event is consumed alone; after an opening
    /// event the reader consumes until the matching close, which is the whole
    /// subtree including the closing event. The sweep is bounded by
    /// `input.len + 1` events, and `error.UnexpectedEnd` is reported when the
    /// document runs out before the containers balance. Events consumed before
    /// a failure stay consumed. Errors are the ones `next` reports.
    pub fn skip(self: *EventReader) Error!void {
        const first = try self.next() orelse return;
        var open_count: usize = switch (first) {
            .object_start, .array_start => 1,
            else => return,
        };

        var steps: usize = 0;
        const max_steps = std.math.add(usize, self.document.input.len, 1) catch
            std.math.maxInt(usize);
        while (open_count > 0) {
            if (steps >= max_steps) return error.UnexpectedEnd;
            const event = try self.next() orelse return error.UnexpectedEnd;
            switch (event) {
                .object_start, .array_start => open_count += 1,
                .object_end, .array_end => open_count -= 1,
                else => {},
            }
            steps += 1;
        }
    }

    fn nextParsed(self: *EventReader) Error!?stage2.ParsedToken {
        try self.ensureFocused();
        if (self.parser.event_cached) |token| {
            self.parser.event_cached = null;
            return token;
        }
        return self.parser.token_reader.next();
    }

    fn advanceEpoch(self: *EventReader) void {
        self.parser.event_epoch +%= 1;
        if (self.parser.event_epoch == 0) self.parser.event_epoch = 1;
        self.expected_epoch = self.parser.event_epoch;
    }

    fn ensureFocused(self: *const EventReader) Error!void {
        if (!self.parser.document_active) return error.DocumentReleased;
        if (self.parser.generation != self.generation) return error.DocumentReleased;
        if (self.parser.focus != .event_reader) return error.FocusLost;
        if (self.parser.event_epoch != self.expected_epoch) {
            return error.OutOfOrderIteration;
        }
    }
};

fn eventFromToken(token: stage2.ParsedToken) Error!Event {
    return switch (token.word.tapeKind()) {
        .object_start => .object_start,
        .object_end => .object_end,
        .array_start => .array_start,
        .array_end => .array_end,
        .key => .{ .key = token.raw },
        .string => .{ .string = token.raw },
        .number => .{ .number = token.raw },
        .true_literal => .{ .bool = true },
        .false_literal => .{ .bool = false },
        .null_literal => .null,
    };
}

fn validateStructuralIndex(
    input: []const u8,
    structural_index: *const stage1.StructuralIndex,
) Error!void {
    return validateIndexes(input, structural_index.indexes, structural_index.count);
}

fn validateIndexes(
    input: []const u8,
    indexes: []const u32,
    count: usize,
) Error!void {
    const source_count = std.math.add(usize, count, sentinel_count) catch {
        return error.InvalidStructuralIndex;
    };
    if (source_count > indexes.len) return error.InvalidStructuralIndex;

    var previous: ?u32 = null;
    for (indexes[0..count]) |offset| {
        if (offset >= input.len) return error.InvalidStructuralIndex;
        if (previous) |previous_offset| {
            if (offset <= previous_offset) return error.InvalidStructuralIndex;
        }
        previous = offset;
    }

    if (input.len > std.math.maxInt(u32)) return error.InputTooLarge;
    const sentinel: u32 = @intCast(input.len);
    if (indexes[count] != sentinel) return error.InvalidStructuralIndex;
    if (indexes[count + 1] != sentinel) return error.InvalidStructuralIndex;
    if (indexes[count + 2] != 0) return error.InvalidStructuralIndex;
}

fn isWhitespace(byte: u8) bool {
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

fn isAtomStart(byte: u8) bool {
    return switch (byte) {
        '-', '0'...'9', 't', 'f', 'n' => true,
        else => false,
    };
}

fn indexForTest(
    allocator: std.mem.Allocator,
    input: []const u8,
) !stage1.StructuralIndex {
    var result = try stage1.StructuralIndex.init(allocator, input.len);
    errdefer result.deinit(allocator);

    var in_string = false;
    var backslash_count: usize = 0;
    var previous_in_atom = false;
    for (input, 0..) |byte, offset| {
        if (byte == '"' and backslash_count % 2 == 0) {
            if (!in_string) {
                result.indexes[result.count] = @intCast(offset);
                result.count += 1;
            }
            in_string = !in_string;
        } else if (!in_string) {
            if (isStructuralByte(byte)) {
                result.indexes[result.count] = @intCast(offset);
                result.count += 1;
            } else if (isAtomStart(byte) and !previous_in_atom) {
                result.indexes[result.count] = @intCast(offset);
                result.count += 1;
            }
        }

        previous_in_atom = !in_string and byte != '"' and
            !isStructuralByte(byte) and !isWhitespace(byte);
        if (byte == '\\') {
            backslash_count += 1;
        } else {
            backslash_count = 0;
        }
    }

    try result.finish(input.len);
    return result;
}

fn expectEvent(expected: Event, actual: Event) !void {
    try testing.expectEqual(std.meta.activeTag(expected), std.meta.activeTag(actual));
    switch (expected) {
        .key => |raw| switch (actual) {
            .key => |actual_raw| try testing.expectEqualStrings(raw, actual_raw),
            else => unreachable,
        },
        .string => |raw| switch (actual) {
            .string => |actual_raw| try testing.expectEqualStrings(raw, actual_raw),
            else => unreachable,
        },
        .number => |raw| switch (actual) {
            .number => |actual_raw| try testing.expectEqualStrings(raw, actual_raw),
            else => unreachable,
        },
        .bool => |value| switch (actual) {
            .bool => |actual_value| try testing.expectEqual(value, actual_value),
            else => unreachable,
        },
        else => {},
    }
}

test "Parser owns indexes and enforces one document and focus" {
    const input = "[0]";
    var structural_index = try indexForTest(testing.allocator, input);
    defer structural_index.deinit(testing.allocator);

    var parser = try Parser.init(testing.allocator, input.len);
    defer parser.deinit();
    var document = try parser.initDocument(input, &structural_index);
    defer document.deinit();

    try testing.expectError(error.DocumentActive, parser.initDocument(input, &structural_index));
    var cursor = try document.tokenCursor();
    try testing.expectError(error.FocusAlreadyClaimed, document.eventReader());

    var stale = cursor;
    _ = try cursor.advance();
    try testing.expectError(error.OutOfOrderIteration, stale.advance());
}

test "Parser preserves grow-on-demand policy across resizes" {
    const first_input = "[0,1,2]";
    const second_input = "[0,1,2,3,4,5,6,7,8,9]";

    var parser = try Parser.init(testing.allocator, 0);
    defer parser.deinit();
    try testing.expect(parser.grow_on_demand);

    var first_capacity: usize = 0;
    {
        const first_indexes = try parser.prepareDocument(first_input);
        for (first_input, 0..) |_, offset| {
            first_indexes[offset] = @intCast(offset);
        }
        var first_document = try parser.completeDocument(first_input, first_input.len);
        defer first_document.deinit();
        first_capacity = parser.capacity;
        try testing.expect(first_capacity >= first_input.len);
    }

    const second_indexes = try parser.prepareDocument(second_input);
    for (second_input, 0..) |_, offset| {
        second_indexes[offset] = @intCast(offset);
    }
    var second_document = try parser.completeDocument(second_input, second_input.len);
    defer second_document.deinit();

    try testing.expect(parser.grow_on_demand);
    try testing.expect(parser.capacity >= second_input.len);
    try testing.expect(parser.capacity > first_capacity);
}

test "TokenCursor exposes sentinels and skips one nested child" {
    const input = "[1,{\"a\":[true]},2]";
    var structural_index = try indexForTest(testing.allocator, input);
    defer structural_index.deinit(testing.allocator);

    var parser = try Parser.init(testing.allocator, input.len);
    defer parser.deinit();
    var document = try parser.initDocument(input, &structural_index);
    defer document.deinit();
    var cursor = try document.tokenCursor();

    try testing.expectEqual(@as(u8, '['), ((try cursor.advance()) orelse return error.TestUnexpectedResult).byte);
    try testing.expectEqual(@as(u8, '1'), ((try cursor.advance()) orelse return error.TestUnexpectedResult).byte);
    try testing.expectEqual(@as(u8, ','), ((try cursor.advance()) orelse return error.TestUnexpectedResult).byte);
    try testing.expectEqual(@as(u8, '{'), ((try cursor.advance()) orelse return error.TestUnexpectedResult).byte);
    try cursor.skipChild(1);
    try testing.expectEqual(@as(u8, ','), ((try cursor.peek()) orelse return error.TestUnexpectedResult).byte);

    while (try cursor.advance()) |_| {}
    try testing.expectEqual(@as(u32, @intCast(input.len)), try cursor.peekIndex(0));
    try testing.expectEqual(@as(u32, 0), try cursor.peekLength(0));
}

test "EventReader emits raw JSON events without allocation" {
    const input = "{\"text\":\"a\\\"b\",\"n\":-12.5,\"ok\":true,\"none\":null,\"a\":[false]}";
    var structural_index = try indexForTest(testing.allocator, input);
    defer structural_index.deinit(testing.allocator);

    var parser = try Parser.init(testing.allocator, input.len);
    defer parser.deinit();
    var document = try parser.initDocument(input, &structural_index);
    defer document.deinit();
    var reader = try document.eventReader();

    try expectEvent(.object_start, (try reader.next()) orelse return error.TestUnexpectedResult);
    try expectEvent(.{ .key = "text" }, (try reader.next()) orelse return error.TestUnexpectedResult);
    try expectEvent(.{ .string = "a\\\"b" }, (try reader.peek()) orelse return error.TestUnexpectedResult);
    try expectEvent(.{ .string = "a\\\"b" }, (try reader.next()) orelse return error.TestUnexpectedResult);
    try expectEvent(.{ .key = "n" }, (try reader.next()) orelse return error.TestUnexpectedResult);
    try expectEvent(.{ .number = "-12.5" }, (try reader.next()) orelse return error.TestUnexpectedResult);
    try expectEvent(.{ .key = "ok" }, (try reader.next()) orelse return error.TestUnexpectedResult);
    try expectEvent(.{ .bool = true }, (try reader.next()) orelse return error.TestUnexpectedResult);
    try expectEvent(.{ .key = "none" }, (try reader.next()) orelse return error.TestUnexpectedResult);
    try expectEvent(.null, (try reader.next()) orelse return error.TestUnexpectedResult);
    try expectEvent(.{ .key = "a" }, (try reader.next()) orelse return error.TestUnexpectedResult);
    try expectEvent(.array_start, (try reader.next()) orelse return error.TestUnexpectedResult);
    try expectEvent(.{ .bool = false }, (try reader.next()) orelse return error.TestUnexpectedResult);
    try expectEvent(.array_end, (try reader.next()) orelse return error.TestUnexpectedResult);
    try expectEvent(.object_end, (try reader.next()) orelse return error.TestUnexpectedResult);
    try testing.expect((try reader.next()) == null);
}

test "EventReader keeps failed peek sticky" {
    const input = "[,]";
    var structural_index = try indexForTest(testing.allocator, input);
    defer structural_index.deinit(testing.allocator);

    var parser = try Parser.init(testing.allocator, input.len);
    defer parser.deinit();
    var document = try parser.initDocument(input, &structural_index);
    defer document.deinit();
    var reader = try document.eventReader();

    try expectEvent(.array_start, (try reader.next()) orelse return error.TestUnexpectedResult);
    try testing.expectError(error.UnexpectedToken, reader.peek());
    try testing.expectError(error.UnexpectedToken, reader.next());
}

test "copied Document cannot claim shared event reader" {
    const input = "[1]";
    var structural_index = try indexForTest(testing.allocator, input);
    defer structural_index.deinit(testing.allocator);

    var parser = try Parser.init(testing.allocator, input.len);
    defer parser.deinit();
    var document = try parser.initDocument(input, &structural_index);
    defer document.deinit();
    var copied = document;

    var reader = try document.eventReader();
    try testing.expectError(error.FocusAlreadyClaimed, copied.eventReader());
    try expectEvent(.array_start, (try reader.next()) orelse return error.TestUnexpectedResult);
}

test "EventReader rejects trailing commas and malformed numbers" {
    const cases = [_]struct {
        input: []const u8,
        expected: Error,
    }{
        .{ .input = "[0,]", .expected = error.TrailingComma },
        .{ .input = "01", .expected = error.InvalidNumber },
    };

    for (cases) |case| {
        var structural_index = try indexForTest(testing.allocator, case.input);
        defer structural_index.deinit(testing.allocator);
        var parser = try Parser.init(testing.allocator, case.input.len);
        defer parser.deinit();
        var document = try parser.initDocument(case.input, &structural_index);
        defer document.deinit();
        var reader = try document.eventReader();

        var saw_error = false;
        while (!saw_error) {
            const event = reader.next() catch |err| {
                try testing.expectEqual(case.expected, err);
                saw_error = true;
                break;
            };
            if (event == null) return error.TestUnexpectedResult;
        }
    }
}

test "EventReader enforces the fixed depth bound" {
    var input: [2 * (max_depth + 1)]u8 = undefined;
    @memset(input[0 .. max_depth + 1], '[');
    @memset(input[max_depth + 1 ..], ']');

    var structural_index = try indexForTest(testing.allocator, &input);
    defer structural_index.deinit(testing.allocator);
    var parser = try Parser.init(testing.allocator, input.len);
    defer parser.deinit();
    var document = try parser.initDocument(&input, &structural_index);
    defer document.deinit();
    var reader = try document.eventReader();

    for (0..max_depth) |_| {
        try expectEvent(.array_start, (try reader.next()) orelse return error.TestUnexpectedResult);
    }
    try testing.expectError(error.DepthExceeded, reader.next());
}

test "EventReader handles zero-index quoted dialect roots" {
    const cases = [_]struct {
        input: []const u8,
        dialect: stage2.Dialect,
    }{
        .{ .input = "\"hello\"", .dialect = .jsonc },
        .{ .input = "'hello'", .dialect = .json5 },
    };

    for (cases) |case| {
        var parser = try Parser.init(testing.allocator, case.input.len);
        defer parser.deinit();
        _ = try parser.prepareDocument(case.input);
        var document = try parser.completeDialectDocument(case.input, 0, case.dialect);
        defer document.deinit();
        var reader = try document.eventReader();

        const raw = case.input[1 .. case.input.len - 1];
        const event = (try reader.next()) orelse return error.TestUnexpectedResult;
        try expectEvent(.{ .string = raw }, event);
        switch (event) {
            .string => |actual| try testing.expect(actual.ptr == raw.ptr),
            else => unreachable,
        }
        try testing.expect((try reader.next()) == null);
    }
}

test "EventReader completes JSONC comments and JSON5 syntax" {
    const cases = [_]struct {
        input: []const u8,
        offsets: []const u32,
        dialect: stage2.Dialect,
    }{
        .{
            .input = "{\"a\":1/*x*/}",
            .offsets = &.{ 0, 4, 5, 11 },
            .dialect = .jsonc,
        },
        .{
            .input = "{a:'x',}",
            .offsets = &.{ 0, 1, 2, 6, 7 },
            .dialect = .json5,
        },
    };

    for (cases) |case| {
        var parser = try Parser.init(testing.allocator, case.input.len);
        defer parser.deinit();
        const slots = try parser.prepareDocument(case.input);
        @memcpy(slots[0..case.offsets.len], case.offsets);
        var document = try parser.completeDialectDocument(
            case.input,
            case.offsets.len,
            case.dialect,
        );
        defer document.deinit();
        var reader = try document.eventReader();

        try expectEvent(.object_start, (try reader.next()) orelse return error.TestUnexpectedResult);
        try expectEvent(.{ .key = "a" }, (try reader.next()) orelse return error.TestUnexpectedResult);
        if (case.dialect == .jsonc) {
            try expectEvent(.{ .number = "1" }, (try reader.next()) orelse return error.TestUnexpectedResult);
        } else {
            try expectEvent(.{ .string = "x" }, (try reader.next()) orelse return error.TestUnexpectedResult);
        }
        try expectEvent(.object_end, (try reader.next()) orelse return error.TestUnexpectedResult);
        try testing.expect((try reader.next()) == null);
    }
}

test "EventReader rejects copies and released documents before source access" {
    const input = "[0]";
    var structural_index = try indexForTest(testing.allocator, input);
    defer structural_index.deinit(testing.allocator);

    var parser = try Parser.init(testing.allocator, input.len);
    defer parser.deinit();
    var document = try parser.initDocument(input, &structural_index);
    var reader = try document.eventReader();
    var copied = reader;

    try expectEvent(.array_start, (try reader.next()) orelse return error.TestUnexpectedResult);
    try testing.expectError(error.OutOfOrderIteration, copied.next());

    document.deinit();
    try testing.expectError(error.DocumentReleased, reader.next());
    try testing.expectError(error.DocumentReleased, copied.next());

    var reused = try parser.initDocument(input, &structural_index);
    defer reused.deinit();
    try testing.expectError(error.DocumentReleased, reader.next());
}

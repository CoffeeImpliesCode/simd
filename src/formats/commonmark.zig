//! CommonMark 0.31.2 semantic parser and HTML renderer.
//!
//! The module is reached as `simd.formats.commonmark`. Everything a consumer
//! needs is exported here: `parseCommonMark`, `renderCommonMarkHtml`,
//! `CommonMarkDocument` and its `ChildIterator`, the node, text and reference
//! types, the option types, and the two error sets. The sibling files under
//! `commonmark/` are entity, case-folding and punctuation tables reached only by
//! relative import and are not part of that surface.
//!
//! ```
//! var document = try commonmark.parseCommonMark(gpa, source, .{});
//! defer document.deinit();
//! const html = try commonmark.renderCommonMarkHtml(gpa, &document, .{});
//! defer gpa.free(html);
//! ```
//!
//! The caller owns `gpa` and `source` for as long as the document lives, and
//! releases the document with `CommonMarkDocument.deinit` and each rendered
//! buffer with the same allocator.
//!
//! This is not the marker-only `formats.markdown` tape and not an extension of
//! it, and it exposes no stream indexer. It performs no I/O of its own: it takes
//! no `std.Io`, opens nothing, and needs no clock or randomness. The trust
//! boundary in `HtmlRenderMode.conformance` belongs to the caller, because that
//! mode reproduces the specification's expected output, raw HTML included.

const std = @import("std");
const entity_table = @import("commonmark/entities.zig");
const casefold = @import("commonmark/unicode_casefold.zig");
const categories = @import("commonmark/unicode_categories.zig");
const max_u32 = std.math.maxInt(u32);
const max_usize = std.math.maxInt(usize);

/// Document-local index into `CommonMarkDocument.nodes`.
///
/// `root` is the `.document` node every parse appends first, and `none` marks an
/// absent parent, child or sibling. Every other value is the node's own
/// position in `nodes`, so an id means nothing outside the document that
/// produced it and is not a liveness proof: `CommonMarkDocument.node` answers
/// for any in-range id, including a node the child links no longer reach from
/// the root.
///
/// The enum is non-exhaustive, so a consumer switching over one needs an `else`.
pub const NodeId = enum(u32) {
    root = 0,
    none = max_u32,
    _,
};

/// Document-local index into `CommonMarkDocument.texts`, resolved by
/// `CommonMarkDocument.text`.
///
/// `none` marks an absent text: a link or image title the document carries no
/// value for, and the info string of an indented code block. The enum is
/// non-exhaustive, so a consumer switching over one needs an `else`.
pub const TextId = enum(u32) {
    none = max_u32,
    _,
};

/// Block or inline structure that one `Node` records.
pub const NodeKind = enum(u8) {
    /// The one root node of a document. It carries `NodeData.none` and renders
    /// nothing of its own.
    document,
    block_quote,
    list,
    list_item,
    paragraph,
    /// A block that held only link reference definitions. It stays in the tree
    /// carrying `NodeData.none` and renders nothing; the definitions themselves
    /// are in `CommonMarkDocument.references`.
    reference_definition,
    heading,
    thematic_break,
    code_block,
    html_block,
    /// One inline run of literal text, with its entity references, backslash
    /// escapes and line endings already resolved into `NodeData.raw`.
    text,
    softbreak,
    linebreak,
    code_span,
    emph,
    strong,
    link,
    image,
    autolink,
    html_inline,
};

/// Half-open byte range `[start, end)` of one node inside the `source` slice
/// given to `parseCommonMark`.
///
/// Both fields are byte offsets: `start` is included, `end` is one past the last
/// byte. A block node carries the range it occupies, from the start of the line
/// it began on to the end of the line that closed or last extended it, and the
/// root carries `0..source.len`. Every inline node carries `0..0`, so a zero span
/// means this record does not map to source, not that the node sits at offset
/// zero.
pub const SourceSpan = struct {
    start: u32,
    end: u32,
};

/// Orderedness and tightness of one `.list` node.
pub const ListData = struct {
    ordered: bool,
    /// First number of an ordered list, read from its marker and cut off after
    /// nine digits; always `1` for an unordered list.
    start: u32,
    /// `'.'` or `')'` after an ordered marker, and the bullet character
    /// (`'-'`, `'+'` or `'*'`) before an unordered one.
    delimiter: u8,
    /// Decided after parsing: a list is tight when no blank line separates two
    /// of its blocks or two of its items. A tight list renders the paragraphs
    /// directly inside it without the `<p>` wrapper.
    tight: bool,
};

/// Level and unparsed text of one `.heading` node.
pub const HeadingData = struct {
    /// `1` through `6`, from a run of `#` or from a `=`/`-` setext underline.
    level: u8,
    /// The heading's text before inline parsing, so its backslash escapes and
    /// entity references are still in source form.
    raw: TextId,
};

/// Fence and content of one `.code_block` node.
pub const CodeBlockData = struct {
    fenced: bool,
    /// The fence character opening and closing a fenced block, and `0` for an
    /// indented one.
    fence: u8,
    /// Length in characters of the opening fence run, and `0` for an indented
    /// block.
    fence_length: usize,
    /// Info string of a fenced block after link-destination cleaning, so its
    /// entity references and backslash escapes are resolved; `.none` when the
    /// block is indented.
    info: TextId,
    /// The code lines themselves, each terminated by '\n', with the block's own
    /// indentation and trailing blank lines removed. This is the block's
    /// content, not a byte range of `source`.
    raw: TextId,
};

/// Destination and title shared by `.link` and `.image` nodes.
pub const LinkData = struct {
    /// Destination after entity and backslash-escape resolution. A link or
    /// image reachable from the root always names one: an inline pair that
    /// resolved to nothing is removed from the tree instead of being left here
    /// with `.none`.
    destination: TextId,
    /// Title text, or `.none` when the document carries no title for it.
    title: TextId,
};

/// The payload one `Node` carries. The variant corresponds to the node's
/// `Node.kind`, though not always under the same name: every kind that carries
/// no payload uses `.none`, and every `.text`, `.code_span`, `.html_inline`,
/// `.paragraph` and `.html_block` node uses `.raw`.
///
/// A `TextId` here names the document's own semantic bytes and never a byte range
/// of `CommonMarkDocument.source`. What those bytes have been through depends on
/// the kind:
///
///   - A `.paragraph` and a `.heading` hold pre-inline text, so backslash
///     escapes, entity references and emphasis delimiters are still in source
///     form; the inline pass consumes that text afterwards.
///   - A `.text` node holds literal text whose entity references and backslash
///     escapes are already resolved, and an `.autolink` destination has the same
///     treatment.
///   - A `.code_span` and a `.code_block` keep literal content: escapes and
///     entities are not resolved, and a code span only folds line endings into
///     spaces.
///   - A `.html_block` and a `.html_inline` keep the literal tag text.
///
/// `CommonMarkOptions.invalid_utf8` and `.replace_nul` apply to every byte the
/// document records.
pub const NodeData = union(enum) {
    /// For every kind that carries no payload.
    none,
    /// Semantic bytes named by `TextId`, resolved to whatever extent the node's
    /// own `NodeKind` resolves them; see the type comment.
    raw: TextId,
    heading: HeadingData,
    list: ListData,
    code_block: CodeBlockData,
    link: LinkData,
    image: LinkData,
    /// The destination of an `.autolink`, without the `<>` that delimited it and
    /// without any `mailto:` prefix.
    autolink: TextId,
};

/// One node of a parsed document, obtained from `CommonMarkDocument.node`.
pub const Node = struct {
    kind: NodeKind,
    /// Containing node, or `.none` for the root and for a node no child link
    /// reaches any more.
    parent: NodeId,
    /// First child in document order, or `.none` for a leaf.
    first_child: NodeId,
    /// Last child in document order, or `.none` for a leaf.
    last_child: NodeId,
    /// Next sibling in document order, or `.none` at the end of the chain.
    next_sibling: NodeId,
    /// Range in `CommonMarkDocument.source`, and `0..0` for every inline node.
    source: SourceSpan,
    data: NodeData,
};

/// One entry of `CommonMarkDocument.texts`: a byte range inside `text_bytes`,
/// indexed by the `TextId` that names it.
pub const TextRecord = struct {
    start: u32,
    len: u32,
};

/// One link reference definition, collected in definition order.
pub const Reference = struct {
    /// Label after case folding and whitespace collapsing, so a consumer can
    /// compare bytes instead of normalizing a label again.
    label: TextId,
    /// Destination after entity and backslash-escape resolution.
    destination: TextId,
    /// Title, or `.none` when the definition carried none.
    title: TextId,
};

/// What `parseCommonMark` does with input bytes that are not valid UTF-8.
pub const InvalidUtf8Policy = enum {
    /// Copy such bytes through unchanged. The document may then hold a text that
    /// is not valid UTF-8.
    preserve,
    /// Substitute U+FFFD for each byte that does not begin a valid sequence, and
    /// keep every byte of one that does.
    replace,
    /// Reject the whole input with `error.InvalidUtf8` before parsing starts.
    reject,
};

/// Bounds and normalisation applied by one `parseCommonMark` call.
///
/// The defaults assume a caller that parses one document at a time from a
/// source buffer it already holds whole. No field is a hint: each one either
/// rejects the input or bounds the work. The struct is copied into the parser at
/// the call, so changing the caller's value afterwards does not affect it.
pub const CommonMarkOptions = struct {
    /// Largest accepted `source` length in bytes; a longer input fails with
    /// `error.InputTooLarge` before parsing starts, so `0` admits only empty
    /// input. Raise it for a document the default rejects, lower it to put a
    /// fixed ceiling on an input whose size the caller does not control.
    max_input_bytes: usize = 64 * 1024 * 1024,
    /// Largest number of nodes, counting the ones inline parsing detaches from
    /// the tree as well as the ones it keeps; exceeding it fails with
    /// `error.TooManyNodes`, and `0` rejects every input because even the root
    /// node exceeds it. Raise it for inline-heavy source, where delimiter runs
    /// outnumber blocks, lower it to bound node memory per input byte.
    max_nodes: usize = 1_000_000,
    /// Largest total length in bytes of `CommonMarkDocument.text_bytes`;
    /// exceeding it fails with `error.TextTooLarge`, and `0` admits no recorded
    /// text byte at all. A configured value above `4294967295` is capped to
    /// that, the largest offset a `TextRecord` can hold. Raise it for a document
    /// whose semantic text exceeds the default, lower it to bound text-arena
    /// memory.
    max_text_bytes: usize = 64 * 1024 * 1024,
    /// Largest number of link reference definitions; exceeding it fails with
    /// `error.TooManyReferences`, so `0` rejects a document that defines any.
    /// Raise it for a document whose definitions exceed the default, lower it to
    /// cap the definition table.
    max_reference_count: usize = 100_000,
    /// Largest number of emphasis delimiter runs held at once inside one block;
    /// the run that would exceed it fails with `error.TooManyDelimiters`, so `0`
    /// rejects any block holding a `*` or `_` delimiter run. Raise it for a
    /// block dense in emphasis, lower it to cap per-block inline state.
    max_delimiters: usize = 1_000_000,
    /// Largest number of bracket frames left open inside one block; the frame
    /// that would exceed it fails with `error.TooManyBrackets`, so `0` rejects
    /// any block that opens a bracket frame. Raise it for a block dense in
    /// brackets, lower it to cap per-block inline state.
    max_brackets: usize = 1_000_000,
    /// Deepest container nesting and deepest parent chain; either exceeding it
    /// fails with `error.NestingTooDeep`, and `0` admits only a document with no
    /// blocks, because every block adds a parent level. Raise it for deeply
    /// nested containers, lower it to cap nesting. A single line carrying more
    /// than 64 container prefixes fails the same way whatever this value is.
    max_depth: usize = 4096,
    /// Budget of charged parser steps, spent per scanned line, per scanned inline
    /// and label byte, per emphasis closer, and per list-finalization step. The
    /// step that would exceed it fails with `error.WorkLimit`, so `0` admits only
    /// empty input. Raise it for source large enough to exhaust the default,
    /// lower it to cap the work one call may do.
    max_work: u64 = 256 * 1024 * 1024,
    /// Default `.preserve`: bytes that are not valid UTF-8 are copied through.
    invalid_utf8: InvalidUtf8Policy = .preserve,
    /// Replaces each NUL byte in recorded text with U+FFFD. With `false` the NUL
    /// is copied through and the document holds a text containing one. This is
    /// independent of `invalid_utf8`, because NUL is valid UTF-8.
    replace_nul: bool = true,
};

/// How one `renderCommonMarkHtml` call treats raw HTML and link destinations.
pub const HtmlRenderMode = enum {
    /// The default. A `.html_block` or `.html_inline` node renders as
    /// `<!-- raw HTML omitted -->`, and a `.link`, `.image` or `.autolink` whose
    /// destination carries the `javascript:`, `vbscript:`, `file:` or `data:`
    /// scheme renders with an empty `href` or `src`. The scheme test ignores
    /// leading bytes at or below `0x20` and any `\t`, `\n` or `\r` inside the
    /// scheme, so a control-obfuscated scheme is still filtered.
    ///
    /// That is the whole policy, and it is a bounded one: ordinary HTML escaping
    /// of text and of attribute values, and URL percent encoding of
    /// destinations, still apply in this mode exactly as they do in
    /// `.conformance`. `.safe` is not a general-purpose sanitizer or transcoder.
    safe,
    /// Deliberately unsafe. Raw HTML is copied through verbatim and every
    /// destination is emitted, which is what reproduces the pinned
    /// specification's expected output. The caller owns the trust boundary in
    /// this mode.
    conformance,
};

/// Bounds and mode applied by one `renderCommonMarkHtml` call.
pub const HtmlRenderOptions = struct {
    /// Default `.safe`; see `HtmlRenderMode`.
    mode: HtmlRenderMode = .safe,
    /// Largest output length in bytes; the write that would exceed it fails with
    /// `error.OutputTooLarge`, so `0` admits only a document that renders no
    /// bytes at all. Raise it for a document the default rejects, lower it to cap
    /// the buffer one call may build.
    max_output_bytes: usize = 64 * 1024 * 1024,
};

/// Failures of `parseCommonMark`. Every one releases what the parser had built
/// and returns no document, so the caller owns nothing after a failure.
pub const ParseError = error{
    /// `source` is longer than `max_input_bytes`, or longer than the `u32` source
    /// offsets can address. Decided before parsing starts.
    InputTooLarge,
    /// The document would hold more than `max_nodes` nodes.
    TooManyNodes,
    /// Recorded text would exceed `max_text_bytes`.
    TextTooLarge,
    /// The document defines more than `max_reference_count` references.
    TooManyReferences,
    /// One block holds more than `max_delimiters` emphasis delimiter runs.
    TooManyDelimiters,
    /// One block leaves more than `max_brackets` bracket frames open.
    TooManyBrackets,
    /// Container nesting or a parent chain passed `max_depth`, or one line
    /// carried more than 64 container prefixes.
    NestingTooDeep,
    /// Charged parser work reached `max_work`.
    WorkLimit,
    /// `invalid_utf8` is `.reject` and `source` is not valid UTF-8. Decided
    /// before parsing starts, so no text was recorded.
    InvalidUtf8,
    /// Not produced by `parseCommonMark`; retained in the published set.
    InvalidSourceRange,
    /// The tree the parser built did not hold together: a link that left a node
    /// detached, an emphasis run that closed on nothing, or a parent chain that
    /// did not reach the root. A successful parse leaves none of these.
    InvalidDocument,
    /// An allocation failed while the document was being built.
    OutOfMemory,
};

/// Failures of `renderCommonMarkHtml`. Every one releases the output built so
/// far and returns no bytes.
pub const RenderError = error{
    /// The output passed `max_output_bytes`.
    OutputTooLarge,
    /// The document is not walkable: the root is missing or is not a detached
    /// `.document` node, a child or parent link is dangling or crosses parents,
    /// or the walk did not finish within twice the node count in steps.
    InvalidDocument,
    /// Not produced by `renderCommonMarkHtml`; retained in the published set.
    WorkLimit,
    /// An allocation failed while the output was being built.
    OutOfMemory,
};

/// One parsed document: a node table, a text table with its bytes, and the link
/// reference definitions, all allocated from the caller's allocator.
///
/// The document owns `nodes`, `texts`, `text_bytes` and `references`, stores
/// `allocator` so `deinit` can release them into the same one, and borrows
/// `source` without ever freeing it. One owner releases all four, once. Copying
/// the struct duplicates the handle and not the storage: the copy frees nothing,
/// and the hazard is a second `deinit` reached through either copy.
///
/// Parsing allocates each owned slice once. Accessors never resize it, so views
/// into that storage remain valid until `deinit`. The document itself may move;
/// those views point into its allocations, not into the struct.
///
/// Keep `allocator` and the owned slice handles unchanged. `deinit` needs the
/// original allocations and their compatible allocator, whose backing state
/// must remain alive. Replacing a handle can leak an allocation or cause invalid
/// cleanup; assignment alone does not free the old allocation.
///
/// The fields are writable, not private. Writes through their slices change later
/// reads without moving the allocation. Preserve node links, payload kinds and
/// text ranges when modifying values; accessors do not validate the whole tree.
///
/// Readers may share a document only while nobody mutates or deinitializes it.
/// Concurrent render calls also require an allocator that permits that use.
///
/// There is no empty or default instance: a `parseCommonMark` call always
/// produces at least the `.document` root, even for empty input.
pub const CommonMarkDocument = struct {
    /// Allocator every owned slice came from. `deinit` frees into it and never
    /// releases it; the allocator is the caller's, and its backing state must
    /// outlive `deinit`.
    allocator: std.mem.Allocator,
    /// The source bytes, borrowed from the `parseCommonMark` argument. No
    /// accessor reads this field and no `Node.source` offset is checked against
    /// it, so the borrow is recorded rather than enforced.
    source: []const u8,
    /// Node table; index `n` holds the `NodeId` value `n`.
    nodes: []Node,
    /// Text table; index `n` holds the `TextId` value `n`.
    texts: []TextRecord,
    /// The bytes every `TextRecord` range indexes into.
    text_bytes: []u8,
    /// Link reference definitions in definition order. The `.reference_definition`
    /// nodes that carried them hold no payload; the definitions live here.
    references: []Reference,

    /// Releases `references`, `text_bytes`, `texts` and `nodes` into `allocator`.
    /// `source` is borrowed and is not freed, and the allocator is not released.
    ///
    /// The document, and every pointer or slice taken from it, are invalid
    /// afterward, and the struct is overwritten with `undefined`. Exactly one
    /// `deinit` releases that storage; a second one, on this value or through a
    /// copy of it, frees the same bytes again.
    pub fn deinit(self: *CommonMarkDocument) void {
        self.allocator.free(self.references);
        self.allocator.free(self.text_bytes);
        self.allocator.free(self.texts);
        self.allocator.free(self.nodes);
        self.* = undefined;
    }

    /// Returns `NodeId.root`, the document node's fixed identifier.
    pub fn root(self: *const CommonMarkDocument) NodeId {
        _ = self;
        return .root;
    }

    /// The node `id` names, or `null` when `id` is out of range for `nodes`.
    ///
    /// The pointer aliases `nodes` and keeps a fixed address until `deinit`. A
    /// `null` result says only that the id is out of range: an id inside the
    /// table names a node even when the child links no longer reach it.
    pub fn node(self: *const CommonMarkDocument, id: NodeId) ?*const Node {
        const index = @backingInt(id);
        if (index >= self.nodes.len) return null;
        return &self.nodes[index];
    }

    /// A `ChildIterator` over the children of `id`, in document order.
    ///
    /// The iterator borrows the document at the address `self` holds, so that
    /// address must stay live and unmodified while the iterator is used: moving
    /// the document value afterwards leaves the iterator on the original
    /// storage. An `id` naming no node, and a node with no children, both yield
    /// an iterator whose first `nextChild` returns `null`.
    pub fn nodeChildren(self: *const CommonMarkDocument, id: NodeId) ChildIterator {
        const first = if (self.node(id)) |value| value.first_child else .none;
        return .{
            .document = self,
            .next = first,
            .remaining = self.nodes.len,
        };
    }

    /// The bytes of the text `id` names, or `null` when `id` is out of range for
    /// `texts` or its record does not fit in `text_bytes`.
    ///
    /// The slice aliases `text_bytes` and stays valid until `deinit`; parsing has
    /// finished, so no later call resizes the arena. These are the cooked bytes
    /// recorded for a node, not a byte range of `source`.
    pub fn text(self: *const CommonMarkDocument, id: TextId) ?[]const u8 {
        const index = @backingInt(id);
        if (index >= self.texts.len) return null;
        const record = self.texts[index];
        const start: usize = record.start;
        const len: usize = record.len;
        if (start > self.text_bytes.len or len > self.text_bytes.len - start) return null;
        return self.text_bytes[start .. start + len];
    }

    /// Forward walk over one node's children, driven by `nextChild`.
    ///
    /// The iterator borrows the document, so the address obligation on
    /// `nodeChildren` applies to it. It is a value, so a copy is a second walk
    /// over the same children rather than a second owner, and it is not
    /// reentrant: the calls share one position.
    pub const ChildIterator = struct {
        /// The document being walked, at the address held when `nodeChildren`
        /// ran.
        document: *const CommonMarkDocument,
        /// The node `nextChild` will yield next, or `.none` once the chain ends.
        next: NodeId,
        /// Steps left before the walk is declared invalid. It starts at the node
        /// count, so a chain that cannot terminate trips `isInvalid` instead of
        /// looping.
        remaining: usize,
        /// Set once the walk hit a dangling link or ran past the node count, and
        /// cleared only by a fresh `nodeChildren`.
        invalid: bool = false,

        /// The next child, advancing the walk, or `null` at the end of the chain.
        ///
        /// `null` covers both the ordinary end of the chain and a chain that hit
        /// a dangling link or ran past the node count; `isInvalid` tells the two
        /// apart. The iterator stays exhausted once this has returned `null`.
        pub fn nextChild(self: *ChildIterator) ?NodeId {
            if (self.next == .none) return null;
            if (self.remaining == 0) {
                self.invalid = true;
                self.next = .none;
                return null;
            }
            const current = self.next;
            const value = self.document.node(current) orelse {
                self.invalid = true;
                self.next = .none;
                return null;
            };
            self.remaining -= 1;
            self.next = value.next_sibling;
            return current;
        }

        /// Whether the walk hit a dangling link or ran past the node count, which
        /// means the document's child links are malformed.
        pub fn isInvalid(self: *const ChildIterator) bool {
            return self.invalid;
        }
    };
};

const Line = struct {
    start: usize,
    end: usize,
    next: usize,
    content_start: usize,
    indent: usize,
    blank: bool,
};

const PrefixKind = enum { quote, list };

const Prefix = struct {
    kind: PrefixKind,
    start: usize,
    marker: u8,
    ordered: bool,
    list_start: u32,
    delimiter: u8,
    indent: usize,
    continuation_indent: usize,
    content_start: usize,
};

const Prefixes = struct {
    // SAFETY: every write fills `items[len]` before `len` is incremented, and
    // every read is guarded by `len`, so an entry past `len` is never read.
    items: [64]Prefix = undefined,
    len: u32 = 0,
    content_start: usize = 0,

    pub fn clear(self: *Prefixes) void {
        self.len = 0;
        self.content_start = 0;
    }
};

const prefix_depth = 128;

const ActiveBlock = struct {
    node: NodeId,
    container: NodeId,
    code_fence: u8 = 0,
    code_fence_length: usize = 0,
    code_indent: u8 = 0,
    html_tag: u8 = 0,
};

const Builder = struct {
    gpa: std.mem.Allocator,
    source: []const u8,
    options: CommonMarkOptions,
    nodes: std.ArrayList(Node) = .empty,
    texts: std.ArrayList(TextRecord) = .empty,
    text_bytes: std.ArrayList(u8) = .empty,
    lines: std.ArrayList(Line) = .empty,
    references: std.ArrayList(Reference) = .empty,
    work: u64 = 0,

    fn charge(self: *Builder, amount: u64) ParseError!void {
        if (amount > self.options.max_work -| self.work) return error.WorkLimit;
        self.work += amount;
    }

    fn appendText(self: *Builder, bytes: []const u8) ParseError!TextId {
        if (bytes.len > self.options.max_text_bytes) return error.TextTooLarge;
        if (self.text_bytes.items.len > @as(usize, self.options.max_text_bytes) - bytes.len) {
            return error.TextTooLarge;
        }
        if (bytes.len > self.text_bytes.capacity -| self.text_bytes.items.len) return error.TextTooLarge;
        // `TextId.none` is `maxInt(u32)`, so that index is reserved.
        if (@as(usize, max_u32) <= self.texts.items.len) return error.TextTooLarge;
        const start = self.text_bytes.items.len;
        const index = self.texts.items.len;
        self.text_bytes.appendSlice(self.gpa, bytes) catch return error.OutOfMemory;
        self.texts.append(self.gpa, .{
            .start = @intCast(start),
            .len = @intCast(bytes.len),
        }) catch return error.OutOfMemory;
        return @fromBackingInt(@intCast(@as(u32, @intCast(index))));
    }

    fn appendTextNormalized(self: *Builder, bytes: []const u8) ParseError!TextId {
        const start = self.text_bytes.items.len;
        try self.appendNormalizedBytes(bytes);
        const grown = self.text_bytes.items.len - start;
        if (grown > self.options.max_text_bytes) return error.TextTooLarge;
        // `TextId.none` is `maxInt(u32)`, so that index is reserved.
        if (@as(usize, max_u32) <= self.texts.items.len) return error.TextTooLarge;
        const index = self.texts.items.len;
        self.texts.append(self.gpa, .{
            .start = @intCast(start),
            .len = @intCast(grown),
        }) catch return error.OutOfMemory;
        return @fromBackingInt(@intCast(@as(u32, @intCast(index))));
    }

    fn appendNormalizedBytes(self: *Builder, bytes: []const u8) ParseError!void {
        var index: usize = 0;
        while (index < bytes.len) {
            var run_end = index;
            while (run_end < bytes.len and bytes[run_end] != 0 and bytes[run_end] < 0x80) : (run_end += 1) {}
            if (run_end > index) {
                const run_len = run_end - index;
                try self.charge(run_len);
                try self.appendBytesToCurrent(bytes[index..run_end]);
                index = run_end;
                if (index == bytes.len) break;
            }

            try self.charge(1);
            const byte = bytes[index];
            if (byte == 0 and self.options.replace_nul) {
                try self.appendBytesToCurrent("\xEF\xBF\xBD");
                index += 1;
                continue;
            }
            if (self.options.invalid_utf8 == .replace and byte >= 0x80) {
                const width: usize = if ((byte & 0xE0) == 0xC0)
                    2
                else if ((byte & 0xF0) == 0xE0)
                    3
                else if ((byte & 0xF8) == 0xF0)
                    4
                else
                    0;
                if (width != 0 and index + width <= bytes.len and
                    std.unicode.utf8ValidateSlice(bytes[index .. index + width]))
                {
                    try self.appendBytesToCurrent(bytes[index .. index + width]);
                    index += width;
                    continue;
                }
                try self.appendBytesToCurrent("\xEF\xBF\xBD");
                index += 1;
                continue;
            }
            try self.appendBytesToCurrent(bytes[index .. index + 1]);
            index += 1;
        }
    }

    fn appendBytesToCurrent(self: *Builder, bytes: []const u8) ParseError!void {
        if (bytes.len > @as(usize, self.options.max_text_bytes) -| self.text_bytes.items.len) {
            return error.TextTooLarge;
        }
        if (bytes.len > self.text_bytes.capacity -| self.text_bytes.items.len) return error.TextTooLarge;
        self.text_bytes.appendSlice(self.gpa, bytes) catch return error.OutOfMemory;
    }

    fn appendNode(
        self: *Builder,
        kind: NodeKind,
        parent: NodeId,
        source: SourceSpan,
        data: NodeData,
    ) ParseError!NodeId {
        if (self.nodes.items.len >= self.options.max_nodes) return error.TooManyNodes;
        if (@as(usize, std.math.maxInt(u32)) <= self.nodes.items.len) return error.TooManyNodes;
        const id: NodeId = @fromBackingInt(@intCast(@as(u32, @intCast(self.nodes.items.len))));
        self.nodes.append(self.gpa, .{
            .kind = kind,
            .parent = parent,
            .first_child = .none,
            .last_child = .none,
            .next_sibling = .none,
            .source = source,
            .data = data,
        }) catch return error.OutOfMemory;
        if (parent != .none) self.addChild(parent, id) catch return error.InvalidDocument;
        return id;
    }

    fn addChild(self: *Builder, parent: NodeId, child: NodeId) !void {
        const parent_index = @backingInt(parent);
        const child_index = @backingInt(child);
        if (parent_index >= self.nodes.items.len or child_index >= self.nodes.items.len) return error.InvalidDocument;
        if (self.nodes.items[parent_index].last_child == .none) {
            self.nodes.items[parent_index].first_child = child;
        } else {
            const last = @backingInt(self.nodes.items[parent_index].last_child);
            self.nodes.items[last].next_sibling = child;
        }
        self.nodes.items[parent_index].last_child = child;
    }

    fn insertAfter(self: *Builder, parent: NodeId, after: NodeId, child: NodeId) !void {
        const parent_index = @backingInt(parent);
        const after_index = @backingInt(after);
        const child_index = @backingInt(child);
        if (parent_index >= self.nodes.items.len or
            after_index >= self.nodes.items.len or
            child_index >= self.nodes.items.len)
        {
            return error.InvalidDocument;
        }
        if (self.nodes.items[after_index].parent != parent) return error.InvalidDocument;
        self.nodes.items[child_index].parent = parent;
        self.nodes.items[child_index].next_sibling = self.nodes.items[after_index].next_sibling;
        self.nodes.items[after_index].next_sibling = child;
        if (self.nodes.items[parent_index].last_child == after) self.nodes.items[parent_index].last_child = child;
    }

    fn updateSpan(self: *Builder, id: NodeId, end: u32) void {
        const index = @backingInt(id);
        if (index < self.nodes.items.len) self.nodes.items[index].source.end = end;
    }

    fn rawText(self: *const Builder, id: TextId) []const u8 {
        const index = @backingInt(id);
        if (index >= self.texts.items.len) return "";
        const record = self.texts.items[index];
        return self.text_bytes.items[record.start .. record.start + record.len];
    }
};

fn validateTreeDepth(builder: *const Builder) ParseError!void {
    if (builder.nodes.items.len == 0 or builder.nodes.items[0].kind != .document) {
        return error.InvalidDocument;
    }
    for (1..builder.nodes.items.len) |index| {
        if (builder.nodes.items[index].parent == .none) continue;
        var current: NodeId = @fromBackingInt(@intCast(@as(u32, @intCast(index))));
        var depth: usize = 0;
        while (current != .root) {
            if (depth >= builder.options.max_depth) return error.NestingTooDeep;
            const current_index = @backingInt(current);
            if (current_index >= builder.nodes.items.len) return error.InvalidDocument;
            const parent = builder.nodes.items[current_index].parent;
            if (parent == .none) return error.InvalidDocument;
            current = parent;
            depth += 1;
            if (depth > builder.nodes.items.len) return error.InvalidDocument;
        }
    }
}

/// Parses `source` as CommonMark 0.31.2 into a document that owns `nodes`,
/// `texts`, `text_bytes` and `references` and borrows `source`.
///
/// `gpa` receives every owned allocation; its backing state must remain alive
/// through `CommonMarkDocument.deinit`. Keep `source` alive and unchanged through
/// that release as the document's recorded borrow requires. Semantic text is
/// copied or cooked into owned storage; accessors and rendering do not read the
/// original source. The source field supports caller-directed span lookup.
///
/// On any `ParseError` the parser releases what it had built and returns no
/// document, so the caller owns nothing after a failure and the call is
/// retryable with other options. `error.InputTooLarge`, and with `invalid_utf8`
/// set to `.reject` also `error.InvalidUtf8`, are decided before parsing starts;
/// the limit tags are decided partway through and leave the same residue, none.
pub fn parseCommonMark(
    gpa: std.mem.Allocator,
    source: []const u8,
    options: CommonMarkOptions,
) ParseError!CommonMarkDocument {
    if (source.len > options.max_input_bytes) return error.InputTooLarge;
    if (@as(usize, std.math.maxInt(u32)) < source.len) return error.InputTooLarge;
    if (options.invalid_utf8 == .reject and !std.unicode.utf8ValidateSlice(source)) return error.InvalidUtf8;

    var builder: Builder = .{ .gpa = gpa, .source = source, .options = options };
    // `TextRecord.start`/`.len` are `u32`, so the text arena has an inherent
    // 4 GiB ceiling. A larger configured budget cannot be honoured, so it is
    // capped once here instead of rejecting the caller: `appendText` and
    // `appendBytesToCurrent` already refuse to grow the arena past
    // `max_text_bytes`, which now bounds every recorded start, length and end.
    builder.options.max_text_bytes = @min(builder.options.max_text_bytes, @as(usize, max_u32));
    errdefer {
        builder.references.deinit(gpa);
        builder.lines.deinit(gpa);
        builder.text_bytes.deinit(gpa);
        builder.texts.deinit(gpa);
        builder.nodes.deinit(gpa);
    }

    _ = try builder.appendNode(.document, .none, .{ .start = 0, .end = 0 }, .none);
    try scanLines(&builder);
    try reserveInlineText(&builder);
    try parseBlocks(&builder);
    builder.nodes.items[0].source.end = @intCast(source.len);
    try extractReferences(&builder);
    try parseAllInlines(&builder);
    try finalizeLists(&builder);
    try validateTreeDepth(&builder);

    const nodes = builder.nodes.toOwnedSlice(gpa) catch return error.OutOfMemory;
    errdefer gpa.free(nodes);
    const texts = builder.texts.toOwnedSlice(gpa) catch return error.OutOfMemory;
    errdefer gpa.free(texts);
    const text_bytes = builder.text_bytes.toOwnedSlice(gpa) catch return error.OutOfMemory;
    errdefer gpa.free(text_bytes);
    const lines = builder.lines.toOwnedSlice(gpa) catch return error.OutOfMemory;
    gpa.free(lines);
    const references = builder.references.toOwnedSlice(gpa) catch return error.OutOfMemory;
    return .{
        .allocator = gpa,
        .source = source,
        .nodes = nodes,
        .texts = texts,
        .text_bytes = text_bytes,
        .references = references,
    };
}

fn scanLines(builder: *Builder) ParseError!void {
    var start: usize = 0;
    while (start < builder.source.len) {
        try builder.charge(1);
        var end = start;
        while (end < builder.source.len and builder.source[end] != '\n' and builder.source[end] != '\r') : (end += 1) {}
        var next = end;
        if (next < builder.source.len) {
            if (builder.source[next] == '\r' and next + 1 < builder.source.len and builder.source[next + 1] == '\n') {
                next += 2;
            } else {
                next += 1;
            }
        }
        var content_start = start;
        var column: usize = 0;
        var byte_index = start;
        while (byte_index < end) {
            const byte = builder.source[byte_index];
            if (byte == ' ') {
                column += 1;
                byte_index += 1;
            } else if (byte == '\t') {
                const step: usize = 4 - (column % 4);
                column += step;
                byte_index += 1;
            } else {
                break;
            }
        }
        content_start = byte_index;
        builder.lines.append(builder.gpa, .{
            .start = @intCast(start),
            .end = @intCast(end),
            .next = @intCast(next),
            .content_start = @intCast(content_start),
            .indent = column,
            .blank = content_start == end,
        }) catch return error.OutOfMemory;
        if (next == builder.source.len) break;
        start = next;
    }
    // Empty input has no physical lines and therefore no blocks.
}

fn parsePrefixes(builder: *Builder, line: Line, result: *Prefixes) ParseError!void {
    result.clear();
    var cursor: usize = line.start;
    var column: usize = 0;
    while (cursor < line.end) {
        if (result.len >= result.items.len) return error.NestingTooDeep;
        while (cursor < line.end and (builder.source[cursor] == ' ' or builder.source[cursor] == '\t')) {
            if (builder.source[cursor] == ' ') {
                column += 1;
            } else {
                column += @intCast(4 - (column % 4));
            }
            cursor += 1;
        }
        if (cursor < line.end and builder.source[cursor] == '>') {
            const quote_indent = column;
            cursor += 1;
            column += 1;
            if (cursor < line.end and (builder.source[cursor] == ' ' or builder.source[cursor] == '\t')) {
                if (builder.source[cursor] == ' ') {
                    column += 1;
                } else {
                    column += @intCast(4 - (column % 4));
                }
                cursor += 1;
            }
            result.items[result.len] = .{
                .kind = .quote,
                .start = @intCast(cursor - 1),
                .marker = 0,
                .ordered = false,
                .list_start = 0,
                .delimiter = 0,
                .indent = quote_indent,
                .continuation_indent = column,
                .content_start = @intCast(cursor),
            };
            result.len += 1;
            var lookahead = cursor;
            while (lookahead < line.end and (builder.source[lookahead] == ' ' or builder.source[lookahead] == '\t')) {
                lookahead += 1;
            }
            const next_is_prefix = lookahead < line.end and
                (builder.source[lookahead] == '>' or builder.source[lookahead] == '-' or
                    builder.source[lookahead] == '+' or builder.source[lookahead] == '*' or
                    std.ascii.isDigit(builder.source[lookahead]));
            if (!next_is_prefix) {
                result.content_start = cursor;
                break;
            }
            continue;
        }
        if (result.len > 0 and isThematicBreak(builder.source[cursor..line.end])) break;
        const marker_start = cursor;
        if (cursor < line.end and (builder.source[cursor] == '-' or
            builder.source[cursor] == '+' or builder.source[cursor] == '*'))
        {
            const marker = builder.source[cursor];
            cursor += 1;
            if (cursor < line.end and builder.source[cursor] != ' ' and builder.source[cursor] != '\t') {
                cursor = marker_start;
                break;
            }
            const padding_start = cursor;
            var tab_count: usize = 0;
            var space_count: usize = 0;
            var continuation_indent: usize = column + 1;
            while (cursor < line.end and (builder.source[cursor] == ' ' or builder.source[cursor] == '\t')) {
                if (builder.source[cursor] == ' ') {
                    space_count += 1;
                    continuation_indent += 1;
                } else {
                    tab_count += 1;
                    continuation_indent += @intCast(4 - (continuation_indent % 4));
                }
                cursor += 1;
            }
            const has_content = cursor < line.end;
            const excess_padding = tab_count >= 2 or (tab_count == 0 and space_count > 4);
            if (excess_padding) {
                cursor = padding_start + 1;
                continuation_indent = column + 2;
            } else if (!has_content) {
                continuation_indent = column + 2;
            }
            result.items[result.len] = .{
                .kind = .list,
                .start = @intCast(marker_start),
                .marker = marker,
                .ordered = false,
                .list_start = 1,
                .delimiter = marker,
                .indent = column,
                .continuation_indent = continuation_indent,
                .content_start = @intCast(cursor),
            };
            result.len += 1;
            column = continuation_indent;
            if (excess_padding) break;
            continue;
        }
        if (cursor < line.end and std.ascii.isDigit(builder.source[cursor])) {
            var value: u32 = 0;
            var digits: u8 = 0;
            while (cursor < line.end and std.ascii.isDigit(builder.source[cursor]) and digits < 9) : (digits += 1) {
                value = value * 10 + (builder.source[cursor] - '0');
                cursor += 1;
            }
            if (cursor < line.end and (builder.source[cursor] == '.' or builder.source[cursor] == ')')) {
                const delimiter = builder.source[cursor];
                cursor += 1;
                if (cursor < line.end and builder.source[cursor] != ' ' and builder.source[cursor] != '\t') {
                    cursor = marker_start;
                    break;
                }
                const padding_start = cursor;
                var tab_count: usize = 0;
                var space_count: usize = 0;
                var continuation_indent = column + cursor - marker_start;
                while (cursor < line.end and (builder.source[cursor] == ' ' or builder.source[cursor] == '\t')) {
                    if (builder.source[cursor] == ' ') {
                        space_count += 1;
                        continuation_indent += 1;
                    } else {
                        tab_count += 1;
                        continuation_indent += @intCast(4 - (continuation_indent % 4));
                    }
                    cursor += 1;
                }
                const has_content = cursor < line.end;
                const excess_padding = tab_count >= 2 or (tab_count == 0 and space_count > 4);
                if (excess_padding) {
                    cursor = padding_start + 1;
                    continuation_indent = column + cursor - marker_start;
                } else if (!has_content) {
                    continuation_indent = column + cursor - marker_start;
                }
                result.items[result.len] = .{
                    .kind = .list,
                    .start = @intCast(marker_start),
                    .marker = 0,
                    .ordered = true,
                    .list_start = value,
                    .delimiter = delimiter,
                    .indent = column,
                    .continuation_indent = continuation_indent,
                    .content_start = @intCast(cursor),
                };
                result.len += 1;
                column = continuation_indent;
                if (excess_padding) break;
                continue;
            }
        }
        break;
    }
    result.content_start = if (result.len == 0) line.start else cursor;
}

fn leadingIndentColumns(source: []const u8, start: usize, end: usize) usize {
    var index = start;
    var columns: usize = 0;
    while (index < end) : (index += 1) {
        if (source[index] == ' ') {
            columns += 1;
        } else if (source[index] == '\t') {
            columns += 4 - (columns % 4);
        } else {
            break;
        }
    }
    return columns;
}

fn retainedListDepthForIndent(
    prefixes: *const [prefix_depth]Prefix,
    len: u32,
    indent: usize,
) u32 {
    var depth: u32 = 0;
    var retained: u32 = 0;
    containers: while (depth < len) {
        switch (prefixes[depth].kind) {
            .quote => break :containers,
            .list => {
                if (depth + 1 >= len or indent < prefixes[depth].continuation_indent) {
                    break :containers;
                }
                retained = depth + 2;
                depth += 2;
            },
        }
    }
    return retained;
}

fn parseBlocks(builder: *Builder) ParseError!void {
    const root = NodeId.root;
    var container_nodes: [prefix_depth]NodeId = @splat(.none);
    var container_prefixes: [prefix_depth]Prefix = undefined;
    var container_len: u32 = 0;
    var active: ?ActiveBlock = null;
    var line_index: usize = 0;
    var blank_line_pending = false;
    while (line_index < builder.lines.items.len) : (line_index += 1) {
        const line = builder.lines.items[line_index];
        var prefixes: Prefixes = .{};
        if (active) |block| {
            const block_node = builder.nodes.items[@backingInt(block.node)];
            if (block_node.kind == .html_block or
                (block_node.kind == .code_block and block.code_fence != 0))
            {
                if (container_len == 0) {
                    prefixes.clear();
                    prefixes.content_start = line.start;
                } else {
                    try parsePrefixes(builder, line, &prefixes);
                }
            } else {
                try parsePrefixes(builder, line, &prefixes);
            }
        } else {
            try parsePrefixes(builder, line, &prefixes);
        }
        if (container_len == 0 and prefixes.len != 0 and
            prefixes.items[0].kind == .list and
            prefixes.items[0].ordered and
            prefixes.items[0].list_start != 1 and
            active != null and builder.nodes.items[@backingInt(active.?.node)].kind == .paragraph)
        {
            prefixes.clear();
            prefixes.content_start = line.start;
        }
        if (line.indent <= 3 and isThematicBreak(builder.source[line.content_start..line.end])) {
            prefixes.clear();
            prefixes.content_start = line.content_start;
        }
        if (container_len == 0 and active != null and prefixes.len == 1 and
            prefixes.items[0].kind == .list and prefixes.content_start == line.end)
        {
            prefixes.clear();
            prefixes.content_start = line.content_start;
        }
        var next_len: u32 = 0;
        if (prefixes.len == 0) {
            if (container_len != 0) {
                const last_prefix = container_prefixes[container_len - 1];
                const active_is_paragraph = if (active) |b|
                    builder.nodes.items[@backingInt(b.node)].kind == .paragraph
                else
                    false;
                const is_setext = line.indent >= last_prefix.continuation_indent and
                    isSetextUnderline(builder.source[line.content_start..line.end]) != null;
                const interrupts = !line.blank and (!is_setext or !active_is_paragraph) and
                    isInterruptingBlock(builder.source[line.content_start..line.end]);
                if (line.blank) {
                    if (last_prefix.kind == .quote) {
                        next_len = 0;
                    } else {
                        next_len = container_len;
                    }
                } else if (active_is_paragraph and !interrupts) {
                    next_len = container_len;
                } else if (last_prefix.kind == .list and line.indent >= last_prefix.continuation_indent and
                    !(blank_line_pending and
                        builder.nodes.items[@backingInt(container_nodes[container_len - 1])].first_child == .none))
                {
                    next_len = container_len;
                } else {
                    const retained = retainedListDepthForIndent(&container_prefixes, container_len, line.indent);
                    if (retained != 0 and
                        !(blank_line_pending and
                            builder.nodes.items[@backingInt(container_nodes[retained - 1])].first_child == .none))
                    {
                        next_len = retained;
                    }
                }
            }
        }
        if (prefixes.len != 0) {
            var prefix_index: u32 = 0;
            var depth: u32 = 0;
            // Try to match existing open container stack:
            // A quote container matches if prefix is a quote.
            // A list container matches if line continues it (indent >= continuation_indent)
            // or if a new list item marker at the same indent is present.
            while (depth < container_len) {
                if (container_prefixes[depth].kind == .quote) {
                    if (prefix_index < prefixes.len and prefixes.items[prefix_index].kind == .quote) {
                        depth += 1;
                        prefix_index += 1;
                    } else {
                        break;
                    }
                } else if (container_prefixes[depth].kind == .list) {
                    const old = container_prefixes[depth];
                    if (prefix_index < prefixes.len and prefixes.items[prefix_index].kind == .list and
                        prefixes.items[prefix_index].indent < old.continuation_indent and
                        (depth != 0 or prefixes.items[prefix_index].indent <= 3) and
                        prefixes.items[prefix_index].ordered == old.ordered and
                        (old.ordered == false or prefixes.items[prefix_index].delimiter == old.delimiter) and
                        prefixes.items[prefix_index].marker == old.marker)
                    {
                        // New item in the same list!
                        const list = container_nodes[depth];
                        const item = try builder.appendNode(.list_item, list, lineSpan(line), .none);
                        container_nodes[depth + 1] = item;
                        container_prefixes[depth] = prefixes.items[prefix_index];
                        container_prefixes[depth + 1] = prefixes.items[prefix_index];
                        active = null;
                        depth += 2;
                        prefix_index += 1;
                    } else if (prefix_index < prefixes.len and
                        prefixes.items[prefix_index].indent >= old.continuation_indent)
                    {
                        // The prefix belongs to a child/inner container inside this list item!
                        depth += 2;
                    } else if (prefix_index < prefixes.len and prefixes.items[prefix_index].kind == .list and
                        prefixes.items[prefix_index].indent >= 4 and
                        prefixes.items[prefix_index].indent < old.continuation_indent and
                        (line_index == 0 or !builder.lines.items[line_index - 1].blank))
                    {
                        // A marker indented within the current item is lazy text unless
                        // a preceding blank line makes it a new block.
                        depth += 2;
                    } else if (prefix_index == prefixes.len and prefixes.len != 0 and
                        leadingIndentColumns(builder.source, prefixes.content_start, line.end) >=
                            old.continuation_indent - old.indent)
                    {
                        const relative_indent = old.continuation_indent - old.indent;
                        prefixes.content_start = skipIndentColumns(
                            builder.source,
                            prefixes.content_start,
                            line.end,
                            relative_indent,
                        );
                        depth += 2;
                    } else if (line.indent >= old.continuation_indent) {
                        // The line continues this list item!
                        depth += 2;
                    } else {
                        break;
                    }
                } else {
                    break;
                }
            }
            // Then, if the next prefix is indented further than current container list continuation indent,
            // it can nest inside current item!
            while (prefix_index < prefixes.len) : (prefix_index += 1) {
                const prefix = prefixes.items[prefix_index];
                const prev_indent = if (depth == 0) 0 else container_prefixes[depth - 1].continuation_indent;
                if (prefix.indent < prev_indent or prefix.indent - prev_indent >= 4) break;
                if (@as(usize, depth) >= builder.options.max_depth) return error.NestingTooDeep;
                if (prefix.kind == .quote) {
                    if (depth < container_len and container_prefixes[depth].kind == .quote) {
                        depth += 1;
                    } else {
                        if (depth >= prefix_depth) return error.NestingTooDeep;
                        const parent = if (depth == 0) root else container_nodes[depth - 1];
                        const quote = try builder.appendNode(.block_quote, parent, lineSpan(line), .none);
                        container_nodes[depth] = quote;
                        container_prefixes[depth] = prefix;
                        depth += 1;
                    }
                } else {
                    var reuse_list = false;
                    if (depth < container_len and container_prefixes[depth].kind == .list) {
                        const old = container_prefixes[depth];
                        reuse_list = prefix.indent < old.continuation_indent and
                            (depth != 0 or prefix.indent <= 3) and
                            old.ordered == prefix.ordered and
                            (old.ordered == false or old.delimiter == prefix.delimiter) and
                            old.marker == prefix.marker;
                    }
                    if (reuse_list) {
                        container_prefixes[depth] = prefix;
                        const list = container_nodes[depth];
                        if (depth + 1 < container_len and
                            container_prefixes[depth + 1].kind == .list)
                        {
                            const item = try builder.appendNode(.list_item, list, lineSpan(line), .none);
                            container_nodes[depth + 1] = item;
                            container_prefixes[depth + 1] = prefix;
                            active = null;
                        } else {
                            const item = try builder.appendNode(.list_item, list, lineSpan(line), .none);
                            if (depth + 1 >= prefix_depth) return error.NestingTooDeep;
                            container_nodes[depth + 1] = item;
                            container_prefixes[depth + 1] = prefix;
                            active = null;
                        }
                        depth += 2;
                    } else {
                        if (depth >= prefix_depth - 1) return error.NestingTooDeep;
                        const parent = if (depth == 0) root else container_nodes[depth - 1];
                        const list = try builder.appendNode(.list, parent, lineSpan(line), .{ .list = .{
                            .ordered = prefix.ordered,
                            .start = prefix.list_start,
                            .delimiter = prefix.delimiter,
                            .tight = true,
                        } });
                        const item = try builder.appendNode(.list_item, list, lineSpan(line), .none);
                        container_nodes[depth] = list;
                        container_prefixes[depth] = prefix;
                        container_nodes[depth + 1] = item;
                        container_prefixes[depth + 1] = prefix;
                        depth += 2;
                        active = null;
                    }
                }
            }
            if (line.blank and prefix_index == prefixes.len and depth < container_len and
                container_prefixes[depth].kind == .list)
            {
                next_len = container_len;
            }
            if (prefix_index == 0 and prefixes.len != 0 and prefixes.items[0].indent >= 4) {
                prefixes.clear();
                prefixes.content_start = line.start;
            }
            var retain_lazy_quotes = false;
            if (active) |block| {
                if (builder.nodes.items[@backingInt(block.node)].kind == .paragraph and prefixes.len != 0 and
                    prefix_index == prefixes.len and depth < container_len)
                {
                    retain_lazy_quotes = true;
                    var quote_index: u32 = 0;
                    while (quote_index < prefixes.len) : (quote_index += 1) {
                        if (prefixes.items[quote_index].kind != .quote) {
                            retain_lazy_quotes = false;
                            break;
                        }
                    }
                }
            }
            next_len = if (retain_lazy_quotes) container_len else depth;
            if (prefixes.len == 0 and container_len != 0) {
                const last_prefix = container_prefixes[container_len - 1];
                const interrupts = !line.blank and isInterruptingBlock(builder.source[line.start..line.end]);
                const active_is_paragraph = if (active) |b|
                    builder.nodes.items[@backingInt(b.node)].kind == .paragraph
                else
                    false;
                if (active_is_paragraph and !interrupts) {
                    next_len = container_len;
                    if (last_prefix.kind == .quote) prefixes.content_start = line.content_start;
                }
            }
            if (active) |block| {
                const next_container = if (next_len == 0) root else container_nodes[next_len - 1];
                if (block.container != next_container) {
                    trimTrailingBlankLinesInCode(builder, block.node);
                    active = null;
                }
            }
        } else if (next_len == 0 and line.blank) {
            if (active) |block| {
                const kind = builder.nodes.items[@backingInt(block.node)].kind;
                if (kind != .code_block and kind != .html_block) {
                    trimTrailingBlankLinesInCode(builder, block.node);
                    active = null;
                }
            }
        }

        container_len = next_len;
        const container = if (container_len == 0) root else container_nodes[container_len - 1];
        if (active) |block| {
            if (block.container != container) {
                trimTrailingBlankLinesInCode(builder, block.node);
                active = null;
            }
        }
        var content_start = prefixes.content_start;
        var is_lazy = prefixes.len == 0 and container != NodeId.root;
        if (prefixes.len == 0 and container_len > 0) {
            const last_prefix = container_prefixes[container_len - 1];
            if (last_prefix.kind == .list and line.indent >= last_prefix.continuation_indent) {
                content_start = skipIndentColumns(
                    builder.source,
                    line.start,
                    line.end,
                    last_prefix.continuation_indent,
                );
                is_lazy = false;
            }
        }
        try processBlockLine(
            builder,
            &active,
            container,
            line,
            content_start,
            is_lazy,
        );
        var depth = container_len;
        while (depth > 0) : (depth -= 1) {
            builder.updateSpan(container_nodes[depth - 1], @intCast(line.end));
        }
        const active_is_code_or_html = if (active) |b|
            builder.nodes.items[@backingInt(b.node)].kind == .code_block or
                builder.nodes.items[@backingInt(b.node)].kind == .html_block
        else
            false;
        blank_line_pending = line.blank and prefixes.len == 0 and container_len != 0 and !active_is_code_or_html;
    }
    if (active) |block| {
        trimTrailingBlankLinesInCode(builder, block.node);
    }
}

fn lineSpan(line: Line) SourceSpan {
    return .{ .start = @intCast(line.start), .end = @intCast(line.end) };
}

fn processBlockLine(
    builder: *Builder,
    active: *?ActiveBlock,
    container: NodeId,
    line: Line,
    content_start: usize,
    is_lazy: bool,
) ParseError!void {
    const start: usize = content_start;
    const end: usize = line.end;
    const content = if (start <= end) builder.source[start..end] else "";
    var content_indent_columns: usize = 0;
    for (content) |byte| {
        if (byte == ' ') {
            content_indent_columns += 1;
        } else if (byte == '\t') {
            content_indent_columns += 4 - (content_indent_columns % 4);
        } else {
            break;
        }
    }
    if (active.*) |block| {
        const node = &builder.nodes.items[@backingInt(block.node)];
        switch (node.kind) {
            .code_block => {
                if (block.code_fence != 0 and isFenceClose(content, block.code_fence, block.code_fence_length)) {
                    builder.updateSpan(block.node, @intCast(line.end));
                    active.* = null;
                    return;
                } else if (block.code_fence == 0 and !line.blank and content_indent_columns < 4) {
                    trimTrailingBlankLinesInCode(builder, block.node);
                    active.* = null;
                } else {
                    const code_content = if (block.code_fence == 0)
                        builder.source[skipIndentColumns(builder.source, start, end, block.code_indent)..end]
                    else if (block.container == NodeId.root)
                        builder.source[skipIndentColumns(
                            builder.source,
                            line.start,
                            line.end,
                            block.code_indent,
                        )..line.end]
                    else
                        builder.source[skipIndentColumns(builder.source, start, end, block.code_indent)..end];
                    try appendBlockLine(builder, block.node, code_content, true);
                    builder.updateSpan(block.node, @intCast(line.end));
                    return;
                }
            },
            .html_block => {
                const html_content = if (container == NodeId.root)
                    builder.source[line.start..line.end]
                else
                    content;
                // Types 6 and 7 end at a blank line of the CONTAINING content,
                // so a line holding nothing but a container marker closes them
                // as well. This is the container-relative blank the paragraph
                // branch below already computes, not the physical blankness.
                var is_blank_content = line.blank;
                if (!is_blank_content) {
                    var i: usize = 0;
                    while (i < content.len and (content[i] == ' ' or content[i] == '\t')) : (i += 1) {}
                    if (i == content.len) is_blank_content = true;
                }
                if (htmlBlockCloses(block.html_tag, html_content, is_blank_content)) {
                    if (!is_blank_content) try appendBlockLine(builder, block.node, html_content, false);
                    builder.updateSpan(block.node, @intCast(line.end));
                    active.* = null;
                } else {
                    try appendBlockLine(builder, block.node, html_content, false);
                    builder.updateSpan(block.node, @intCast(line.end));
                }
                return;
            },
            .paragraph => {
                var starts_reference = false;
                switch (node.data) {
                    .raw => |raw_id| starts_reference = parseReferenceDefinitionAt(builder.rawText(raw_id), 0) != null,
                    else => {},
                }
                const setext_start = if (container == NodeId.root)
                    skipIndentColumns(builder.source, line.start, line.end, @min(line.indent, @as(usize, 3)))
                else
                    skipIndentColumns(builder.source, content_start, line.end, 3);
                const setext_content = if (setext_start <= line.end) builder.source[setext_start..line.end] else "";
                if (!starts_reference and !is_lazy) {
                    if (isSetextUnderline(setext_content)) |level| {
                        const raw_id = switch (node.data) {
                            .raw => |id| id,
                            else => return error.InvalidDocument,
                        };
                        const raw_index = @backingInt(raw_id);
                        while (builder.texts.items[raw_index].len > 0) {
                            const text_end = builder.texts.items[raw_index].start +
                                builder.texts.items[raw_index].len - 1;
                            if (builder.text_bytes.items[text_end] != ' ' and
                                builder.text_bytes.items[text_end] != '\t') break;
                            builder.texts.items[raw_index].len -= 1;
                        }
                        node.data = .{ .heading = .{ .level = level, .raw = raw_id } };
                        node.kind = .heading;
                        builder.updateSpan(block.node, @intCast(line.end));
                        active.* = null;
                        return;
                    }
                }
                if (!line.blank and container == NodeId.root and line.indent >= 4) {
                    const continuation_start = skipIndentColumns(builder.source, line.start, line.end, line.indent);
                    try appendRawToNode(builder, block.node, builder.source[continuation_start..line.end]);
                    builder.updateSpan(block.node, @intCast(line.end));
                    return;
                }
                var is_blank_content = line.blank;
                if (!is_blank_content) {
                    var i: usize = 0;
                    while (i < content.len and (content[i] == ' ' or content[i] == '\t')) : (i += 1) {}
                    if (i == content.len) is_blank_content = true;
                }
                if (!is_blank_content and isInterruptingBlock(content)) {
                    active.* = null;
                } else if (is_blank_content) {
                    active.* = null;
                    return;
                } else {
                    var continuation = if (container == NodeId.root)
                        builder.source[line.content_start..line.end]
                    else
                        content;
                    // CommonMark lazy or container paragraph continuation trims indentation.
                    const max_strip: usize = if (container == NodeId.root) 3 else 4;
                    var stripped: usize = 0;
                    while (stripped < max_strip and
                        stripped < continuation.len and
                        continuation[stripped] == ' ') : (stripped += 1)
                    {}
                    continuation = continuation[stripped..];
                    try appendRawToNode(builder, block.node, continuation);
                    builder.updateSpan(block.node, @intCast(line.end));
                    return;
                }
            },
            else => active.* = null,
        }
    }
    var is_blank_content = line.blank;
    if (!is_blank_content) {
        var i: usize = 0;
        while (i < content.len and (content[i] == ' ' or content[i] == '\t')) : (i += 1) {}
        if (i == content.len) is_blank_content = true;
    }
    if (is_blank_content) return;
    var indent_cols: usize = 0;
    for (content) |b| {
        if (b == ' ') indent_cols += 1 else if (b == '\t') indent_cols += 4 - (indent_cols % 4) else break;
    }
    if (indent_cols >= 4) {
        const indented_start = skipIndentColumns(builder.source, start, end, 4);
        const indented = if (indented_start <= end) builder.source[indented_start..end] else "";
        const raw = try builder.appendText("");
        const node = try builder.appendNode(.code_block, container, lineSpan(line), .{ .code_block = .{
            .fenced = false,
            .fence = 0,
            .fence_length = 0,
            .info = .none,
            .raw = raw,
        } });
        const has_tab_indent = (content.len > 0 and content[0] == '\t') or
            (start > line.start and std.mem.indexOfScalar(u8, builder.source[line.start..start], '\t') != null);
        if (container != NodeId.root and has_tab_indent) {
            var code_source_start = start;
            var probe = line.start;
            while (probe < start and (builder.source[probe] == ' ' or builder.source[probe] == '\t')) probe += 1;
            if (probe < start and (builder.source[probe] == '>' or builder.source[probe] == '-' or
                builder.source[probe] == '+' or builder.source[probe] == '*'))
            {
                code_source_start = probe + 1;
            }
            try appendCodeLineWithIndent(builder, node, code_source_start, end, 6);
        } else {
            try appendBlockLine(builder, node, indented, true);
        }
        active.* = .{ .node = node, .container = container, .code_indent = 4 };
        return;
    }
    const trim_count = @min(indent_cols, 3);
    const trimmed_start = skipIndentColumns(builder.source, start, end, trim_count);
    const trimmed_content = if (trimmed_start <= end) builder.source[trimmed_start..end] else "";
    if (isAtxHeading(trimmed_content)) |heading| {
        const raw = try builder.appendTextNormalized(heading.text);
        _ = try builder.appendNode(
            .heading,
            container,
            lineSpan(line),
            .{ .heading = .{ .level = heading.level, .raw = raw } },
        );
        return;
    }
    if (isFenceOpen(trimmed_content)) |fence| {
        const info = try cleanDestination(.link, builder, fence.info);
        const raw = try builder.appendText("");
        const node = try builder.appendNode(.code_block, container, lineSpan(line), .{ .code_block = .{
            .fenced = true,
            .fence = fence.character,
            .fence_length = fence.length,
            .info = info,
            .raw = raw,
        } });
        active.* = .{
            .node = node,
            .container = container,
            .code_fence = fence.character,
            .code_fence_length = fence.length,
            .code_indent = @intCast(if (container == NodeId.root) @min(line.indent, @as(usize, 3)) else indent_cols),
        };
        return;
    }
    if (isThematicBreak(trimmed_content)) {
        _ = try builder.appendNode(.thematic_break, container, lineSpan(line), .none);
        return;
    }
    if (isHtmlBlockStart(trimmed_content)) |tag| {
        const html_content = if (container == NodeId.root)
            builder.source[line.start..line.end]
        else
            trimmed_content;
        const raw = try builder.appendTextNormalized(html_content);
        const node = try builder.appendNode(.html_block, container, lineSpan(line), .{ .raw = raw });
        if (!htmlBlockCloses(tag, html_content, false)) {
            active.* = .{ .node = node, .container = container, .html_tag = tag };
        }
        return;
    }
    const raw = try builder.appendTextNormalized(trimmed_content);
    const node = try builder.appendNode(.paragraph, container, lineSpan(line), .{ .raw = raw });
    active.* = .{ .node = node, .container = container };
}

fn appendBlockLine(builder: *Builder, node: NodeId, content: []const u8, is_code: bool) ParseError!void {
    if (is_code) {
        try appendCodeToNode(builder, node, content);
    } else {
        try appendRawToNode(builder, node, content);
    }
}

fn appendCodeToNode(builder: *Builder, node: NodeId, content: []const u8) ParseError!void {
    const index = @backingInt(node);
    if (index >= builder.nodes.items.len) return error.InvalidDocument;
    const raw_id = switch (builder.nodes.items[index].data) {
        .code_block => |code| code.raw,
        else => return error.InvalidDocument,
    };
    const raw_index = @backingInt(raw_id);
    if (raw_index >= builder.texts.items.len) return error.InvalidDocument;
    const start = builder.text_bytes.items.len;
    try builder.appendNormalizedBytes(content);
    try builder.appendBytesToCurrent("\n");
    builder.texts.items[raw_index].len += @intCast(builder.text_bytes.items.len - start);
}
fn appendCodeLineWithIndent(
    builder: *Builder,
    node: NodeId,
    source_start: usize,
    source_end: usize,
    strip_columns: usize,
) ParseError!void {
    const node_index = @backingInt(node);
    if (node_index >= builder.nodes.items.len or source_start > source_end) return error.InvalidDocument;
    const raw_id = switch (builder.nodes.items[node_index].data) {
        .code_block => |code| code.raw,
        else => return error.InvalidDocument,
    };
    const raw_index = @backingInt(raw_id);
    if (raw_index >= builder.texts.items.len) return error.InvalidDocument;

    var cursor = source_start;
    var column: usize = 0;
    var remaining = strip_columns;
    var residual_spaces: usize = 0;
    while (cursor < source_end and remaining != 0) {
        if (builder.source[cursor] == ' ') {
            cursor += 1;
            column += 1;
            remaining -= 1;
        } else if (builder.source[cursor] == '\t') {
            const width = 4 - (column % 4);
            cursor += 1;
            column += width;
            if (width <= remaining) {
                remaining -= width;
            } else {
                residual_spaces = width - remaining;
                remaining = 0;
            }
        } else break;
    }
    const start = builder.text_bytes.items.len;
    if (residual_spaces != 0) {
        const spaces = [_]u8{ ' ', ' ', ' ', ' ' };
        try builder.appendBytesToCurrent(spaces[0..residual_spaces]);
    }
    try builder.appendNormalizedBytes(builder.source[cursor..source_end]);
    try builder.appendBytesToCurrent("\n");
    builder.texts.items[raw_index].len += @intCast(builder.text_bytes.items.len - start);
}

fn trimTrailingBlankLinesInCode(builder: *Builder, node: NodeId) void {
    const index = @backingInt(node);
    if (index >= builder.nodes.items.len) return;
    const raw_id = switch (builder.nodes.items[index].data) {
        .code_block => |code| code.raw,
        else => return,
    };
    const raw_index = @backingInt(raw_id);
    if (raw_index >= builder.texts.items.len) return;
    var record = &builder.texts.items[raw_index];
    while (record.len > 0) {
        const bytes = builder.text_bytes.items[record.start .. record.start + record.len];
        if (bytes.len == 0) break;
        if (bytes[bytes.len - 1] == '\n') {
            var line_start = bytes.len - 1;
            while (line_start > 0 and bytes[line_start - 1] != '\n') : (line_start -= 1) {}
            const line_content = bytes[line_start .. bytes.len - 1];
            var only_ws = true;
            for (line_content) |b| {
                if (b != ' ' and b != '\t') {
                    only_ws = false;
                    break;
                }
            }
            if (only_ws) {
                record.len = @intCast(line_start);
                continue;
            }
        }
        break;
    }
}
fn appendRawToNode(builder: *Builder, node: NodeId, content: []const u8) ParseError!void {
    const index = @backingInt(node);
    if (index >= builder.nodes.items.len) return error.InvalidDocument;
    const raw_id = switch (builder.nodes.items[index].data) {
        .heading => |heading| heading.raw,
        .code_block => |code| code.raw,
        .raw => |raw| raw,
        .none => return error.InvalidDocument,
        else => return error.InvalidDocument,
    };
    const raw_index = @backingInt(raw_id);
    if (raw_index >= builder.texts.items.len) return error.InvalidDocument;
    const record = builder.texts.items[raw_index];
    const separator_len: usize = if (record.len > 0) 1 else 0;
    const start = builder.text_bytes.items.len;
    if (separator_len != 0) try builder.appendBytesToCurrent("\n");
    try builder.appendNormalizedBytes(content);
    builder.texts.items[raw_index].len += @intCast(builder.text_bytes.items.len - start);
}

fn skipIndentColumns(source: []const u8, start: usize, end: usize, columns: usize) usize {
    var index = start;
    var column: usize = 0;
    while (index < end and column < columns) {
        if (source[index] == ' ') {
            column += 1;
            index += 1;
        } else if (source[index] == '\t') {
            const step = 4 - (column % 4);
            if (column + step > columns) break;
            column += step;
            index += 1;
        } else {
            break;
        }
    }
    return index;
}
fn isInterruptingBlock(content: []const u8) bool {
    if (isFenceOpen(content) != null) return true;
    if (isAtxHeading(content) != null) return true;
    if (isThematicBreak(content)) return true;
    if (isHtmlBlockStart(content)) |tag| return tag != 9;
    return false;
}

const Fence = struct { character: u8, length: usize, info: []const u8 };

fn isFenceOpen(content: []const u8) ?Fence {
    var index: usize = 0;
    while (index < content.len and index < 4 and content[index] == ' ') : (index += 1) {}
    if (index >= 4 or index >= content.len or (content[index] != '`' and content[index] != '~')) return null;
    const character = content[index];
    var length: usize = 0;
    while (index + length < content.len and content[index + length] == character) : (length += 1) {}
    if (length < 3) return null;
    var info_start = index + length;
    while (info_start < content.len and (content[info_start] == ' ' or content[info_start] == '\t')) info_start += 1;
    var info = content[info_start..];
    while (info.len > 0 and (info[info.len - 1] == ' ' or info[info.len - 1] == '\t')) info = info[0 .. info.len - 1];
    if (character == '`' and std.mem.indexOfScalar(u8, info, '`') != null) return null;
    return .{ .character = character, .length = length, .info = info };
}

fn isFenceClose(content: []const u8, character: u8, length: usize) bool {
    var index: usize = 0;
    while (index < content.len and index < 4 and content[index] == ' ') : (index += 1) {}
    if (index >= 4 or index >= content.len or content[index] != character) return false;
    var count: usize = 0;
    while (index + count < content.len and content[index + count] == character) : (count += 1) {}
    if (count < length) return false;
    while (index + count < content.len) : (count += 1) {
        if (content[index + count] != ' ' and content[index + count] != '\t') return false;
    }
    return true;
}

const Heading = struct { level: u8, text: []const u8 };

fn isAtxHeading(content: []const u8) ?Heading {
    var index: usize = 0;
    while (index < content.len and index < 4 and content[index] == ' ') : (index += 1) {}
    const start = index;
    while (index < content.len and content[index] == '#') : (index += 1) {}
    const level = index - start;
    if (level == 0 or level > 6) return null;
    if (index < content.len and content[index] != ' ' and content[index] != '\t') return null;
    while (index < content.len and (content[index] == ' ' or content[index] == '\t')) : (index += 1) {}
    var end = content.len;
    while (end > index and (content[end - 1] == ' ' or content[end - 1] == '\t')) : (end -= 1) {}
    if (end > index and content[end - 1] == '#') {
        var hash_start = end;
        while (hash_start > index and content[hash_start - 1] == '#') : (hash_start -= 1) {}
        if (hash_start <= index or content[hash_start - 1] == ' ' or content[hash_start - 1] == '\t') {
            end = hash_start;
            while (end > index and (content[end - 1] == ' ' or content[end - 1] == '\t')) : (end -= 1) {}
        }
    }
    return .{ .level = @intCast(level), .text = content[index..end] };
}

fn isThematicBreak(content: []const u8) bool {
    var count: usize = 0;
    var marker: u8 = 0;
    for (content) |byte| {
        if (byte == ' ' or byte == '\t') continue;
        if (marker == 0) marker = byte;
        if (byte != marker or (marker != '*' and marker != '-' and marker != '_')) return false;
        count += 1;
    }
    return count >= 3;
}
fn isSetextUnderline(content: []const u8) ?u8 {
    if (content.len == 0) return null;
    const marker = content[0];
    if (marker != '=' and marker != '-') return null;
    var index: usize = 1;
    while (index < content.len and content[index] == marker) : (index += 1) {}
    while (index < content.len and (content[index] == ' ' or content[index] == '\t')) : (index += 1) {}
    if (index != content.len) return null;
    return if (marker == '=') 1 else 2;
}

fn tagNameEquals(name: []const u8, expected: []const u8) bool {
    if (name.len != expected.len) return false;
    for (name, expected) |actual, wanted| {
        if (std.ascii.toLower(actual) != wanted) return false;
    }
    return true;
}

fn isBlockHtmlTag(name: []const u8) bool {
    const names = [_][]const u8{
        "address",  "article",  "aside",    "base",       "basefont", "blockquote", "body",   "caption",
        "center",   "col",      "colgroup", "dd",         "details",  "dialog",     "dir",    "div",
        "dl",       "dt",       "fieldset", "figcaption", "figure",   "footer",     "form",   "frame",
        "frameset", "h1",       "h2",       "h3",         "h4",       "h5",         "h6",     "head",
        "header",   "hr",       "html",     "iframe",     "legend",   "li",         "link",   "main",
        "menu",     "menuitem", "nav",      "noframes",   "ol",       "optgroup",   "option", "p",
        "param",    "search",   "section",  "summary",    "table",    "tbody",      "td",     "tfoot",
        "th",       "thead",    "title",    "tr",         "track",    "ul",
    };
    for (names) |expected| if (tagNameEquals(name, expected)) return true;
    return false;
}

/// A tag name is an ASCII letter followed by ASCII letters, digits, or
/// hyphens. The scan also reports whether the name belongs to a closing tag and
/// which byte follows it, because the start conditions of the type 1 and
/// type 6 blocks depend on that delimiter.
const TagName = struct { name: []const u8, closing: bool, delimiter: ?u8 };

fn scanTagName(tag: []const u8) ?TagName {
    var index: usize = 1;
    var closing = false;
    if (index < tag.len and tag[index] == '/') {
        closing = true;
        index += 1;
    }
    if (index >= tag.len or !std.ascii.isAlphabetic(tag[index])) return null;
    const start = index;
    while (index < tag.len and (std.ascii.isAlphanumeric(tag[index]) or tag[index] == '-')) : (index += 1) {}
    return .{
        .name = tag[start..index],
        .closing = closing,
        .delimiter = if (index < tag.len) tag[index] else null,
    };
}

/// The delimiter the type 1 start condition accepts after the tag name: a
/// space, a tab, `>`, or the end of the line. The type 6 condition is wider and
/// is handled by `isBlockTagNameDelimiter`.
fn isTagNameDelimiter(delimiter: ?u8) bool {
    return delimiter == null or delimiter == ' ' or delimiter == '\t' or delimiter == '>';
}

/// The type 6 start condition adds the string `/>` to the type 1 delimiter set,
/// so `<div/>` opens a type-6 block. `TagName.delimiter` holds only the single
/// byte after the name, so the byte behind it is inspected here; both call
/// sites hold the whole line.
fn isBlockTagNameDelimiter(line: []const u8, scanned: TagName) bool {
    if (isTagNameDelimiter(scanned.delimiter)) return true;
    if (scanned.delimiter != '/') return false;
    const name_end = 1 + @as(usize, if (scanned.closing) 1 else 0) + scanned.name.len;
    return name_end + 1 < line.len and line[name_end + 1] == '>';
}

fn isTypeOneTagName(name: []const u8) bool {
    return tagNameEquals(name, "pre") or tagNameEquals(name, "script") or
        tagNameEquals(name, "style") or tagNameEquals(name, "textarea");
}

fn isHtmlBlockStart(content: []const u8) ?u8 {
    var trimmed = content;
    while (trimmed.len > 0 and (trimmed[0] == ' ' or trimmed[0] == '\t')) trimmed = trimmed[1..];
    if (trimmed.len == 0 or trimmed[0] != '<') return null;
    if (std.mem.startsWith(u8, trimmed, "<!--")) return 1;
    if (std.mem.startsWith(u8, trimmed, "<?")) return 2;
    if (std.mem.startsWith(u8, trimmed, "<![CDATA[")) return 3;
    if (trimmed.len > 2 and std.mem.startsWith(u8, trimmed, "<!") and
        std.ascii.isAlphabetic(trimmed[2])) return 4;
    const scanned = scanTagName(trimmed) orelse return null;
    if (isBlockTagNameDelimiter(trimmed, scanned) and isBlockHtmlTag(scanned.name)) return 8;
    if (isTagNameDelimiter(scanned.delimiter) and !scanned.closing) {
        if (tagNameEquals(scanned.name, "script")) return 5;
        if (tagNameEquals(scanned.name, "pre")) return 6;
        if (tagNameEquals(scanned.name, "style")) return 7;
        if (tagNameEquals(scanned.name, "textarea")) return 10;
    }
    return if (isHtmlBlockType7Start(trimmed)) 9 else null;
}

/// A type 7 block starts at a complete open tag whose name is not one of the
/// type 1 names, or at a complete closing tag, followed by only spaces and tabs
/// up to the end of the line.
fn isHtmlBlockType7Start(line: []const u8) bool {
    var tail = line;
    while (tail.len > 0 and (tail[tail.len - 1] == ' ' or tail[tail.len - 1] == '\t')) {
        tail = tail[0 .. tail.len - 1];
    }
    const close = findTagEnd(tail, 0) orelse return false;
    if (close + 1 != tail.len or !isHtmlInlineTag(tail)) return false;
    const scanned = scanTagName(tail) orelse return false;
    return scanned.closing or !isTypeOneTagName(scanned.name);
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (haystack.len < needle.len) return false;
    const last = haystack.len - needle.len;
    var index: usize = 0;
    while (index <= last) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[index..][0..needle.len], needle)) return true;
    }
    return false;
}

/// A type 1 block ends at a line holding any of the four end tags, in any case.
/// Types 6 and 7 end at the blank line that follows the block; that line is not
/// part of the block and the caller must not append it.
fn htmlBlockCloses(tag: u8, content: []const u8, is_blank: bool) bool {
    return switch (tag) {
        1 => std.mem.indexOf(u8, content, "-->") != null,
        2 => std.mem.indexOf(u8, content, "?>") != null,
        3 => std.mem.indexOf(u8, content, "]]>") != null,
        4 => std.mem.indexOfScalar(u8, content, '>') != null,
        5, 6, 7, 10 => containsIgnoreCase(content, "</script>") or
            containsIgnoreCase(content, "</pre>") or
            containsIgnoreCase(content, "</style>") or
            containsIgnoreCase(content, "</textarea>"),
        8, 9 => is_blank,
        else => true,
    };
}

fn parseAllInlines(builder: *Builder) ParseError!void {
    var index: usize = 0;
    while (index < builder.nodes.items.len) : (index += 1) {
        const kind = builder.nodes.items[index].kind;
        if (kind != .paragraph and kind != .heading) continue;
        const raw_id = switch (builder.nodes.items[index].data) {
            .raw => |id| id,
            .heading => |heading| heading.raw,
            else => continue,
        };
        const raw = builder.rawText(raw_id);
        try parseInlineText(builder, @fromBackingInt(@intCast(@as(u32, @intCast(index)))), raw);
    }
}

fn reserveInlineText(builder: *Builder) ParseError!void {
    const scaled = std.math.mul(usize, builder.source.len, 8) catch max_usize;
    const requested = @min(builder.options.max_text_bytes, scaled +| 1024);
    builder.text_bytes.ensureTotalCapacity(builder.gpa, requested) catch return error.OutOfMemory;
}
const ReferenceParts = struct {
    label: []const u8,
    destination: []const u8,
    title: ?[]const u8,
};

const ParsedReference = struct {
    parts: ReferenceParts,
    end: usize,
};
fn referenceResult(
    raw: []const u8,
    label_start: usize,
    close: usize,
    destination_start: usize,
    destination_end: usize,
    end: usize,
) ParsedReference {
    return .{
        .parts = .{
            .label = raw[label_start..close],
            .destination = raw[destination_start..destination_end],
            .title = null,
        },
        .end = end,
    };
}

fn parseReferenceDefinitionAt(raw: []const u8, start: usize) ?ParsedReference {
    var index = start;
    var indent: usize = 0;
    while (index < raw.len and (raw[index] == ' ' or raw[index] == '\t') and indent < 4) : (indent += 1) {
        index += 1;
    }
    if (indent > 3 or index >= raw.len or raw[index] != '[') return null;
    const label_start = index + 1;
    var close = label_start;
    var has_non_ws = false;
    while (close < raw.len) {
        if (raw[close] == '\\' and close + 1 < raw.len) {
            has_non_ws = true;
            close += 2;
            continue;
        }
        if (raw[close] == '[') return null;
        if (raw[close] == ']') break;
        if (raw[close] != ' ' and raw[close] != '\t' and raw[close] != '\n' and raw[close] != '\r') has_non_ws = true;
        close += 1;
    }
    if (!has_non_ws or close >= raw.len or close == label_start or
        close + 1 >= raw.len or raw[close + 1] != ':') return null;
    index = close + 2;
    while (index < raw.len and (raw[index] == ' ' or raw[index] == '\t' or raw[index] == '\n')) : (index += 1) {}
    if (index >= raw.len) return null;

    const destination_start: usize = if (raw[index] == '<') index + 1 else index;
    var destination_end = destination_start;
    if (raw[index] == '<') {
        while (destination_end < raw.len and raw[destination_end] != '>' and
            raw[destination_end] != '\n') : (destination_end += 1)
        {}
        if (destination_end >= raw.len or raw[destination_end] != '>') return null;
        index = destination_end + 1;
    } else {
        var depth: usize = 0;
        while (destination_end < raw.len) {
            const byte = raw[destination_end];
            if (byte == '\\' and destination_end + 1 < raw.len) {
                destination_end += 2;
                continue;
            }
            if (byte == '(') {
                depth += 1;
            } else if (byte == ')') {
                if (depth == 0) break;
                depth -= 1;
            } else if ((byte == ' ' or byte == '\t' or byte == '\n') and depth == 0) {
                break;
            }
            destination_end += 1;
        }
        if (destination_end == destination_start or depth != 0) return null;
        index = destination_end;
    }
    var title: ?[]const u8 = null;
    var separated = false;
    var separated_by_newline = false;
    var first_line_end: usize = 0;
    while (index < raw.len and (raw[index] == ' ' or raw[index] == '\t')) : (index += 1) {
        separated = true;
    }
    if (index < raw.len and raw[index] == '\n') {
        first_line_end = index + 1;
        separated_by_newline = true;
        index += 1;
        while (index < raw.len and (raw[index] == ' ' or raw[index] == '\t')) : (index += 1) {}
        if (index >= raw.len or (raw[index] == '\n') or
            (raw[index] != '"' and raw[index] != '\'' and raw[index] != '('))
        {
            return referenceResult(raw, label_start, close, destination_start, destination_end, first_line_end);
        }
        separated = true;
    }
    if (index < raw.len and (raw[index] == '"' or raw[index] == '\'' or raw[index] == '(')) {
        if (!separated) return null;
        const opener = raw[index];
        const closer = if (opener == '(') ')' else opener;
        index += 1;
        const title_start = index;
        while (index < raw.len) {
            if (raw[index] == '\\' and index + 1 < raw.len) {
                index += 2;
                continue;
            }
            if (raw[index] == closer) break;
            index += 1;
        }
        if (index >= raw.len) {
            if (separated_by_newline) return referenceResult(
                raw,
                label_start,
                close,
                destination_start,
                destination_end,
                first_line_end,
            );
            return null;
        }
        title = raw[title_start..index];
        index += 1;
        while (index < raw.len and (raw[index] == ' ' or raw[index] == '\t')) : (index += 1) {}
    }
    if (index < raw.len and raw[index] == '\n') {
        index += 1;
    } else if (index < raw.len) {
        if (separated_by_newline) return referenceResult(
            raw,
            label_start,
            close,
            destination_start,
            destination_end,
            first_line_end,
        );
        return null;
    }
    return .{
        .parts = .{
            .label = raw[label_start..close],
            .destination = raw[destination_start..destination_end],
            .title = title,
        },
        .end = index,
    };
}

fn extractReferences(builder: *Builder) ParseError!void {
    var index: usize = 0;
    while (index < builder.nodes.items.len) : (index += 1) {
        if (builder.nodes.items[index].kind != .paragraph) continue;
        const raw_id = switch (builder.nodes.items[index].data) {
            .raw => |id| id,
            else => continue,
        };
        const raw = builder.rawText(raw_id);
        var cursor: usize = 0;
        var count: usize = 0;
        while (parseReferenceDefinitionAt(raw, cursor)) |parsed| {
            const label = try normalizeLabel(builder, parsed.parts.label) orelse break;
            if (builder.references.items.len >= builder.options.max_reference_count) return error.TooManyReferences;
            const destination = try cleanDestination(.link, builder, parsed.parts.destination);
            const title = if (parsed.parts.title) |value| try cleanDestination(.link, builder, value) else .none;
            builder.references.append(builder.gpa, .{
                .label = label,
                .destination = destination,
                .title = title,
            }) catch return error.OutOfMemory;
            count += 1;
            cursor = parsed.end;
            if (cursor >= raw.len) break;
        }
        if (count == 0) continue;
        if (cursor >= raw.len or std.mem.trim(u8, raw[cursor..], " \t\n").len == 0) {
            builder.nodes.items[index].kind = .reference_definition;
            builder.nodes.items[index].data = .none;
        } else {
            const remainder = try builder.appendTextNormalized(raw[cursor..]);
            const remainder_bytes = builder.rawText(remainder);
            var scan: usize = 0;
            var heading_level: u8 = 0;
            var heading_end: usize = 0;
            var tail_start: usize = remainder_bytes.len;
            var found_heading = false;
            while (scan < remainder_bytes.len) {
                const line_end = std.mem.indexOfScalarPos(u8, remainder_bytes, scan, '\n') orelse remainder_bytes.len;
                const line = remainder_bytes[scan..line_end];
                if (scan > 0) {
                    if (isSetextUnderline(std.mem.trim(u8, line, " \t\n"))) |level| {
                        var candidate_end = scan - 1;
                        while (candidate_end > 0 and
                            (remainder_bytes[candidate_end - 1] == ' ' or
                                remainder_bytes[candidate_end - 1] == '\t')) : (candidate_end -= 1)
                        {}
                        if (candidate_end > 0) {
                            heading_level = level;
                            heading_end = candidate_end;
                            tail_start = if (line_end < remainder_bytes.len) line_end + 1 else line_end;
                            found_heading = true;
                            break;
                        }
                    }
                }
                if (line_end >= remainder_bytes.len) break;
                scan = line_end + 1;
            }
            if (found_heading) {
                builder.texts.items[@backingInt(remainder)].len = @intCast(heading_end);
                builder.nodes.items[index].kind = .heading;
                builder.nodes.items[index].data = .{ .heading = .{ .level = heading_level, .raw = remainder } };
                if (tail_start < remainder_bytes.len and
                    std.mem.trim(u8, remainder_bytes[tail_start..], " \t\n").len != 0)
                {
                    const tail = try builder.appendTextNormalized(remainder_bytes[tail_start..]);
                    const parent = builder.nodes.items[index].parent;
                    const tail_node = try builder.appendNode(
                        .paragraph,
                        .none,
                        builder.nodes.items[index].source,
                        .{ .raw = tail },
                    );
                    try builder.insertAfter(parent, @fromBackingInt(@intCast(@as(u32, @intCast(index)))), tail_node);
                }
            } else {
                builder.nodes.items[index].data = .{ .raw = remainder };
            }
        }
    }
}

const InlineFrame = struct {
    node: NodeId,
    marker: u8,
    length: usize,
    can_open: bool,
    can_close: bool,
    active: bool = true,
};
const BracketFrame = struct {
    node: NodeId,
    parent: NodeId,
    image: bool,
    source_start: u32,
    active: bool = true,
    delimiter_position: usize = 0,
};

fn parseInlineText(builder: *Builder, block: NodeId, raw: []const u8) ParseError!void {
    var delimiters: std.ArrayList(InlineFrame) = .empty;
    var brackets: std.ArrayList(BracketFrame) = .empty;
    defer delimiters.deinit(builder.gpa);
    defer brackets.deinit(builder.gpa);
    var parent = block;
    var index: usize = 0;
    var text_start: usize = 0;
    while (index < raw.len) {
        try builder.charge(1);
        const byte = raw[index];
        if (byte == '\\') {
            if (index > text_start) try appendTextNode(builder, parent, raw[text_start..index]);
            if (index + 1 < raw.len and raw[index + 1] == '\n') {
                _ = try builder.appendNode(.linebreak, parent, .{ .start = 0, .end = 0 }, .none);
                index += 2;
            } else if (index + 1 < raw.len and isEscapable(raw[index + 1])) {
                try appendTextNode(builder, parent, raw[index + 1 .. index + 2]);
                index += 2;
            } else {
                try appendTextNode(builder, parent, "\\");
                index += 1;
            }
            text_start = index;
            continue;
        }
        if (byte == '&') {
            if (parseEntity(raw[index..])) |entity| {
                if (index > text_start) try appendTextNode(builder, parent, raw[text_start..index]);
                try appendTextNode(builder, parent, entity.value[0..entity.len]);
                index += entity.consumed;
                text_start = index;
                continue;
            }
        }
        if (byte == '`') {
            var run: usize = 0;
            while (index + run < raw.len and raw[index + run] == '`') : (run += 1) {}
            if (findBacktickClose(raw, index + run, run)) |close| {
                if (index > text_start) try appendTextNode(builder, parent, raw[text_start..index]);
                const code = raw[index + run .. close];
                const code_id = try appendCodeSpanText(builder, code);
                _ = try builder.appendNode(.code_span, parent, .{ .start = 0, .end = 0 }, .{ .raw = code_id });
                index = close + run;
                text_start = index;
                continue;
            }
            index += run;
            continue;
        }
        if (byte == '<') {
            if (parseAutolink(raw[index..])) |link| {
                if (index > text_start) try appendTextNode(builder, parent, raw[text_start..index]);
                const destination = try cleanDestination(.autolink, builder, link.destination);
                _ = try builder.appendNode(.autolink, parent, .{ .start = 0, .end = 0 }, .{ .autolink = destination });
                index += link.consumed;
                text_start = index;
                continue;
            }
            if (findTagEnd(raw, index)) |close| {
                if (isHtmlInlineTag(raw[index .. close + 1])) {
                    if (index > text_start) try appendTextNode(builder, parent, raw[text_start..index]);
                    const html = try builder.appendTextNormalized(raw[index .. close + 1]);
                    _ = try builder.appendNode(.html_inline, parent, .{ .start = 0, .end = 0 }, .{ .raw = html });
                    index = close + 1;
                    text_start = index;
                    continue;
                }
            }
        }
        if (byte == '[' or (byte == '!' and index + 1 < raw.len and raw[index + 1] == '[')) {
            if (brackets.items.len >= builder.options.max_brackets) return error.TooManyBrackets;
            if (index > text_start) try appendTextNode(builder, parent, raw[text_start..index]);
            const image = byte == '!';
            const marker_start = index;
            const link_node = if (image)
                try builder.appendNode(
                    .image,
                    parent,
                    .{ .start = 0, .end = 0 },
                    .{ .image = .{ .destination = .none, .title = .none } },
                )
            else
                try builder.appendNode(
                    .link,
                    parent,
                    .{ .start = 0, .end = 0 },
                    .{ .link = .{ .destination = .none, .title = .none } },
                );
            const frame: BracketFrame = .{
                .node = link_node,
                .parent = parent,
                .image = image,
                .source_start = @intCast(marker_start),
                .active = true,
                .delimiter_position = delimiters.items.len,
            };
            brackets.append(builder.gpa, frame) catch return error.OutOfMemory;
            parent = link_node;
            index += if (image) 2 else 1;
            text_start = index;
            continue;
        }
        if (byte == ']' and brackets.items.len > 0) {
            const frame = brackets.pop() orelse unreachable;
            if (index > text_start) try appendTextNode(builder, parent, raw[text_start..index]);
            if (frame.active) {
                if (try parseLinkAfterClose(raw, index + 1, builder, frame)) |link| {
                    const data: LinkData = .{ .destination = link.destination, .title = link.title };
                    try processEmphasis(builder, &delimiters, frame.delimiter_position);
                    if (frame.image) {
                        builder.nodes.items[@backingInt(frame.node)].data = .{ .image = data };
                    } else {
                        builder.nodes.items[@backingInt(frame.node)].data = .{ .link = data };
                        for (brackets.items) |*b| {
                            if (!b.image) b.active = false;
                        }
                    }
                    parent = frame.parent;
                    index = link.end;
                    text_start = index;
                    continue;
                }
            }
            const target = if (builder.nodes.items[@backingInt(frame.node)].first_child != .none)
                builder.nodes.items[@backingInt(frame.node)].first_child
            else
                builder.nodes.items[@backingInt(frame.node)].next_sibling;
            unwrapNode(builder, frame.node, frame.parent);
            if (target != .none) {
                try insertTextNodeBefore(builder, frame.parent, target, if (frame.image) "![" else "[");
            } else {
                try appendTextNode(builder, frame.parent, if (frame.image) "![" else "[");
            }
            parent = frame.parent;
            text_start = index;
            index += 1;
            continue;
        }
        if (byte == '*' or byte == '_') {
            var run: usize = 0;
            while (index + run < raw.len and raw[index + run] == byte) : (run += 1) {}
            const can_open = isDelimiterOpener(raw, index, run);
            const can_close = isDelimiterCloser(raw, index, run);
            if (can_open or can_close) {
                if (delimiters.items.len >= builder.options.max_delimiters) return error.TooManyDelimiters;
                if (index > text_start) try appendTextNode(builder, parent, raw[text_start..index]);
                const text = try builder.appendTextNormalized(raw[index .. index + run]);
                const node = try builder.appendNode(.text, parent, .{ .start = 0, .end = 0 }, .{ .raw = text });
                delimiters.append(builder.gpa, .{
                    .node = node,
                    .marker = byte,
                    .length = run,
                    .can_open = can_open,
                    .can_close = can_close,
                }) catch return error.OutOfMemory;
                index += run;
                text_start = index;
                continue;
            }
            index += run;
            continue;
        }
        if (byte == '\n') {
            var text_end = index;
            while (text_end > text_start and raw[text_end - 1] == ' ') : (text_end -= 1) {}
            if (text_end > text_start) try appendTextNode(builder, parent, raw[text_start..text_end]);
            if (index - text_end >= 2) {
                _ = try builder.appendNode(.linebreak, parent, .{ .start = 0, .end = 0 }, .none);
            } else {
                _ = try builder.appendNode(.softbreak, parent, .{ .start = 0, .end = 0 }, .none);
            }
            index += 1;
            text_start = index;
            continue;
        }
        index += 1;
    }
    var final_end = index;
    while (final_end > text_start and (raw[final_end - 1] == ' ' or raw[final_end - 1] == '\t')) : (final_end -= 1) {}
    if (final_end > text_start) try appendTextNode(builder, parent, raw[text_start..final_end]);
    while (brackets.items.len > 0) {
        const frame = brackets.pop() orelse unreachable;
        const target = if (builder.nodes.items[@backingInt(frame.node)].first_child != .none)
            builder.nodes.items[@backingInt(frame.node)].first_child
        else
            builder.nodes.items[@backingInt(frame.node)].next_sibling;
        unwrapNode(builder, frame.node, frame.parent);
        if (target != .none) {
            try insertTextNodeBefore(builder, frame.parent, target, if (frame.image) "![" else "[");
        } else {
            try appendTextNode(builder, frame.parent, if (frame.image) "![" else "[");
        }
    }
    try processEmphasis(builder, &delimiters, 0);
}

fn appendTextNode(builder: *Builder, parent: NodeId, bytes: []const u8) ParseError!void {
    if (bytes.len == 0) return;
    const text = try builder.appendTextNormalized(bytes);
    _ = try builder.appendNode(.text, parent, .{ .start = 0, .end = 0 }, .{ .raw = text });
}
fn appendCodeSpanText(builder: *Builder, source: []const u8) ParseError!TextId {
    var normalized: std.ArrayList(u8) = .empty;
    defer normalized.deinit(builder.gpa);
    var index: usize = 0;
    while (index < source.len) {
        if (source[index] == '\r') {
            if (index + 1 < source.len and source[index + 1] == '\n') index += 1;
            normalized.append(builder.gpa, ' ') catch return error.OutOfMemory;
        } else if (source[index] == '\n') {
            normalized.append(builder.gpa, ' ') catch return error.OutOfMemory;
        } else {
            normalized.append(builder.gpa, source[index]) catch return error.OutOfMemory;
        }
        index += 1;
    }
    var bytes = normalized.items;
    if (bytes.len >= 2 and bytes[0] == ' ' and bytes[bytes.len - 1] == ' ' and std.mem.trim(u8, bytes, " ").len != 0) {
        bytes = bytes[1 .. bytes.len - 1];
    }
    return builder.appendTextNormalized(bytes);
}
fn insertTextNodeBefore(builder: *Builder, parent: NodeId, target: NodeId, bytes: []const u8) ParseError!void {
    if (bytes.len == 0) return;
    const text = try builder.appendTextNormalized(bytes);
    const inserted = try builder.appendNode(.text, .none, .{ .start = 0, .end = 0 }, .{ .raw = text });
    const parent_index = @backingInt(parent);
    const target_index = @backingInt(target);
    if (parent_index >= builder.nodes.items.len or
        target_index >= builder.nodes.items.len) return error.InvalidDocument;
    var previous: NodeId = .none;
    var current = builder.nodes.items[parent_index].first_child;
    while (current != .none and current != target) {
        previous = current;
        current = builder.nodes.items[@backingInt(current)].next_sibling;
    }
    if (current == .none) return error.InvalidDocument;
    builder.nodes.items[@backingInt(inserted)].parent = parent;
    builder.nodes.items[@backingInt(inserted)].next_sibling = target;
    if (previous == .none) {
        builder.nodes.items[parent_index].first_child = inserted;
    } else {
        builder.nodes.items[@backingInt(previous)].next_sibling = inserted;
    }
}

fn processEmphasis(builder: *Builder, delimiters: *std.ArrayList(InlineFrame), bottom: usize) ParseError!void {
    var closer_index = bottom;
    while (closer_index < delimiters.items.len) {
        try builder.charge(1);
        const closer = &delimiters.items[closer_index];
        if (!closer.active or !closer.can_close or closer.length == 0) {
            closer_index += 1;
            continue;
        }
        var opener_index = closer_index;
        var matched = false;
        while (opener_index > bottom) {
            opener_index -= 1;
            try builder.charge(1);
            const opener = &delimiters.items[opener_index];
            if (!opener.active or !opener.can_open or opener.length == 0 or opener.marker != closer.marker) continue;
            if ((opener.can_close or closer.can_open) and
                (opener.length + closer.length) % 3 == 0 and
                (opener.length % 3 != 0 or closer.length % 3 != 0)) continue;
            if (builder.nodes.items[@backingInt(opener.node)].parent !=
                builder.nodes.items[@backingInt(closer.node)].parent) continue;
            try wrapEmphasis(builder, opener, closer);
            for (delimiters.items[opener_index + 1 .. closer_index]) |*inner| {
                try builder.charge(1);
                inner.active = false;
            }
            matched = true;
            break;
        }
        if (!matched or closer.length == 0) closer_index += 1;
    }
    delimiters.shrinkRetainingCapacity(bottom);
}

fn wrapEmphasis(builder: *Builder, opener: *InlineFrame, closer: *InlineFrame) ParseError!void {
    const consumed: u32 = if (opener.length >= 2 and closer.length >= 2) 2 else 1;
    const open_index = @backingInt(opener.node);
    const close_index = @backingInt(closer.node);
    const parent = builder.nodes.items[open_index].parent;
    const first = builder.nodes.items[open_index].next_sibling;
    if (first == .none or first == closer.node) return error.InvalidDocument;
    const wrapper = try builder.appendNode(
        if (consumed == 2) .strong else .emph,
        .none,
        .{ .start = 0, .end = 0 },
        .none,
    );
    const wrapper_index = @backingInt(wrapper);
    var current = first;
    var last: NodeId = .none;
    while (current != closer.node) {
        try builder.charge(1);
        if (current == .none) return error.InvalidDocument;
        last = current;
        builder.nodes.items[@backingInt(current)].parent = wrapper;
        current = builder.nodes.items[@backingInt(current)].next_sibling;
    }
    builder.nodes.items[wrapper_index].parent = parent;
    builder.nodes.items[wrapper_index].first_child = first;
    builder.nodes.items[wrapper_index].last_child = last;
    builder.nodes.items[wrapper_index].next_sibling = closer.node;
    builder.nodes.items[open_index].next_sibling = wrapper;
    builder.nodes.items[@backingInt(last)].next_sibling = .none;
    const open_text = @backingInt(builder.nodes.items[open_index].data.raw);
    const close_text = @backingInt(builder.nodes.items[close_index].data.raw);
    builder.texts.items[open_text].len -= consumed;
    builder.texts.items[close_text].start += consumed;
    builder.texts.items[close_text].len -= consumed;
    opener.length -= consumed;
    closer.length -= consumed;
    if (opener.length == 0) unwrapNode(builder, opener.node, parent);
    if (closer.length == 0) unwrapNode(builder, closer.node, parent);
}

fn unwrapNode(builder: *Builder, node: NodeId, parent: NodeId) void {
    const node_index = @backingInt(node);
    const parent_index = @backingInt(parent);
    if (node_index >= builder.nodes.items.len or parent_index >= builder.nodes.items.len) return;
    const next = builder.nodes.items[node_index].next_sibling;
    var previous: NodeId = .none;
    var current = builder.nodes.items[parent_index].first_child;
    while (current != .none and current != node) {
        previous = current;
        current = builder.nodes.items[@backingInt(current)].next_sibling;
    }
    if (current == .none) return;
    const first = builder.nodes.items[node_index].first_child;
    const last = builder.nodes.items[node_index].last_child;
    if (first != .none and last != .none) {
        if (previous == .none) {
            builder.nodes.items[parent_index].first_child = first;
        } else {
            builder.nodes.items[@backingInt(previous)].next_sibling = first;
        }
        builder.nodes.items[@backingInt(last)].next_sibling = next;
        if (builder.nodes.items[parent_index].last_child == node) {
            builder.nodes.items[parent_index].last_child = last;
        }
        var child = first;
        while (child != .none and child != next) {
            builder.nodes.items[@backingInt(child)].parent = parent;
            child = builder.nodes.items[@backingInt(child)].next_sibling;
        }
    } else {
        if (previous == .none) {
            builder.nodes.items[parent_index].first_child = next;
        } else {
            builder.nodes.items[@backingInt(previous)].next_sibling = next;
        }
        if (builder.nodes.items[parent_index].last_child == node) {
            builder.nodes.items[parent_index].last_child = previous;
        }
    }
    builder.nodes.items[node_index].parent = .none;
    builder.nodes.items[node_index].first_child = .none;
    builder.nodes.items[node_index].last_child = .none;
    builder.nodes.items[node_index].next_sibling = .none;
}

fn delimiterCodepointBefore(raw: []const u8, index: usize) ?u32 {
    if (index == 0) return null;
    var start = index - 1;
    while (start > 0 and (raw[start] & 0xC0) == 0x80) start -= 1;
    return std.unicode.utf8Decode(raw[start..index]) catch @as(u21, raw[index - 1]);
}

fn delimiterCodepointAfter(raw: []const u8, index: usize) ?u32 {
    if (index >= raw.len) return null;
    const width = std.unicode.utf8ByteSequenceLength(raw[index]) catch 1;
    const end = @min(raw.len, index + width);
    return std.unicode.utf8Decode(raw[index..end]) catch @as(u21, raw[index]);
}

fn delimiterIsWhitespace(codepoint: ?u32) bool {
    return categories.isWhitespace(codepoint orelse return true);
}

fn delimiterIsPunctuation(codepoint: ?u32) bool {
    return categories.isPunctuation(codepoint orelse return false);
}

fn isDelimiterOpener(raw: []const u8, index: usize, length: usize) bool {
    const before = delimiterCodepointBefore(raw, index);
    const after = delimiterCodepointAfter(raw, index + length);
    const before_space = delimiterIsWhitespace(before);
    const after_space = delimiterIsWhitespace(after);
    const before_punct = delimiterIsPunctuation(before);
    const after_punct = delimiterIsPunctuation(after);
    const left_flanking = !after_space and (!after_punct or before_space or before_punct);
    const right_flanking = !before_space and (!before_punct or after_space or after_punct);
    if (raw[index] == '*') return left_flanking;
    return left_flanking and (!right_flanking or before_punct);
}

fn isDelimiterCloser(raw: []const u8, index: usize, length: usize) bool {
    const before = delimiterCodepointBefore(raw, index);
    const after = delimiterCodepointAfter(raw, index + length);
    const before_space = delimiterIsWhitespace(before);
    const after_space = delimiterIsWhitespace(after);
    const before_punct = delimiterIsPunctuation(before);
    const after_punct = delimiterIsPunctuation(after);
    const left_flanking = !after_space and (!after_punct or before_space or before_punct);
    const right_flanking = !before_space and (!before_punct or after_space or after_punct);
    if (raw[index] == '*') return right_flanking;
    return right_flanking and (!left_flanking or after_punct);
}

/// Size of `Entity.value`. The named-entity table is validated against it at
/// compile time and `utf8Encode` writes at most four bytes, so nothing ever
/// runs past the buffer.
const entity_value_max = 16;
comptime {
    @setEvalBranchQuota(entity_table.entries.len * 2);
    for (entity_table.entries) |entry| {
        if (entity_value_max < entry.value.len) {
            @compileError("entity_table entry does not fit Entity.value: " ++ entry.name);
        }
    }
}

const Entity = struct {
    value: [entity_value_max]u8,
    len: u8,
    consumed: usize,
};

fn parseEntity(raw: []const u8) ?Entity {
    if (raw.len < 3 or raw[0] != '&') return null;
    if (raw[1] == '#') {
        var base: u8 = 10;
        var index: usize = 2;
        if (index < raw.len and (raw[index] == 'x' or raw[index] == 'X')) {
            base = 16;
            index += 1;
        }
        const start = index;
        while (index < raw.len and
            ((base == 10 and std.ascii.isDigit(raw[index])) or
                (base == 16 and std.ascii.isHex(raw[index])))) : (index += 1)
        {}
        if (index == start or index - start > @as(usize, if (base == 16) 6 else 7) or
            index >= raw.len or raw[index] != ';') return null;
        var codepoint = std.fmt.parseInt(u32, raw[start..index], base) catch return null;
        if (codepoint == 0 or codepoint > 0x10FFFF or (codepoint >= 0xD800 and codepoint <= 0xDFFF)) {
            codepoint = 0xFFFD;
        }
        var encoded: [4]u8 = undefined;
        const encoded_len = std.unicode.utf8Encode(@intCast(codepoint), &encoded) catch return null;
        var result: Entity = .{
            .value = @splat(0),
            .len = @intCast(encoded_len),
            .consumed = index + 1,
        };
        for (encoded[0..encoded_len], 0..) |byte, encoded_index| result.value[encoded_index] = byte;
        return result;
    }
    var index: usize = 1;
    while (index < raw.len and index < 40 and raw[index] != ';') : (index += 1) {
        if (!std.ascii.isAlphabetic(raw[index]) and !std.ascii.isDigit(raw[index])) return null;
    }
    if (index >= raw.len or raw[index] != ';') return null;
    const name = raw[1..index];
    var left: usize = 0;
    var right: usize = entity_table.entries.len;
    while (left < right) {
        const middle = left + (right - left) / 2;
        const entry = entity_table.entries[middle];
        const order = std.mem.order(u8, name, entry.name);
        if (order == .lt) {
            right = middle;
        } else if (order == .gt) {
            left = middle + 1;
        } else {
            var result: Entity = .{ .value = @splat(0), .len = 0, .consumed = index + 1 };
            for (entry.value, 0..) |byte, value_index| result.value[value_index] = byte;
            result.len = @intCast(entry.value.len);
            return result;
        }
    }
    return null;
}

fn findBacktickClose(raw: []const u8, start: usize, run: usize) ?usize {
    var index = start;
    while (index < raw.len) {
        if (raw[index] != '`') {
            index += 1;
            continue;
        }
        var count: usize = 0;
        while (index + count < raw.len and raw[index + count] == '`') : (count += 1) {}
        if (count == run) return index;
        index += count;
    }
    return null;
}

const AutoLink = struct { destination: []const u8, consumed: usize };

fn parseAutolink(raw: []const u8) ?AutoLink {
    if (raw.len < 3 or raw[0] != '<') return null;
    const close = std.mem.indexOfScalar(u8, raw, '>') orelse return null;
    const inside = raw[1..close];
    if (inside.len == 0) return null;
    for (inside) |byte| {
        if (byte <= 0x20 or byte == '<') return null;
    }
    if (std.mem.findScalar(u8, inside, ':')) |colon| {
        if (colon < 2 or colon > 32 or !std.ascii.isAlphabetic(inside[0])) return null;
        for (inside[1..colon]) |byte| {
            if (!std.ascii.isAlphanumeric(byte) and byte != '+' and byte != '-' and byte != '.') return null;
        }
    } else {
        const at = std.mem.indexOfScalar(u8, inside, '@') orelse return null;
        if (at == 0 or at + 1 == inside.len) return null;
        for (inside[0..at]) |byte| {
            if (!std.ascii.isAlphanumeric(byte) and
                std.mem.indexOfScalar(u8, ".!#$%&'*+/=?^_`{|}~-", byte) == null) return null;
        }
        var labels = std.mem.splitScalar(u8, inside[at + 1 ..], '.');
        while (labels.next()) |label| {
            if (label.len == 0 or label.len > 63) return null;
            if (!std.ascii.isAlphanumeric(label[0])) return null;
            if (!std.ascii.isAlphanumeric(label[label.len - 1])) return null;
            for (label) |byte| {
                if (!std.ascii.isAlphanumeric(byte) and byte != '-') return null;
            }
        }
    }
    return .{ .destination = inside, .consumed = close + 1 };
}

fn findTagEnd(raw: []const u8, start: usize) ?usize {
    if (start >= raw.len or raw[start] != '<') return null;
    const rest = raw[start..];
    if (std.mem.startsWith(u8, rest, "<!--")) {
        if (std.mem.find(u8, rest, "-->")) |offset| return start + offset + 2;
        return null;
    }
    if (std.mem.startsWith(u8, rest, "<![CDATA[")) {
        if (std.mem.find(u8, rest, "]]>")) |offset| return start + offset + 2;
        return null;
    }
    if (std.mem.startsWith(u8, rest, "<?")) {
        if (std.mem.find(u8, rest, "?>")) |offset| return start + offset + 1;
        return null;
    }
    // A declaration carries no quote rules and ends at the first `>`.
    if (std.mem.startsWith(u8, rest, "<!")) {
        if (std.mem.findScalar(u8, rest, '>')) |offset| return start + offset;
        return null;
    }
    var index = start + 1;
    var quote: u8 = 0;
    while (index < raw.len) : (index += 1) {
        const byte = raw[index];
        if (quote != 0) {
            if (byte == quote) quote = 0;
        } else if (byte == '\'' or byte == '"') {
            quote = byte;
        } else if (byte == '>') {
            return index;
        }
    }
    return null;
}

fn isHtmlWhitespace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r';
}

/// Bytes permitted in an unquoted attribute value: anything but whitespace,
/// a quote, `=`, an angle bracket, or a backtick.
fn isHtmlAttributeValueChar(byte: u8) bool {
    return !isHtmlWhitespace(byte) and byte != '"' and byte != '\'' and byte != '=' and
        byte != '<' and byte != '>' and byte != '`';
}

fn isHtmlAttributeNameStart(byte: u8) bool {
    return std.ascii.isAlphabetic(byte) or byte == '_' or byte == ':';
}

fn isHtmlAttributeNameChar(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte == ':' or
        byte == '.' or byte == '-';
}

fn isHtmlInlineTag(tag: []const u8) bool {
    if (tag.len < 3 or tag[0] != '<' or tag[tag.len - 1] != '>') return false;
    if (std.mem.startsWith(u8, tag, "<!--")) return std.mem.endsWith(u8, tag, "-->");
    if (std.mem.startsWith(u8, tag, "<?")) return std.mem.endsWith(u8, tag, "?>");
    if (std.mem.startsWith(u8, tag, "<![CDATA[")) return std.mem.endsWith(u8, tag, "]]>");
    // A declaration is `<!`, an ASCII letter, any characters other than `>`,
    // and the closing `>`.
    if (std.mem.startsWith(u8, tag, "<!")) {
        if (tag.len < 4 or !std.ascii.isAlphabetic(tag[2])) return false;
        return std.mem.indexOfScalar(u8, tag[3 .. tag.len - 1], '>') == null;
    }

    var index: usize = 1;
    var closing = false;
    if (tag[index] == '/') {
        closing = true;
        index += 1;
    }
    if (index >= tag.len - 1) return false;
    if (!((tag[index] >= 'A' and tag[index] <= 'Z') or (tag[index] >= 'a' and tag[index] <= 'z'))) return false;
    while (index < tag.len - 1 and ((tag[index] >= 'A' and tag[index] <= 'Z') or
        (tag[index] >= 'a' and tag[index] <= 'z') or (tag[index] >= '0' and tag[index] <= '9') or
        tag[index] == '-')) : (index += 1)
    {}
    if (closing) {
        while (index < tag.len - 1 and isHtmlWhitespace(tag[index])) : (index += 1) {}
        return index == tag.len - 1;
    }
    if (index < tag.len - 1 and tag[index] != '/' and tag[index] != '>' and !isHtmlWhitespace(tag[index])) return false;
    while (index < tag.len - 1 and isHtmlWhitespace(tag[index])) : (index += 1) {}
    while (index < tag.len - 1) {
        if (tag[index] == '/') return index + 1 == tag.len - 1;
        if (index >= tag.len - 1 or !isHtmlAttributeNameStart(tag[index])) return false;
        while (index < tag.len - 1 and isHtmlAttributeNameChar(tag[index])) : (index += 1) {}
        const after_name = index;
        while (index < tag.len - 1 and isHtmlWhitespace(tag[index])) : (index += 1) {}
        if (index < tag.len - 1 and tag[index] == '=') {
            index += 1;
            while (index < tag.len - 1 and isHtmlWhitespace(tag[index])) : (index += 1) {}
            if (index >= tag.len - 1) return false;
            if (tag[index] == '\'' or tag[index] == '"') {
                const quote = tag[index];
                index += 1;
                while (index < tag.len - 1 and tag[index] != quote) : (index += 1) {}
                if (index >= tag.len - 1) return false;
                index += 1;
            } else {
                const value_start = index;
                while (index < tag.len - 1 and isHtmlAttributeValueChar(tag[index])) : (index += 1) {}
                if (index == value_start) return false;
            }
        } else {
            index = after_name;
        }
        if (index < tag.len - 1 and tag[index] != '/' and !isHtmlWhitespace(tag[index])) return false;
        while (index < tag.len - 1 and isHtmlWhitespace(tag[index])) : (index += 1) {}
    }
    return index == tag.len - 1;
}

fn isEscapable(byte: u8) bool {
    return std.mem.indexOfScalar(u8, "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~", byte) != null;
}

const LinkParse = struct { destination: TextId, title: TextId, end: usize };

fn parseLinkAfterClose(raw: []const u8, start: usize, builder: *Builder, frame: BracketFrame) ParseError!?LinkParse {
    var index = start;
    inline_check: {
        if (index >= raw.len or raw[index] != '(') break :inline_check;
        index += 1;
        while (index < raw.len and (raw[index] == ' ' or raw[index] == '\t' or raw[index] == '\n')) index += 1;
        var destination: TextId = .none;
        var angle_destination = false;
        if (index < raw.len and raw[index] == '<') {
            angle_destination = true;
            index += 1;
            const destination_start = index;
            while (index < raw.len) {
                if (raw[index] == '\\' and index + 1 < raw.len and isEscapable(raw[index + 1])) {
                    index += 2;
                    continue;
                }
                if (raw[index] == '>' or raw[index] == '\n') break;
                index += 1;
            }
            if (index >= raw.len or raw[index] != '>') break :inline_check;
            destination = try cleanDestination(.link, builder, raw[destination_start..index]);
            index += 1;
        } else {
            const destination_start = index;
            var depth: u32 = 0;
            while (index < raw.len) {
                if (raw[index] == '\\' and index + 1 < raw.len and isEscapable(raw[index + 1])) {
                    index += 2;
                    continue;
                }
                if (raw[index] == '(') depth += 1;
                if (raw[index] == ')') {
                    if (depth == 0) break;
                    depth -= 1;
                }
                if (raw[index] == ' ' or raw[index] == '\t' or raw[index] == '\n') break;
                index += 1;
            }
            if (index >= raw.len or depth != 0) break :inline_check;
            destination = try cleanDestination(.link, builder, raw[destination_start..index]);
        }
        // A title after an angle destination needs whitespace to separate them.
        var separator_seen = !angle_destination;
        while (index < raw.len and (raw[index] == ' ' or raw[index] == '\t' or raw[index] == '\n')) {
            separator_seen = true;
            index += 1;
        }
        var title: TextId = .none;
        if (separator_seen and index < raw.len and (raw[index] == '"' or raw[index] == '\'' or raw[index] == '(')) {
            const opener = raw[index];
            const closer = if (opener == '(') ')' else opener;
            index += 1;
            const title_start = index;
            while (index < raw.len) {
                if (raw[index] == '\\' and index + 1 < raw.len and isEscapable(raw[index + 1])) {
                    index += 2;
                    continue;
                }
                if (raw[index] == closer) break;
                index += 1;
            }
            if (index >= raw.len or raw[index] != closer) break :inline_check;
            title = try cleanDestination(.link, builder, raw[title_start..index]);
            index += 1;
        }
        while (index < raw.len and (raw[index] == ' ' or raw[index] == '\t' or raw[index] == '\n')) index += 1;
        if (index >= raw.len or raw[index] != ')') break :inline_check;
        return .{ .destination = destination, .title = title, .end = index + 1 };
    }
    index = start;
    full_reference: {
        if (index >= raw.len or raw[index] != '[') break :full_reference;
        index += 1;
        const label_start = index;
        var is_label = true;
        while (index < raw.len) {
            if (raw[index] == '\\' and index + 1 < raw.len) {
                index += 2;
                continue;
            }
            if (raw[index] == '[') {
                is_label = false;
                break;
            }
            if (raw[index] == ']') break;
            index += 1;
        }
        // An unescaped `[` means the bracketed text is not a label, so the
        // shortcut reference is tried instead.
        if (!is_label) break :full_reference;
        // The scan reached the end of the text without a `]`, so the bracketed
        // text is no label and the shortcut reference is tried instead.
        if (index >= raw.len) break :full_reference;
        const label = try normalizeLabel(builder, raw[label_start..index]) orelse return null;
        if (builder.rawText(label).len != 0) {
            if (lookupReference(builder, label)) |reference| {
                return .{ .destination = reference.destination, .title = reference.title, .end = index + 1 };
            }
            return null;
        }
        const implicit_start = @as(usize, frame.source_start) + @as(usize, if (frame.image) 2 else 1);
        var implicit_end = implicit_start;
        while (implicit_end < raw.len and raw[implicit_end] != ']') : (implicit_end += 1) {}
        if (implicit_end >= raw.len) return null;
        const implicit = try normalizeLabel(builder, raw[implicit_start..implicit_end]) orelse return null;
        if (lookupReference(builder, implicit)) |reference| {
            return .{ .destination = reference.destination, .title = reference.title, .end = index + 1 };
        }
        return null;
    }
    const label_start_width: usize = if (frame.image) 2 else 1;
    const label = try normalizeLabel(
        builder,
        raw[frame.source_start + label_start_width .. start - 1],
    ) orelse return null;
    if (lookupReference(builder, label)) |reference| return .{
        .destination = reference.destination,
        .title = reference.title,
        .end = start,
    };
    return null;
}

fn cleanDestination(comptime mode: enum { link, autolink }, builder: *Builder, raw: []const u8) ParseError!TextId {
    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(builder.gpa);
    var index: usize = 0;
    while (index < raw.len) : (index += 1) {
        if (mode == .link and raw[index] == '\\' and index + 1 < raw.len and isEscapable(raw[index + 1])) {
            result.append(builder.gpa, raw[index + 1]) catch return error.OutOfMemory;
            index += 1;
        } else if (raw[index] == '&') {
            if (parseEntity(raw[index..])) |entity| {
                result.appendSlice(builder.gpa, entity.value[0..entity.len]) catch return error.OutOfMemory;
                index += entity.consumed - 1;
            } else result.append(builder.gpa, raw[index]) catch return error.OutOfMemory;
        } else result.append(builder.gpa, raw[index]) catch return error.OutOfMemory;
    }
    return builder.appendTextNormalized(result.items);
}

fn normalizeLabel(builder: *Builder, raw: []const u8) ParseError!?TextId {
    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(builder.gpa);
    var codepoints: u32 = 0;
    var pending_space = false;
    var index: usize = 0;
    while (index < raw.len) {
        try builder.charge(1);
        const sequence = std.unicode.utf8ByteSequenceLength(raw[index]) catch 1;
        const end = @min(raw.len, index + sequence);
        const cp: u21 = switch (end - index) {
            1 => raw[index],
            2 => std.unicode.utf8Decode2(raw[index..][0..2].*) catch @as(u21, raw[index]),
            3 => std.unicode.utf8Decode3(raw[index..][0..3].*) catch @as(u21, raw[index]),
            4 => std.unicode.utf8Decode4(raw[index..][0..4].*) catch @as(u21, raw[index]),
            else => raw[index],
        };
        codepoints += 1;
        if (codepoints > 999) return null;
        if (cp == ' ' or cp == '\t' or cp == '\n' or cp == '\r') {
            pending_space = result.items.len != 0;
        } else {
            if (pending_space) result.append(builder.gpa, ' ') catch return error.OutOfMemory;
            pending_space = false;
            if (casefold.lookup(cp)) |folded| {
                result.appendSlice(builder.gpa, folded) catch return error.OutOfMemory;
            } else {
                var encoded: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(cp, &encoded) catch return error.InvalidUtf8;
                result.appendSlice(builder.gpa, encoded[0..len]) catch return error.OutOfMemory;
            }
        }
        index = end;
    }
    const text_id = try builder.appendTextNormalized(result.items);
    return text_id;
}

fn lookupReference(builder: *Builder, label: TextId) ?Reference {
    const label_bytes = builder.rawText(label);
    for (builder.references.items) |reference| {
        if (std.mem.eql(u8, label_bytes, builder.rawText(reference.label))) return reference;
    }
    return null;
}

fn finalizeLists(builder: *Builder) ParseError!void {
    for (builder.nodes.items) |*list| {
        if (list.kind != .list) continue;
        var tight = true;
        var previous_item: NodeId = .none;
        var item_id = list.first_child;
        while (item_id != .none) {
            try builder.charge(1);
            const item = builder.nodes.items[@backingInt(item_id)];
            if (previous_item != .none and
                try blocksHaveBlankBetween(builder, previous_item, item_id)) tight = false;
            var previous_block: NodeId = .none;
            var block_id = item.first_child;
            while (block_id != .none) {
                try builder.charge(1);
                if (previous_block != .none and
                    try blocksHaveBlankBetween(builder, previous_block, block_id)) tight = false;
                previous_block = block_id;
                block_id = builder.nodes.items[@backingInt(block_id)].next_sibling;
            }
            previous_item = item_id;
            item_id = item.next_sibling;
        }
        list.data.list.tight = tight;
    }
}

fn blocksHaveBlankBetween(builder: *Builder, previous: NodeId, next: NodeId) ParseError!bool {
    var terminal = previous;
    while (true) {
        try builder.charge(1);
        const node = builder.nodes.items[@backingInt(terminal)];
        switch (node.kind) {
            .list, .list_item, .block_quote => {
                if (node.last_child != .none) {
                    terminal = node.last_child;
                    continue;
                }
            },
            else => {},
        }
        break;
    }
    var end: usize = builder.nodes.items[@backingInt(terminal)].source.end;
    const start = builder.nodes.items[@backingInt(terminal)].source.start;
    while (end > start and std.ascii.isWhitespace(builder.source[end - 1])) {
        try builder.charge(1);
        end -= 1;
    }
    const next_start = builder.nodes.items[@backingInt(next)].source.start;
    if (end >= next_start) return false;
    const gap = builder.source[end..next_start];
    try builder.charge(@intCast(gap.len));
    var line_start = (std.mem.indexOfScalar(u8, gap, '\n') orelse return false) + 1;
    while (std.mem.findScalarPos(u8, gap, line_start, '\n')) |line_end| {
        var content = std.mem.trim(u8, gap[line_start..line_end], " \t\r");
        var ancestor = builder.nodes.items[@backingInt(previous)].parent;
        while (ancestor != .none) {
            try builder.charge(1);
            const node = builder.nodes.items[@backingInt(ancestor)];
            if (node.kind == .block_quote and content.len != 0 and content[0] == '>') {
                content = std.mem.trimStart(u8, content[1..], " \t");
            }
            ancestor = node.parent;
        }
        if (content.len == 0) return true;
        line_start = line_end + 1;
    }
    return false;
}

/// Renders `document` as HTML into bytes the caller owns.
///
/// `gpa` receives the result and every temporary, and the caller frees the
/// result with that same allocator. The document is borrowed for the call only
/// and must not be `deinit`'d, mutated or otherwise disposed of while it runs.
/// The call reads the document and mutates nothing, so several calls may run
/// against one live document, including from more than one thread; `gpa` must
/// be an allocator the caller is using that way.
///
/// A missing root, a root that is not a detached `.document` node, a dangling or
/// cross-parented child or parent link, and a walk that does not finish within
/// twice the node count in steps all fail with `error.InvalidDocument`. On any
/// error the partial output is released and no bytes are returned. On success
/// the result is a fresh buffer of exactly the produced length.
pub fn renderCommonMarkHtml(
    gpa: std.mem.Allocator,
    document: *const CommonMarkDocument,
    options: HtmlRenderOptions,
) RenderError![]u8 {
    const root = document.node(.root) orelse return error.InvalidDocument;
    if (root.kind != .document or root.parent != .none or root.next_sibling != .none) return error.InvalidDocument;
    var output: RenderOutput = .{ .limit = options.max_output_bytes };
    errdefer output.bytes.deinit(gpa);
    var stack: std.ArrayList(RenderFrame) = .empty;
    defer stack.deinit(gpa);
    var children: std.ArrayList(NodeId) = .empty;
    defer children.deinit(gpa);

    stack.append(gpa, .{ .node = .root, .exit = false }) catch return error.OutOfMemory;
    var work: u64 = 0;
    while (stack.items.len > 0) {
        if (work >= @as(u64, @intCast(document.nodes.len)) *| 2) return error.InvalidDocument;
        work += 1;
        const frame = stack.pop() orelse return error.InvalidDocument;
        const node = document.node(frame.node) orelse return error.InvalidDocument;
        if (frame.exit) {
            try renderExit(gpa, document, &output, options, frame.node);
            continue;
        }

        try renderEnter(gpa, document, &output, options, frame.node);
        stack.append(gpa, .{ .node = frame.node, .exit = true }) catch return error.OutOfMemory;
        if (node.kind != .image) {
            try collectRenderChildren(gpa, document, frame.node, &children);
            var child_index = children.items.len;
            while (child_index > 0) {
                child_index -= 1;
                stack.append(gpa, .{
                    .node = children.items[child_index],
                    .exit = false,
                }) catch return error.OutOfMemory;
            }
        }
    }
    return output.bytes.toOwnedSlice(gpa) catch return error.OutOfMemory;
}

const RenderFrame = struct { node: NodeId, exit: bool };

const RenderOutput = struct {
    bytes: std.ArrayList(u8) = .empty,
    limit: usize,

    fn appendSlice(self: *RenderOutput, gpa: std.mem.Allocator, value: []const u8) RenderError!void {
        if (value.len > self.limit -| self.bytes.items.len) return error.OutputTooLarge;
        self.bytes.appendSlice(gpa, value) catch return error.OutOfMemory;
    }

    fn append(self: *RenderOutput, gpa: std.mem.Allocator, value: u8) RenderError!void {
        try self.appendSlice(gpa, &.{value});
    }

    fn print(
        self: *RenderOutput,
        comptime format: []const u8,
        gpa: std.mem.Allocator,
        args: anytype,
    ) RenderError!void {
        if (std.fmt.count(format, args) > self.limit -| self.bytes.items.len) return error.OutputTooLarge;
        self.bytes.print(gpa, format, args) catch return error.OutOfMemory;
    }
};

fn collectRenderChildren(
    gpa: std.mem.Allocator,
    document: *const CommonMarkDocument,
    parent: NodeId,
    children: *std.ArrayList(NodeId),
) RenderError!void {
    if (document.node(parent) == null) return error.InvalidDocument;
    children.items.len = 0;
    var iterator = document.nodeChildren(parent);
    while (iterator.nextChild()) |child| {
        const node = document.node(child) orelse return error.InvalidDocument;
        if (node.parent != parent) return error.InvalidDocument;
        children.append(gpa, child) catch return error.OutOfMemory;
    }
    if (iterator.isInvalid()) return error.InvalidDocument;
}

fn listItemNeedsLeadingNewline(document: *const CommonMarkDocument, id: NodeId) RenderError!bool {
    const node = document.node(id) orelse return error.InvalidDocument;
    if (node.parent == .none) return false;
    const parent = document.node(node.parent) orelse return error.InvalidDocument;
    if (parent.kind != .list_item) return false;
    // A link reference definition contributes no bytes, so it neither needs a
    // line of its own nor hides the line the block after it opens on. An item
    // whose only child was consumed as a definition renders `<li></li>`.
    if (node.kind == .reference_definition) return false;
    var iterator = document.nodeChildren(node.parent);
    var previous: NodeId = .none;
    while (iterator.nextChild()) |child| {
        if (child == id) {
            if (previous == .none) {
                return switch (node.kind) {
                    .paragraph => !isTightParagraph(document, node),
                    else => true,
                };
            }
            const previous_node = document.node(previous) orelse return error.InvalidDocument;
            return previous_node.kind == .paragraph and isTightParagraph(document, previous_node);
        }
        const child_node = document.node(child) orelse return error.InvalidDocument;
        if (child_node.kind != .reference_definition) previous = child;
    }
    return error.InvalidDocument;
}

fn renderEnter(
    gpa: std.mem.Allocator,
    document: *const CommonMarkDocument,
    output: *RenderOutput,
    options: HtmlRenderOptions,
    id: NodeId,
) RenderError!void {
    const node = document.node(id) orelse return error.InvalidDocument;
    if (try listItemNeedsLeadingNewline(document, id)) try appendLiteral(output, gpa, "\n");
    switch (node.kind) {
        .document => {},
        .reference_definition => {},
        .block_quote => try appendLiteral(output, gpa, "<blockquote>\n"),
        .list => {
            const data = switch (node.data) {
                .list => |value| value,
                else => return error.InvalidDocument,
            };
            if (data.ordered) {
                if (data.start == 1) try appendLiteral(output, gpa, "<ol>\n") else try appendFmt(
                    "<ol start=\"{d}\">\n",
                    gpa,
                    output,
                    .{data.start},
                );
            } else try appendLiteral(output, gpa, "<ul>\n");
        },
        .list_item => try appendLiteral(output, gpa, "<li>"),
        .paragraph => {
            if (!isTightParagraph(document, node)) try appendLiteral(output, gpa, "<p>");
        },
        .heading => {
            const data = switch (node.data) {
                .heading => |value| value,
                else => return error.InvalidDocument,
            };
            try appendFmt("<h{d}>", gpa, output, .{data.level});
        },
        .thematic_break => try appendLiteral(output, gpa, "<hr />\n"),
        .code_block => {
            const data = switch (node.data) {
                .code_block => |value| value,
                else => return error.InvalidDocument,
            };
            try appendLiteral(output, gpa, "<pre><code");
            if (document.text(data.info)) |info| {
                if (info.len > 0) {
                    const first = std.mem.indexOfAny(u8, info, " \t\n") orelse info.len;
                    const word = info[0..first];
                    // The prefix names a bare language word, so an info word
                    // that already starts with it keeps exactly one copy.
                    try appendLiteral(output, gpa, " class=\"");
                    if (!std.mem.startsWith(u8, word, "language-")) {
                        try appendLiteral(output, gpa, "language-");
                    }
                    try appendEscaped(output, gpa, word);
                    try appendLiteral(output, gpa, "\"");
                }
            }
            try appendLiteral(output, gpa, ">");
            if (document.text(data.raw)) |raw| {
                if (raw.len > 0) {
                    try appendEscaped(output, gpa, raw);
                    if (!std.mem.endsWith(u8, raw, "\n")) try appendLiteral(output, gpa, "\n");
                }
            }
        },
        .html_block => {
            if (options.mode == .conformance) {
                if (node.data == .raw) if (document.text(node.data.raw)) |raw| try appendBytes(output, gpa, raw);
            } else try appendLiteral(output, gpa, "<!-- raw HTML omitted -->");
            try appendLiteral(output, gpa, "\n");
        },
        .text => if (node.data == .raw) if (document.text(node.data.raw)) |text|
            try appendEscaped(output, gpa, text),
        .softbreak => try appendLiteral(output, gpa, "\n"),
        .linebreak => try appendLiteral(output, gpa, "<br />\n"),
        .code_span => {
            try appendLiteral(output, gpa, "<code>");
            if (node.data == .raw) if (document.text(node.data.raw)) |text| try appendEscaped(output, gpa, text);
        },
        .emph => try appendLiteral(output, gpa, "<em>"),
        .strong => try appendLiteral(output, gpa, "<strong>"),
        .link => {
            const data = switch (node.data) {
                .link => |value| value,
                else => return error.InvalidDocument,
            };
            try appendLiteral(output, gpa, "<a href=\"");
            if (document.text(data.destination)) |destination| {
                if (options.mode == .conformance or !isDangerousUrl(destination))
                    try appendHref(output, gpa, destination);
            }
            if (data.title != .none) {
                try appendLiteral(output, gpa, "\" title=\"");
                if (document.text(data.title)) |title| try appendEscaped(output, gpa, title);
            }
            try appendLiteral(output, gpa, "\">");
        },
        .image => {
            const data = switch (node.data) {
                .image => |value| value,
                else => return error.InvalidDocument,
            };
            try appendLiteral(output, gpa, "<img src=\"");
            if (document.text(data.destination)) |destination| {
                if (options.mode == .conformance or !isDangerousUrl(destination))
                    try appendHref(output, gpa, destination);
            }
            try appendLiteral(output, gpa, "\" alt=\"");
            try renderPlainChildren(gpa, document, output, options, id);
            if (data.title != .none) {
                try appendLiteral(output, gpa, "\" title=\"");
                if (document.text(data.title)) |title| try appendEscaped(output, gpa, title);
            }
            try appendLiteral(output, gpa, "\" />");
        },
        .autolink => {
            const value = switch (node.data) {
                .autolink => |text| text,
                else => return error.InvalidDocument,
            };
            const text = document.text(value) orelse return error.InvalidDocument;
            try appendLiteral(output, gpa, "<a href=\"");
            if (options.mode == .conformance or !isDangerousUrl(text)) {
                if (std.mem.indexOfScalar(u8, text, '@') != null and std.mem.indexOfScalar(u8, text, ':') == null) {
                    try appendLiteral(output, gpa, "mailto:");
                }
                try appendHref(output, gpa, text);
            }
            try appendLiteral(output, gpa, "\">");
            try appendEscaped(output, gpa, text);
        },
        .html_inline => {
            if (options.mode == .conformance) {
                if (node.data == .raw) if (document.text(node.data.raw)) |raw| try appendBytes(output, gpa, raw);
            } else try appendLiteral(output, gpa, "<!-- raw HTML omitted -->");
        },
    }
}

fn renderExit(
    gpa: std.mem.Allocator,
    document: *const CommonMarkDocument,
    output: *RenderOutput,
    _: HtmlRenderOptions,
    id: NodeId,
) RenderError!void {
    const node = document.node(id) orelse return error.InvalidDocument;
    switch (node.kind) {
        .document => {},
        .block_quote => try appendLiteral(output, gpa, "</blockquote>\n"),
        .list => {
            const data = switch (node.data) {
                .list => |value| value,
                else => return error.InvalidDocument,
            };
            try appendLiteral(output, gpa, if (data.ordered) "</ol>\n" else "</ul>\n");
        },
        .list_item => try appendLiteral(output, gpa, "</li>\n"),
        .paragraph => if (!isTightParagraph(document, node)) try appendLiteral(output, gpa, "</p>\n"),
        .heading => {
            const data = switch (node.data) {
                .heading => |value| value,
                else => return error.InvalidDocument,
            };
            try appendFmt("</h{d}>\n", gpa, output, .{data.level});
        },
        .code_block => try appendLiteral(output, gpa, "</code></pre>\n"),
        .code_span => try appendLiteral(output, gpa, "</code>"),
        .emph => try appendLiteral(output, gpa, "</em>"),
        .strong => try appendLiteral(output, gpa, "</strong>"),
        .link, .autolink => try appendLiteral(output, gpa, "</a>"),
        else => {},
    }
}

fn isTightParagraph(document: *const CommonMarkDocument, node: *const Node) bool {
    const item = document.node(node.parent) orelse return false;
    if (item.kind != .list_item) return false;
    const list = document.node(item.parent) orelse return false;
    if (list.kind != .list) return false;
    return switch (list.data) {
        .list => |data| data.tight,
        else => false,
    };
}

fn renderPlainChildren(
    gpa: std.mem.Allocator,
    document: *const CommonMarkDocument,
    output: *RenderOutput,
    _: HtmlRenderOptions,
    id: NodeId,
) RenderError!void {
    var stack: std.ArrayList(NodeId) = .empty;
    defer stack.deinit(gpa);
    var children: std.ArrayList(NodeId) = .empty;
    defer children.deinit(gpa);

    try collectRenderChildren(gpa, document, id, &children);
    var child_index = children.items.len;
    while (child_index > 0) {
        child_index -= 1;
        stack.append(gpa, children.items[child_index]) catch return error.OutOfMemory;
    }

    var visited: usize = 0;
    while (stack.items.len > 0) {
        if (visited >= document.nodes.len) return error.InvalidDocument;
        visited += 1;
        const current = stack.pop() orelse return error.InvalidDocument;
        const node = document.node(current) orelse return error.InvalidDocument;
        switch (node.kind) {
            .text, .code_span => if (node.data == .raw) if (document.text(node.data.raw)) |text|
                try appendEscaped(output, gpa, text),
            // Raw HTML inside an image contributes its literal bytes to the
            // alt text, escaped the way an attribute value is.
            .html_inline, .html_block => if (node.data == .raw) if (document.text(node.data.raw)) |raw|
                try appendEscaped(output, gpa, raw),
            .softbreak, .linebreak => try appendLiteral(output, gpa, " "),
            else => {
                try collectRenderChildren(gpa, document, current, &children);
                child_index = children.items.len;
                while (child_index > 0) {
                    child_index -= 1;
                    stack.append(gpa, children.items[child_index]) catch return error.OutOfMemory;
                }
            },
        }
    }
}

fn appendLiteral(output: *RenderOutput, gpa: std.mem.Allocator, bytes: []const u8) RenderError!void {
    try output.appendSlice(gpa, bytes);
}

fn appendBytes(output: *RenderOutput, gpa: std.mem.Allocator, bytes: []const u8) RenderError!void {
    try output.appendSlice(gpa, bytes);
}

fn appendFmt(
    comptime format: []const u8,
    gpa: std.mem.Allocator,
    output: *RenderOutput,
    args: anytype,
) RenderError!void {
    try output.print(format, gpa, args);
}

/// Escapes the bytes an HTML text node or attribute value cannot carry. One
/// table serves both contexts: `cmark` runs `houdini_escape_html` with
/// `secure = 0` from every call site and `commonmark.js` `escapeXml` handles
/// only `&`, `<`, `>` and `"`, so an apostrophe is written through as itself.
fn appendEscaped(output: *RenderOutput, gpa: std.mem.Allocator, bytes: []const u8) RenderError!void {
    for (bytes) |byte| {
        switch (byte) {
            '&' => try appendLiteral(output, gpa, "&amp;"),
            '<' => try appendLiteral(output, gpa, "&lt;"),
            '>' => try appendLiteral(output, gpa, "&gt;"),
            '"' => try appendLiteral(output, gpa, "&quot;"),
            else => try output.append(gpa, byte),
        }
    }
}

fn appendHref(output: *RenderOutput, gpa: std.mem.Allocator, bytes: []const u8) RenderError!void {
    const hex = "0123456789ABCDEF";
    for (bytes) |byte| {
        // The set mirrors cmark's HREF_SAFE: every byte outside printable ASCII
        // that a URL cannot carry literally, and `%` stays as written.
        if (byte <= 0x20 or byte >= 0x80 or byte == 0x7F or byte == '"' or byte == '<' or
            byte == '>' or byte == '\\' or byte == '`' or byte == '[' or byte == ']' or
            byte == '^' or byte == '{' or byte == '|' or byte == '}')
        {
            try output.appendSlice(gpa, &.{ '%', hex[byte >> 4], hex[byte & 0x0F] });
        } else if (byte == '&') {
            try appendLiteral(output, gpa, "&amp;");
        } else try output.append(gpa, byte);
    }
}

fn isDangerousUrl(url: []const u8) bool {
    var index: usize = 0;
    while (index < url.len and url[index] <= 0x20) : (index += 1) {}
    var scheme: [10]u8 = undefined;
    var length: usize = 0;
    while (index < url.len) : (index += 1) {
        const byte = url[index];
        if (byte == '\t' or byte == '\n' or byte == '\r') continue;
        if (byte == ':') {
            const lower = scheme[0..length];
            return std.mem.eql(u8, lower, "javascript") or std.mem.eql(u8, lower, "vbscript") or
                std.mem.eql(u8, lower, "file") or std.mem.eql(u8, lower, "data");
        }
        if (length == scheme.len or
            (!std.ascii.isAlphanumeric(byte) and byte != '+' and byte != '-' and byte != '.')) return false;
        scheme[length] = std.ascii.toLower(byte);
        length += 1;
    }
    return false;
}

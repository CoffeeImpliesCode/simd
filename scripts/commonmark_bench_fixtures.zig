//! Data-only CommonMark 0.31.2 benchmark fixtures and their oracle tables.
//!
//! This module imports `std` and the shared semantic contract only. It must
//! never import `@import("simd_lib")`: the archive/report decoder has to be
//! able to read the declared work domain without a CPU-dependent library
//! module and without invoking a parser.
//!
//! Every expectation below is written by hand from the specification and from
//! the profile's documented rules. No value here is copied out of a parser run,
//! and a disagreement between the parser and these tables is settled by
//! deriving the correct expectation, never by adopting the observed one. The
//! basis of each field is:
//!
//!  - `source`: a document assembled from the constructs the pinned CommonMark
//!    0.31.2 specification
//!    (`test/corpus/upstream/commonmark-0.31.2/spec.json`) names in its block
//!    and inline sections. No fixture is a verbatim upstream example, so the
//!    `html` of a matching example is a reference for the construct and never
//!    the expected output below.
//!  - `expected`: the complete preorder tree the profile's node model yields,
//!    carrying the payload each node kind is documented to carry (`Attrs`
//!    below) with every `depth`, `child_index` and `child_count` derived from
//!    that same tree.
//!  - `html`: exact `HtmlRenderMode.safe` output. Safe mode emits
//!    `<!-- raw HTML omitted -->` in place of raw HTML and leaves the
//!    destination of a dangerous URL empty, so this differs from upstream HTML
//!    by design wherever a document carries either.
//!  - `outcome` and `limits`: `accepted` or a name from the parser's published
//!    `ParseError` set, with each resource fixture differing from the defaults
//!    in exactly one bound and its counting argument stated beside its source.
//!
//! `commonmark_bench.zig` is what enforces the tables: a preflight runs before
//! any timing, compares every fixture against the real parser field by field,
//! and fails loudly on the first disagreement, naming the record and printing
//! both its expected and its observed fields. It never repairs an expectation
//! by copying what the parser produced.
//!
//! Every fixture source below is a complete document and ends with a line
//! ending, the way every example in the pinned `spec.json` does. A Zig
//! multiline string literal never appends one, so each source spells its final
//! `"\n"` out explicitly instead of leaving the document truncated.
//!
//! Every expected safe HTML below ends with the line ending the renderer emits
//! after its last block. A Zig multiline string literal never appends one, so
//! each expectation written as a multiline literal spells that final `"\n"` out
//! as a concatenation continuation on its own line, exactly as the fixture
//! sources above do.

const std = @import("std");
const contract = @import("semantic_contract");

/// Outcome recorded by the benchmark when the real call returned without an
/// error. Every other outcome is `@errorName(observed_error)`.
pub const accepted_outcome: []const u8 = "accepted";

/// The `parse` stage deliberately consumes very little: the document root
/// kind plus the kinds of the first and last top-level blocks. It is reported
/// as `small` in the benchmark metadata rather than implying whole-document
/// coverage. `traverse` is the complete semantic consumption.
pub const parse_stage_coverage: []const u8 = "small";

// ---------------------------------------------------------------------------
// Semantic record vocabulary
// ---------------------------------------------------------------------------

/// The node kinds this benchmark traverses. The discriminant order is stable
/// and is mixed into the semantic checksum as a u64.
pub const Kind = enum(u8) {
    document,
    block_quote,
    list,
    list_item,
    paragraph,
    reference_definition,
    heading,
    thematic_break,
    code_block,
    html_block,
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

pub const ListAttrs = struct {
    ordered: bool,
    start: u32,
    delimiter: u8,
    tight: bool,
};

pub const HeadingAttrs = struct {
    level: u8,
    /// The heading's own raw text (`NodeData.heading.raw`).
    text: []const u8,
};

pub const CodeBlockAttrs = struct {
    fenced: bool,
    fence: u8,
    fence_length: usize,
    info: []const u8,
    raw: []const u8,
};

pub const DestinationAttrs = struct {
    destination: []const u8,
    /// Empty when the node carries no title (`TextId.none`).
    title: []const u8,
};

/// The kind-specific payload of one traversed node. Every variant is written
/// out explicitly so a mismatch names the exact attribute that drifted.
pub const Attrs = union(enum) {
    /// document, block_quote, list_item, reference_definition,
    /// thematic_break, softbreak, linebreak, emph, strong.
    none,
    /// The node's own raw text: paragraph, text, code_span, html_inline,
    /// html_block.
    raw: []const u8,
    list: ListAttrs,
    heading: HeadingAttrs,
    code_block: CodeBlockAttrs,
    /// link and image.
    destination: DestinationAttrs,
    autolink: []const u8,
};

/// One node of the complete preorder semantic tree.
pub const Record = struct {
    kind: Kind,
    /// 0 for the document root, 1 for top-level blocks, and so on.
    depth: u32,
    /// 0-based position among the parent's children.
    child_index: u32,
    child_count: u32,
    attrs: Attrs,
};

/// Plain-data mirror of `commonmark.CommonMarkOptions`. Values below are the
/// parser's own defaults; a resource fixture overrides exactly one field.
pub const Limits = struct {
    max_input_bytes: usize,
    max_nodes: usize,
    max_text_bytes: usize,
    max_reference_count: usize,
    max_delimiters: usize,
    max_brackets: usize,
    max_depth: usize,
    max_work: u64,
};

pub const default_limits: Limits = .{
    .max_input_bytes = 64 * 1024 * 1024,
    .max_nodes = 1_000_000,
    .max_text_bytes = 64 * 1024 * 1024,
    .max_reference_count = 100_000,
    .max_delimiters = 1_000_000,
    .max_brackets = 1_000_000,
    .max_depth = 4096,
    .max_work = 256 * 1024 * 1024,
};

/// Plain-data mirror of the one `HtmlRenderOptions` field this benchmark
/// varies. Safe mode is applied by the implementation, never configured here.
pub const RenderLimits = struct {
    max_output_bytes: usize,
};

pub const default_render_limits: RenderLimits = .{
    .max_output_bytes = 64 * 1024 * 1024,
};

/// The richer, format-specific oracle. `fixtures` below is the reduced common
/// view the controller and report decoder consume.
pub const Oracle = struct {
    /// Independently authored expected outcome: `accepted`, or a real
    /// `ParseError` name taken from the parser's published error set.
    outcome: []const u8,
    limits: Limits,
    render_limits: RenderLimits,
    /// Complete preorder semantic tree. Empty for a resource fixture, which
    /// produces no document.
    expected: []const Record,
    /// Exact `HtmlRenderMode.safe` HTML. Empty for a resource fixture.
    html: []const u8,
};

// ---------------------------------------------------------------------------
// Documented semantic checksum
// ---------------------------------------------------------------------------

/// Mix one length-prefixed string: the byte length as a u64, then one FNV step
/// per byte. Length prefixing keeps empty strings, embedded NUL bytes and
/// concatenated fields unambiguous.
fn mixString(checksum: *u64, bytes: []const u8) void {
    const length: u64 = bytes.len;
    contract.mix(checksum, length);
    for (bytes) |byte| contract.mix(checksum, byte);
}

/// Complete preorder semantic checksum of a document tree.
///
/// The value is FNV-1a64 over a total, deterministic encoding:
///
///  1. the number of records, as a u64;
///  2. for every record in preorder:
///     a. the `Kind` discriminant as a u64;
///     b. `depth`, `child_index` and `child_count`, each as a u64;
///     c. the kind-specific payload, in this fixed order:
///        - `.none`: nothing;
///        - `.raw`: one length-prefixed string;
///        - `.list`: ordered (0/1), start, delimiter, tight (0/1);
///        - `.heading`: level, then one length-prefixed string;
///        - `.code_block`: fenced (0/1), fence, fence_length, then two
///          length-prefixed strings (info, raw);
///        - `.destination`: two length-prefixed strings;
///        - `.autolink`: one length-prefixed string.
///
/// Preorder plus `depth` and `child_index` encode the tree relations and the
/// nesting depth; `child_count` distinguishes an absent child slot from an
/// empty one. String payloads cover the node's normalized semantic text and
/// the link/image destinations and titles; `list` and `code_block` carry the
/// list and code attributes.
pub fn checksumRecords(records: []const Record) u64 {
    var checksum: u64 = 0;
    const record_count: u64 = records.len;
    contract.mix(&checksum, record_count);
    for (records) |record| {
        contract.mix(&checksum, @backingInt(record.kind));
        contract.mix(&checksum, record.depth);
        contract.mix(&checksum, record.child_index);
        contract.mix(&checksum, record.child_count);
        switch (record.attrs) {
            .none => {},
            .raw => |text| mixString(&checksum, text),
            .autolink => |destination| mixString(&checksum, destination),
            .list => |list| {
                contract.mix(&checksum, @intFromBool(list.ordered));
                contract.mix(&checksum, list.start);
                contract.mix(&checksum, list.delimiter);
                contract.mix(&checksum, @intFromBool(list.tight));
            },
            .heading => |heading| {
                contract.mix(&checksum, heading.level);
                mixString(&checksum, heading.text);
            },
            .code_block => |code| {
                contract.mix(&checksum, @intFromBool(code.fenced));
                contract.mix(&checksum, code.fence);
                contract.mix(&checksum, code.fence_length);
                mixString(&checksum, code.info);
                mixString(&checksum, code.raw);
            },
            .destination => |link| {
                mixString(&checksum, link.destination);
                mixString(&checksum, link.title);
            },
        }
    }
    return checksum;
}

/// The `parse` stage's small consumption, derived from the same authored tree
/// so the stage has an independent oracle too. It mixes the root kind, the
/// kind of the first top-level block and the kind of the last top-level block.
pub fn smallChecksumExpected(records: []const Record) u64 {
    var checksum: u64 = 0;
    if (records.len == 0) return checksum;
    contract.mix(&checksum, @backingInt(records[0].kind));
    // With no top-level block there is no first or last block to mix: the real
    // consumption returns right after the root kind there, so this does too.
    if (records[0].child_count == 0 or records.len < 2) return checksum;
    contract.mix(&checksum, @backingInt(records[1].kind));
    // Preorder finishes a top-level block before starting the next one, so the
    // last depth-1 record is the last top-level block. Its own children follow
    // it and are deeper, which is what makes this the last block and not
    // `records[child_count]`, a position that lands mid-document.
    var index = records.len;
    while (index > 1) {
        index -= 1;
        if (records[index].depth != 1) continue;
        contract.mix(&checksum, @backingInt(records[index].kind));
        break;
    }
    return checksum;
}

/// Exact preorder comparison of an authored tree against a walked tree. A
/// `false` result always means the parser and this module disagree.
pub fn recordsEqual(expected: []const Record, actual: []const Record) bool {
    if (expected.len != actual.len) return false;
    for (expected, actual) |want, got| {
        if (want.kind != got.kind) return false;
        if (want.depth != got.depth) return false;
        if (want.child_index != got.child_index) return false;
        if (want.child_count != got.child_count) return false;
        switch (want.attrs) {
            .none => if (got.attrs != .none) return false,
            .raw => |want_text| switch (got.attrs) {
                .raw => |got_text| if (!std.mem.eql(u8, want_text, got_text)) return false,
                else => return false,
            },
            .autolink => |want_text| switch (got.attrs) {
                .autolink => |got_text| if (!std.mem.eql(u8, want_text, got_text)) return false,
                else => return false,
            },
            .list => |want_list| switch (got.attrs) {
                .list => |got_list| {
                    if (want_list.ordered != got_list.ordered) return false;
                    if (want_list.start != got_list.start) return false;
                    if (want_list.delimiter != got_list.delimiter) return false;
                    if (want_list.tight != got_list.tight) return false;
                },
                else => return false,
            },
            .heading => |want_heading| switch (got.attrs) {
                .heading => |got_heading| {
                    if (want_heading.level != got_heading.level) return false;
                    if (!std.mem.eql(u8, want_heading.text, got_heading.text)) return false;
                },
                else => return false,
            },
            .code_block => |want_code| switch (got.attrs) {
                .code_block => |got_code| {
                    if (want_code.fenced != got_code.fenced) return false;
                    if (want_code.fence != got_code.fence) return false;
                    if (want_code.fence_length != got_code.fence_length) return false;
                    if (!std.mem.eql(u8, want_code.info, got_code.info)) return false;
                    if (!std.mem.eql(u8, want_code.raw, got_code.raw)) return false;
                },
                else => return false,
            },
            .destination => |want_link| switch (got.attrs) {
                .destination => |got_link| {
                    if (!std.mem.eql(u8, want_link.destination, got_link.destination)) return false;
                    if (!std.mem.eql(u8, want_link.title, got_link.title)) return false;
                },
                else => return false,
            },
        }
    }
    return true;
}

// ---------------------------------------------------------------------------
// cm_blocks: block structure
// ---------------------------------------------------------------------------

const cm_blocks_source: []const u8 =
    \\# Report
    \\
    \\Summary line
    \\continues here
    \\
    \\---
    \\
    \\> quoted text
    \\
    \\- alpha
    \\- beta
    \\
    \\3. gamma
    \\4. delta
    \\
    \\```json
    \\{"k": 1}
    \\```
    \\
    \\    indented code
++ "\n";

const cm_blocks_expected: []const Record = &.{
    .{ .kind = .document, .depth = 0, .child_index = 0, .child_count = 8, .attrs = .none },
    .{
        .kind = .heading,
        .depth = 1,
        .child_index = 0,
        .child_count = 1,
        .attrs = .{ .heading = .{ .level = 1, .text = "Report" } },
    },
    .{ .kind = .text, .depth = 2, .child_index = 0, .child_count = 0, .attrs = .{ .raw = "Report" } },
    .{
        .kind = .paragraph,
        .depth = 1,
        .child_index = 1,
        .child_count = 3,
        .attrs = .{ .raw = "Summary line\ncontinues here" },
    },
    .{ .kind = .text, .depth = 2, .child_index = 0, .child_count = 0, .attrs = .{ .raw = "Summary line" } },
    .{ .kind = .softbreak, .depth = 2, .child_index = 1, .child_count = 0, .attrs = .none },
    .{ .kind = .text, .depth = 2, .child_index = 2, .child_count = 0, .attrs = .{ .raw = "continues here" } },
    .{ .kind = .thematic_break, .depth = 1, .child_index = 2, .child_count = 0, .attrs = .none },
    .{ .kind = .block_quote, .depth = 1, .child_index = 3, .child_count = 1, .attrs = .none },
    .{ .kind = .paragraph, .depth = 2, .child_index = 0, .child_count = 1, .attrs = .{ .raw = "quoted text" } },
    .{ .kind = .text, .depth = 3, .child_index = 0, .child_count = 0, .attrs = .{ .raw = "quoted text" } },
    .{
        .kind = .list,
        .depth = 1,
        .child_index = 4,
        .child_count = 2,
        .attrs = .{ .list = .{ .ordered = false, .start = 1, .delimiter = '-', .tight = true } },
    },
    .{ .kind = .list_item, .depth = 2, .child_index = 0, .child_count = 1, .attrs = .none },
    .{ .kind = .paragraph, .depth = 3, .child_index = 0, .child_count = 1, .attrs = .{ .raw = "alpha" } },
    .{ .kind = .text, .depth = 4, .child_index = 0, .child_count = 0, .attrs = .{ .raw = "alpha" } },
    .{ .kind = .list_item, .depth = 2, .child_index = 1, .child_count = 1, .attrs = .none },
    .{ .kind = .paragraph, .depth = 3, .child_index = 0, .child_count = 1, .attrs = .{ .raw = "beta" } },
    .{ .kind = .text, .depth = 4, .child_index = 0, .child_count = 0, .attrs = .{ .raw = "beta" } },
    .{
        .kind = .list,
        .depth = 1,
        .child_index = 5,
        .child_count = 2,
        .attrs = .{ .list = .{ .ordered = true, .start = 3, .delimiter = '.', .tight = true } },
    },
    .{ .kind = .list_item, .depth = 2, .child_index = 0, .child_count = 1, .attrs = .none },
    .{ .kind = .paragraph, .depth = 3, .child_index = 0, .child_count = 1, .attrs = .{ .raw = "gamma" } },
    .{ .kind = .text, .depth = 4, .child_index = 0, .child_count = 0, .attrs = .{ .raw = "gamma" } },
    .{ .kind = .list_item, .depth = 2, .child_index = 1, .child_count = 1, .attrs = .none },
    .{ .kind = .paragraph, .depth = 3, .child_index = 0, .child_count = 1, .attrs = .{ .raw = "delta" } },
    .{ .kind = .text, .depth = 4, .child_index = 0, .child_count = 0, .attrs = .{ .raw = "delta" } },
    .{
        .kind = .code_block,
        .depth = 1,
        .child_index = 6,
        .child_count = 0,
        .attrs = .{ .code_block = .{
            .fenced = true,
            .fence = '`',
            .fence_length = 3,
            .info = "json",
            .raw = "{\"k\": 1}\n",
        } },
    },
    .{
        .kind = .code_block,
        .depth = 1,
        .child_index = 7,
        .child_count = 0,
        .attrs = .{ .code_block = .{
            .fenced = false,
            .fence = 0,
            .fence_length = 0,
            .info = "",
            .raw = "indented code\n",
        } },
    },
};

const cm_blocks_html: []const u8 =
    \\<h1>Report</h1>
    \\<p>Summary line
    \\continues here</p>
    \\<hr />
    \\<blockquote>
    \\<p>quoted text</p>
    \\</blockquote>
    \\<ul>
    \\<li>alpha</li>
    \\<li>beta</li>
    \\</ul>
    \\<ol start="3">
    \\<li>gamma</li>
    \\<li>delta</li>
    \\</ol>
    \\<pre><code class="language-json">{&quot;k&quot;: 1}
    \\</code></pre>
    \\<pre><code>indented code
    \\</code></pre>
++ "\n";

// ---------------------------------------------------------------------------
// cm_inline: emphasis, code spans and line breaks
// ---------------------------------------------------------------------------

const cm_inline_source: []const u8 =
    \\*emph* and **strong** and ***both***
    \\
    \\`code span` plus ``tick ` inside``
    \\
    \\hard\
    \\break here
    \\
    \\\*escaped\* and \[not a link](/foo)
++ "\n";

const cm_inline_expected: []const Record = &.{
    .{ .kind = .document, .depth = 0, .child_index = 0, .child_count = 4, .attrs = .none },
    .{
        .kind = .paragraph,
        .depth = 1,
        .child_index = 0,
        .child_count = 5,
        .attrs = .{ .raw = "*emph* and **strong** and ***both***" },
    },
    .{ .kind = .emph, .depth = 2, .child_index = 0, .child_count = 1, .attrs = .none },
    .{ .kind = .text, .depth = 3, .child_index = 0, .child_count = 0, .attrs = .{ .raw = "emph" } },
    .{ .kind = .text, .depth = 2, .child_index = 1, .child_count = 0, .attrs = .{ .raw = " and " } },
    .{ .kind = .strong, .depth = 2, .child_index = 2, .child_count = 1, .attrs = .none },
    .{ .kind = .text, .depth = 3, .child_index = 0, .child_count = 0, .attrs = .{ .raw = "strong" } },
    .{ .kind = .text, .depth = 2, .child_index = 3, .child_count = 0, .attrs = .{ .raw = " and " } },
    .{ .kind = .emph, .depth = 2, .child_index = 4, .child_count = 1, .attrs = .none },
    .{ .kind = .strong, .depth = 3, .child_index = 0, .child_count = 1, .attrs = .none },
    .{ .kind = .text, .depth = 4, .child_index = 0, .child_count = 0, .attrs = .{ .raw = "both" } },
    .{
        .kind = .paragraph,
        .depth = 1,
        .child_index = 1,
        .child_count = 3,
        .attrs = .{ .raw = "`code span` plus ``tick ` inside``" },
    },
    .{ .kind = .code_span, .depth = 2, .child_index = 0, .child_count = 0, .attrs = .{ .raw = "code span" } },
    .{ .kind = .text, .depth = 2, .child_index = 1, .child_count = 0, .attrs = .{ .raw = " plus " } },
    .{ .kind = .code_span, .depth = 2, .child_index = 2, .child_count = 0, .attrs = .{ .raw = "tick ` inside" } },
    .{ .kind = .paragraph, .depth = 1, .child_index = 2, .child_count = 3, .attrs = .{ .raw = "hard\\\nbreak here" } },
    .{ .kind = .text, .depth = 2, .child_index = 0, .child_count = 0, .attrs = .{ .raw = "hard" } },
    .{ .kind = .linebreak, .depth = 2, .child_index = 1, .child_count = 0, .attrs = .none },
    .{ .kind = .text, .depth = 2, .child_index = 2, .child_count = 0, .attrs = .{ .raw = "break here" } },
    .{
        .kind = .paragraph,
        .depth = 1,
        .child_index = 3,
        .child_count = 6,
        .attrs = .{ .raw = "\\*escaped\\* and \\[not a link](/foo)" },
    },
    .{ .kind = .text, .depth = 2, .child_index = 0, .child_count = 0, .attrs = .{ .raw = "*" } },
    .{ .kind = .text, .depth = 2, .child_index = 1, .child_count = 0, .attrs = .{ .raw = "escaped" } },
    .{ .kind = .text, .depth = 2, .child_index = 2, .child_count = 0, .attrs = .{ .raw = "*" } },
    .{ .kind = .text, .depth = 2, .child_index = 3, .child_count = 0, .attrs = .{ .raw = " and " } },
    .{ .kind = .text, .depth = 2, .child_index = 4, .child_count = 0, .attrs = .{ .raw = "[" } },
    .{ .kind = .text, .depth = 2, .child_index = 5, .child_count = 0, .attrs = .{ .raw = "not a link](/foo)" } },
};

const cm_inline_html: []const u8 =
    \\<p><em>emph</em> and <strong>strong</strong> and <em><strong>both</strong></em></p>
    \\<p><code>code span</code> plus <code>tick ` inside</code></p>
    \\<p>hard<br />
    \\break here</p>
    \\<p>*escaped* and [not a link](/foo)</p>
++ "\n";

// ---------------------------------------------------------------------------
// cm_links: inline links, images, reference links and autolinks
// ---------------------------------------------------------------------------

const cm_links_source: []const u8 =
    \\[inline](/url "title") and ![img](/pic "cap")
    \\
    \\[ref][label] and ![alt][label]
    \\
    \\<https://example.com/a?b=c> and <mail@example.org>
    \\
    \\[label]: /target "Ref Title"
++ "\n";

const cm_links_expected: []const Record = &.{
    .{ .kind = .document, .depth = 0, .child_index = 0, .child_count = 4, .attrs = .none },
    .{
        .kind = .paragraph,
        .depth = 1,
        .child_index = 0,
        .child_count = 3,
        .attrs = .{ .raw = "[inline](/url \"title\") and ![img](/pic \"cap\")" },
    },
    .{
        .kind = .link,
        .depth = 2,
        .child_index = 0,
        .child_count = 1,
        .attrs = .{ .destination = .{ .destination = "/url", .title = "title" } },
    },
    .{ .kind = .text, .depth = 3, .child_index = 0, .child_count = 0, .attrs = .{ .raw = "inline" } },
    .{ .kind = .text, .depth = 2, .child_index = 1, .child_count = 0, .attrs = .{ .raw = " and " } },
    .{
        .kind = .image,
        .depth = 2,
        .child_index = 2,
        .child_count = 1,
        .attrs = .{ .destination = .{ .destination = "/pic", .title = "cap" } },
    },
    .{ .kind = .text, .depth = 3, .child_index = 0, .child_count = 0, .attrs = .{ .raw = "img" } },
    .{
        .kind = .paragraph,
        .depth = 1,
        .child_index = 1,
        .child_count = 3,
        .attrs = .{ .raw = "[ref][label] and ![alt][label]" },
    },
    .{
        .kind = .link,
        .depth = 2,
        .child_index = 0,
        .child_count = 1,
        .attrs = .{ .destination = .{ .destination = "/target", .title = "Ref Title" } },
    },
    .{ .kind = .text, .depth = 3, .child_index = 0, .child_count = 0, .attrs = .{ .raw = "ref" } },
    .{ .kind = .text, .depth = 2, .child_index = 1, .child_count = 0, .attrs = .{ .raw = " and " } },
    .{
        .kind = .image,
        .depth = 2,
        .child_index = 2,
        .child_count = 1,
        .attrs = .{ .destination = .{ .destination = "/target", .title = "Ref Title" } },
    },
    .{ .kind = .text, .depth = 3, .child_index = 0, .child_count = 0, .attrs = .{ .raw = "alt" } },
    .{
        .kind = .paragraph,
        .depth = 1,
        .child_index = 2,
        .child_count = 3,
        .attrs = .{ .raw = "<https://example.com/a?b=c> and <mail@example.org>" },
    },
    .{
        .kind = .autolink,
        .depth = 2,
        .child_index = 0,
        .child_count = 0,
        .attrs = .{ .autolink = "https://example.com/a?b=c" },
    },
    .{ .kind = .text, .depth = 2, .child_index = 1, .child_count = 0, .attrs = .{ .raw = " and " } },
    .{
        .kind = .autolink,
        .depth = 2,
        .child_index = 2,
        .child_count = 0,
        .attrs = .{ .autolink = "mail@example.org" },
    },
    .{ .kind = .reference_definition, .depth = 1, .child_index = 3, .child_count = 0, .attrs = .none },
};

const cm_links_html: []const u8 =
    "<p><a href=\"/url\" title=\"title\">inline</a> and <img src=\"/pic\" alt=\"img\" title=\"cap\" /></p>\n" ++
    "<p><a href=\"/target\" title=\"Ref Title\">ref</a> and " ++
    "<img src=\"/target\" alt=\"alt\" title=\"Ref Title\" /></p>\n" ++
    "<p><a href=\"https://example.com/a?b=c\">https://example.com/a?b=c</a>" ++
    " and <a href=\"mailto:mail@example.org\">mail@example.org</a></p>\n";

// ---------------------------------------------------------------------------
// cm_unicode: Unicode text, named entities and numeric references
// ---------------------------------------------------------------------------

const cm_unicode_source: []const u8 =
    "Foo \u{03C7}\u{03C1}\u{1F74}\u{03BD} \u{2014} na\u{00EF}ve \u{00FC}n\u{00EF}c\u{00F6}d\u{00E9} " ++
    "\u{2713} \u{4E2D}\u{6587}\n" ++
    "&nbsp; &amp; &copy; &AElig; &Dcaron;\n" ++
    "&#X22; &#XD06; &#xcab;\n";

const cm_unicode_line1: []const u8 =
    "Foo \u{03C7}\u{03C1}\u{1F74}\u{03BD} \u{2014} na\u{00EF}ve \u{00FC}n\u{00EF}c\u{00F6}d\u{00E9} " ++
    "\u{2713} \u{4E2D}\u{6587}";

/// The three source lines are one lazy paragraph, not three: only soft breaks
/// separate them. Its raw text keeps the entity and reference source spellings
/// exactly as written, without the document's trailing line ending.
const cm_unicode_paragraph_raw: []const u8 =
    "Foo \u{03C7}\u{03C1}\u{1F74}\u{03BD} \u{2014} na\u{00EF}ve \u{00FC}n\u{00EF}c\u{00F6}d\u{00E9} " ++
    "\u{2713} \u{4E2D}\u{6587}\n" ++
    "&nbsp; &amp; &copy; &AElig; &Dcaron;\n" ++
    "&#X22; &#XD06; &#xcab;";

const cm_unicode_expected: []const Record = &.{
    .{ .kind = .document, .depth = 0, .child_index = 0, .child_count = 1, .attrs = .none },
    .{
        .kind = .paragraph,
        .depth = 1,
        .child_index = 0,
        .child_count = 17,
        .attrs = .{ .raw = cm_unicode_paragraph_raw },
    },
    .{ .kind = .text, .depth = 2, .child_index = 0, .child_count = 0, .attrs = .{ .raw = cm_unicode_line1 } },
    .{ .kind = .softbreak, .depth = 2, .child_index = 1, .child_count = 0, .attrs = .none },
    .{ .kind = .text, .depth = 2, .child_index = 2, .child_count = 0, .attrs = .{ .raw = "\u{00A0}" } },
    .{ .kind = .text, .depth = 2, .child_index = 3, .child_count = 0, .attrs = .{ .raw = " " } },
    .{ .kind = .text, .depth = 2, .child_index = 4, .child_count = 0, .attrs = .{ .raw = "&" } },
    .{ .kind = .text, .depth = 2, .child_index = 5, .child_count = 0, .attrs = .{ .raw = " " } },
    .{ .kind = .text, .depth = 2, .child_index = 6, .child_count = 0, .attrs = .{ .raw = "\u{00A9}" } },
    .{ .kind = .text, .depth = 2, .child_index = 7, .child_count = 0, .attrs = .{ .raw = " " } },
    .{ .kind = .text, .depth = 2, .child_index = 8, .child_count = 0, .attrs = .{ .raw = "\u{00C6}" } },
    .{ .kind = .text, .depth = 2, .child_index = 9, .child_count = 0, .attrs = .{ .raw = " " } },
    .{ .kind = .text, .depth = 2, .child_index = 10, .child_count = 0, .attrs = .{ .raw = "\u{010E}" } },
    .{ .kind = .softbreak, .depth = 2, .child_index = 11, .child_count = 0, .attrs = .none },
    .{ .kind = .text, .depth = 2, .child_index = 12, .child_count = 0, .attrs = .{ .raw = "\"" } },
    .{ .kind = .text, .depth = 2, .child_index = 13, .child_count = 0, .attrs = .{ .raw = " " } },
    .{ .kind = .text, .depth = 2, .child_index = 14, .child_count = 0, .attrs = .{ .raw = "\u{0D06}" } },
    .{ .kind = .text, .depth = 2, .child_index = 15, .child_count = 0, .attrs = .{ .raw = " " } },
    .{ .kind = .text, .depth = 2, .child_index = 16, .child_count = 0, .attrs = .{ .raw = "\u{0CAB}" } },
};

const cm_unicode_html: []const u8 =
    "<p>Foo \u{03C7}\u{03C1}\u{1F74}\u{03BD} \u{2014} na\u{00EF}ve \u{00FC}n\u{00EF}c\u{00F6}d\u{00E9} " ++
    "\u{2713} \u{4E2D}\u{6587}\n" ++
    "\u{00A0} &amp; \u{00A9} \u{00C6} \u{010E}\n" ++
    "&quot; \u{0D06} \u{0CAB}</p>\n";

// ---------------------------------------------------------------------------
// cm_raw_html: safe-mode suppression of raw HTML and dangerous URL schemes
// ---------------------------------------------------------------------------

const cm_raw_html_source: []const u8 =
    \\<div class="raw">
    \\block html
    \\</div>
    \\
    \\inline <b>bold</b> text
    \\
    \\[xss](javascript:alert(1)) and [ok](https://example.com/a)
    \\
    \\![data](data:text/html;base64,AAA)
++ "\n";

const cm_raw_html_expected: []const Record = &.{
    .{ .kind = .document, .depth = 0, .child_index = 0, .child_count = 4, .attrs = .none },
    .{
        .kind = .html_block,
        .depth = 1,
        .child_index = 0,
        .child_count = 0,
        .attrs = .{ .raw = "<div class=\"raw\">\nblock html\n</div>" },
    },
    .{
        .kind = .paragraph,
        .depth = 1,
        .child_index = 1,
        .child_count = 5,
        .attrs = .{ .raw = "inline <b>bold</b> text" },
    },
    .{ .kind = .text, .depth = 2, .child_index = 0, .child_count = 0, .attrs = .{ .raw = "inline " } },
    .{ .kind = .html_inline, .depth = 2, .child_index = 1, .child_count = 0, .attrs = .{ .raw = "<b>" } },
    .{ .kind = .text, .depth = 2, .child_index = 2, .child_count = 0, .attrs = .{ .raw = "bold" } },
    .{ .kind = .html_inline, .depth = 2, .child_index = 3, .child_count = 0, .attrs = .{ .raw = "</b>" } },
    .{ .kind = .text, .depth = 2, .child_index = 4, .child_count = 0, .attrs = .{ .raw = " text" } },
    .{
        .kind = .paragraph,
        .depth = 1,
        .child_index = 2,
        .child_count = 3,
        .attrs = .{ .raw = "[xss](javascript:alert(1)) and [ok](https://example.com/a)" },
    },
    .{
        .kind = .link,
        .depth = 2,
        .child_index = 0,
        .child_count = 1,
        .attrs = .{ .destination = .{ .destination = "javascript:alert(1)", .title = "" } },
    },
    .{ .kind = .text, .depth = 3, .child_index = 0, .child_count = 0, .attrs = .{ .raw = "xss" } },
    .{ .kind = .text, .depth = 2, .child_index = 1, .child_count = 0, .attrs = .{ .raw = " and " } },
    .{
        .kind = .link,
        .depth = 2,
        .child_index = 2,
        .child_count = 1,
        .attrs = .{ .destination = .{ .destination = "https://example.com/a", .title = "" } },
    },
    .{ .kind = .text, .depth = 3, .child_index = 0, .child_count = 0, .attrs = .{ .raw = "ok" } },
    .{
        .kind = .paragraph,
        .depth = 1,
        .child_index = 3,
        .child_count = 1,
        .attrs = .{ .raw = "![data](data:text/html;base64,AAA)" },
    },
    .{
        .kind = .image,
        .depth = 2,
        .child_index = 0,
        .child_count = 1,
        .attrs = .{ .destination = .{ .destination = "data:text/html;base64,AAA", .title = "" } },
    },
    .{ .kind = .text, .depth = 3, .child_index = 0, .child_count = 0, .attrs = .{ .raw = "data" } },
};

const cm_raw_html_html: []const u8 =
    \\<!-- raw HTML omitted -->
    \\<p>inline <!-- raw HTML omitted -->bold<!-- raw HTML omitted --> text</p>
    \\<p><a href="">xss</a> and <a href="https://example.com/a">ok</a></p>
    \\<p><img src="" alt="data" /></p>
++ "\n";

// ---------------------------------------------------------------------------
// Resource families: one configured limit each
// ---------------------------------------------------------------------------

// Input byte bound. 44 source bytes against a 24-byte `max_input_bytes`:
// `ParseError.InputTooLarge`.
const cm_input_limit_source: []const u8 =
    \\# Title
    \\
    \\Body paragraph with several words.
++ "\n";

// Node bound. Nine lines parse into a document plus five paragraphs and five
// text nodes; `max_nodes = 4` stops at the fourth block node, so the real node
// bound fires: `ParseError.TooManyNodes`.
const cm_node_limit_source: []const u8 =
    \\one
    \\
    \\two
    \\
    \\three
    \\
    \\four
    \\
    \\five
++ "\n";

// Delimiter bound. One paragraph with fourteen emphasis delimiter runs;
// `max_delimiters = 4` stops at the fifth run:
// `ParseError.TooManyDelimiters`.
const cm_delimiter_limit_source: []const u8 =
    \\*a* *b* *c* *d* *e* *f* *g*
++ "\n";

// Work bound. Two scanned lines charge 2 units, and normalizing the first
// paragraph text charges 13 more, so `max_work = 6` fires:
// `ParseError.WorkLimit`.
const cm_work_limit_source: []const u8 =
    \\one two three
    \\four five six
++ "\n";

// ---------------------------------------------------------------------------
// Fixture views
// ---------------------------------------------------------------------------

const accepted_stages = [_]contract.Stage{ .parse, .traverse, .render_html };
const resource_stages = [_]contract.Stage{.resource_error};

/// The reduced common view the controller enumerates and the report decoder
/// decodes: one entry per fixture, in `contract.Workload` declaration order.
pub const fixtures: []const contract.Fixture = &[_]contract.Fixture{
    .{
        .workload = .cm_blocks,
        .source = cm_blocks_source,
        .stages = &accepted_stages,
        .outcome = accepted_outcome,
    },
    .{
        .workload = .cm_inline,
        .source = cm_inline_source,
        .stages = &accepted_stages,
        .outcome = accepted_outcome,
    },
    .{
        .workload = .cm_links,
        .source = cm_links_source,
        .stages = &accepted_stages,
        .outcome = accepted_outcome,
    },
    .{
        .workload = .cm_unicode,
        .source = cm_unicode_source,
        .stages = &accepted_stages,
        .outcome = accepted_outcome,
    },
    .{
        .workload = .cm_raw_html,
        .source = cm_raw_html_source,
        .stages = &accepted_stages,
        .outcome = accepted_outcome,
    },
    .{
        .workload = .cm_input_limit,
        .source = cm_input_limit_source,
        .stages = &resource_stages,
        .outcome = "InputTooLarge",
    },
    .{
        .workload = .cm_node_limit,
        .source = cm_node_limit_source,
        .stages = &resource_stages,
        .outcome = "TooManyNodes",
    },
    .{
        .workload = .cm_delimiter_limit,
        .source = cm_delimiter_limit_source,
        .stages = &resource_stages,
        .outcome = "TooManyDelimiters",
    },
    .{
        .workload = .cm_work_limit,
        .source = cm_work_limit_source,
        .stages = &resource_stages,
        .outcome = "WorkLimit",
    },
};

/// Each resource fixture states its full limit configuration so the bound
/// under test is auditable: exactly one field differs from `default_limits`.
const cm_input_limit_limits: Limits = .{
    .max_input_bytes = 24,
    .max_nodes = default_limits.max_nodes,
    .max_text_bytes = default_limits.max_text_bytes,
    .max_reference_count = default_limits.max_reference_count,
    .max_delimiters = default_limits.max_delimiters,
    .max_brackets = default_limits.max_brackets,
    .max_depth = default_limits.max_depth,
    .max_work = default_limits.max_work,
};

const cm_node_limit_limits: Limits = .{
    .max_input_bytes = default_limits.max_input_bytes,
    .max_nodes = 4,
    .max_text_bytes = default_limits.max_text_bytes,
    .max_reference_count = default_limits.max_reference_count,
    .max_delimiters = default_limits.max_delimiters,
    .max_brackets = default_limits.max_brackets,
    .max_depth = default_limits.max_depth,
    .max_work = default_limits.max_work,
};

const cm_delimiter_limit_limits: Limits = .{
    .max_input_bytes = default_limits.max_input_bytes,
    .max_nodes = default_limits.max_nodes,
    .max_text_bytes = default_limits.max_text_bytes,
    .max_reference_count = default_limits.max_reference_count,
    .max_delimiters = 4,
    .max_brackets = default_limits.max_brackets,
    .max_depth = default_limits.max_depth,
    .max_work = default_limits.max_work,
};

const cm_work_limit_limits: Limits = .{
    .max_input_bytes = default_limits.max_input_bytes,
    .max_nodes = default_limits.max_nodes,
    .max_text_bytes = default_limits.max_text_bytes,
    .max_reference_count = default_limits.max_reference_count,
    .max_delimiters = default_limits.max_delimiters,
    .max_brackets = default_limits.max_brackets,
    .max_depth = default_limits.max_depth,
    .max_work = 6,
};

/// The richer parallel oracle table, indexed exactly like `fixtures`.
pub const oracles: []const Oracle = &[_]Oracle{
    .{
        .outcome = accepted_outcome,
        .limits = default_limits,
        .render_limits = default_render_limits,
        .expected = cm_blocks_expected,
        .html = cm_blocks_html,
    },
    .{
        .outcome = accepted_outcome,
        .limits = default_limits,
        .render_limits = default_render_limits,
        .expected = cm_inline_expected,
        .html = cm_inline_html,
    },
    .{
        .outcome = accepted_outcome,
        .limits = default_limits,
        .render_limits = default_render_limits,
        .expected = cm_links_expected,
        .html = cm_links_html,
    },
    .{
        .outcome = accepted_outcome,
        .limits = default_limits,
        .render_limits = default_render_limits,
        .expected = cm_unicode_expected,
        .html = cm_unicode_html,
    },
    .{
        .outcome = accepted_outcome,
        .limits = default_limits,
        .render_limits = default_render_limits,
        .expected = cm_raw_html_expected,
        .html = cm_raw_html_html,
    },
    .{
        .outcome = "InputTooLarge",
        .limits = cm_input_limit_limits,
        .render_limits = default_render_limits,
        .expected = &.{},
        .html = "",
    },
    .{
        .outcome = "TooManyNodes",
        .limits = cm_node_limit_limits,
        .render_limits = default_render_limits,
        .expected = &.{},
        .html = "",
    },
    .{
        .outcome = "TooManyDelimiters",
        .limits = cm_delimiter_limit_limits,
        .render_limits = default_render_limits,
        .expected = &.{},
        .html = "",
    },
    .{
        .outcome = "WorkLimit",
        .limits = cm_work_limit_limits,
        .render_limits = default_render_limits,
        .expected = &.{},
        .html = "",
    },
};

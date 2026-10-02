//! Data-only `yaml-extended-e2b-1.2.2` benchmark fixtures and their
//! independently authored oracles.
//!
//! This module imports `std` and the shared semantic contract only. It must
//! never import `@import("simd_lib")`: the archive/report decoder has to be
//! able to read the declared work domain without a CPU-dependent library
//! module and without invoking a parser.
//!
//! Every expectation below is written from the profile rules recorded in
//! `AGENTS.md` and implemented by `src/formats/yaml_extended.zig`: literal and
//! folded block scalars with clip/strip/keep chomping, multiline quoted
//! scalars, compact sequence mappings, the constructs this profile defers
//! (aliases, tags, multiple documents), and the configured resource bounds.
//! Expectations are logical structure plus exact cooked bytes, never raw marker
//! spans, so a mismatch names real semantic drift instead of formatting.
//! `yaml_extended_bench.zig` fails loudly when the parser disagrees with these
//! tables instead of adopting the observed behavior.

const std = @import("std");
const contract = @import("semantic_contract");

/// The `parse` stage consumes the built container skeleton only: every event
/// kind and its logical depth, with no scalar bytes and no cooked values. It is
/// reported as `small` rather than implying whole-document semantic coverage;
/// `traverse` is the complete semantic consumption.
pub const parse_stage_coverage: []const u8 = "small";

// ---------------------------------------------------------------------------
// Semantic record vocabulary
// ---------------------------------------------------------------------------

/// The tape event kinds this benchmark traverses, declared in the order the
/// profile's own `YamlTokenKind` declares them. The discriminant order is
/// stable and is mixed into the semantic checksum as a u64.
///
/// The two document delimiters are part of the vocabulary even though no
/// fixture here emits one: both tape builders emit `document_start` only for an
/// explicit `---` marker line and `document_end` only for an explicit `...`
/// marker line, and no accepted source in this profile carries either. Keeping
/// the members means a delimiter that did reach the tape is hashed and
/// compared like every other event instead of being skipped by a narrower
/// traversal.
pub const EventKind = enum(u8) {
    document_start,
    document_end,
    mapping_start,
    mapping_end,
    sequence_start,
    sequence_end,
    key,
    scalar,
};

/// Which storage a traversed value lives in. The document owns its tape, its
/// scalar metadata, and its cooked bytes; the source stays borrowed, so a
/// plain key or value is `source_borrowed` and a quoted or block scalar is
/// `document_owned`. The field is recorded per event so a benchmark row can
/// never imply that cooked bytes came from the source.
pub const Ownership = enum(u8) {
    source_borrowed,
    document_owned,
};

pub const Style = enum(u8) {
    plain,
    single_quoted,
    double_quoted,
    literal,
    folded,
};

pub const Chomping = enum(u8) {
    clip,
    strip,
    keep,
};

/// The diagnostic classification the profile reports for a rejected document.
/// `syntax` and `unsupported` describe a malformed or deferred construct;
/// `resource` describes a configured bound that fired.
pub const DiagnosticKind = enum(u8) {
    syntax,
    unsupported,
    resource,
    invalid_index,
};

/// One logical event of the parsed document.
///
/// `ownership`, `style`, `chomping`, `indentation_width`, and `bytes` describe
/// `key` and `scalar` events only; the fields carry their defaults on the six
/// structural events, which have no value.
pub const Event = struct {
    kind: EventKind,
    ownership: Ownership = .source_borrowed,
    style: Style = .plain,
    chomping: Chomping = .clip,
    /// The block indentation a cooked block scalar was folded at. Zero for
    /// plain and quoted scalars, which have no block indentation.
    indentation_width: u32 = 0,
    /// The complete cooked bytes of the value, or the borrowed source bytes of
    /// a plain key/value. Length matters: `""` is an empty value, which is not
    /// the same observation as an absent one.
    bytes: []const u8 = "",
};

// ---------------------------------------------------------------------------
// Limits
// ---------------------------------------------------------------------------

/// Plain-data mirror of `yaml_extended.Limits`. Every field is stated so the
/// bound under test is auditable: a resource fixture differs from
/// `default_limits` in exactly one field.
pub const Limits = struct {
    source_bytes_max: usize,
    cooked_bytes_max: usize,
    scalar_source_bytes_max: usize,
    line_count_max: usize,
    scalar_line_count_max: usize,
    indentation_max: usize,
    depth_max: usize,
    tape_words_max: usize,
};

/// The profile's own defaults, restated rather than inherited so the decoder
/// and the parser cannot drift apart silently. `depth_max` is the profile
/// ceiling `yaml.yaml_max_depth`; the parser accepts lower values only.
pub const default_limits: Limits = .{
    .source_bytes_max = std.math.maxInt(u32),
    .cooked_bytes_max = 16 * 1024 * 1024,
    .scalar_source_bytes_max = std.math.maxInt(u24),
    .line_count_max = 1024 * 1024,
    .scalar_line_count_max = 1024 * 1024,
    .indentation_max = 1024,
    .depth_max = 1024,
    .tape_words_max = 1024 * 1024,
};

/// One bound under test: exactly one field drops below its default so the
/// genuine bound fires on an otherwise valid document.
const yaml_cooked_limit_limits: Limits = .{
    .source_bytes_max = default_limits.source_bytes_max,
    .cooked_bytes_max = 8,
    .scalar_source_bytes_max = default_limits.scalar_source_bytes_max,
    .line_count_max = default_limits.line_count_max,
    .scalar_line_count_max = default_limits.scalar_line_count_max,
    .indentation_max = default_limits.indentation_max,
    .depth_max = default_limits.depth_max,
    .tape_words_max = default_limits.tape_words_max,
};

/// A quoted scalar's opening line already counts as its first scalar line, so
/// a two-line quoted value needs a budget of at least two.
const yaml_scalar_line_limit_limits: Limits = .{
    .source_bytes_max = default_limits.source_bytes_max,
    .cooked_bytes_max = default_limits.cooked_bytes_max,
    .scalar_source_bytes_max = default_limits.scalar_source_bytes_max,
    .line_count_max = default_limits.line_count_max,
    .scalar_line_count_max = 1,
    .indentation_max = default_limits.indentation_max,
    .depth_max = default_limits.depth_max,
    .tape_words_max = default_limits.tape_words_max,
};

const yaml_depth_limit_limits: Limits = .{
    .source_bytes_max = default_limits.source_bytes_max,
    .cooked_bytes_max = default_limits.cooked_bytes_max,
    .scalar_source_bytes_max = default_limits.scalar_source_bytes_max,
    .line_count_max = default_limits.line_count_max,
    .scalar_line_count_max = default_limits.scalar_line_count_max,
    .indentation_max = default_limits.indentation_max,
    .depth_max = 2,
    .tape_words_max = default_limits.tape_words_max,
};

// ---------------------------------------------------------------------------
// Documented semantic checksum
// ---------------------------------------------------------------------------

/// The parse-stage consumption: the complete container skeleton. It is FNV-1a64
/// over the number of events, then, per event in tape order, the `EventKind`
/// discriminant followed by the depth the running counter holds as the event is
/// folded in, before that event adjusts it. A container start is therefore
/// folded at the depth outside the container it opens and a container end at
/// the depth inside it, the same depth its own members were folded at and one
/// level deeper than the start that opened it, because the counter is lowered
/// only after that end is folded. A document delimiter, a key and a scalar
/// leave the counter alone and are folded at the depth as it stands.
///
/// Every event in the stream is walked, so the encoding covers the whole tape
/// and not only its containers: a document delimiter contributes its own
/// discriminant at the depth outside the root, exactly as the real traversal
/// reports it.
///
/// No cooked bytes and no raw marker offsets are mixed in: the parse stage is
/// deliberately the smaller consumption, and `traverse` is the complete one.
pub fn checksumSkeleton(events: []const Event) u64 {
    var checksum: u64 = contract.fnv_offset_basis;
    const event_count: u64 = events.len;
    contract.mix(&checksum, event_count);
    var depth: u64 = 0;
    for (events) |event| {
        contract.mix(&checksum, @intFromEnum(event.kind));
        contract.mix(&checksum, depth);
        switch (event.kind) {
            .mapping_start, .sequence_start => depth += 1,
            .mapping_end, .sequence_end => depth -= 1,
            // A document delimiter is not a container, so it leaves the depth
            // alone; a key and a scalar are values inside the current one.
            .document_start, .document_end, .key, .scalar => {},
        }
    }
    return checksum;
}

/// The traverse-stage consumption: the same skeleton encoding plus, for every
/// `key` and `scalar`, the `Ownership` discriminant, the `Style` and
/// `Chomping` discriminants, the block indentation width, and the complete
/// cooked bytes behind their length prefix.
///
/// Container structure, keys, values, and cooked scalar bytes are therefore all
/// covered: nothing in the row depends on marker characters or on raw spans. A
/// document delimiter has no value, so it contributes exactly what the skeleton
/// encoding already gave it and nothing more.
pub fn checksumSemantics(events: []const Event) u64 {
    var checksum: u64 = contract.fnv_offset_basis;
    var depth: u64 = 0;
    for (events) |event| {
        contract.mix(&checksum, @intFromEnum(event.kind));
        contract.mix(&checksum, depth);
        switch (event.kind) {
            .mapping_start, .sequence_start => depth += 1,
            .mapping_end, .sequence_end => depth -= 1,
            .document_start, .document_end => {},
            .key, .scalar => {
                contract.mix(&checksum, @intFromEnum(event.ownership));
                contract.mix(&checksum, @intFromEnum(event.style));
                contract.mix(&checksum, @intFromEnum(event.chomping));
                contract.mix(&checksum, event.indentation_width);
                contract.mixBytes(&checksum, event.bytes);
            },
        }
    }
    return checksum;
}

/// The richer parallel oracle table. `fixtures` below is the reduced common
/// view the controller and the report decoder consume.
pub const Oracle = struct {
    /// Independently authored expected outcome: `accepted`, or an exact error
    /// name taken from the profile's published error set.
    outcome: []const u8,
    limits: Limits,
    /// The complete logical event stream. Empty for a rejected or resource
    /// fixture, which produces no document.
    events: []const Event,
    /// The diagnostic classification the profile reports for this rejection.
    /// Ignored for an accepted fixture.
    diagnostic_kind: DiagnosticKind,
};

// ---------------------------------------------------------------------------
// Sources
// ---------------------------------------------------------------------------
//
// A multiline string literal ends at its last line: it never supplies a line
// break of its own. The four documents whose oracle depends on that final
// byte, or on a blank line inside a block scalar, therefore concatenate a
// newline onto the literal instead of leaving the byte implied.

// A literal block at clip chomping: the body is folded at the indentation of
// its first content line and the trailing line break is kept, so the cooked
// value ends in exactly one newline.
const yaml_literal_clip_source: []const u8 =
    \\body: |
    \\  first
    \\  second
++ "\n";

// The same body under strip chomping: every trailing line break is removed, so
// the cooked value is the same bytes without the final newline.
const yaml_literal_strip_source: []const u8 =
    \\body: |-
    \\  first
    \\  second
++ "\n";

// Keep chomping with a trailing blank line: the value keeps every trailing line
// break, which is what separates keep from clip. Clip would fold this down to
// one newline and strip to none. The blank line is a blank line to the profile
// only while it is itself terminated by a break, so the final newline is
// stated here instead of being left to the literal.
const yaml_literal_keep_source: []const u8 =
    \\body: |+
    \\  alpha
    \\  beta
    \\
++ "\n";

// A folded block: a single line break between two equally indented, non-blank
// lines folds to a space, so the cooked value is one line.
const yaml_folded_source: []const u8 =
    \\body: >
    \\  first line
    \\  second line
++ "\n";

// A multiline single-quoted scalar. The line break folds to a single space and
// the leading indentation of the continuation line is not part of the value.
const yaml_single_multiline_source: []const u8 =
    \\text: 'alpha
    \\  beta'
;

// A multiline double-quoted scalar. The physical line break folds to a space
// and the two-character `\n` escape then contributes a real newline byte, so
// the cooked value ends in a newline the source only spells as a backslash
// followed by an `n`.
const yaml_double_multiline_source: []const u8 =
    \\text: "alpha
    \\  beta\n"
;

// A compact sequence mapping: `- id: 1` opens a sequence whose first entry is
// a mapping, `name` continues that mapping on the next line, and `note` has no
// value at all. The empty value is a real scalar event with zero bytes.
const yaml_compact_mapping_source: []const u8 =
    \\- id: 1
    \\  name: alpha
    \\  note:
;

// An opening double quote that the document never closes: the continuation line
// is ordinary content and the scalar stays open to the end of the source.
const yaml_unterminated_quote_source: []const u8 =
    \\text: "first
    \\  second
;

// A literal block header with an explicit indentation indicator of two whose
// body line is indented by only one: the content is less indented than the
// header promised, which is malformed block content.
const yaml_malformed_block_source: []const u8 =
    \\body: |2
    \\ text
;

// An alias reference. Aliases stay outside this profile.
const yaml_alias_source: []const u8 = "value: *alias\n";

// An explicit tag. Tags stay outside this profile.
const yaml_tag_source: []const u8 = "value: !tag text\n";

// Two documents in one source. Multiple documents stay outside this profile.
const yaml_multiple_documents_source: []const u8 =
    \\---
    \\value: first
    \\---
    \\value: second
;

// A literal block whose cooked content is ten bytes, against a bound of eight.
const yaml_cooked_limit_source: []const u8 =
    \\body: |
    \\  abcdefghij
;

// A two-line quoted scalar against a one-line budget; the opening line already
// consumes that budget.
const yaml_scalar_line_limit_source: []const u8 =
    \\text: "first
    \\  second"
;

// Three nested mappings, each opened with a block scalar header, against a
// depth budget of two.
const yaml_depth_limit_source: []const u8 =
    \\a:
    \\  b:
    \\    c: |
    \\      x
;

// ---------------------------------------------------------------------------
// Accepted event streams
// ---------------------------------------------------------------------------

// body: |  ->  key "body" plus one literal scalar whose cooked bytes are
// "first\nsecond\n": the body folded at indent 2, one trailing break kept.
const yaml_literal_clip_events: []const Event = &.{
    .{ .kind = .mapping_start },
    .{ .kind = .key, .bytes = "body" },
    .{
        .kind = .scalar,
        .ownership = .document_owned,
        .style = .literal,
        .chomping = .clip,
        .indentation_width = 2,
        .bytes = "first\nsecond\n",
    },
    .{ .kind = .mapping_end },
};

// Strip chomping is the same document with the trailing break removed, so the
// cooked bytes differ from the clip case by exactly one newline.
const yaml_literal_strip_events: []const Event = &.{
    .{ .kind = .mapping_start },
    .{ .kind = .key, .bytes = "body" },
    .{
        .kind = .scalar,
        .ownership = .document_owned,
        .style = .literal,
        .chomping = .strip,
        .indentation_width = 2,
        .bytes = "first\nsecond",
    },
    .{ .kind = .mapping_end },
};

// Keep chomping retains the trailing blank line as a second newline.
const yaml_literal_keep_events: []const Event = &.{
    .{ .kind = .mapping_start },
    .{ .kind = .key, .bytes = "body" },
    .{
        .kind = .scalar,
        .ownership = .document_owned,
        .style = .literal,
        .chomping = .keep,
        .indentation_width = 2,
        .bytes = "alpha\nbeta\n\n",
    },
    .{ .kind = .mapping_end },
};

// A folded block joins the two content lines with a space rather than a break.
const yaml_folded_events: []const Event = &.{
    .{ .kind = .mapping_start },
    .{ .kind = .key, .bytes = "body" },
    .{
        .kind = .scalar,
        .ownership = .document_owned,
        .style = .folded,
        .chomping = .clip,
        .indentation_width = 2,
        .bytes = "first line second line\n",
    },
    .{ .kind = .mapping_end },
};

// The single-quoted scalar is document-owned: its cooked bytes no longer match
// the source span, which still carries the quotes and the line break.
const yaml_single_multiline_events: []const Event = &.{
    .{ .kind = .mapping_start },
    .{ .kind = .key, .bytes = "text" },
    .{
        .kind = .scalar,
        .ownership = .document_owned,
        .style = .single_quoted,
        .chomping = .clip,
        .bytes = "alpha beta",
    },
    .{ .kind = .mapping_end },
};

// The double-quoted scalar folds its line break and then decodes `\n`, so the
// cooked bytes are "alpha beta" followed by a real newline byte.
const yaml_double_multiline_events: []const Event = &.{
    .{ .kind = .mapping_start },
    .{ .kind = .key, .bytes = "text" },
    .{
        .kind = .scalar,
        .ownership = .document_owned,
        .style = .double_quoted,
        .chomping = .clip,
        .bytes = "alpha beta\n",
    },
    .{ .kind = .mapping_end },
};

// The compact mapping is reported in expanded form: the sequence owns a mapping
// that owns three pairs. Every value is a plain borrowed span; the third pair
// has an empty value, which is a zero-length scalar and not a missing one.
const yaml_compact_mapping_events: []const Event = &.{
    .{ .kind = .sequence_start },
    .{ .kind = .mapping_start },
    .{ .kind = .key, .bytes = "id" },
    .{ .kind = .scalar, .bytes = "1" },
    .{ .kind = .key, .bytes = "name" },
    .{ .kind = .scalar, .bytes = "alpha" },
    .{ .kind = .key, .bytes = "note" },
    .{ .kind = .scalar, .bytes = "" },
    .{ .kind = .mapping_end },
    .{ .kind = .sequence_end },
};

// ---------------------------------------------------------------------------
// Fixture views
// ---------------------------------------------------------------------------

const accepted_stages = [_]contract.Stage{ .parse, .traverse };
const reject_stages = [_]contract.Stage{.reject};
const resource_stages = [_]contract.Stage{.resource_error};

/// The reduced common view the controller enumerates and the report decoder
/// decodes: one entry per fixture, in `contract.Workload` declaration order.
/// The YAML profile has no renderer, so no fixture declares `render_html`.
pub const fixtures: []const contract.Fixture = &[_]contract.Fixture{
    .{
        .workload = .yaml_literal_clip,
        .source = yaml_literal_clip_source,
        .stages = &accepted_stages,
        .outcome = contract.accepted_outcome,
    },
    .{
        .workload = .yaml_literal_strip,
        .source = yaml_literal_strip_source,
        .stages = &accepted_stages,
        .outcome = contract.accepted_outcome,
    },
    .{
        .workload = .yaml_literal_keep,
        .source = yaml_literal_keep_source,
        .stages = &accepted_stages,
        .outcome = contract.accepted_outcome,
    },
    .{
        .workload = .yaml_folded,
        .source = yaml_folded_source,
        .stages = &accepted_stages,
        .outcome = contract.accepted_outcome,
    },
    .{
        .workload = .yaml_single_multiline,
        .source = yaml_single_multiline_source,
        .stages = &accepted_stages,
        .outcome = contract.accepted_outcome,
    },
    .{
        .workload = .yaml_double_multiline,
        .source = yaml_double_multiline_source,
        .stages = &accepted_stages,
        .outcome = contract.accepted_outcome,
    },
    .{
        .workload = .yaml_compact_mapping,
        .source = yaml_compact_mapping_source,
        .stages = &accepted_stages,
        .outcome = contract.accepted_outcome,
    },
    .{
        .workload = .yaml_unterminated_quote,
        .source = yaml_unterminated_quote_source,
        .stages = &reject_stages,
        .outcome = "Invalid",
    },
    .{
        .workload = .yaml_malformed_block,
        .source = yaml_malformed_block_source,
        .stages = &reject_stages,
        .outcome = "Invalid",
    },
    .{
        .workload = .yaml_alias,
        .source = yaml_alias_source,
        .stages = &reject_stages,
        .outcome = "Unsupported",
    },
    .{
        .workload = .yaml_tag,
        .source = yaml_tag_source,
        .stages = &reject_stages,
        .outcome = "Unsupported",
    },
    .{
        .workload = .yaml_multiple_documents,
        .source = yaml_multiple_documents_source,
        .stages = &reject_stages,
        .outcome = "Unsupported",
    },
    .{
        .workload = .yaml_cooked_limit,
        .source = yaml_cooked_limit_source,
        .stages = &resource_stages,
        .outcome = "CookedBytesExceeded",
    },
    .{
        .workload = .yaml_scalar_line_limit,
        .source = yaml_scalar_line_limit_source,
        .stages = &resource_stages,
        .outcome = "ScalarLineLimitExceeded",
    },
    .{
        .workload = .yaml_depth_limit,
        .source = yaml_depth_limit_source,
        .stages = &resource_stages,
        .outcome = "DepthExceeded",
    },
};

/// The richer parallel oracle table, indexed exactly like `fixtures`.
pub const oracles: []const Oracle = &[_]Oracle{
    .{
        .outcome = contract.accepted_outcome,
        .limits = default_limits,
        .events = yaml_literal_clip_events,
        .diagnostic_kind = .syntax,
    },
    .{
        .outcome = contract.accepted_outcome,
        .limits = default_limits,
        .events = yaml_literal_strip_events,
        .diagnostic_kind = .syntax,
    },
    .{
        .outcome = contract.accepted_outcome,
        .limits = default_limits,
        .events = yaml_literal_keep_events,
        .diagnostic_kind = .syntax,
    },
    .{
        .outcome = contract.accepted_outcome,
        .limits = default_limits,
        .events = yaml_folded_events,
        .diagnostic_kind = .syntax,
    },
    .{
        .outcome = contract.accepted_outcome,
        .limits = default_limits,
        .events = yaml_single_multiline_events,
        .diagnostic_kind = .syntax,
    },
    .{
        .outcome = contract.accepted_outcome,
        .limits = default_limits,
        .events = yaml_double_multiline_events,
        .diagnostic_kind = .syntax,
    },
    .{
        .outcome = contract.accepted_outcome,
        .limits = default_limits,
        .events = yaml_compact_mapping_events,
        .diagnostic_kind = .syntax,
    },
    // An unterminated quoted scalar is a syntax error, not a resource bound.
    .{
        .outcome = "Invalid",
        .limits = default_limits,
        .events = &.{},
        .diagnostic_kind = .syntax,
    },
    // Block content indented less than an explicit header promised is malformed
    // input, so it is a syntax error too.
    .{
        .outcome = "Invalid",
        .limits = default_limits,
        .events = &.{},
        .diagnostic_kind = .syntax,
    },
    // Aliases, tags, and multiple documents are deferred features of the basic
    // profile, so the extended profile reports them as unsupported.
    .{
        .outcome = "Unsupported",
        .limits = default_limits,
        .events = &.{},
        .diagnostic_kind = .unsupported,
    },
    .{
        .outcome = "Unsupported",
        .limits = default_limits,
        .events = &.{},
        .diagnostic_kind = .unsupported,
    },
    .{
        .outcome = "Unsupported",
        .limits = default_limits,
        .events = &.{},
        .diagnostic_kind = .unsupported,
    },
    // The three resource fixtures differ from `default_limits` in exactly one
    // field each, and every one of them classifies as a resource diagnostic.
    .{
        .outcome = "CookedBytesExceeded",
        .limits = yaml_cooked_limit_limits,
        .events = &.{},
        .diagnostic_kind = .resource,
    },
    .{
        .outcome = "ScalarLineLimitExceeded",
        .limits = yaml_scalar_line_limit_limits,
        .events = &.{},
        .diagnostic_kind = .resource,
    },
    .{
        .outcome = "DepthExceeded",
        .limits = yaml_depth_limit_limits,
        .events = &.{},
        .diagnostic_kind = .resource,
    },
};

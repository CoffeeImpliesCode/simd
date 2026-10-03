const std = @import("std");
const simd = @import("../core/simd.zig");

/// U+FEFF in UTF-8. A byte order mark at the head of a stream, and the one
/// character this profile reads as content only inside a quoted scalar.
const bom = "\xef\xbb\xbf";

pub fn failureOffset(input: []const u8) error{InputTooLarge}!?usize {
    return failureOffsetImpl(simd.default_vector_len, input);
}

/// The offset of the first byte of `input` this profile cannot read, or `null`
/// when it can read all of it.
///
/// U+FEFF is the one character whose legality is a property of where it stands
/// rather than of the bytes it is made of, so the answer needs the quote state
/// of the source and not only the width of one character. A caller that reads a
/// source one line at a time feeds that same state one line at a time through
/// `failureOffsetInLine` and reaches the same verdict for the same line.
pub fn failureOffsetImpl(
    comptime vlen: usize,
    input: []const u8,
) error{InputTooLarge}!?usize {
    comptime {
        if (vlen < 4) {
            @compileError("YAML validation vector width must be at least four bytes");
        }
    }
    if (input.len > std.math.maxInt(u32)) return error.InputTooLarge;

    // The walk reads the whole source as one window, so it sees the line breaks
    // themselves and is only advanced as far as a U+FEFF candidate needs it.
    var state: SourceState = .{};
    const start: usize = if (std.mem.startsWith(u8, input, bom)) bom.len else 0;
    return scan(vlen, &state, input, start, false);
}

/// The offset within `line` of the first byte this profile cannot read, or
/// `null` when it can read all of it.
///
/// `line` is one line of a source without its line break and without any
/// document byte order mark, and `has_newline` says whether a break follows it.
/// `state` is the caller's and keeps what this line leaves behind, so the next
/// line answers against the lines above it: an open quote that spans lines, a
/// block scalar header whose body starts here, and a token that began on an
/// earlier line all reach this one. The state is bounded by one line, so a
/// caller can hold it for a document of any length without keeping the source.
///
/// A returned offset leaves the walk on the line it stopped at; the caller has
/// refused the source by then and reaches no further line through this state.
pub fn failureOffsetInLine(
    state: *SourceState,
    line: []const u8,
    has_newline: bool,
) ?usize {
    comptime {
        if (simd.default_vector_len < 4) {
            @compileError("YAML validation vector width must be at least four bytes");
        }
    }
    if (scan(simd.default_vector_len, state, line, 0, has_newline)) |offset| {
        return offset;
    }
    // The next line reads the context this one leaves, so this line is finished
    // here rather than left behind the bytes the scan walked past.
    state.endWindow();
    return null;
}

pub fn failureOffsetScalarFrom(
    input: []const u8,
    start: usize,
) error{InputTooLarge}!?usize {
    if (input.len > std.math.maxInt(u32)) return error.InputTooLarge;

    var index = start;
    if (start == 0 and std.mem.startsWith(u8, input, bom)) index = bom.len;
    while (index < input.len) {
        const width = yamlCharacterWidth(input, index) orelse return index;
        index += width;
    }
    return null;
}

/// Walks `window` from `start` and returns the first offset it cannot read,
/// leaving the source state wherever the walk reached.
fn scan(
    comptime vlen: usize,
    state: *SourceState,
    window: []const u8,
    start: usize,
    has_newline: bool,
) ?usize {
    state.open(window, start, has_newline);
    var index = start;
    while (index < window.len) {
        index = printableRun(vlen, window, index);
        if (index >= window.len) break;

        const scalar_end = index + @min(vlen, window.len - index);
        while (index < scalar_end) {
            if (isQuotedContent(window, index, state)) {
                index += bom.len;
                continue;
            }
            const width = yamlCharacterWidth(window, index) orelse return index;
            index += width;
        }
    }
    return null;
}

/// The first offset from `start` that is not printable ASCII, and the end of
/// `window` when a whole run of them is left. A `vlen`-wide step settles that
/// for a vector of bytes at a time.
fn printableRun(comptime vlen: usize, window: []const u8, start: usize) usize {
    const printable_mask = simd.exactMask(
        simd.Mask(vlen),
        std.math.maxInt(simd.Mask(vlen)),
    );
    var index = start;
    while (window.len - index >= vlen) {
        const bytes: simd.Vec(u8, vlen) = window[index..][0..vlen].*;
        const printable = simd.exactMask(
            simd.Mask(vlen),
            simd.matchRange(vlen, bytes, 0x20, 0x7e),
        );
        if (printable != printable_mask) break;
        index += vlen;
    }
    return index;
}

/// Which quote, if any, is open at the byte the walk sits on. U+FEFF is
/// content inside a quoted scalar and nowhere else, and deciding that needs
/// the quote state of the source rather than the width of one character.
const QuoteState = enum { none, single, double };

/// The source context one bounded value carries from line to line.
///
/// A quote byte only opens a scalar where a scalar can start, and what starts a
/// scalar is a property of the whole source rather than of the bytes on screen:
/// a line indented under a block scalar header above it is body, where every
/// byte is text, and a quoted scalar that opened on an earlier line is still
/// open here. A walk that holds one line and a walk that holds all of it
/// therefore cannot each answer from the line alone, and this is what both read
/// instead: the caller feeds it a line at a time and it answers each against
/// the lines it has already seen.
///
/// Where a node starts is lexical, not grammatical, so this tracks what a node
/// already read on the line leaves behind. A plain scalar runs to the end of
/// its line and onto the lines below that are indented under the entry it
/// belongs to, and there a quote, a bracket or a comma is its content rather
/// than a new node. The entry it belongs to is the one whose value slot the
/// scalar fills: the `-` or the key that opened that slot, whether that stood
/// on this line or on the line above. That is the whole nesting this keeps, and
/// it is a lexical bound rather than a claim about what either profile accepts.
///
/// It owns no bytes and allocates nothing, and `cursor` is bounded by the
/// window the caller opened, so a caller that validates a whole stream holds
/// one of these for the whole stream and never the stream itself.
pub const SourceState = struct {
    /// The bytes the walk reads: one line without its break, or a whole source
    /// whose breaks are bytes of it.
    window: []const u8 = &.{},
    /// Whether a line break follows `window` rather than being part of it.
    has_newline: bool = false,
    /// Where the walk sits within `window`.
    cursor: usize = 0,
    quote: QuoteState = .none,
    /// A node can start at the byte the walk sits on.
    token_start: bool = true,
    /// The walk is still counting the indentation of this line.
    at_line_start: bool = true,
    line_indent: usize = 0,
    /// A node, quoted or plain, has been read on this line, so the punctuation
    /// after it is trailing content rather than the start of another one.
    node_read: bool = false,
    /// Where the node being read began on this line, which is the column a
    /// mapping separator after it belongs to.
    node_column: usize = 0,
    /// The indentation of the entry whose value slot is open and waiting: the
    /// column of the `-` or the key that opened it. A plain scalar read into
    /// that slot belongs to that entry, not to its own column.
    pending_owner: ?usize = null,
    /// The node being read is a plain scalar, which is the one kind that runs
    /// onto the lines below it. A quoted scalar ends at its closing quote.
    plain_node: bool = false,
    /// This line continues a plain scalar from the line above, so its bytes are
    /// that scalar's content from here to the break.
    plain_continuing: bool = false,
    /// The indent of the line a block scalar header sat on, while that block
    /// scalar is still open.
    block_parent_indent: ?usize = null,
    /// The rest of this line is text rather than source structure: a comment,
    /// a block scalar header, or the body of a block scalar opened above.
    rest_is_text: bool = false,
    /// A plain scalar was still open when the line above ended.
    plain_across_break: bool = false,
    /// The indent of the entry the plain scalar belongs to, which is what a
    /// line has to be more indented than to continue that scalar rather than
    /// start the next entry beside it.
    plain_parent_indent: usize = 0,
    /// How many flow collections are open. Every entry of one is a token, so a
    /// quote inside one opens a scalar wherever the line puts it, and a comma
    /// outside one is content of the plain scalar it sits in.
    flow_depth: usize = 0,

    /// Offset in `window` of the first byte of the line being read, so a
    /// column is a real line column on every route and not an offset into a
    /// whole source.
    line_start: usize = 0,

    /// The column of the byte the walk sits on within its line.
    fn column(self: *SourceState) usize {
        return self.cursor - self.line_start;
    }

    /// Points the walk at the bytes of the next line, from `start`.
    fn open(self: *SourceState, window: []const u8, start: usize, has_newline: bool) void {
        self.window = window;
        self.has_newline = has_newline;
        self.cursor = start;
        self.line_start = start;
    }

    /// Finishes the window. The walk reaches its last byte, and the break that
    /// follows returns the line state to where a line begins. A quote that is
    /// still open is the exception: a quoted scalar that spans lines carries
    /// its line state into the line it continues, and a walk over the whole
    /// source reads those bytes the same way.
    fn endWindow(self: *SourceState) void {
        while (self.cursor < self.window.len) self.stepByte();
        if (!self.has_newline or self.quote != .none) return;
        self.lineBreak();
    }

    /// Whether the byte at `offset` is inside a quoted scalar, advancing the
    /// walk over the bytes before it. Offsets never move backwards, so one
    /// forward walk answers a whole document.
    fn quotedContentAt(self: *SourceState, offset: usize) bool {
        while (self.cursor < offset) self.stepByte();
        return self.quote != .none;
    }

    fn stepByte(self: *SourceState) void {
        const byte = self.window[self.cursor];
        switch (self.quote) {
            .single => {
                if (byte == '\'' and self.peek() == '\'') {
                    self.cursor += @min(2, self.window.len - self.cursor);
                    return;
                }
                if (byte == '\'') {
                    self.quote = .none;
                    self.node_read = true;
                    self.plain_node = false;
                }
                self.cursor += 1;
                return;
            },
            .double => {
                if (byte == '\\') {
                    const room = self.window.len - self.cursor;
                    self.cursor += @min(2, room);
                    // An escape on the last byte of a line took the break with
                    // it, and nothing else: `endWindow` sees the quote that is
                    // still open and keeps the line state, so the byte after
                    // the break is read as the scalar content it is.
                    return;
                }
                if (byte == '"') {
                    self.quote = .none;
                    self.node_read = true;
                    self.plain_node = false;
                }
                self.cursor += 1;
                return;
            },
            .none => {},
        }
        if (self.rest_is_text) {
            self.takeBreakOrByte(byte);
            return;
        }
        if (self.at_line_start) {
            if (byte == ' ') {
                self.line_indent += 1;
                self.cursor += 1;
                return;
            }
            self.at_line_start = false;
            if (self.block_parent_indent) |parent| {
                if (byte == '\n' or byte == '\r') {
                    // An empty line is body text and keeps the block open.
                    self.takeBreak();
                    return;
                }
                if (self.line_indent > parent) {
                    self.rest_is_text = true;
                    self.cursor += 1;
                    return;
                }
                self.block_parent_indent = null;
            }
            if (self.plain_across_break and self.line_indent > self.plain_parent_indent) {
                // This line continues the plain scalar the line above left
                // open, so its first byte is that scalar's content and the
                // node it starts is not a new one.
                self.plain_across_break = false;
                self.node_read = true;
                self.plain_node = true;
                self.plain_continuing = true;
                self.token_start = false;
                self.cursor += 1;
                return;
            }
            self.plain_across_break = false;
        }
        if (byte == '\n' or byte == '\r') {
            self.takeBreak();
            return;
        }
        if (self.token_start) {
            switch (byte) {
                '#' => {
                    self.rest_is_text = true;
                    self.cursor += 1;
                    return;
                },
                '|', '>' => {
                    // The modifiers, the comment and the trailing spaces that
                    // finish the header are text, and every line indented under
                    // it is body until one comes back out to this indentation.
                    // The block scalar is the value the slot was waiting for.
                    self.block_parent_indent = self.line_indent;
                    self.rest_is_text = true;
                    self.pending_owner = null;
                    self.cursor += 1;
                    return;
                },
                '\'' => {
                    self.quote = .single;
                    self.node_column = self.column();
                    self.pending_owner = null;
                    self.token_start = false;
                    self.cursor += 1;
                    return;
                },
                '"' => {
                    self.quote = .double;
                    self.node_column = self.column();
                    self.pending_owner = null;
                    self.token_start = false;
                    self.cursor += 1;
                    return;
                },
                else => {},
            }
        }
        if (byte == '#' and self.cursor > 0 and self.window[self.cursor - 1] == ' ') {
            self.rest_is_text = true;
            self.cursor += 1;
            return;
        }
        // A node starts only where the grammar allows one to start. Everywhere
        // else these punctuation bytes belong to the node this line already
        // read, so a quote among them is its content and opens nothing.
        switch (byte) {
            '[', '{' => {
                // A flow collection opens only where a node can start; inside
                // the node this line already read the bracket is its content.
                if (!self.node_read) {
                    self.flow_depth += 1;
                    self.node_column = self.column();
                    self.pending_owner = null;
                    self.token_start = true;
                    self.plain_node = false;
                }
            },
            ']', '}' => {
                self.flow_depth -= @min(self.flow_depth, 1);
                self.node_read = false;
                self.plain_node = false;
                self.token_start = false;
            },
            ',' => {
                // The comma ends an entry of a flow collection. Outside one it
                // is content of the plain scalar it sits in, and the walk
                // stays inside that scalar.
                if (self.flow_depth > 0) {
                    self.node_read = false;
                    self.plain_node = false;
                    self.node_column = self.column() + 1;
                    self.pending_owner = null;
                    self.token_start = true;
                }
            },
            ':' => {
                // A colon and a space close the key and open the value slot,
                // wherever they stand: a plain key ends at one. Inside a flow
                // collection a quoted key ends at a bare colon too, which is
                // how a JSON-style pair writes one, and a quoted key is the
                // only key that does. The value the slot holds belongs to the
                // entry the key belongs to, which is where that key began. A
                // line that continues a plain scalar has no mapping to close,
                // so there the colon is content.
                const quoted_key = self.node_read and !self.plain_node and
                    self.flow_depth > 0;
                if (!self.plain_continuing and
                    (self.peek() == ' ' or self.atEnd() or quoted_key))
                {
                    self.node_read = false;
                    self.plain_node = false;
                    self.pending_owner = self.node_column;
                    self.token_start = true;
                }
            },
            '-', '?' => {
                // A sequence entry or an explicit key, and only where no node
                // has been read on this line yet: a hyphen between words is
                // content of the plain scalar around it. The entry it opens
                // owns the value that follows it.
                if (self.peek() == ' ' or self.atEnd()) {
                    self.token_start = !self.node_read;
                    if (self.token_start) self.pending_owner = self.column();
                }
            },
            ' ' => {},
            else => {
                // The first byte of a plain scalar measures it against the
                // entry whose slot it fills, which is the indentation of that
                // entry rather than the column the scalar starts at.
                if (!self.node_read) {
                    self.node_column = self.column();
                    self.plain_parent_indent = self.pending_owner orelse self.line_indent;
                    self.pending_owner = null;
                }
                self.token_start = false;
                self.node_read = true;
                self.plain_node = true;
            },
        }
        self.cursor += 1;
    }

    /// Takes the break at the cursor, CRLF as one break.
    fn takeBreak(self: *SourceState) void {
        const crlf = self.window[self.cursor] == '\r' and self.peek() == '\n';
        self.cursor += if (crlf) 2 else 1;
        self.lineBreak();
    }

    /// Takes a byte of a line whose bytes are text, or the break that ends it.
    fn takeBreakOrByte(self: *SourceState, byte: u8) void {
        if (byte == '\n' or byte == '\r') {
            self.takeBreak();
            return;
        }
        self.cursor += 1;
    }

    /// The state a line begins in. A block header above stays open across the
    /// break, so a line indented under it is still body, and a plain scalar
    /// that reached the end of the line above stays open for a line indented
    /// under the entry it belongs to.
    fn lineBreak(self: *SourceState) void {
        // Only a plain scalar reaches past the break. A quoted one ended at its
        // closing quote, a block body is read by its own rule, and a comment
        // ends with its line. `pending_owner` survives on purpose: a slot a `:`
        // or a `- ` opened waits for its value on the line below.
        self.plain_across_break = self.plain_node and self.quote == .none and
            !self.rest_is_text;
        self.line_start = self.cursor;
        self.at_line_start = true;
        self.token_start = true;
        self.line_indent = 0;
        self.node_column = 0;
        self.node_read = false;
        self.plain_node = false;
        self.plain_continuing = false;
        self.rest_is_text = false;
    }

    fn peek(self: *SourceState) u8 {
        const next = self.cursor + 1;
        if (next < self.window.len) return self.window[next];
        return if (self.has_newline) '\n' else 0;
    }

    fn atEnd(self: *SourceState) bool {
        const next = self.cursor + 1;
        if (next >= self.window.len) return true;
        const byte = self.window[next];
        return byte == '\n' or byte == '\r';
    }
};

/// Whether the three bytes at `offset` are U+FEFF in a spot this profile reads
/// as content rather than as a character it cannot read.
///
/// The offset is relative to the window the walk was opened on, which is a line
/// without its break or a whole source, and the document byte order mark is
/// never inside it. So a U+FEFF at the first byte of a line is a continuation
/// of whatever the line above left open, and the walk decides: quoted content
/// inside a quoted scalar, and the character this profile cannot read
/// anywhere else.
fn isQuotedContent(
    window: []const u8,
    offset: usize,
    state: *SourceState,
) bool {
    if (offset + 2 >= window.len) return false;
    if (window[offset] != 0xef or window[offset + 1] != 0xbb or
        window[offset + 2] != 0xbf)
    {
        return false;
    }
    return state.quotedContentAt(offset);
}

fn yamlCharacterWidth(input: []const u8, index: usize) ?usize {
    const first = input[index];
    // U+FEFF is never a character this profile reads. A document byte order
    // mark is skipped by the caller that opens the window, and a quoted
    // occurrence never reaches here because `isQuotedContent` consumes it
    // first, so no offset is exempt.
    if (first == 0xef and index + 2 < input.len and
        input[index + 1] == 0xbb and input[index + 2] == 0xbf)
    {
        return null;
    }
    if (first < 0x20 and first != '\n' and first != '\r' and first != '\t') return null;
    if (first == 0x7f) return null;
    if (first < 0x80) return 1;

    if (first == 0xc2) {
        if (index + 1 >= input.len or !isContinuation(input[index + 1])) return null;
        const second = input[index + 1];
        if (second == 0x85 or second >= 0xa0) return 2;
        return null;
    }
    if (first >= 0xc3 and first <= 0xdf) {
        if (index + 1 >= input.len or !isContinuation(input[index + 1])) return null;
        return 2;
    }
    if (first == 0xe0) {
        if (index + 2 >= input.len or input[index + 1] < 0xa0 or input[index + 1] > 0xbf or
            !isContinuation(input[index + 2])) return null;
        return 3;
    }
    if (first >= 0xe1 and first <= 0xec or first == 0xee) {
        if (index + 2 >= input.len or !isContinuation(input[index + 1]) or
            !isContinuation(input[index + 2])) return null;
        return 3;
    }
    if (first == 0xed) {
        if (index + 2 >= input.len or input[index + 1] < 0x80 or input[index + 1] > 0x9f or
            !isContinuation(input[index + 2])) return null;
        return 3;
    }
    if (first == 0xef) {
        if (index + 2 >= input.len or !isContinuation(input[index + 1]) or
            !isContinuation(input[index + 2])) return null;
        if (input[index + 1] == 0xbf and input[index + 2] >= 0xbe) return null;
        return 3;
    }
    if (first == 0xf0) {
        if (index + 3 >= input.len or input[index + 1] < 0x90 or input[index + 1] > 0xbf or
            !isContinuation(input[index + 2]) or !isContinuation(input[index + 3])) return null;
        return 4;
    }
    if (first >= 0xf1 and first <= 0xf3) {
        if (index + 3 >= input.len or !isContinuation(input[index + 1]) or
            !isContinuation(input[index + 2]) or !isContinuation(input[index + 3])) return null;
        return 4;
    }
    if (first == 0xf4) {
        if (index + 3 >= input.len or input[index + 1] < 0x80 or input[index + 1] > 0x8f or
            !isContinuation(input[index + 2]) or !isContinuation(input[index + 3])) return null;
        return 4;
    }
    return null;
}

fn isContinuation(byte: u8) bool {
    return byte >= 0x80 and byte <= 0xbf;
}

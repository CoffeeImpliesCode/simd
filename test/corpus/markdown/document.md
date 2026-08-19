# Project Specification

This is an introduction paragraph with **bold text**, *italic emphasis*, and `inline code` elements.

## Architecture

> Notice: On-Demand parsers process structural elements lazily.
> Multiple blockquote lines follow the initial prefix.

- First item in an unordered list
- Second item with a [link reference](https://example.com)
- Third item with sub-points:
  * Sub-item A
  * Sub-item B

1. Numbered step one
2. Numbered step two

```zig
pub fn main() !void {
    // Code block contents must not trigger markdown heading `# not a heading`
    const vector_len: usize = 64;
    _ = vector_len;
}
```

---

End of document section with trailing remarks.

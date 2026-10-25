# simd

Experimental native Zig primitives, structural indexes, and parsers for caller-owned byte slices.
Requires Zig 0.17.0. The package has no library dependencies or C ABI.

## Use

Add the package to your project:

```sh
zig fetch --save=simd git+https://github.com/CoffeeImpliesCode/simd
```

In `build.zig`, use the consumer's target, optimization mode, and executable:

```zig
const dependency = b.dependency("simd", .{
    .target = target,
    .optimize = optimize,
    .vector_len = @as(usize, 16),
});
exe.root_module.addImport("simd", dependency.module("simd"));
```

The module supplies its generated `build_options`. `vector_len` is optional.
The default is 64 with AVX-512F and AVX-512BW, 32 with AVX2, otherwise 16.
An explicit width must be at least 4. It need not be a power of two.
`Mask(N)` is an N-bit integer. Bit `i` represents lane `i`, independent of storage padding.

Build artifacts are `simd-static` (static archive) and `simd` (sample mask visualizer).
Use the native module for generic APIs. The archive does not provide C bindings.

## Interfaces

| Namespace | Scope |
| --- | --- |
| `simd` | Byte vectors, masks, and UTF-8 checks |
| `stage1` | Owned structural offsets and sentinels |
| `stage2` | JSON-family validation, tape, cursors, and borrowed diagnostics |
| `json_value` | Strict JSON string decoding and number conversion |
| `ondemand` | Reusable JSON-family indexes with one active document/focus |
| `stream` | Chunk-fed JSON-family and JSONL indexing |
| `debug` | Visualization through a caller-supplied writer |
| `formats.json`, `jsonc`, `json5`, `jsonl` | Format-specific grammar and framing |
| `formats.markdown` | Marker-kind tape |
| `formats.xml` | UTF-8 lexical XML, without DTD or namespace resolution |
| `formats.yaml` | Bounded `yaml-basic-1.2.2` profile |
| `formats.commonmark` | CommonMark 0.31.2 semantic parser and HTML renderer |
| `formats.yaml_extended` | Opt-in `yaml-extended-e2b-1.2.2` profile |

CommonMark and extended YAML have no streaming interface.
Root aliases refer to the core declarations. Public state fields follow their documented access protocol.

## Ownership

```zig
const simd = @import("simd");

var document = try simd.formats.json.buildJsonTape(allocator, input);
defer document.deinit(allocator);
const cursor = try document.root(input);
const raw = try cursor.rawValue();
```

This example uses a scalar root. The document owns its tape. `raw` borrows `input`.
JSON-family `root(input)` does not check source identity.
Pass the original immutable bytes and keep the source and tape alive through cursor use.

- Copies of owners alias allocations. Release each allocation once with a compatible allocator.
- Keep reusable parsers at stable addresses with live allocator backing state.
- A resident parser permits one active document/focus. Release it before reuse.
- JSONL record-parser advance invalidates previous checked records and cursors.
- Generation checks require live owner storage. They do not preserve a destroyed parser.
- CommonMark owns nodes, text, and references. Pin its document while a `ChildIterator` exists.
- Extended YAML owns tape, metadata, and cooked bytes. `Value.ownership()` identifies the storage.
- Rendered HTML is a separate allocation owned by the caller.
- Mutating operations require exclusive access. Readers require no concurrent storage mutation or disposal.

See [`examples/consumer.zig`](examples/consumer.zig) for cleanup, resident traversal, index transfer, and semantic values.
The [architecture reference](docs/architecture-stage2-stream.md) describes source checks, errors, and format limits.

## Build and test

```sh
zig build
zig build test
zig build corpus
zig build run
zig build example
zig build docs
zig build check
```

`check` includes native tests, offline corpora, widths 4, 5, 7, 12, 16, 24, 32, and 64,
benchmark behavior tests, the consumer example, formatting, analyzers, and cross-target checks.
It requires Zig 0.17-compatible `zig-gate`, `zbc`, `zwanzig`, and `cross-test` on `PATH`, plus `mkdir` and `env`.
These are development tools, not consumer dependencies. Their absence or incompatibility fails `check`.
`-Dscratch_dir=PATH` selects external-check scratch storage.

The optional devenv shell uses Zig from `PATH` and checks its version.
An anyzig installation selects the compiler from `build.zig.zon`.

## Layout and corpus terms

- `src/core/`: SIMD, indexes, tapes, resident state, and streams.
- `src/formats/`: format-specific parsers and semantic models.
- `test/`: unit, fuzz, lifecycle, and offline corpus tests.
- `scripts/`: benchmark capture, archive verification, and semantic measurements.
- `test/corpus/upstream/commonmark-0.31.2/`: CommonMark examples under CC BY-SA 4.0. See its `LICENSE` and `provenance.zon`.
- Other upstream corpus manifests record source pins and redistribution terms.

## References

- [1902.08318: Parsing Gigabytes of JSON per Second](https://arxiv.org/abs/1902.08318).
- [2312.17149: On-Demand JSON: A Better Way to Parse Documents?](https://arxiv.org/abs/2312.17149).
- [2010.03090: Validating UTF-8 In Less Than One Instruction Per Byte](https://arxiv.org/abs/2010.03090).
- [2011.08313: IR-improved DGLAP parton shower effects for associated production of a W boson and jets in pp collisions at √s = 8 and 13 TeV](https://arxiv.org/abs/2011.08313).

## License

MIT, see [LICENSE](LICENSE). Third-party components keep their own licenses: see THIRD_PARTY_NOTICES.md

# W3C XML Test Suite corpus manifest

## Source pin

- `source_name`: W3C XML Conformance Test Suite
- `source_revision`: `xmlts20130923` (23 September 2013)
- `source_url`: <https://www.w3.org/XML/Test/xmlts20130923.tar.gz>
- `release_index`: <https://www.w3.org/XML/Test/>
- `archive_name`: `xmlts20130923.tar.gz`
- `archive_length`: `641522` bytes
- `archive_sha256`: `9b61db9f5dbffa545f4b8d78422167083a8568c59bd1129f94138f936cf6fc1f`
- `license_url`: <https://www.w3.org/Consortium/Legal/copyright-software-19980720>
- `license_files`: `LICENSE.w3c-19980720.html`; preserve embedded notices under `xmlconf/`

The dated URL and the byte hash form the source pin. Do not replace this URL with an undated release or a CVS snapshot.

W3C does not publish a checksum beside this archive. A maintainer captured the values above from the downloaded archive bytes.

## Local SHA capture

Archive acquisition is a manual import step. It is not part of a build or test.

From the repository root, capture a candidate archive in a temporary directory:

```sh
url=https://www.w3.org/XML/Test/xmlts20130923.tar.gz
archive="${TMPDIR:-/tmp}/xmlts20130923.tar.gz"
curl --fail --location --proto '=https' --output "$archive" "$url"
wc -c "$archive"
sha256sum "$archive"
```

The commands must report `641522` bytes and the SHA-256 value in the source pin. Stop the import if either value differs.

Verify a saved archive before each extraction:

```sh
printf '%s  %s\n' \
  9b61db9f5dbffa545f4b8d78422167083a8568c59bd1129f94138f936cf6fc1f \
  test/corpus/upstream/xml/xmlts20130923.tar.gz | sha256sum --check -
```

Record a new release as a separate source revision. Do not update this pin in place.

## License

The test suite uses the [W3C Software Notice and License dated 20 July 1998](https://www.w3.org/Consortium/Legal/copyright-software-19980720).
The [XML Test Suite FAQ](https://www.w3.org/XML/Test/xmlfaq.htm#copyright) applies that license to published contributions.
The [test-suite process](https://www.w3.org/XML/Test/XMLConformanceTS-Process-20031210.html) describes contribution and publication rules.

The license permits use, copy, modification, and distribution under its notice conditions. Preserve the full W3C notice with redistributed files.
Preserve all embedded Sun, OASIS, W3C, and contributor notices. Record each modified fixture, its change, and its change date.
Do not use contributor or W3C names for endorsement.

Before corpus files are committed, save a verbatim copy of the applicable license beside the extracted revision. Also add a dated modification record for derived fixtures.

## Raw layout

Keep the archive and extracted tree in this layout:

```text
test/corpus/upstream/xml/
├── MANIFEST.md
├── xmlts20130923.tar.gz
└── w3c-xmlts-20130923/
    ├── LICENSE.w3c-19980720.html
    ├── MODIFICATIONS.md
    └── xmlconf/
        ├── xmlconf.xml
        ├── testcases.dtd
        └── ...
```

The `xmlconf/` directory is the archive root. Preserve all relative paths, file names, encodings, line endings, and bytes.
Do not flatten the tree. Do not overwrite source files with normalized or transcoded copies.
This manifest does not vendor the archive or its contents.

## Import procedure

1. Run the manual acquisition procedure from a network-enabled maintainer environment.
2. Compare the archive length and SHA-256 value with the source pin.
3. List the archive entries before extraction.
4. Reject an absolute path, a `..` path component, a symbolic link, or a hard link.
5. Extract into a new, empty `w3c-xmlts-20130923/` staging directory.
6. Move the complete `xmlconf/` tree without changing its contents.
7. Parse `xmlconf/xmlconf.xml` as the suite catalog.
8. Resolve its catalog entities only from paths inside the extracted `xmlconf/` tree.
9. Resolve each inherited `xml:base` and `TEST.URI` against its catalog file.
10. Reject a URI with a scheme, an absolute path, or a path that escapes the extracted tree.
11. Apply the profile and entity filters below.
12. Copy selected fixtures without byte changes into the reviewed corpus area.
13. Record each fixture path, source `TEST.ID`, profile, collection, recommendation, edition, type, and entity mode.
14. Record the source and fixture byte lengths and SHA-256 values.
15. Record the expected accept or reject result and the parser feature that controls the result.

Catalog entity resolution in steps 7 and 8 belongs only to the importer. It does not enable entity resolution in the XML parser or tests.

## Profile policy

The first import profile tests the supported XML 1.0 UTF-8 grammar. It does not claim full W3C XML conformance.

Apply these catalog filters:

| Catalog field | Initial profile |
| --- | --- |
| `RECOMMENDATION` | Include `XML1.0` only. Exclude XML 1.1 and namespace recommendations. |
| `VERSION` | Include an omitted value or a token list that contains `1.0`. |
| `EDITION` | Include an omitted value or a token list that contains `5`. |
| `TYPE` | Consider `valid` and `not-wf`. Exclude `invalid` and `error`. |
| `ENTITIES` | Include `none` only. |
| `NAMESPACE` | Preserve the value as metadata. Do not infer namespace conformance from it. |

For a positive `valid` fixture, require valid UTF-8 source bytes. Permit no encoding declaration or an `encoding="UTF-8"` declaration.
For a negative `not-wf` fixture, include only a failure that exercises the supported UTF-8 XML grammar.
Exclude a case when its expected result depends on validation, XML 1.1, namespace processing, another character encoding, or canonical output.
Retain excluded cases in the untouched raw tree. Record the exclusion reason in importer output.

## DTD and `DOCTYPE` scope

DTD parsing and validation are out of scope. Internal subsets, external subsets, notation declarations, and default attributes are out of scope.
The importer must exclude every selected fixture that contains a `DOCTYPE` declaration.
The importer must also exclude a fixture whose expected result depends on a DTD or validity constraint.

A `DOCTYPE` fixture can remain in the raw tree for future profiles. The current profile must not treat its result as an XML parser conformance result.

## Entity policy

The current profile permits the five predefined XML entities and numeric character references. It does not expand declared general or parameter entities.

Exclude a fixture when `ENTITIES` is `general`, `parameter`, or `both`. Also exclude a fixture that declares or uses another named entity.
Do not resolve a `SYSTEM` or `PUBLIC` identifier. Do not read an external entity, external DTD, catalog, or schema during a test.
Treat a missing local dependency as an importer exclusion. Never fetch it on demand.

## No-network test rule

Tests must not access the network. Builds, test discovery, fixture loading, parsing, and failure recovery must use local files only.

The manual archive download is the only network step in this procedure. A test must not run the download command or contact the release URL.
Disable every external resolver in the test process. A fixture that can request a network resource is not eligible for the initial profile.

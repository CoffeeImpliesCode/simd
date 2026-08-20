# Stage 2 XML specification and conformance evidence

## Scope

This note covers XML 1.0 Fifth Edition parsing. It does not define XML Namespaces or XML 1.1 behavior.

The normative source is the W3C Recommendation dated 26 November 2008. W3C states that the Fifth Edition supersedes the Fourth Edition. It also states that the Fifth Edition is not a new XML version. The edition includes accumulated errata, especially the expanded name-character rules from erratum E09.

- Stable specification: [Extensible Markup Language (XML) 1.0, Fifth Edition](https://www.w3.org/TR/2008/REC-xml-20081126/)
- Latest specification alias: [W3C XML 1.0](https://www.w3.org/TR/xml/)
- Fifth Edition errata: [XML 1.0 Fifth Edition errata](https://www.w3.org/XML/xml-V10-5e-errata)
- Fifth Edition implementation report: [Implementation Report for XML 1.0 Fifth Edition](https://www.w3.org/XML/2008/01/xml10-5e-implementation.html)

Use the dated Recommendation as the implementation baseline. Check the errata before changing grammar or expected results.

## Normative requirements for Stage 2

### XML declaration

The XML declaration is optional, but an XML document should start with one. Production 23 requires `version` first. It permits an optional encoding declaration, an optional standalone declaration, and optional trailing white space. Production 26 accepts version numbers that match `1.` followed by one or more digits. See [section 2.8, productions 22 through 27](https://www.w3.org/TR/2008/REC-xml-20081126/#sec-prolog-dtd).

The document entity and each external parsed entity have separate encoding rules. All XML processors must accept UTF-8 and UTF-16. See [section 2.2](https://www.w3.org/TR/2008/REC-xml-20081126/#charsets) and [section 4.3.3](https://www.w3.org/TR/2008/REC-xml-20081126/#charencoding).

### Names

Production 4 defines `NameStartChar`. Production 4a defines later `NameChar` values. Production 5 combines them into `Name`. Names cannot start with an ASCII digit, a hyphen, or a period. A colon is an XML 1.0 name character even when namespace processing is disabled. Names that start with any case variant of `xml` are reserved. See [section 2.3, productions 4 through 8](https://www.w3.org/TR/2008/REC-xml-20081126/#sec-common-syn).

The Fifth Edition expanded the name ranges. W3C identifies this as a material compatibility change from earlier editions. Do not use the Fourth Edition `BaseChar` and `Ideographic` productions for Fifth Edition names.

### Attributes

Production 10 defines quoted attribute values. A literal `<` is not permitted. References can occur inside the value. See [section 2.3, production 10](https://www.w3.org/TR/2008/REC-xml-20081126/#NT-AttValue).

Productions 40 and 41 define attribute placement and syntax. An attribute name cannot occur twice in one start-tag or empty-element tag. An attribute value cannot contain a direct or indirect reference to an external entity. Entity replacement text used in an attribute cannot contain `<`. See [section 3.1](https://www.w3.org/TR/2008/REC-xml-20081126/#sec-starttags).

The processor must normalize attribute values before it reports or validates them. The algorithm handles line endings, entity references, character references, and white-space normalization for non-CDATA types. See [section 3.3.3](https://www.w3.org/TR/2008/REC-xml-20081126/#AVNormalize).

### Character and entity references

Production 66 permits decimal and hexadecimal character references. The referenced code point must match the `Char` production. Productions 67 through 69 define general and parameter entity references. See [section 4.1](https://www.w3.org/TR/2008/REC-xml-20081126/#sec-references).

A parsed entity cannot reference itself directly or indirectly. An entity reference cannot name an unparsed entity. Parameter entity references can occur only in the DTD. The declaration rules depend on the external subset and the standalone declaration. These constraints are part of [section 4.1](https://www.w3.org/TR/2008/REC-xml-20081126/#sec-references).

The five predefined general entities are `amp`, `lt`, `gt`, `apos`, and `quot`. See [section 4.6](https://www.w3.org/TR/2008/REC-xml-20081126/#sec-predefined-ent). Internal and external entity declarations are defined in [section 4.2](https://www.w3.org/TR/2008/REC-xml-20081126/#sec-entity-decl).

### Comments, processing instructions, and CDATA sections

Comments can occur outside other markup. The string `--` cannot occur inside a comment. Entity references are not recognized in comments. See [section 2.5 and production 15](https://www.w3.org/TR/2008/REC-xml-20081126/#sec-comments).

A processing instruction target is a `Name`, except for any case variant of `xml`. The data cannot contain the `?>` terminator. A processor must pass processing instructions to the application. Entity references are not recognized in processing instructions. See [section 2.6, productions 16 and 17](https://www.w3.org/TR/2008/REC-xml-20081126/#sec-pi).

A CDATA section can occur where character data can occur. Only `]]>` ends the section. CDATA sections cannot nest. Entity and character references are not expanded inside the section. See [section 2.7, productions 18 through 21](https://www.w3.org/TR/2008/REC-xml-20081126/#sec-cdata-sect).

### Character validity

Production 2 permits `#x9`, `#xA`, `#xD`, `#x20-#xD7FF`, `#xE000-#xFFFD`, and `#x10000-#x10FFFF`. This excludes most C0 controls, surrogate code points, `#xFFFE`, and `#xFFFF`. A character reference does not make an excluded code point legal. See [section 2.2, production 2](https://www.w3.org/TR/2008/REC-xml-20081126/#charsets) and the [Legal Character constraint](https://www.w3.org/TR/2008/REC-xml-20081126/#wf-Legalchar).

XML 1.0 discourages some legal control and noncharacter ranges. This is authoring advice, not a well-formedness rejection rule.

## Authoritative conformance corpus

### Provenance and revision

Use the [W3C XML Conformance Test Suites page](https://www.w3.org/XML/Test/) as the upstream release index. W3C calls this corpus the XML Conformance Test Suite and states that the XML Core Working Group maintains it. The page reports more than 2,000 test files.

The corpus is official W3C test-suite material, but W3C did not author every test. OASIS transferred the XML 1.0 Second Edition suite to W3C. W3C then added material from the XML Core Working Group and other contributors. The [W3C test report introduction](https://www.w3.org/XML/Test/xmlconf-20130923.html#intro) names these source collections:

- James Clark XMLTEST cases
- Fuji Xerox Japanese text tests
- Sun Microsystems XML tests
- OASIS and NIST tests
- IBM XML tests
- Richard Tobin errata, XML 1.1, and namespace tests
- University of Edinburgh XML 1.0 edition tests

The latest listed archive is the 23 September 2013 release:

- [xmlts20130923.tar.gz](https://www.w3.org/XML/Test/xmlts20130923.tar.gz)
- [xmlts20130923.zip](https://www.w3.org/XML/Test/xmlts20130923.zip)
- [xmlts20130923.tar](https://www.w3.org/XML/Test/xmlts20130923.tar)

The release page calls the 2013 version a minor release with corrections and additions. It does not publish a checksum. The source URL and release date are therefore the only upstream pin data.

The 27 August 2008 archive has stronger Fifth Edition provenance. The [Fifth Edition implementation report](https://www.w3.org/XML/2008/01/xml10-5e-implementation.html) states that this release contains tests for all testable changes since the Fourth Edition. The 2013 archive is the preferred corpus because it is the later W3C release. Keep the 2008 report as evidence for Fifth Edition coverage.

The HTML file named `xmlconf-20130923.html` still identifies itself as the 27 August 2008 report. It also links the 2008 archive in its header. Treat the W3C release index as the authority for the 2013 archive identity. Do not infer a separate 2013 report revision from that filename.

### Corpus structure

The archive has an `xmlconf/` root. The suite contains test collections, XML description files, test documents, expected output files, and an XSL-generated report. The [W3C XML Test Suite FAQ](https://www.w3.org/XML/Test/faq.html) states that each collection has an XML description file with pointers to individual tests.

The public [test-case DTD](https://www.w3.org/XML/Test/testcases.dtd) documents the core manifest model:

- `TESTSUITE` groups one or more `TESTCASES` collections.
- `PROFILE` identifies a collection or supplier profile.
- Each `TEST` has a unique `ID`, a relative `URI`, a `TYPE`, and specification `SECTIONS`.
- `TYPE` is `valid`, `invalid`, `not-wf`, or `error`.
- `ENTITIES` records required external general or parameter entities.
- `OUTPUT` and `OUTPUT3` point to canonical expected output.
- `NAMESPACE` marks namespace-sensitive cases.

The dated [2002 suite manifest](https://www.w3.org/XML/Test/xmlconf-20020606.xml) shows the composition pattern. It uses external entities to include collection manifests under directories such as `sun/`, `xmltest/`, `japanese/`, `oasis/`, and `ibm/`.

Later manifests add recommendation and edition metadata. The W3C release page states that the 2008 releases added `EDITION`. Some old tests use `EDITION="1 2 3 4"`. New Fifth Edition tests use `EDITION="5"`. The generated report also displays a `RECOMMENDATION` value for each case.

Do not flatten the archive. Relative URIs, external entity files, output files, encodings, and duplicate local names depend on the collection layout.

### Expected-result categories

The [W3C test matrix](https://www.w3.org/XML/Test/xmlconf-20130923.html#matrix) defines four input categories:

| Corpus type | Non-validating processor | Validating processor | Stage 2 use |
| --- | --- | --- | --- |
| `valid` | Accept | Accept | Positive well-formedness cases |
| `invalid` | Accept | Reject | Positive cases unless Stage 2 performs DTD validation |
| `not-wf` | Reject | Reject | Negative well-formedness cases |
| `error` | Result not specified | Result not specified | Exclude from pass/fail gates |

Some well-formedness failures are visible only when a processor reads an external entity. Use the `ENTITIES` field to select the correct expectation. Do not mark an external-entity case as passed when the parser skipped the bytes that contain the fault.

Many valid tests have an `OUTPUT` file. These files check the information that a processor reports after entity expansion and normalization. They are not simple byte-for-byte rewrites of the input.

### Relevant coverage

The [W3C test report](https://www.w3.org/XML/Test/xmlconf-20130923.html#listings) indexes cases by specification section, production, recommendation, collection, and test ID. It includes the required Stage 2 areas:

| Area | Direct corpus evidence |
| --- | --- |
| XML declaration | IBM production 22 and 23 cases cover prolog placement, `VersionInfo`, `EncodingDecl`, `SDDecl`, and trailing white space. |
| Names | Fifth Edition University of Edinburgh cases cover `NameStartChar`, `NameChar`, element names, and `Nmtoken` ranges. |
| Attributes | Cases cover production 10 values, start-tag attributes, declarations, defaulting, normalization, duplicate names, and entity restrictions. |
| Entities | Cases cover character references, general and parameter entities, declaration order, recursion, external entities, and external encodings. |
| Comments | Positive cases cover empty text, legal characters, one hyphen, placement, and the absence of entity expansion. Negative cases exercise forbidden `--` forms. |
| Processing instructions | Cases cover empty data, target names, placement, multiple instructions, reserved targets, and `?>` termination. |
| CDATA | Cases cover empty and ordinary data, literal `<` and `&`, section placement, non-nesting, and the `]]>` terminator. |
| Characters | IBM production 2 cases cover legal ranges and discrete characters. Negative cases cover excluded literal code points and illegal character references. |

The report includes XML 1.1 and namespace cases beside XML 1.0 cases. A corpus runner must filter by metadata. A filename prefix alone is not a reliable format selector.

The FAQ states that the suite is comprehensive, not complete. Passing all cases supports only a claim of conformance to that suite. It does not prove full conformance to the XML Recommendation.

## License and redistribution

The [XML Test Suite process document](https://www.w3.org/XML/Test/XMLConformanceTS-Process-20031210.html) requires contributors to grant W3C distribution rights under the W3C Software License dated 20 July 1998. The [XML Test Suite FAQ](https://www.w3.org/XML/Test/faq.html#copyright) repeats this grant and states that published contributions use that license.

The applicable [W3C Software Notice and License](https://www.w3.org/Consortium/Legal/copyright-software-19980720) permits use, copying, modification, and distribution without fee. Redistribution has three conditions:

1. Include the full license notice in a location visible to users.
2. Preserve all existing intellectual-property notices, disclaimers, and terms.
3. Identify each change to a W3C file and give the change date.

The license also prohibits unauthorized trademark use in advertising. It provides the work without warranty.

Some older files contain separate Sun Microsystems and OASIS copyright notices. The public manifest and DTD show these notices directly. Preserve them with the W3C license. Do not replace them with one repository-wide SPDX line.

The XML Recommendation has separate document terms. Section 1.1 permits free distribution only when all text and legal notices remain intact. This recommendation does not require a local copy of the specification.

**Redistribution status:** local vendoring is permitted if the repository keeps the full 1998 W3C license, all file notices, and a dated modification record. An unmodified archive plus a separate generated manifest gives the clearest provenance.

## Local-ingestion recommendation

Do not add corpus bytes during this research pass. Use this procedure in a later ingestion change:

1. Fetch `xmlts20130923.tar.gz` from the dated W3C URL.
2. Record the URL, release date, byte length, and a locally computed SHA-256 digest in the corpus lock data.
3. Extract the unchanged `xmlconf/` tree under `tests/corpora/xml/w3c-xmlts-20130923/`.
4. Add the full 1998 W3C license and preserve every embedded contributor notice.
5. Parse the suite and collection manifests. Resolve all relative references inside the corpus root.
6. Reject absolute paths and paths that escape the corpus root. Disable network access for external system identifiers.
7. Preserve each test as raw bytes. Do not decode and re-encode UTF-16 or legacy encoding cases.
8. Select XML 1.0 cases by `RECOMMENDATION`. Exclude XML 1.1 and namespace-only collections from the base XML gate.
9. For Fifth Edition, include cases with no `EDITION` restriction or with edition 5. Exclude cases restricted to editions 1 through 4.
10. Run `valid` and `invalid` cases as accept cases for a non-validating Stage 2 parser.
11. Run `not-wf` cases as reject cases when their required entity mode is supported.
12. Keep `error` and unsupported external-entity cases in a reported skip set. Do not count them as passes.
13. Compare `OUTPUT` files only after Stage 2 exposes the required normalized data and entity-expansion behavior.

Keep the W3C test ID, collection profile, source URI, recommendation, edition, section, type, and entity mode in each local case record. These fields make failures reproducible and prevent ID collisions across collections.

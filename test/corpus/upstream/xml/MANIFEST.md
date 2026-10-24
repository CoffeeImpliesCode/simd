# W3C XML corpus reference

No upstream archive or payloads are vendored in this directory.

- Suite: W3C XML Conformance Test Suite, `xmlts20130923`.
- Archive: <https://www.w3.org/XML/Test/xmlts20130923.tar.gz>.
- Length: `641522` bytes.
- SHA-256: `9b61db9f5dbffa545f4b8d78422167083a8568c59bd1129f94138f936cf6fc1f`.
- Catalog: `xmlconf/xmlconf.xml`.
- License: [W3C Software Notice and License, 20 July 1998](https://www.w3.org/Consortium/Legal/copyright-software-19980720).

Redistributed files must retain the full W3C license and all embedded Sun, OASIS, W3C, and contributor notices.
Modified fixtures require a description and date of each change.
Do not use contributor or W3C names for endorsement.

The local parser covers UTF-8 XML 1.0 without DTDs, DOCTYPE declarations, namespace processing, or declared entity expansion.
Cases that depend on other encodings, XML 1.1, DTD validation, or external entities do not establish support for this subset.
Tests must not access the network. They use checked-in files only and do not resolve external entities.

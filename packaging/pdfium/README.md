# PDF seeking

PDFium 8076's `CPDF_Document::TraversePDFPages` walks every preceding leaf
when locating a page. With remote files, each dictionary read can fetch another
64 KiB block. Opening page 471 of Aljam3 file 8291 transferred 7,320,430 bytes
of an 8,500,078-byte PDF in the unpatched runtime.

`skip-page-branches.patch` skips unvisited `/Pages` branches using their positive
`/Count`, following the same principle as PDF.js's page lookup. Because skipped
leaves are no longer cached, a backward lookup restarts traversal when needed.
Rendering, HTTP response validation, the bounded byte cache, and explicit
offline downloads are unchanged. Missing or nonpositive counts retain traversal.

The patch includes a native regression for skipped branches and mixed forward
and backward navigation. The application test renders a generated 128-page
tree over HTTP and checks page pixels and a 1 MiB transfer budget per jump.
The live smoke and packaged-runtime checks also open pages 104 and 471 of the
reported book with fresh caches, compare against a local reference, and enforce
that budget. Full reference downloads belong only to these test helpers.

`bin/build-pdfium` pins the PDFium, build-script, and depot-tools revisions.
PDFium's DEPS pins its transitive build dependencies. The built library's version
includes a fingerprint of the builder and patch; CI caches it using the same
inputs. Initial compilation needs Git, Python, a C/C++ build environment, Bash,
and (on Linux) pkg-config. Subsequent setup runs reuse the compiled library.

Measure cold seeks independently of the full-download verification with
`mise run benchmark-pdf -- 3435 8291 104 471`. Each page starts with empty byte
and image caches, reports transferred bytes and time, then verifies a cached
reread. This benchmark only requests PDF ranges.

PDF.js references inspected at commit
[`7445074`](https://github.com/mozilla/pdf.js/tree/7445074a761d7d4697370546fc32f53b5620d4b2):

- [`Catalog.getPageDict`](https://github.com/mozilla/pdf.js/blob/7445074a761d7d4697370546fc32f53b5620d4b2/src/core/catalog.js): caches page references and skips branches using `/Count`.
- [`ChunkedStreamManager`](https://github.com/mozilla/pdf.js/blob/7445074a761d7d4697370546fc32f53b5620d4b2/src/core/chunked_stream.js): deduplicates and groups missing ranges; optional background prefetch.
- [`getDocument` options](https://github.com/mozilla/pdf.js/blob/7445074a761d7d4697370546fc32f53b5620d4b2/src/display/api.js): defaults to 64 KiB chunks; both `disableAutoFetch` and `disableStream` must be true to prevent background fetching. Aljam3's web viewer sets both.

Range requests alone do not guarantee small transfers. Flat page trees, damaged
indexes, large images, or shared resources can still require more bytes. The
reader does not start a background download or accept a host's full HTTP 200
response in place of a requested range.

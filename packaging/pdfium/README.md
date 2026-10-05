# PDFium patches

## Failed stream reads

`handle-stream-read-errors.patch` makes `CPDF_SyntaxParser::ReadStream` return
an error when the file-access callback cannot read a stream's bytes. PDFium
8076 otherwise calls `CHECK(did_read)` and terminates the process. Online
reading can reach this check when navigation cancels a page load or an HTTP
range request fails while reading an embedded image. Ruby's callback catches
the exception and returns failure, but cannot handle a native process trap.

Returning `nullptr` preserves the read validator's error and lets the native
call finish. Aljam3's existing `FileAccess#check!` then raises the original
cancellation or connection error in Ruby, and its render cleanup runs normally.
Cancelled requests are discarded by the reader's existing request checks.

The native regression covers failed stream reads with valid, missing, and
incorrect length declarations. Application regressions cancel or interrupt a
multi-block image read, verify that failed pages are not cached, and compare a
successful retry with a local render. They run in child processes so a native
crash is reported as a test failure without killing the test runner.

`bin/verify-package` repeats the read-failure regressions through the relocated
app's launcher and bundled Ruby/PDFium. It also runs 20 reader stress cycles:
close a book, switch books, turn pages rapidly, and change zoom while an image
read is paused inside PDFium. Each cycle verifies cancellation and compares the
final displayed page and zoom with local reference pixels. These deterministic
checks use a local HTTP range server, without downloading any live books.

The PDF verification report records the loaded library path, SHA-256, patch
fingerprint, app revision, runtime and OS. An outdated patch fingerprint fails
verification. CI repeats the PDF checks against the **same archived Mac app** on
macOS 26, after its full macOS 15 checks. To run only these checks on an existing
`dist/Aljam3.app` (or Windows `dist/Aljam3`), use `ruby bin/verify-package --pdf-only`.
The source UI stress check is `mise exec -- bundle exec ruby bin/verify-ui pdf`.

## Page seeking

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
includes a fingerprint of the builder and all patches; CI caches it using the same
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

`zz-page-index-prefetch.patch` exposes optional byte-offset hints for unresolved
top-level page dictionaries in flat trees. The reader fetches up to 128 distinct
64 KiB blocks through four independent, validated HTTP connections before the
normal page traversal. Already parsed dictionaries and cached blocks are skipped.
The hints never select pages or replace PDFium's traversal, so irregular trees
and missing hints retain the normal parser behavior. Compressed dictionary
objects also retain the normal path. No image streams are deliberately prefetched
by this index step. It uses the existing 8 MiB byte cache, and failed/cancelled
batches publish no partial results or leave live connections behind.

This addresses the same scattered top-level dictionary reads that PDF.js requests
concurrently. A generated 96-page, 18 MiB image PDF exercises this path with
40 ms of latency per request; correctness checks compare distant and reversed
seeks with local page pixels. `mise run verify-scroll` accepts
`ALJAM3_BENCHMARK_PDF=/nonexistent` to use this generated fixture.

Range requests alone do not guarantee small transfers. Very large flat trees,
damaged indexes, large images, or shared resources can still require more bytes. The
reader does not start a background download or accept a host's full HTTP 200
response in place of a requested range.

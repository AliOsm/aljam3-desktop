# PDFium patches

`bin/build-pdfium` pins PDFium, its build scripts, and depot tools. Its version fingerprint includes the builder and these patches, so setup rebuilds when they change.

- `handle-stream-read-errors.patch`: return an error when an HTTP read fails or is cancelled, allowing Ruby to handle it without a native crash.
- `skip-page-branches.patch`: skip unrelated page-tree branches during distant seeks; restart traversal when needed for backward navigation.
- `zz-page-index-prefetch.patch`: expose page-dictionary offsets for bounded concurrent fetching of flat indexes. PDFium still validates and selects each page.

```sh
mise exec -- bundle exec ruby bin/verify-ui pdf
mise run verify-scroll
mise run benchmark-pdf -- 3435 8291 104 471
```

`ruby bin/verify-package --pdf-only` checks an existing package. Verification covers failed reads, cancellation, page pixels, navigation, zoom, and online/offline scrolling. Online reading uses byte ranges; explicit downloads save complete PDFs.

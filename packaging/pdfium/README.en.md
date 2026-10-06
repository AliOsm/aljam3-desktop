<p align="center" dir="ltr">
  <a href="README.md">العربية</a> · <a href="README.en.md">English</a>
</p>

# PDFium patches

`bin/build-pdfium` pins PDFium, its build scripts, and depot tools. The version fingerprint includes the build script and these patches, so changes trigger a rebuild.

- `handle-stream-read-errors.patch`: Returns an error when an HTTP read fails or is cancelled, allowing Ruby to handle it without crashing the native engine.
- `skip-page-branches.patch`: Skips unrelated page-tree branches during distant seeks and restarts traversal when needed to return to earlier pages.
- `zz-page-index-prefetch.patch`: Exposes page-dictionary offsets for bounded concurrent fetching of flat indexes. PDFium remains responsible for validating and selecting each page.

```sh
mise exec -- bundle exec ruby bin/verify-ui pdf
mise run verify-scroll
mise run benchmark-pdf -- 3435 8291 104 471
```

`ruby bin/verify-package --pdf-only` checks an existing package. Tests cover failed reads, cancellation, page images, navigation, zoom, and scrolling online and offline. Online reading uses byte ranges, while explicit downloads save complete PDF files.

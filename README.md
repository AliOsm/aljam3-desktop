# الجامع · Aljam3 Desktop

An Arabic desktop library built with Ruby and Scarpe's native renderer. Browse [aljam3.com](https://aljam3.com), download books, and read and search them without an internet connection.

The interface follows [aljam3-web-app](https://github.com/ieasybooks/aljam3-web-app)'s light design system: terracotta primary color, warm neutral borders, top navigation, and bordered book cards. Its logo, Noto Naskh Arabic UI, Cairo, and Kitab fonts are bundled locally; see [asset provenance](assets/README.md).

## Run

Install [mise](https://mise.jdx.dev), Git, curl, tar, and a C/C++ build toolchain. On macOS, install Xcode Command Line Tools. Linux needs a graphical desktop for the app window; previews and tests run headlessly.

```sh
cd aljam3-desktop
mise trust
mise install
mise run setup
mise run start
```

Setup fetches the pinned Scarpe source, applies the included native input, button, and Windows/clipboard patches, installs the Ruby bundle, compiles the native renderer, and installs checksum-verified PDFium and Arabic tokenizer binaries. The first build takes a few minutes. Mise manages Ruby 3.4.7, Rust 1.98.1, and `sqlite-tokenizer-ar` 0.1.13.

The dependency releases cover Linux x64/arm64 with glibc, macOS Apple silicon, and Windows x64. Standalone test packages target Apple silicon Macs and Windows x64. Use a window of at least 800 × 700 for the current layout.

## Using the library

- **المكتبة**: browse books, filter by category, or search titles and page text.
- **تنزيل الكتاب**: save every PDF volume and its searchable page text. Progress appears under **التنزيلات**. Failed downloads can be retried.
- **كتبي المحمّلة**: browse and filter the books stored on this device.
- **قراءة / عرض الصفحة**: open a book or a search result with its text on the left and original PDF on the right. **جنبًا إلى جنب**, **PDF**, and **النص** select the reading view. Both panes follow the same page and volume, scroll independently, and work offline. The PDF initially fits the whole page. Zoom or drag a larger page, change volumes, or jump using Arabic, Persian, or Western page numbers. Reading position is saved per book. **رجوع** restores the previous results and scroll position.
- **Text controls**: change the font size independently of PDF zoom, toggle **تشكيل**, or copy the displayed text with the copy icon. The icon confirms a successful copy. Layout, text size, and tashkeel preferences are remembered.
- **بحث في الكتاب**: search within the open book using the API, with SQLite fallback when offline. Ctrl-F (Cmd-F on macOS) opens book search; Escape returns to the reader. In the library, the same shortcut focuses the main search input.

PDF pages are rendered inside Scarpe with PDFium. Text comes from the API and remains available alongside the original PDF. This reader provides page images and a text pane; it does not provide PDF annotations or text selection directly on the page image.

## Online and offline search

Every library search tries the API first. A connection failure switches that request to SQLite over **completed downloads only**. The next search tries the API again, so reconnecting needs no manual toggle. HTTP errors also permit local results, with a distinct service-unavailable label. An empty successful API response stays empty.

Offline full-text search uses SQLite FTS5 with [sqlite-tokenizer-ar](https://github.com/yshalsager/sqlite-tokenizer-ar): Arabic normalization, light stemming, and Arabic/Persian digit folding. Common words are retained. Query words are safely quoted, prefix-matched, and combined with AND; advanced Lucene query syntax is not implemented locally. SQLite ranks results and produces excerpts around matching text. Online and offline rankings can differ.

Previously browsed catalog entries and categories are cached. Offline browsing can show that cached catalog, but offline title and content searches only return downloaded books. The app does not mirror the entire remote catalog.

Downloads use temporary files, fetch text in batches, and validate PDF responses and page counts before publishing a book as available offline. Partial books never appear in offline search. Retrying an interrupted download starts that book again. API calls are spaced to respect the documented 60 requests/minute limit within this app process.

## Development

```sh
mise run test      # Minitest; no internet or display needed
mise run test-native # native input, buttons, keyboard, accessibility, and rendering
mise run smoke    # live catalog, sample book, offline search, PDF rendering
mise run peek     # native screenshot and layout, without opening a window
```

The smoke check downloads book 1 if it is not already under `.cache/smoke`. It then simulates an unreachable API to verify SQLite fallback and renders a real PDF page. To repeat the actual download, use an empty smoke directory.

`peek` forwards Scarpe's inspection arguments. It uses a scratch HOME, scratch app data, and Scarpe's fake clipboard/dialog commands. Screenshots and preview data stay under ignored `.cache/`.

```sh
mise run peek -- --size 800x700 --wait 5 --shot .cache/compact.png --a11y

# Use the downloaded smoke book and force the API connection to fail.
ALJAM3_DATA_DIR="$PWD/.cache/smoke" ALJAM3_API_URL=http://127.0.0.1:1 \
  mise run peek -- --wait 2 --shot .cache/offline.png
```

Tests cover API preference and reconnection, offline-only download filtering, Arabic search, index migration, failed-download cleanup, HTTP failures, and mapping search results to the correct volume and saved reading position.

## Code layout

| File | Responsibility |
| --- | --- |
| `app.rb`, `lib/aljam3/ui.rb`, `lib/aljam3/ui/` | UI lifecycle, shared components, catalog, reader, and scoped search |
| `lib/aljam3/api.rb`, `http.rb` | API requests, throttling, and streaming HTTP downloads |
| `lib/aljam3/library.rb` | API-first queries and local fallback |
| `lib/aljam3/store.rb`, `schema.sql`, `migrations/` | Catalog, pages, FTS index, and preferences |
| `lib/aljam3/downloader.rb` | Complete-book download lifecycle |
| `lib/aljam3/pdf.rb` | Small PDFium FFI binding and bounded render cache |
| `lib/aljam3/worker.rb` | Background work with callbacks delivered on the UI thread |

Scarpe is pinned in `bin/setup`. [The source patch](patches/scarpe-input-alignment.patch) adds `align: "left" / "center" / "right"` to its native `EditLine`. Search and list filters use right alignment; Arabic shaping and bidirectional text remain handled by the native text engine. Text, caret, selection, and mouse coordinates share the same alignment, and long queries scroll horizontally. Setup applies the patch once and refuses conflicting changes; rerunning it is safe. The patch includes native regression tests and can be removed when the feature is available upstream.

The Gemfile uses Lacci and Scarpe components directly from that checkout. No webview or local web server is needed.

[The button patch](patches/scarpe-button-variants.patch) adds flat solid, outline, and ghost variants to the native button renderer, preserving keyboard, hover, focus, and disabled behavior. Icon buttons use their tooltip as an accessible name. Both source patches include native regression checks and apply idempotently during setup; there are no runtime monkey patches or simulated controls.

## Desktop test packages

Download the ZIP for your machine from [Releases](https://github.com/AliOsm/aljam3-desktop/releases). These packages include Ruby, the native renderer, PDFium, SQLite, the Arabic tokenizer, and app assets. Ruby, mise, and developer tools are not needed to run them.

- **Apple silicon (M1 or newer), macOS 13+:** extract `Aljam3-0.1.0-macos-arm64.zip`, move `Aljam3.app` to Applications, and open it. The test app is ad-hoc signed and not notarized. If macOS blocks the first launch, use **System Settings → Privacy & Security → Open Anyway**, then confirm.
- **Windows x64:** extract the entire `Aljam3-0.1.0-windows-x64.zip` and open `Aljam3/Aljam3.exe`. Keep the accompanying files with the executable. The test executable is unsigned; SmartScreen may require **More info → Run anyway**.

The [packaging workflow](.github/workflows/packages.yml) builds on native macOS arm64 and Windows x64 runners. Before archiving, it relocates the app to a directory with spaces and launches its bundled runtime headlessly. Checks exercise HTTPS, a real downloaded book, SQLite/Arabic search, Arabic input, clipboard, and the PDF/text reader. Verification reports and screenshots are saved with the build artifacts. These automated checks do not replace interactive testing on users' desktops.

To build on either target platform after setup:

```sh
mise run test
mise run smoke
mise run package
mise exec -- ruby bin/verify-package
mise exec -- ruby bin/archive-package
```

The Windows package uses a small native launcher and a source patch for Scarpe's Windows process handling and native clipboard. The macOS bundle uses an ad-hoc code signature. Public distribution with a verified publisher would additionally need platform signing credentials and macOS notarization.

## Local data

Linux: `${XDG_DATA_HOME:-~/.local/share}/aljam3`.

macOS: `~/Library/Application Support/Aljam3`.

Windows: `%LOCALAPPDATA%/Aljam3`.

Each directory contains `library.sqlite3`, `books/<book-id>/<file-id>.pdf`, and a bounded `renders/` cache. `ALJAM3_DATA_DIR` overrides the location. `ALJAM3_API_URL` overrides the API host for development. Setup and standalone packages include the Arabic tokenizer; development runs can override its path with `SQLITE_TOKENIZER_AR_EXTENSION`.

Startup logs are at `~/Library/Logs/Aljam3/launcher.log` on macOS and `%LOCALAPPDATA%/Aljam3/launcher.log` on Windows.

The initial Unicode-only database schema migrates transactionally to the Arabic tokenizer and rebuilds the index from saved text. Books and reading positions are preserved.

## Sources and attribution

- [Aljam3 API documentation](https://aljam3.com/api-docs/index.html)
- [Scarpe agent guide](https://github.com/scarpe-team/scarpe/blob/main/FOR_AGENTS.md)
- [sqlite-tokenizer-ar](https://github.com/yshalsager/sqlite-tokenizer-ar), Apache-2.0; see its included third-party notices for Lucene and stopwords.
- [PDFium binaries](https://github.com/bblanchon/pdfium-binaries), release `chromium/8076`; licenses are included under `vendor/pdfium` by setup.
- Design and logo from [aljam3-web-app](https://github.com/ieasybooks/aljam3-web-app).
- Noto Naskh Arabic UI, Cairo, and Kitab fonts from the web app, with SIL Open Font Licenses under `assets/fonts/`.

# الجامع · Aljam3 Desktop

An Arabic desktop library built with Ruby and Scarpe's native renderer. Browse [aljam3.com](https://aljam3.com), download books, and read and search them without an internet connection.

The interface follows [aljam3-web-app](https://github.com/ieasybooks/aljam3-web-app)'s light and dark design systems: terracotta primary colors, warm neutral surfaces, top navigation, and bordered book cards. Typography follows the FAQ app: Thmanyah for headings, Noto Naskh Arabic UI for controls, and Kitab for reading. Fonts and the Aljam3 logo are bundled locally; see [asset provenance](assets/README.md).

Pages share content boundaries and grid gutters, including forms and scrolling lists. Reading panels and book cards align their measured content within each row, retaining full titles. Focus outlines remain inside controls, including dialogs. A compact bottom bar shows connection status throughout the app, including the reader.

Filters open in a compact popup beside their button, with searchable library/category lists and an author picker. Search, bookmark, and export dialogs reserve space for their current contents; empty states stay small, while long lists have bounded scrolling.

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

- **الرئيسية / التصنيفات / المؤلفون / الكتب**: discover libraries and categories, browse authors and their books, or search the catalog. Category and author names on book cards are links.
- **تابع القراءة**: the home screen resumes your latest book and lists recent reading. Positions, progress, and bookmarks survive restarting the app and removing downloaded copies.
- **Search**: switch between **النصوص** and **العناوين**, or open **المؤلفون** to search by author. The filter popup offers library, category, and author selection. Text search combines all three; the current API supports only one scope at a time for title browsing. Author-name search uses the authors endpoint. Previous/next controls keep each screen to one page of results, and excerpts can be expanded.
- **قراءة / عرض الصفحة**: read online without downloading a whole volume. Text loads one page at a time; PDFium seeks through HTTP byte ranges to fetch the PDF structures and page content it needs. There is no background full-PDF download. Online search responses omit volume IDs, so the reader verifies the page ID against the book's volumes before opening a result.
- **تنزيل الكتاب**: saves every PDF volume and its searchable page text. The download queue survives closing the app. Pause, resume, retry, or cancel transfers under **التنزيلات والمساحة**, with sizes and progress. Filter unfinished or completed downloads, remove a downloaded copy, or clear temporary page images to reclaim space.
- **Reader**: text is on the **right** and the PDF on the **left**, matching the Arabic web UI. Drag the divider to choose their widths. The toolbar selects text, PDF, or both panes. Reading options hold text size, the web app's tashkeel control, and split presets. The tools menu groups bookmarks, PDF/TXT/DOCX exports, sharing, saving a page image, and keyboard help. Copy text and fit/zoom/pan the PDF as before.
- **Navigation**: type Arabic, Persian, or Western page digits and press Enter. Invalid numbers produce inline feedback. Choose a volume from an anchored popover; global navigation remains visible in the reader. The book's reading position and reader preferences are saved. Returning to the catalog restores the results and scroll position.
- **بحث في الكتاب**: search in a dialog over the reader using the API, with SQLite fallback for downloaded books. Ctrl-F (Cmd-F on macOS) opens it; Escape closes it. In the library, the shortcut focuses the main search input.
- **Reader shortcuts**: Left/Page Down advances, Right/Page Up goes back, Home/End selects the first/last page of the volume, Ctrl/Cmd-J focuses the page number, and Ctrl/Cmd-D toggles a bookmark. Search results highlight normalized matching words in the reader; F3 and Shift-F3 move between matches **on the current page**. Escape clears highlighting. Use book search to find other matching pages.
- **Appearance**: the initial theme follows the operating system where available. The sun/moon button switches between Aljam3's light and dark palettes and saves your choice. Document scans retain their original colors.

PDF pages are rendered inside Scarpe with PDFium. Online reading caches up to 8 MiB of PDF chunks for each of three recent volumes and 50 text pages in memory; these never enter the offline search index. Cached chunks are reused when paging and zooming, and disappear when the app exits. PDF layout affects how much data a page needs. A host that ignores byte ranges produces an explanation, never an automatic full download. Explicit book downloads and PDF exports still save complete files. Only explicitly downloaded books are guaranteed to remain readable and searchable offline.

The interface is currently Arabic-only. Web features still outside this implementation include popular-book carousels, image cropping/copying to the clipboard, and account UI. The API does not expose the web homepage's curated/popular lists. PDF annotations and direct text selection on the rendered PDF image are not supported.

## Online and offline search

**كل المكتبة** searches the API first. A connection failure switches that request to SQLite over **completed downloads only**. The next search tries the API again, so reconnecting needs no manual toggle. **كتبي المحمّلة** explicitly searches only SQLite, even online. HTTP errors also permit local results, with a distinct service-unavailable label. An empty successful API response stays empty.

Offline full-text search uses SQLite FTS5 with [sqlite-tokenizer-ar](https://github.com/yshalsager/sqlite-tokenizer-ar): Arabic normalization, light stemming, and Arabic/Persian digit folding. Common words are retained. Query words are safely quoted, prefix-matched, and combined with AND; advanced Lucene query syntax is not implemented locally. SQLite ranks results and produces excerpts around matching text. Online and offline rankings can differ.

**Offline relevance uses a bounded pool:** matching and all filters run first, then the first 10,000 eligible pages in rowid order are ranked with BM25 in a temporary FTS5 index. Queries with at most 10,000 matches include every match. Broader queries show a lower-bound count and **البحث في المزيد**, which adds another 10,000 candidates and reranks the expanded pool. The temporary index reuses the same Arabic tokenizer; ranking statistics are local to the pool. A more relevant page outside the pool can be missed. The optional library-order sort remains uncapped.

The pool and ranked IDs are cached until the query, scope, pool size, or database version changes. Expansion reuses already indexed candidates. Only the visible result page's text is loaded into Ruby. A two-character prefix index accelerates short Arabic stems. Search and indexing run in separate Ruby processes, and replacing a running search cancels it. Page reads use an independent connection; no search transaction remains open between requests.

Downloads are queued in SQLite and listed in pages of 12. The app keeps only the current transfer in memory, and storage totals use saved PDF sizes rather than walking the book directories. Catalog filters and downloaded-author lookups have dedicated indexes. New databases use 16 KiB pages to pack OCR text more tightly; upgrades preserve the existing page size and do not vacuum a user's entire library. See `bench/` for reproducible scale measurements.

Previously browsed catalog entries, categories, libraries, and author metadata are cached. Browsing immediately shows cached books while refreshing in the background. Availability labels distinguish online books from complete downloads; the bottom status bar reports the last API request's status and offers reconnection. Offline browsing can show the cached catalog, but offline title and content searches only return downloaded books. The app does not mirror the entire remote catalog.

Downloads use temporary files, fetch text in batches, and validate PDF responses and page counts before publishing a book as available offline. Partial books never appear in offline search. Retrying reuses completed volumes and indexed batches. Partial PDFs resume with HTTP Range/If-Range when the server provides a validator; otherwise that PDF restarts safely. A changed file manifest restarts the affected book. Pausing takes effect at the next chunk or batch boundary. API calls are spaced to respect the documented 60 requests/minute limit within this app process.

### Accepted offline search decision

Accepted on October 2, 2026 and implemented in 0.1.5. This supersedes exhaustive offline relevance ranking; online search is unchanged.

- Apply the existing Arabic query matching and all selected book, author, category, and library filters to completed downloads before selecting candidates.
- Collect an initial pool of up to **10,000 matching pages** in deterministic library order, then rank only that pool. Queries with fewer matches include every matching page.
- Use a temporary SQLite FTS index with the existing Arabic tokenizer to keep scoring and its statistics within the selected pool. Its scores and ordering may differ from whole-library BM25. A final SQL `LIMIT` on the existing exhaustive ranked query is insufficient.
- Cache the pool and ranked result IDs so pagination remains stable for an unchanged query, scope, and indexed library. Invalidate the cached search when its underlying content or eligibility changes.
- Indicate when additional matches exist and explain that relevance covers the selected pool. Offer **Search more** to expand the pool and rerank; expansion can change the result order. The action is **البحث في المزيد**, in increments of 10,000 pages, in both catalog and book search.
- Preserve online API search and the optional library-order sort.

The accepted tradeoff is that a more relevant page outside the pool can be missed, and deterministic selection can favor particular books or collections. Keyword matching stays unchanged; global relevance coverage is relaxed. The reproducible comparison covers 2K, 5K, and 10K pools; see [measurements and limitations](bench/README.md). These timings do not establish a latency guarantee or human relevance quality.

## Development

```sh
mise run test      # Minitest; no internet or display needed
mise run test-native # native input, buttons, keyboard, accessibility, and rendering
mise run smoke    # live catalog, sample book, offline search, PDF rendering
mise run peek     # native screenshot and layout, without opening a window
mise run verify-ui # live online/offline reading and native UI integration checks
mise run verify-layout # deterministic alignment and focus checks, light/dark, 800/1160px
```

The smoke check downloads book 1 if it is not already under `.cache/smoke`. It then simulates an unreachable API to verify SQLite fallback and renders a real PDF page. It also renders distant pages using HTTP ranges, verifies identical pixels to the local PDF, measures transferred bytes, and checks that cached pages need no new requests. To repeat the actual download, use an empty smoke directory.

`peek` forwards Scarpe's inspection arguments. It uses a scratch HOME, scratch app data, and Scarpe's fake clipboard/dialog commands. Screenshots and preview data stay under ignored `.cache/`.

```sh
mise run peek -- --size 800x700 --wait 5 --shot .cache/compact.png --a11y

# Use the downloaded smoke book and force the API connection to fail.
ALJAM3_DATA_DIR="$PWD/.cache/smoke" ALJAM3_API_URL=http://127.0.0.1:1 \
  mise run peek -- --wait 2 --shot .cache/offline.png
```

Tests cover API preference and reconnection, explicit local scope, Arabic search and highlight offsets, schema migration, durable reading/bookmarks, queued transfers, pause/cancel/restart, ranged downloads, and exact volume/page resolution. The live headless UI check starts with an empty scratch library, verifies online reading, exercises RTL panes and dialogs at 800 × 700, then checks offline search, keyboard navigation, divider dragging, bookmarks, Continue reading, and download removal. It also checks typing during background refresh, anchored popups, focus return, Arabic page entry, and validation. It saves screenshots under `.cache/preview/parity/`.

## Code layout

| File | Responsibility |
| --- | --- |
| `app.rb`, `lib/aljam3/ui.rb`, `lib/aljam3/ui/` | UI lifecycle, shared components, catalog, reader, and scoped search |
| `lib/aljam3/api.rb`, `http.rb` | API requests, throttling, and streaming HTTP downloads |
| `lib/aljam3/library.rb` | API-first queries and local fallback |
| `lib/aljam3/store.rb`, `store/`, `schema.sql`, `migrations/` | Catalog, FTS index, reading history, bookmarks, and durable queue |
| `lib/aljam3/downloads.rb`, `downloader.rb`, `reading.rb` | Queue lifecycle, resumable downloads, and temporary online reading |
| `lib/aljam3/pdf.rb`, `remote_pdf.rb` | PDFium file/range callbacks, bounded chunk cache, and rendered page cache |
| `lib/aljam3/worker.rb` | Background work with callbacks delivered on the UI thread |

Scarpe is pinned in `bin/setup`. The [UI source patch](patches/scarpe-ui.patch) adds RTL rows and scrollbars, centered row alignment, input placeholders and focus notifications, aligned menu buttons, flat button variants, theme-aware disabled controls, and accessible names for icon buttons and search fields. Arabic shaping, caret movement, selection, and mouse coordinates remain native. The patch combines the earlier input/button patches and includes native regression checks; setup applies it idempotently and refuses conflicting source changes. The [reading patch](patches/scarpe-reading.patch) fixes native RTL span highlights and adds theme colors and RTL fill to progress bars, with pixel regression checks. The UI patch also adds measured row height groups, bidirectional column stretching, and inset focus outlines. Layout checks use mixed title lengths and missing metadata at 1160 × 820 and 800 × 700 in both themes, with focus pixel checks at 1×, 1.25×, and 2×. These run against the packaged runtime as well; source screenshots are saved under `.cache/preview/alignment/`. There are no runtime monkey patches or webviews.

The Gemfile uses Lacci and Scarpe directly from that checkout. No local web server is needed.

## Desktop test packages

Test files are shared directly or downloaded from private build artifacts. Publishing a release is a separate step that requires an explicit request. These packages include Ruby, the native renderer, PDFium, SQLite, the Arabic tokenizer, and app assets. Ruby, mise, and developer tools are not needed to run them.

- **Apple silicon (M1 or newer), macOS 13+:** extract `Aljam3-0.1.8-macos-arm64.zip`, move `Aljam3.app` to Applications, and open it. The test app is ad-hoc signed and not notarized. If macOS blocks the first launch, use **System Settings → Privacy & Security → Open Anyway**, then confirm.
- **Windows x64 installer:** run `Aljam3-0.1.8-windows-x64-setup.exe`. It installs for your user without administrator access, adds a Start menu shortcut, and offers an optional desktop shortcut. Windows Settings can uninstall it. Downloads and reading positions stay in `%LOCALAPPDATA%/Aljam3` through upgrades and uninstalling.
- **Windows x64 portable ZIP:** extract the entire `Aljam3-0.1.8-windows-x64.zip` and open `Aljam3/Aljam3.exe`. Keep the accompanying files with the executable. Windows test executables are unsigned; SmartScreen may require **More info → Run anyway**.

The [packaging workflow](.github/workflows/packages.yml) builds on native macOS arm64 and Windows x64 runners. Before archiving, it relocates the app to a directory with spaces and launches its bundled runtime headlessly. Checks exercise HTTPS, a real downloaded book, SQLite/Arabic search, Arabic input, clipboard, and the PDF/text reader. Verification reports and screenshots are saved with the build artifacts. These automated checks do not replace interactive testing on users' desktops.

To build on either target platform after setup:

```sh
mise run test
mise run smoke
mise run package
mise exec -- ruby bin/verify-package
mise exec -- ruby bin/archive-package
```

Build the Windows package from an x64 Visual Studio developer shell with the Windows SDK resource compiler (`rc.exe`) available. The launcher embeds the same white app icon used by the installer and shortcuts.

On Windows, install [Inno Setup 6](https://jrsoftware.org/isinfo.php), then run `mise run installer` to wrap `dist/Aljam3` in a single setup executable. `ISCC` can override the compiler path. The manual [installer workflow](.github/workflows/windows-installer.yml) can reuse a previously verified Windows ZIP and checks silent installation, shortcuts, the installed runtime, in-place upgrade, uninstall, and preservation of downloaded books. It only uploads test artifacts.

The Windows package uses a small native launcher and a source patch for Scarpe's Windows process handling and native clipboard. The macOS bundle uses an ad-hoc code signature. Public distribution with a verified publisher would additionally need platform signing credentials and macOS notarization.

Packaging also applies [Ruby OpenSSL's upstream CRL fix](https://github.com/ruby/openssl/pull/950) to the pinned portable runtime. Certificate and hostname verification remain enabled.

On macOS, setup compiles the pinned tokenizer release for macOS 13 because its upstream binary declares macOS 26 as its minimum. The extension uses the SQLite instance supplied by the app's bundled gem.

## Local data

Linux: `${XDG_DATA_HOME:-~/.local/share}/aljam3`.

macOS: `~/Library/Application Support/Aljam3`.

Windows: `%LOCALAPPDATA%/Aljam3`.

Each directory contains `library.sqlite3`, `books/<book-id>/<file-id>.pdf`, and a bounded `renders/` cache. `ALJAM3_DATA_DIR` overrides the location. `ALJAM3_API_URL` overrides the API host for development. Setup and standalone packages include the Arabic tokenizer; development runs can override its path with `SQLITE_TOKENIZER_AR_EXTENSION`.

Startup logs are at `~/Library/Logs/Aljam3/launcher.log` on macOS and `%LOCALAPPDATA%/Aljam3/launcher.log` on Windows.

Database migrations run transactionally. Older libraries gain Arabic search, recent reading, bookmarks, and the persistent queue while preserving downloaded books and reading positions. The 0.1.4 upgrade rebuilds the search index once to add short-prefix indexing; an already large library will take longer on its first launch after upgrading.

## Sources and attribution

- [Aljam3 API documentation](https://aljam3.com/api-docs/index.html)
- [Scarpe agent guide](https://github.com/scarpe-team/scarpe/blob/main/FOR_AGENTS.md)
- [sqlite-tokenizer-ar](https://github.com/yshalsager/sqlite-tokenizer-ar), Apache-2.0; see its included third-party notices for Lucene and stopwords.
- [PDFium binaries](https://github.com/bblanchon/pdfium-binaries), release `chromium/8076`; licenses are included under `vendor/pdfium` by setup.
- Design and logo from [aljam3-web-app](https://github.com/ieasybooks/aljam3-web-app).
- Noto Naskh Arabic UI and Kitab use SIL Open Font Licenses; Thmanyah has its own license. All are retained under `assets/fonts/`.

# الجامع · Aljam3 Desktop

An Arabic desktop library for [aljam3.com](https://aljam3.com), built with Ruby and [Scarpe](https://github.com/scarpe-team/scarpe). Browse books, read PDFs and text, and download books for offline reading and search.

Pre-launch version: **0.0.1**. Packages support Apple silicon Macs (macOS 13+) and Windows 10/11 x64, including Windows 11 ARM through emulation.

## Run from source

Install [mise](https://mise.jdx.dev), Git, curl, Python, and a C/C++ toolchain. macOS needs Xcode Command Line Tools; Windows needs Visual Studio C++ tools and Git Bash; Linux needs pkg-config.

```sh
mise trust
mise install
mise run setup
mise run start
```

Setup installs pinned dependencies and builds the native renderer and PDFium. The first build takes longer. The interface is Arabic; development on Linux requires a graphical desktop to open the window.

## Development

```sh
mise run test          # Application tests
mise run test-native   # Native renderer tests
mise run verify-ui     # Reader and UI integration checks
mise run verify-scroll # PDF scrolling and pinch zoom
mise run package      # Standalone app, on macOS or Windows
mise run installer    # Windows installer; requires Inno Setup 6
mise run clean        # Remove builds, reports, and scratch data
```

GitHub builds run manually. Temporary artifacts expire after one day; delete test runs after review and publish approved builds through GitHub Releases. Performance tools live in [bench/](bench/README.md); PDFium patch notes are in [packaging/pdfium/](packaging/pdfium/README.md).

## Installation and data

On Mac, extract the ZIP and move `Aljam3.app` to Applications. The app is ad-hoc signed without notarization; macOS may require **Privacy & Security → Open Anyway**. On Windows, run the installer or extract the entire portable ZIP. Windows executables are unsigned and may trigger SmartScreen.

Books, settings, and reading positions are stored outside the app:

- macOS: `~/Library/Application Support/Aljam3`
- Windows: `%LOCALAPPDATA%/Aljam3`
- Linux: `${XDG_DATA_HOME:-~/.local/share}/aljam3`

`ALJAM3_DATA_DIR` overrides this location. Offline reading and search require completed downloads. Offline relevance ranks an initial pool of 10,000 matching pages; **البحث في المزيد** expands it, so results can differ from online search.

Assets and licenses are documented in [assets/](assets/README.md). Setup retains the licenses for [PDFium](https://pdfium.googlesource.com/pdfium/) and [sqlite-tokenizer-ar](https://github.com/yshalsager/sqlite-tokenizer-ar) under `vendor/`.

<p align="center" dir="ltr">
  <a href="README.md">العربية</a> · <a href="README.en.md">English</a>
</p>

# Aljam3 Desktop

An Arabic app for the [Aljam3 library](https://aljam3.com), built with Ruby and [Scarpe](https://github.com/scarpe-team/scarpe). Browse books, search their titles and text, read PDFs alongside text, and download books or an entire category for offline reading and search.

Supports Apple silicon Macs running macOS 13 or later, Windows 10 and 11 x64, and Windows 11 ARM through emulation.

## Download and installation

Packages are available on the [releases page](https://github.com/ieasybooks/aljam3-desktop/releases).

- **Mac:** Open the DMG, drag the app into Applications, then launch it from there. The app is not notarized by Apple; you may need to select **Open Anyway** under **System Settings → Privacy & Security**.
- **Windows:** Run the EXE installer. SmartScreen may display a warning because the app is not signed with a developer certificate.

The app checks for updates daily and downloads them in the background after verifying their digital signatures. Open **Settings** (the gear icon) to check manually or select **Restart and update** (إعادة التشغيل والتحديث). Books, settings, and reading positions are preserved.

Settings also shows the library folder and its size. **Move library** transfers books, the search index, bookmarks, and reading positions to an empty folder on your computer or an external drive. Keep that drive connected while using the app.

## Running from source

Install [mise](https://mise.jdx.dev), Git, curl, Python, and C/C++ tools. Mac requires Xcode Command Line Tools; Windows requires Visual Studio C++ tools and Git Bash; Linux requires pkg-config.

```sh
mise trust
mise install
mise run setup
mise run start
```

Setup installs pinned dependencies and builds the native renderer and PDFium, so the first run takes longer. Opening the app on Linux requires a graphical desktop environment.

## Development and releases

```sh
mise run test          # Application tests
mise run test-native   # Native renderer tests
mise run verify-ui     # Reader and UI tests
mise run verify-scroll # Scrolling and pinch zoom tests
mise run package       # Build the app on Mac or Windows
mise run installer     # Create the Windows installer; requires Inno Setup 6
mise run dmg           # Create a DMG from the built app
mise run clean         # Remove packages, reports, and temporary data
```

To prepare a release, update `lib/aljam3/version.rb`, then manually run **Build packages** in GitHub Actions. Choose `draft` in the `release` field to prepare a draft after platform checks pass, or `publish` to publish directly. Temporary Actions artifacts expire after one day; delete test runs after reviewing them.

Update metadata is signed using the `UPDATE_PRIVATE_KEY` repository secret. Keep an independent backup of the private key; the public key is in `packaging/update-public.pem`. Mac uses [Sparkle](https://sparkle-project.org) for updates, while Windows uses the installer with a recovery copy of the previous app.

Performance tools are in [bench/](bench/README.en.md), and PDFium patches are described in [packaging/pdfium/](packaging/pdfium/README.en.md).

## Data and offline use

Books, settings, and reading positions are stored outside the app directory:

- Mac: `~/Library/Application Support/Aljam3`
- Windows: `%LOCALAPPDATA%/Aljam3`
- Linux: `${XDG_DATA_HOME:-~/.local/share}/aljam3`

You can change this location using `ALJAM3_DATA_DIR`. Offline reading and search require completed downloads. Local search ranks the first 10,000 matching pages and expands the search when you select **Search more** (البحث في المزيد), so results may differ from online search.

Sources and licenses for graphics and fonts are documented in [assets/](assets/README.en.md). Setup retains the licenses for [PDFium](https://pdfium.googlesource.com/pdfium/) and [sqlite-tokenizer-ar](https://github.com/yshalsager/sqlite-tokenizer-ar) under `vendor/`.

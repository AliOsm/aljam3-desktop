# Aljam3 design assets

Imported from [ieasybooks/aljam3-web-app](https://github.com/ieasybooks/aljam3-web-app/tree/be4bb9f39ad926d1f36a1f5d974df38193586b39). The desktop app uses its light and dark design systems.

- `brand/aljam3.svg`: the original path and viewBox from `app/components/aljam3_logo.rb`, with `currentColor` resolved to the primary color, `#ae4721`.
- `brand/aljam3.png`: a transparent 732 × 576 rasterization of that SVG for Scarpe's native image widget, generated with CairoSVG. The vector source is retained.
- `brand/app-icon.svg`, `brand/app-icon.png`: the original logo centered on a white rounded tile, rendered at 1024 pixels for the macOS app icon.
- `brand/aljam3.ico`: the white app tile rendered at 16, 24, 32, 48, 64, 128, and 256 pixels for the Windows executable, installer, and shortcuts.
- `fonts/NotoNaskhArabicUI.ttf`: an unchanged copy of `app/assets/fonts/NotoNaskhArabicUI[wght].ttf`, used for controls and interface text.
- `fonts/Cairo.ttf`: `Cairo-arabic.woff2`, decompressed to TrueType for headings.
- `fonts/Kitab.ttf`: `Kitab-Base-Regular.woff2`, decompressed to TrueType for excerpts and page text.
- `icons/`: [Lucide 0.468.0](https://github.com/lucide-icons/lucide/tree/0.468.0/icons), matching the web app's icon library. The original SVG paths are retained, with `currentColor` set to `#4e3f3b`. PNG copies at 48 × 48 are rasterized with CairoSVG for native controls; the app displays them at 16 × 16. The ISC license is in `icons/LICENSE`.
- `icons/filled-shaddah*` and `icons/dotted-shaddah*`: the web app's custom tashkeel icons from `app/components/custom_icons/`, with their original paths and viewBox. Light and dark variants follow the same color treatment as the other controls.

The WOFF2 fonts were decompressed with FontTools (`font.flavor = None; font.save(...)`). These are bundled assets; Python and conversion tools are not application dependencies. Font copyrights and licenses are retained in `fonts/OFL.txt`, `fonts/OFL-Cairo.txt`, and `fonts/OFL-Kitab.txt`.

`lib/aljam3/ui/theme.rb` contains both web palettes, converted from OKLCH to sRGB. The `-dark.svg` variants resolve the same vector paths to the dark palette (white icons, `#e16e4a` logo); their PNGs are rasterized from those vectors. Document PDF images are left unchanged. The desktop layout follows its top navigation, bordered cards, separated metadata footers, and muted author/category labels. Controls keep Scarpe's native interaction and rendering.

# Aljam3 design assets

Imported from [ieasybooks/aljam3-web-app](https://github.com/ieasybooks/aljam3-web-app/tree/be4bb9f39ad926d1f36a1f5d974df38193586b39). The desktop app uses its light design system.

- `brand/aljam3.svg`: the original path and viewBox from `app/components/aljam3_logo.rb`, with `currentColor` resolved to the primary color, `#ae4721`.
- `brand/aljam3.png`: a transparent 732 × 576 rasterization of that SVG for Scarpe's native image widget, generated with CairoSVG. The vector source is retained.
- `fonts/NotoNaskhArabicUI.ttf`: an unchanged copy of `app/assets/fonts/NotoNaskhArabicUI[wght].ttf`, used for controls and interface text.
- `fonts/Cairo.ttf`: `Cairo-arabic.woff2`, decompressed to TrueType for headings.
- `fonts/Kitab.ttf`: `Kitab-Base-Regular.woff2`, decompressed to TrueType for excerpts and page text.
- `icons/`: [Lucide 0.468.0](https://github.com/lucide-icons/lucide/tree/0.468.0/icons), matching the web app's icon library. The original SVG paths are retained, with `currentColor` set to `#4e3f3b`. PNG copies at 48 × 48 are rasterized with CairoSVG for native controls; the app displays them at 16 × 16. The ISC license is in `icons/LICENSE`.

The WOFF2 fonts were decompressed with FontTools (`font.flavor = None; font.save(...)`). These are bundled assets; Python and conversion tools are not application dependencies. Font copyrights and licenses are retained in `fonts/OFL.txt`, `fonts/OFL-Cairo.txt`, and `fonts/OFL-Kitab.txt`.

`lib/aljam3/ui/theme.rb` contains the web app's light OKLCH tokens converted to sRGB. The desktop layout follows its top navigation, bordered cards, separated metadata footers, and muted author/category labels. Controls keep Scarpe's native interaction and rendering.

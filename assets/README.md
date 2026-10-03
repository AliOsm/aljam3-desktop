# Aljam3 design assets

Imported from [ieasybooks/aljam3-web-app](https://github.com/ieasybooks/aljam3-web-app/tree/be4bb9f39ad926d1f36a1f5d974df38193586b39). The desktop app uses its light and dark design systems.

- `brand/aljam3.svg`: the original path and viewBox from `app/components/aljam3_logo.rb`, with `currentColor` resolved to the primary color, `#ae4721`.
- `brand/aljam3.png`: a transparent 732 × 576 rasterization of that SVG for Scarpe's native image widget, generated with CairoSVG. The vector source is retained.
- `brand/app-icon.svg`, `brand/app-icon.png`: the original logo centered on a white rounded tile, rendered at 1024 pixels for the macOS app icon.
- `brand/aljam3.ico`: the white app tile rendered at 16, 24, 32, 48, 64, 128, and 256 pixels for the Windows executable, installer, and shortcuts.
- Typography matches [ieasybooks/faqieh-web-app](https://github.com/ieasybooks/faqieh-web-app/tree/cc1c9e0e22ee729f39bab45c6af34abd1f204d8d): Noto Naskh Arabic UI for controls, Thmanyah Serif Display Medium for headings, and Kitab for book text and excerpts.
- `fonts/NotoNaskhArabicUI.ttf`, `fonts/Kitab.ttf`: the FAQ app's `NotoNaskhArabicUI.woff2` and `Kitab-Regular.woff2`, decompressed for the native renderer.
- `fonts/Thmanyah.ttf`: the FAQ app's `ThmanyahSerifDisplay-Medium.woff2`, version 1.003, at its native weight of 500. The official source is [Thmanyah's specimen asset](https://framerusercontent.com/assets/ahIxG21c1088n0jA0bPQBjKu6M.woff2), SHA-256 `ef836058036ef2760e12af676b7fe0377f7401aed4fa94c6df1247ad17cd54f2`. Only the WOFF2 container is decompressed; names, outlines, and license metadata are retained. Its custom license is in `fonts/Thmanyah-license.txt`. These are private evaluation builds; this does not establish clearance for public font distribution.
- `icons/`: [Lucide 0.468.0](https://github.com/lucide-icons/lucide/tree/0.468.0/icons), matching the web app's icon library. The original SVG paths are retained, with `currentColor` set to `#4e3f3b`. PNG copies at 48 × 48 are rasterized with CairoSVG for native controls; the app displays them at 16 × 16. The ISC license is in `icons/LICENSE`.
- `icons/filled-shaddah*` and `icons/dotted-shaddah*`: the web app's custom tashkeel icons from `app/components/custom_icons/`, with their original paths and viewBox. Light and dark variants follow the same color treatment as the other controls.

The WOFF2 fonts were decompressed with FontTools (`recalcTimestamp=False; font.flavor = None; font.save(...)`). These are bundled assets; Python and conversion tools are not application dependencies. Noto and Kitab copyrights and licenses are retained in `fonts/OFL.txt` and `fonts/OFL-Kitab.txt`.

`lib/aljam3/ui/theme.rb` contains both web palettes, converted from OKLCH to sRGB. The `-dark.svg` variants resolve the same vector paths to the dark palette (white icons, `#e16e4a` logo); their PNGs are rasterized from those vectors. Document PDF images are left unchanged. The desktop layout follows its top navigation, bordered cards, separated metadata footers, and muted author/category labels. Controls keep Scarpe's native interaction and rendering.

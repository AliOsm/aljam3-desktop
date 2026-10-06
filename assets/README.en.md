<p align="center" dir="ltr">
  <a href="README.md">العربية</a> · <a href="README.en.md">English</a>
</p>

# Graphics and font sources

- Logo and tashkeel icons: [aljam3-web-app](https://github.com/ieasybooks/aljam3-web-app/tree/be4bb9f39ad926d1f36a1f5d974df38193586b39). Original SVG files are retained, and PNG versions are used in the interface. The app icon is the logo on a white background.
- Fonts: [faqieh-web-app](https://github.com/ieasybooks/faqieh-web-app/tree/cc1c9e0e22ee729f39bab45c6af34abd1f204d8d). WOFF2 files were converted to TTF without changing glyph outlines or license metadata.
- Noto Naskh Arabic UI and Kitab: SIL Open Font Licenses are retained in `fonts/OFL.txt` and `fonts/OFL-Kitab.txt`.
- Thmanyah Serif Display Medium, version 1.003: [official file](https://framerusercontent.com/assets/ahIxG21c1088n0jA0bPQBjKu6M.woff2), SHA-256 `ef836058036ef2760e12af676b7fe0377f7401aed4fa94c6df1247ad17cd54f2`. Redistribution permission remains unresolved; embedded license metadata is retained.
- Standard icons: [Lucide 0.468.0](https://github.com/lucide-icons/lucide/tree/0.468.0/icons), with the ISC license retained in `icons/LICENSE`.

Light and dark mode colors follow the website palette in `lib/aljam3/ui/theme.rb`. PNGs are generated from the SVG files using CairoSVG; the app does not require conversion tools at runtime.

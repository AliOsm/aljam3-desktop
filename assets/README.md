# Asset provenance

- Logo and custom tashkeel icons: [aljam3-web-app](https://github.com/ieasybooks/aljam3-web-app/tree/be4bb9f39ad926d1f36a1f5d974df38193586b39). SVG sources are retained; PNGs are rasterized for native controls, and the app icon uses the logo on a white tile.
- Typography: [faqieh-web-app](https://github.com/ieasybooks/faqieh-web-app/tree/cc1c9e0e22ee729f39bab45c6af34abd1f204d8d). WOFF2 files were decompressed to TTF without changing outlines or license metadata.
- Noto Naskh Arabic UI and Kitab: SIL Open Font Licenses in `fonts/OFL.txt` and `fonts/OFL-Kitab.txt`.
- Thmanyah Serif Display Medium, version 1.003: [official specimen asset](https://framerusercontent.com/assets/ahIxG21c1088n0jA0bPQBjKu6M.woff2), SHA-256 `ef836058036ef2760e12af676b7fe0377f7401aed4fa94c6df1247ad17cd54f2`. Redistribution permission remains unresolved; embedded license metadata is retained.
- Standard icons: [Lucide 0.468.0](https://github.com/lucide-icons/lucide/tree/0.468.0/icons), ISC license in `icons/LICENSE`.

Light/dark colors follow the web palette in `lib/aljam3/ui/theme.rb`. PNGs are generated from the retained SVG sources with CairoSVG; conversion tools are not runtime dependencies.

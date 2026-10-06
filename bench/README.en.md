<p align="center" dir="ltr">
  <a href="README.md">العربية</a> · <a href="README.en.md">English</a>
</p>

# Performance tools

Run these tools against temporary test data under `.cache/benchmark`, and avoid using them on your personal library.

```sh
mise run benchmark-data
mise run benchmark -- --prepare --pages 100000 --path .cache/benchmark/library.sqlite3
mise exec -- bundle exec ruby bench/limited.rb .cache/benchmark/library.sqlite3 .cache/benchmark/search.json
mise run benchmark-pdf -- 3435 8291 104 471
mise run verify-scroll
```

Test data repeats samples of OCR text with unique numeric suffixes. It measures query behavior and resource use, not the quality of results for readers or real-world search speed. Creating large samples can take hours and consume substantial disk space.

Local search ranks the first 10,000 matching pages and expands the search on request. `limited.rb` measures this search, while the other scripts examine indexing, excerpts, prefixes, and test data generation. The token-cache extension is only used to accelerate test data generation.

Keep reports under `.cache/benchmark`. The `mise run clean` command removes test data and reports.

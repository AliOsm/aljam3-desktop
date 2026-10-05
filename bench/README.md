# Performance tools

Run against disposable fixtures under `.cache/benchmark`, never a personal library.

```sh
mise run benchmark-data
mise run benchmark -- --prepare --pages 100000 --path .cache/benchmark/library.sqlite3
mise exec -- bundle exec ruby bench/limited.rb .cache/benchmark/library.sqlite3 .cache/benchmark/search.json
mise run benchmark-pdf -- 3435 8291 104 471
mise run verify-scroll
```

Search fixtures repeat sampled public OCR with unique numeric suffixes. They measure query behavior and resource use, not human relevance or real-world latency. Creating large fixtures can take hours and substantial disk space.

Offline relevance ranks the first 10,000 eligible matching pages and expands on request. `limited.rb` measures this search; the other scripts diagnose indexing, excerpts, prefixes, and fixture generation. The token-cache extension is only a fixture-generation accelerator.

Keep reports in `.cache/benchmark`. `mise run clean` removes fixtures and reports.

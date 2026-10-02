# Library scale measurements

These scripts use disposable databases under `.cache/benchmark`. They never need the user's downloaded PDFs or app data directory.

## Workload

The public source indexes contain **63,535 entries and 37,610,673 pages** across the Prophet Mosque, Shamela/Waqfeya, and Waqfeya collections. This is a workload envelope, not an exact current API catalog count. `prepare.rb` saves the source URLs and SHA-256 checksums, samples eight text volumes from distinct categories in each collection, and retains the actual catalog titles, authors, and categories.

The 24 sampled volumes contain 7,031 pages (6,827 distinct texts), averaging 2,097 UTF-8 bytes per page. `library.rb` repeats them deterministically, appends a unique numeric token to each page, and distributes the requested number of pages across the catalog. Book/page associations and PDF byte counts are synthetic. No PDFs are fetched. This exercises large posting lists and all catalog entries, but is not the full unique corpus and does not measure human relevance judgments. Real OCR vocabulary, book lengths, topic distribution, hardware, and PDFs will change the timings and disk requirements.

## Reproduce

```sh
mise run benchmark-data
mise run benchmark -- --prepare --pages 1000000 --label baseline
mise run benchmark -- --label repeat

# Use a separate path for a different target size.
mise run benchmark -- --prepare --pages 37610673 \
  --path .cache/benchmark/full/library.sqlite3 --label full-scale
```

Creation can take hours. It commits completed books incrementally, can resume the same marked fixture, and stops if less than 8 GiB remains free on the host. Reports and progress logs belong in `.cache/benchmark`; copy the final small reports to `bench/results` when documenting a comparison. A changed target page count requires a fresh fixture path.

Measurements use the actual `Store` and its worker processes. Each timed search evicts the small result cache first without restarting the worker; the cache-hit measurement is reported separately. OS/database cache state is not forced cold. Three repetitions report first, median, and maximum latency. Linux runs also sample combined parent/child RSS and a 20 ms Ruby heartbeat. The heartbeat demonstrates process isolation, not native frame-rate performance. Native interactions are checked separately with `mise run verify-ui` and the packaged runtime probes.

## Experiments

- `prefix.rb [database] [prefix-lengths]` adds `trial_fts` to a **disposable fixture**, rebuilds it, compares ranking and index size, and leaves it for further inspection. Do not reuse an existing trial table with different prefix lengths.
- `indexing.rb` compares normal Arabic indexing with 8/64 MiB writer caches and different FTS merge settings, using fresh scratch databases and 100,000 real sample pages. It does not use the token cache below.
- The 100,000-page storage trial used 298.6 MB at 4 KiB SQLite pages, 253.9 MB at 8 KiB, and 233.7 MB at 16 KiB (page text and page-number index). New app databases use 16 KiB; existing libraries retain their page size.

Measurements on an Intel i5-8500, 16 GiB RAM, SSD, Ruby 3.4.7, and SQLite 3.53.2 showed these warm medians at 1,000,000 pages / 63,535 books. Raw reports: [baseline](results/baseline-1m.json), [optimized](results/optimized-1m.json).

| Operation | Original | Optimized |
|---|---:|---:|
| Catalog page 1 | 49.81 ms | 2.35 ms |
| Catalog page 5000 | 623.59 ms | 6.30 ms |
| Downloaded authors | 756.28 ms | 13.14 ms |
| Downloads screen data | 883.09 ms, all entries | 16.43 ms, 12 entries |
| `الله`, relevance | 3576.04 ms | 1123.03 ms |
| `في`, relevance | 4232.94 ms | 1385.74 ms |
| `العلم العمل`, relevance | 489.12 ms | 221.11 ms |
| `الله`, one book | 2511.07 ms | 31.05 ms |
| Next cached search page | Not cached | 0.84 ms |

The downloads comparison intentionally measures different amounts of UI data: pagination removes the need to load the entire history. Relevance searches still rank the complete matching set. Counts above 1,000 are displayed as lower bounds; this limit does not restrict ranked candidates or navigation.

This fixture has 740,305 matches for `الله`, 887,630 for `في`, 43,678 for `العلم العمل`, and 2,849 for `الزمخشري`. The optimized run sampled about 196 MiB combined parent/worker RSS and a maximum 60 ms heartbeat gap. The old single-process peak was about 507 MiB; the new peak is not just the parent process. These memory figures cover the benchmark driver and SQL workers, excluding the native renderer and PDFs. The upgraded 4 KiB-page fixture occupies 4.13 GB including the added prefix index; new-database storage is measured separately at full scale.

A combined 2/3/4-character prefix index increased FTS data from 594 MB to 1,716 MB while improving broad ranked queries by approximately 15–20%; it was rejected. A subsequent two-character-only index used 1,038 MB and reduced the ranked SQL query within a book from 264 to 29 ms, with identical IDs and ordering. The app adopts this smaller option, which indexes normalized short stems such as the one produced for `الله`. Increasing the writer cache from 8 to 64 MiB had little effect (36.66 vs 36.47 seconds per 100,000 pages). Increasing the merge threshold also offered only a small improvement in that trial. These observations should not be treated as universal tuning rules.

The full-size measurement is in progress; the one-million-page table above is not evidence of completed full-corpus verification.

## Optional fixture-generation accelerator

`token_cache.cc` is a benchmark-only SQLite extension that caches the upstream Arabic tokenizer's output for repeated sample text. The numeric suffix is still analyzed normally; query and snippet analysis always use the real tokenizer. It is never included in the app or used to report normal indexing throughput.

On Linux, with C++17 and SQLite development headers available:

```sh
c++ -O2 -std=c++17 -shared -fPIC bench/token_cache.cc \
  -o .cache/benchmark/token_cache.so
mise exec -- bundle exec ruby bench/verify_token_cache.rb
mise run benchmark -- --prepare --pages 37610673 \
  --path .cache/benchmark/full/library.sqlite3 --label full-scale \
  --token-cache .cache/benchmark/token_cache.so
```

The verifier compares all term/document/column/position tuples in both directions for every sample, repeated twice. The recorded check covered 14,062 pages and 2,992,680 token occurrences with no differences. After fixture creation, the benchmark reopens the database using the unmodified production tokenizer. For clean runtime RSS measurements, run the read-only benchmark again in a fresh process after generation.

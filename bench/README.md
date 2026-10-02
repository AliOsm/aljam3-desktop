# Library scale measurements

Generation and performance benchmarks use disposable databases under `.cache/benchmark`; small correctness verifiers also use temporary directories. They never need the user's downloaded PDFs or app data directory. Performance runs place SQLite temporary files beside their fixtures, on the SSD used for the measurements.

## Workload

The public source indexes contain **63,535 entries and 37,610,673 pages** across the Prophet Mosque, Shamela/Waqfeya, and Waqfeya collections. This is a workload envelope, not an exact current API catalog count. `prepare.rb` saves the source URLs and SHA-256 checksums, samples eight text volumes from distinct categories in each collection, and retains the actual catalog titles, authors, and categories.

The 24 sampled volumes contain 7,031 pages (6,827 distinct texts), averaging 2,113 UTF-8 bytes per page as split by the fixture generator. `library.rb` repeats them deterministically, appends a unique numeric token to each page, and distributes the requested number of pages across the catalog. Book/page associations and PDF byte counts are synthetic. No PDFs are fetched. This exercises large posting lists and all catalog entries, but is not the full unique corpus and does not measure human relevance judgments. Real OCR vocabulary, book lengths, topic distribution, hardware, and PDFs will change the timings and disk requirements.

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

For a separate Linux cold-start trial, close other connections to the fixture and add `--evict-cache --label cold-start`. This requests `POSIX_FADV_DONTNEED` for that database before opening it; it does not clear global caches or affect other files. Metadata checks precede the first search, and later searches reuse OS caches, so this is not a cold-cache measurement of every operation. The kernel may retain pinned pages despite the request.

## Experiments

- `prefix.rb [database] [prefix-lengths]` adds `trial_fts` to a **disposable fixture**, rebuilds it, compares ranking and index size, and leaves it for further inspection. Do not reuse an existing trial table with different prefix lengths.
- `indexing.rb` compares the previous per-row inserts with production bulk inserts, 8/64 MiB writer caches, and different FTS merge settings, using fresh SSD scratch databases and 100,000 real sample pages. It does not use the token cache below.
- The 100,000-page storage trial used 298.6 MB at 4 KiB SQLite pages, 253.9 MB at 8 KiB, and 233.7 MB at 16 KiB (page text and page-number index). New app databases use 16 KiB; existing libraries retain their page size.

Measurements on an Intel i5-8500, 16 GiB RAM, SSD, Ruby 3.4.7, and SQLite 3.53.2 showed these warm medians at 1,000,000 pages / 63,535 books. Raw reports: [baseline](results/baseline-1m.json), [first optimization](results/optimized-1m.json), [final query plans](results/optimized-final-1m.json).

| Operation | Original | Optimized |
|---|---:|---:|
| Catalog page 1 | 49.81 ms | 2.45 ms |
| Catalog page 5000 | 623.59 ms | 6.28 ms |
| Downloaded authors | 756.28 ms | 13.55 ms |
| Downloads screen data | 883.09 ms, all entries | 15.25 ms, 12 entries |
| `الله`, relevance | 3576.04 ms | 651.82 ms |
| `في`, relevance | 4232.94 ms | 805.20 ms |
| `العلم العمل`, relevance | 489.12 ms | 226.12 ms |
| `الله`, one book | 2511.07 ms | 31.30 ms |
| Search page 100 | 6572.23 ms | 642.95 ms |
| Next cached search page | Not cached | 0.71 ms |

The downloads comparison intentionally measures different amounts of UI data: pagination removes the need to load the entire history. Relevance searches still rank the complete matching set. Counts above 1,000 are displayed as lower bounds; this limit does not restrict ranked candidates or navigation.

This fixture has 740,305 matches for `الله`, 887,630 for `في`, 43,678 for `العلم العمل`, and 2,849 for `الزمخشري`. The final run sampled about 184 MiB combined parent/worker RSS and a maximum 53 ms heartbeat gap. The old single-process peak was about 507 MiB; the new peak is not just the parent process. These memory figures cover the benchmark driver and SQL workers, excluding the native renderer and PDFs. The upgraded 4 KiB-page fixture occupied 4.13 GB after adding the prefix index; subsequent disposable index trials left some free pages in the final report. New-database storage is measured separately at full scale.

For dense unfiltered searches, explicit `ORDER BY bm25(), rowid` retains the best IDs while scoring every match, then fetches their text and excerpts in one bounded FTS scan. This avoids the FTS rank cursor's complete internal sort. A density estimate from the count probe chooses the query plan only, never the candidate set. Sparse or scoped searches keep the rank cursor, which avoids a second prefix scan. If any indexed book is incomplete, filtering remains inside the ranked query. Both plans run in a single read transaction; completing or removing a download invalidates cached results and density metadata.

A combined 2/3/4-character prefix index increased FTS data from 594 MB to 1,716 MB while improving broad ranked queries by approximately 15–20%; it was rejected. A subsequent two-character-only index used 1,038 MB and reduced the ranked SQL query within a book from 264 to 29 ms, with identical IDs and ordering. The app adopts this smaller option, which indexes normalized short stems such as the one produced for `الله`.

The final [SSD indexing trial](results/indexing-ssd.json) took 50.31 seconds for the previous per-row inserts and 33.24 seconds for bulk insertion of the same 100,000 pages: about 34% less time. Both produced 74,043 matches and the same leading results. The app now binds up to 500 pages into each insert statement, retaining the surrounding transaction, duplicate handling, and file bounds. A failed batch rolls back before retrying. These timings exclude HTTP transfer and worker IPC, and the full fixture was being generated concurrently. Larger writer caches and a higher merge threshold did not improve this trial enough to adopt them. Earlier indexing microbenchmarks used `/tmp`, which is RAM-backed on this host; the final comparison uses SSD files and supersedes those timings.

The full-size measurement is in progress; the one-million-page table above is not evidence of completed full-corpus verification.

## Optional fixture-generation accelerator

`token_cache.cc` is a benchmark-only SQLite extension that caches the upstream Arabic tokenizer's output for repeated sample text. The numeric suffix is still analyzed normally; query and snippet analysis always use the real tokenizer. It is never included in the app or used to report normal indexing throughput. With this option, `bulk_pages.rb` also generates repeated content through SQL, using the normal insert trigger, one transaction per book, a 256 MiB writer cache, a 16,384-page WAL checkpoint threshold, and `synchronous=NORMAL`. These generation settings do not change the production app's settings.

On Linux, with C++17 and SQLite development headers available:

```sh
c++ -O2 -std=c++17 -shared -fPIC bench/token_cache.cc \
  -o .cache/benchmark/token_cache.so
mise exec -- bundle exec ruby bench/verify_token_cache.rb
mise exec -- bundle exec ruby bench/verify_bulk_pages.rb
mise run benchmark -- --prepare --pages 37610673 \
  --path .cache/benchmark/full/library.sqlite3 --label full-scale \
  --token-cache .cache/benchmark/token_cache.so
```

The tokenizer verifier compares all term/document/column/position tuples in both directions for every sample, repeated twice. The recorded check covered 14,062 pages and 2,992,680 token occurrences with no differences. The bulk verifier compares page text, file bounds, and every term position against normal Ruby insertion. After fixture creation, the benchmark reopens the database using the unmodified production tokenizer. For clean runtime RSS measurements, run the read-only benchmark again in a fresh process after generation.

`check_library.rb [database]` verifies SQLite integrity, expected full match counts calculated independently from the sample cycle, selected book scopes, ranking across the result-cache boundary, cancellation, and page reads during a broad search. It refuses incomplete fixtures.

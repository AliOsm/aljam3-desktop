// Fixture-generation helper only. Cache the real Arabic tokenizer's output for
// repeated OCR samples; the final unique numeric line is still tokenized normally.
// Query and auxiliary tokenization always use the real tokenizer. This does not
// measure indexing throughput and is never shipped with the application.
#include <sqlite3ext.h>
SQLITE_EXTENSION_INIT1
#include <algorithm>
#include <cstdlib>
#include <string>
#include <unordered_map>
#include <vector>

namespace {
struct Token { int flags, start, end; std::string text; };
struct Source { void *context; fts5_tokenizer methods; };
struct Cache {
  Source *source;
  Fts5Tokenizer *original;
  std::unordered_map<std::string, std::vector<Token>> texts;
};
using Emit = int (*)(void *, int, const char *, int, int, int);
int create(void *context, const char **args, int count, Fts5Tokenizer **out) {
  auto *cache = new Cache{static_cast<Source *>(context), nullptr, {}};
  int rc = cache->source->methods.xCreate(cache->source->context, args, count, &cache->original);
  if (rc != SQLITE_OK) { delete cache; return rc; }
  *out = reinterpret_cast<Fts5Tokenizer *>(cache);
  return SQLITE_OK;
}
void destroy(Fts5Tokenizer *tokenizer) {
  auto *cache = reinterpret_cast<Cache *>(tokenizer);
  cache->source->methods.xDelete(cache->original);
  delete cache;
}
int collect(void *context, int flags, const char *text, int length, int start, int end) {
  static_cast<std::vector<Token> *>(context)->push_back({flags, start, end, std::string(text, length)});
  return SQLITE_OK;
}
struct Offset { void *context; Emit emit; int offset; };
int shifted(void *context, int flags, const char *text, int length, int start, int end) {
  auto *offset = static_cast<Offset *>(context);
  return offset->emit(offset->context, flags, text, length, start + offset->offset, end + offset->offset);
}
int tokenize(Fts5Tokenizer *tokenizer, void *context, int flags, const char *text, int length, Emit emit) {
  auto *cache = reinterpret_cast<Cache *>(tokenizer);
  int boundary = length;
  while (boundary > 0 && text[boundary - 1] >= '0' && text[boundary - 1] <= '9') --boundary;
  if (flags != FTS5_TOKENIZE_DOCUMENT || boundary == length || boundary == 0 || text[boundary - 1] != '\n') {
    return cache->source->methods.xTokenize(cache->original, context, flags, text, length, emit);
  }
  auto [it, added] = cache->texts.try_emplace(std::string(text, boundary));
  if (added) {
    int rc = cache->source->methods.xTokenize(cache->original, &it->second, flags, text, boundary, collect);
    if (rc != SQLITE_OK) return rc;
  }
  for (const auto &token : it->second) {
    int rc = emit(context, token.flags, token.text.data(), token.text.size(), token.start, token.end);
    if (rc != SQLITE_OK) return rc;
  }
  Offset offset{context, emit, boundary};
  return cache->source->methods.xTokenize(cache->original, &offset, flags, text + boundary, length - boundary, shifted);
}
}
extern "C" int sqlite3_tokencache_init(sqlite3 *db, char **, const sqlite3_api_routines *api) {
  SQLITE_EXTENSION_INIT2(api);
  const char *original = std::getenv("ALJAM3_BENCH_TOKENIZER");
  if (!original) return SQLITE_MISUSE;
  int rc = sqlite3_load_extension(db, original, nullptr, nullptr);
  if (rc != SQLITE_OK) return rc;
  fts5_api *fts = nullptr;
  sqlite3_stmt *statement = nullptr;
  rc = sqlite3_prepare_v2(db, "SELECT fts5(?1)", -1, &statement, nullptr);
  if (rc != SQLITE_OK) return rc;
  sqlite3_bind_pointer(statement, 1, &fts, "fts5_api_ptr", nullptr);
  sqlite3_step(statement);
  sqlite3_finalize(statement);
  if (!fts) return SQLITE_ERROR;
  auto *source = new Source{};
  rc = fts->xFindTokenizer(fts, "sqlite_tokenizer_ar", &source->context, &source->methods);
  if (rc != SQLITE_OK) { delete source; return rc; }
  fts5_tokenizer methods{create, destroy, tokenize};
  return fts->xCreateTokenizer(fts, "sqlite_tokenizer_ar", source, &methods, [](void *p) { delete static_cast<Source *>(p); });
}

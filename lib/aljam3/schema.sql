CREATE TABLE IF NOT EXISTS books (
  id INTEGER PRIMARY KEY,
  title TEXT NOT NULL,
  search_title TEXT NOT NULL,
  category_id INTEGER,
  data TEXT NOT NULL,
  downloaded_at TEXT
);

CREATE TABLE IF NOT EXISTS files (
  id INTEGER PRIMARY KEY,
  book_id INTEGER NOT NULL REFERENCES books(id) ON DELETE CASCADE,
  position INTEGER NOT NULL,
  data TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS files_book ON files(book_id, position);

CREATE TABLE IF NOT EXISTS pages (
  id INTEGER PRIMARY KEY,
  file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
  number INTEGER NOT NULL,
  content TEXT NOT NULL,
  UNIQUE(file_id, number)
);

CREATE VIRTUAL TABLE IF NOT EXISTS pages_fts USING fts5(
  content, content = 'pages', content_rowid = 'id',
  tokenize = 'sqlite_tokenizer_ar disable_stopwords'
);
CREATE TRIGGER IF NOT EXISTS pages_insert AFTER INSERT ON pages BEGIN
  INSERT INTO pages_fts(rowid, content) VALUES (new.id, new.content);
END;
CREATE TRIGGER IF NOT EXISTS pages_delete AFTER DELETE ON pages BEGIN
  INSERT INTO pages_fts(pages_fts, rowid, content) VALUES ('delete', old.id, old.content);
END;

CREATE TABLE IF NOT EXISTS preferences (key TEXT PRIMARY KEY, value TEXT NOT NULL);
PRAGMA user_version = 2;

CREATE TABLE books (
  id INTEGER PRIMARY KEY,
  title TEXT NOT NULL,
  search_title TEXT NOT NULL,
  category_id INTEGER,
  data TEXT NOT NULL,
  downloaded_at TEXT
);
CREATE TABLE files (
  id INTEGER PRIMARY KEY,
  book_id INTEGER NOT NULL REFERENCES books(id) ON DELETE CASCADE,
  position INTEGER NOT NULL,
  data TEXT NOT NULL
);
CREATE INDEX files_book ON files(book_id, position);
CREATE TABLE pages (
  id INTEGER PRIMARY KEY,
  file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
  number INTEGER NOT NULL,
  content TEXT NOT NULL,
  search_text TEXT NOT NULL,
  UNIQUE(file_id, number)
);
CREATE VIRTUAL TABLE pages_fts USING fts5(
  search_text, content = 'pages', content_rowid = 'id',
  tokenize = 'unicode61 remove_diacritics 2'
);
CREATE TRIGGER pages_insert AFTER INSERT ON pages BEGIN
  INSERT INTO pages_fts(rowid, search_text) VALUES (new.id, new.search_text);
END;
CREATE TRIGGER pages_delete AFTER DELETE ON pages BEGIN
  INSERT INTO pages_fts(pages_fts, rowid, search_text) VALUES ('delete', old.id, old.search_text);
END;
CREATE TABLE preferences (key TEXT PRIMARY KEY, value TEXT NOT NULL);
PRAGMA user_version = 1;

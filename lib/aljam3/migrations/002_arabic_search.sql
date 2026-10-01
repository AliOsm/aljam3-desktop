DROP TRIGGER pages_insert;
DROP TRIGGER pages_delete;
DROP TABLE pages_fts;
ALTER TABLE pages DROP COLUMN search_text;

CREATE VIRTUAL TABLE pages_fts USING fts5(
  content, content = 'pages', content_rowid = 'id',
  tokenize = 'sqlite_tokenizer_ar disable_stopwords'
);
CREATE TRIGGER pages_insert AFTER INSERT ON pages BEGIN
  INSERT INTO pages_fts(rowid, content) VALUES (new.id, new.content);
END;
CREATE TRIGGER pages_delete AFTER DELETE ON pages BEGIN
  INSERT INTO pages_fts(pages_fts, rowid, content) VALUES ('delete', old.id, old.content);
END;
INSERT INTO pages_fts(pages_fts) VALUES ('rebuild');
PRAGMA user_version = 2;

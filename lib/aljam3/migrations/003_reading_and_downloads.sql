CREATE TABLE reading_history (
  book_id INTEGER PRIMARY KEY REFERENCES books(id),
  file_id INTEGER NOT NULL,
  number INTEGER NOT NULL,
  read_at TEXT NOT NULL
);
INSERT INTO reading_history(book_id, file_id, number, read_at)
  SELECT b.id, json_extract(p.value, '$.file_id'), json_extract(p.value, '$.number'), ''
  FROM preferences p JOIN books b ON p.key = 'reading:' || b.id
  WHERE json_extract(p.value, '$.file_id') IS NOT NULL AND json_extract(p.value, '$.number') IS NOT NULL;

CREATE TABLE bookmarks (
  book_id INTEGER NOT NULL REFERENCES books(id),
  file_id INTEGER NOT NULL,
  number INTEGER NOT NULL,
  excerpt TEXT NOT NULL,
  created_at TEXT NOT NULL,
  PRIMARY KEY(book_id, file_id, number)
);

CREATE TABLE downloads (
  book_id INTEGER PRIMARY KEY REFERENCES books(id),
  state TEXT NOT NULL,
  details TEXT NOT NULL
);
PRAGMA user_version = 3;

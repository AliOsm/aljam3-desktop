CREATE TABLE category_downloads (
  category_id INTEGER PRIMARY KEY,
  name TEXT NOT NULL,
  created_at TEXT NOT NULL
);
CREATE TABLE category_download_books (
  book_id INTEGER PRIMARY KEY REFERENCES books(id),
  category_id INTEGER NOT NULL REFERENCES category_downloads(category_id) ON DELETE CASCADE
);
CREATE INDEX category_download_members ON category_download_books(category_id, book_id);
PRAGMA user_version = 5;

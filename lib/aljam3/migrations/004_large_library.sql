ALTER TABLE books ADD COLUMN author_id INTEGER GENERATED ALWAYS AS (json_extract(data, '$.author.id')) VIRTUAL;
ALTER TABLE books ADD COLUMN library_id INTEGER GENERATED ALWAYS AS (json_extract(data, '$.library.id')) VIRTUAL;
ALTER TABLE books ADD COLUMN download_bytes INTEGER;
UPDATE books SET download_bytes = (SELECT json_extract(details, '$.bytes') FROM downloads WHERE book_id = books.id AND state = 'done');
CREATE INDEX books_title ON books(title, id);
CREATE INDEX books_author ON books(author_id, title, id);
CREATE INDEX books_library ON books(library_id, title, id);
CREATE INDEX books_category ON books(category_id, title, id);
CREATE INDEX books_downloaded ON books(download_bytes) WHERE downloaded_at IS NOT NULL;
CREATE INDEX books_offline_title ON books(title, id) WHERE downloaded_at IS NOT NULL;
CREATE INDEX books_offline_author ON books(author_id) WHERE downloaded_at IS NOT NULL;
ALTER TABLE downloads ADD COLUMN queued_at TEXT GENERATED ALWAYS AS (json_extract(details, '$.queued_at')) VIRTUAL;
CREATE INDEX downloads_state ON downloads(state, queued_at, book_id);
CREATE INDEX reading_recent ON reading_history(read_at DESC, book_id DESC);

CREATE TABLE authors (id INTEGER PRIMARY KEY, name TEXT NOT NULL, search_name TEXT NOT NULL, data TEXT NOT NULL);
CREATE INDEX authors_name ON authors(name, id);

ALTER TABLE files ADD COLUMN first_page_id INTEGER;
ALTER TABLE files ADD COLUMN last_page_id INTEGER;
UPDATE files SET first_page_id = (SELECT min(id) FROM pages WHERE file_id = files.id),
                 last_page_id = (SELECT max(id) FROM pages WHERE file_id = files.id);
PRAGMA user_version = 4;

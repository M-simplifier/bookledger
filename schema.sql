PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS categories (
  name TEXT PRIMARY KEY
);

CREATE TABLE IF NOT EXISTS series (
  title TEXT PRIMARY KEY
);

CREATE TABLE IF NOT EXISTS books (
  id INTEGER PRIMARY KEY,
  title TEXT NOT NULL,
  author TEXT NOT NULL,
  status TEXT NOT NULL CHECK (
    status IN ('unread', 'reading', 'finished', 'disposed')
  ),
  category TEXT NOT NULL REFERENCES categories(name)
    ON UPDATE CASCADE,
  series TEXT REFERENCES series(title)
    ON UPDATE CASCADE,
  volume_no REAL,
  memo TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE UNIQUE INDEX IF NOT EXISTS books_identity_idx
ON books (
  title,
  author,
  COALESCE(series, ''),
  COALESCE(volume_no, -1)
);

INSERT OR IGNORE INTO categories (name) VALUES
  ('未分類'),
  ('小説'),
  ('専門書'),
  ('一般書');

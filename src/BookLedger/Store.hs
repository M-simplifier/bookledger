{-# LANGUAGE OverloadedStrings #-}

module BookLedger.Store
  ( openDb
  , initDb
  , addCategory
  , renameCategory
  , listCategories
  , addSeries
  , renameSeries
  , listSeries
  , insertBook
  , updateBookStatus
  , listBooks
  , integrityCheck
  , vacuumInto
  ) where

import BookLedger.Domain
import Control.Exception (throwIO)
import Data.Maybe (catMaybes)
import Data.Text (Text)
import qualified Data.Text as T
import Database.SQLite.Simple
import System.Directory (createDirectoryIfMissing)
import System.FilePath (takeDirectory)

openDb :: FilePath -> IO Connection
openDb path = do
  createDirectoryIfMissing True (takeDirectory path)
  conn <- open path
  execute_ conn "PRAGMA foreign_keys = ON"
  pure conn

initDb :: Connection -> IO ()
initDb conn = do
  execute_ conn "PRAGMA foreign_keys = ON"
  execute_ conn "CREATE TABLE IF NOT EXISTS categories (name TEXT PRIMARY KEY)"
  execute_ conn "CREATE TABLE IF NOT EXISTS series (title TEXT PRIMARY KEY)"
  execute_ conn "CREATE TABLE IF NOT EXISTS books (id INTEGER PRIMARY KEY, title TEXT NOT NULL, author TEXT NOT NULL, status TEXT NOT NULL CHECK (status IN ('unread', 'reading', 'finished', 'disposed')), category TEXT NOT NULL REFERENCES categories(name) ON UPDATE CASCADE, series TEXT REFERENCES series(title) ON UPDATE CASCADE, volume_no REAL, memo TEXT NOT NULL DEFAULT '', created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP, updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP)"
  execute_ conn "CREATE UNIQUE INDEX IF NOT EXISTS books_identity_idx ON books (title, author, COALESCE(series, ''), COALESCE(volume_no, -1))"
  mapM_ (execute conn "INSERT OR IGNORE INTO categories (name) VALUES (?)" . Only)
    (["未分類", "小説", "専門書", "一般書"] :: [Text])

addCategory :: Connection -> Text -> IO ()
addCategory conn name =
  execute conn "INSERT INTO categories (name) VALUES (?)" (Only (T.strip name))

renameCategory :: Connection -> Text -> Text -> IO ()
renameCategory conn old new =
  execute conn "UPDATE categories SET name = ? WHERE name = ?" (T.strip new, T.strip old)

listCategories :: Connection -> IO [Text]
listCategories conn = do
  rows <- query_ conn "SELECT name FROM categories ORDER BY name" :: IO [Only Text]
  pure (map fromOnly rows)

addSeries :: Connection -> Text -> IO ()
addSeries conn title =
  execute conn "INSERT INTO series (title) VALUES (?)" (Only (T.strip title))

renameSeries :: Connection -> Text -> Text -> IO ()
renameSeries conn old new =
  execute conn "UPDATE series SET title = ? WHERE title = ?" (T.strip new, T.strip old)

listSeries :: Connection -> IO [Text]
listSeries conn = do
  rows <- query_ conn "SELECT title FROM series ORDER BY title" :: IO [Only Text]
  pure (map fromOnly rows)

insertBook :: Connection -> NewBook -> IO Int
insertBook conn book = do
  ensureCategory conn (newCategory book)
  mapM_ (ensureSeries conn) (newSeries book)
  execute conn
    "INSERT INTO books (title, author, status, category, series, volume_no, memo) VALUES (?, ?, ?, ?, ?, ?, ?)"
    ( T.strip (newTitle book)
    , T.strip (newAuthor book)
    , statusText (newStatus book)
    , T.strip (newCategory book)
    , newSeries book
    , newVolumeNo book
    , newMemo book
    )
  fromIntegral <$> lastInsertRowId conn

updateBookStatus :: Connection -> Int -> Status -> IO ()
updateBookStatus conn bookId status =
  execute conn
    "UPDATE books SET status = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?"
    (statusText status, bookId)

listBooks :: Connection -> BookFilter -> IO [Book]
listBooks conn filters =
  map unBookRow <$> query conn (Query sql) params
 where
  parts = catMaybes
    [ fmap (\status -> ("status = ?", [SQLText (statusText status)])) (filterStatus filters)
    , fmap (\category -> ("category = ?", [SQLText category])) (filterCategory filters)
    , fmap (\series -> ("series = ?", [SQLText series])) (filterSeries filters)
    , fmap searchClause (filterSearch filters)
    ]
  clauses = map fst parts
  params = concatMap snd parts
  whereSql =
    if null clauses
      then ""
      else " WHERE " <> T.intercalate " AND " clauses
  sql =
    "SELECT id, title, author, status, category, series, volume_no, memo, created_at, updated_at FROM books"
      <> whereSql
      <> " ORDER BY category, COALESCE(series, title), COALESCE(volume_no, 0), title"
  searchClause value =
    ( "(title LIKE ? OR author LIKE ? OR memo LIKE ?)"
    , replicate 3 (SQLText ("%" <> value <> "%"))
    )

integrityCheck :: Connection -> IO ()
integrityCheck conn = do
  rows <- query_ conn "PRAGMA integrity_check" :: IO [Only Text]
  case rows of
    [Only "ok"] -> pure ()
    _ -> throwIO (userError ("SQLite integrity_check failed: " <> show rows))

vacuumInto :: Connection -> FilePath -> IO ()
vacuumInto conn target =
  execute conn "VACUUM INTO ?" (Only target)

ensureCategory :: Connection -> Text -> IO ()
ensureCategory conn category = do
  rows <- query conn "SELECT 1 FROM categories WHERE name = ? LIMIT 1" (Only (T.strip category)) :: IO [Only Int]
  case rows of
    [_] -> pure ()
    _ -> throwIO (userError ("unknown category: " <> T.unpack category))

ensureSeries :: Connection -> Text -> IO ()
ensureSeries conn seriesTitle = do
  rows <- query conn "SELECT 1 FROM series WHERE title = ? LIMIT 1" (Only (T.strip seriesTitle)) :: IO [Only Int]
  case rows of
    [_] -> pure ()
    _ -> throwIO (userError ("unknown series: " <> T.unpack seriesTitle))

newtype BookRow = BookRow { unBookRow :: Book }

instance FromRow BookRow where
  fromRow = do
    bookId <- field
    title <- field
    author <- field
    statusValue <- field
    category <- field
    seriesTitle <- field
    volumeNo <- field
    memo <- field
    createdAt <- field
    updatedAt <- field
    let status =
          case parseStatus statusValue of
            Just parsed -> parsed
            Nothing -> error ("unknown status in database: " <> T.unpack statusValue)
    pure (BookRow Book
      { bookId = bookId
      , bookTitle = title
      , bookAuthor = author
      , bookStatus = status
      , bookCategory = category
      , bookSeries = seriesTitle
      , bookVolumeNo = volumeNo
      , bookMemo = memo
      , bookCreatedAt = createdAt
      , bookUpdatedAt = updatedAt
      })

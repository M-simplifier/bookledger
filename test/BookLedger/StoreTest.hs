{-# LANGUAGE OverloadedStrings #-}

module BookLedger.StoreTest (tests) where

import BookLedger.Domain
import qualified BookLedger.Store as Store
import BookLedger.TestSupport
import Data.List (sort)
import Data.List.NonEmpty (NonEmpty((:|)))
import Data.Text (Text)
import qualified Data.Text as T
import Database.SQLite.Simple (Only(..), execute, execute_, query_)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "Store"
    [ testCase "initializes a fresh database with default categories" testInitializesDefaults
    , testCase "round-trips every stored book field" testBookRoundTrip
    , testCase "rejects an unknown category without inserting a row" testRejectsUnknownCategory
    , testCase "rejects an unknown series without inserting a row" testRejectsUnknownSeries
    , testCase "rejects duplicate book identities" testRejectsDuplicateIdentity
    , testCase "renaming category and series cascades to books" testRenameCascades
    , testCase "updates, filters, searches, and active ordering agree" testUpdatesAndFilters
    , testCase "batch update changes every editable book field" testBatchUpdateAllFields
    , testCase "batch update rolls back every book when one update fails" testBatchUpdateRollsBack
    , testCase "migrates the legacy schema without losing books" testLegacyMigration
    ]

testInitializesDefaults :: IO ()
testInitializesDefaults =
  withTestConfig 2 $ \cfg ->
    withInitializedConnection cfg $ \conn -> do
      categories <- Store.listCategories conn
      sort categories @?= sort ["未分類", "小説", "専門書", "一般書"]
      Store.integrityCheck conn

testBookRoundTrip :: IO ()
testBookRoundTrip =
  withTestConfig 2 $ \cfg ->
    withInitializedConnection cfg $ \conn -> do
      Store.addSeries conn "新潮文庫"
      insertedId <- Store.insertBook conn sampleBook
      books <- Store.listBooks conn (allBooks SortCatalog)
      case books of
        [book] -> do
          bookId book @?= insertedId
          bookTitle book @?= newTitle sampleBook
          bookAuthor book @?= newAuthor sampleBook
          bookStatus book @?= newStatus sampleBook
          bookCategory book @?= newCategory sampleBook
          bookSeries book @?= newSeries sampleBook
          bookVolumeNo book @?= newVolumeNo sampleBook
          bookMemo book @?= newMemo sampleBook
          bookUrl book @?= newUrl sampleBook
          assertBool "created_at should be populated" (not (T.null (bookCreatedAt book)))
          assertBool "updated_at should be populated" (not (T.null (bookUpdatedAt book)))
        _ -> assertFailure ("expected one book, got " <> show books)

testRejectsUnknownCategory :: IO ()
testRejectsUnknownCategory =
  withTestConfig 2 $ \cfg ->
    withInitializedConnection cfg $ \conn -> do
      assertThrows
        (Store.insertBook conn sampleBook {newCategory = "存在しない", newSeries = Nothing})
      Store.listBooks conn (allBooks SortCatalog) >>= (@?= [])

testRejectsUnknownSeries :: IO ()
testRejectsUnknownSeries =
  withTestConfig 2 $ \cfg ->
    withInitializedConnection cfg $ \conn -> do
      assertThrows
        (Store.insertBook conn sampleBook {newSeries = Just "存在しないシリーズ"})
      Store.listBooks conn (allBooks SortCatalog) >>= (@?= [])

testRejectsDuplicateIdentity :: IO ()
testRejectsDuplicateIdentity =
  withTestConfig 2 $ \cfg ->
    withInitializedConnection cfg $ \conn -> do
      Store.addSeries conn "新潮文庫"
      _ <- Store.insertBook conn sampleBook
      assertThrows (Store.insertBook conn sampleBook)
      books <- Store.listBooks conn (allBooks SortCatalog)
      length books @?= 1

testRenameCascades :: IO ()
testRenameCascades =
  withTestConfig 2 $ \cfg ->
    withInitializedConnection cfg $ \conn -> do
      Store.addSeries conn "新潮文庫"
      _ <- Store.insertBook conn sampleBook
      Store.renameCategory conn "小説" "文学"
      Store.renameSeries conn "新潮文庫" "新潮文庫 改版"
      books <- Store.listBooks conn (allBooks SortCatalog)
      case books of
        [book] -> do
          bookCategory book @?= "文学"
          bookSeries book @?= Just "新潮文庫 改版"
        _ -> assertFailure ("expected one book, got " <> show books)

testUpdatesAndFilters :: IO ()
testUpdatesAndFilters =
  withTestConfig 2 $ \cfg ->
    withInitializedConnection cfg $ \conn -> do
      Store.addSeries conn "新潮文庫"
      readingId <- Store.insertBook conn sampleBook
      _ <- Store.insertBook conn sampleBook
        { newTitle = "未読の本"
        , newStatus = Unread
        , newSeries = Nothing
        , newVolumeNo = Nothing
        }
      _ <- Store.insertBook conn sampleBook
        { newTitle = "購入予定の本"
        , newStatus = Planned
        , newCategory = "一般書"
        , newSeries = Nothing
        , newVolumeNo = Nothing
        }
      Store.updateBookStatus conn readingId Finished
      Store.updateBookMemo conn readingId "更新後のメモ"

      matching <-
        Store.listBooks conn
          BookFilter
            { filterStatus = Just Finished
            , filterCategory = Just "小説"
            , filterSeries = Just "新潮文庫"
            , filterSearch = Just "更新後"
            , filterSort = SortActive
            }
      map bookId matching @?= [readingId]

      active <- Store.listBooks conn (allBooks SortActive)
      map bookStatus active @?= [Unread, Planned, Finished]

testBatchUpdateAllFields :: IO ()
testBatchUpdateAllFields =
  withTestConfig 2 $ \cfg ->
    withInitializedConnection cfg $ \conn -> do
      Store.addSeries conn "新潮文庫"
      Store.addSeries conn "岩波文庫"
      bookId <- Store.insertBook conn sampleBook

      Store.updateBooks conn
        ( BookUpdate
            { bookUpdateId = bookId
            , bookUpdateTitle = "  砂の女 改版  "
            , bookUpdateAuthor = "  安部 公房  "
            , bookUpdateStatus = Finished
            , bookUpdateCategory = "一般書"
            , bookUpdateSeries = Just "岩波文庫"
            , bookUpdateVolumeNo = Just 2.5
            , bookUpdateMemo = "一括更新後\nのメモ"
            , bookUpdateUrl = Just "https://example.com/updated"
            }
        :| []
        )

      books <- Store.listBooks conn (allBooks SortCatalog)
      case books of
        [book] -> do
          bookTitle book @?= "砂の女 改版"
          bookAuthor book @?= "安部 公房"
          bookStatus book @?= Finished
          bookCategory book @?= "一般書"
          bookSeries book @?= Just "岩波文庫"
          bookVolumeNo book @?= Just 2.5
          bookMemo book @?= "一括更新後\nのメモ"
          bookUrl book @?= Just "https://example.com/updated"
        _ -> assertFailure ("expected one updated book, got " <> show books)

testBatchUpdateRollsBack :: IO ()
testBatchUpdateRollsBack =
  withTestConfig 2 $ \cfg ->
    withInitializedConnection cfg $ \conn -> do
      firstId <- Store.insertBook conn sampleBook {newSeries = Nothing, newVolumeNo = Nothing}
      secondId <- Store.insertBook conn sampleBook
        { newTitle = "別の本"
        , newSeries = Nothing
        , newVolumeNo = Nothing
        }
      let updateFor bookId title =
            BookUpdate
              { bookUpdateId = bookId
              , bookUpdateTitle = title
              , bookUpdateAuthor = newAuthor sampleBook
              , bookUpdateStatus = Reading
              , bookUpdateCategory = "小説"
              , bookUpdateSeries = Nothing
              , bookUpdateVolumeNo = Nothing
              , bookUpdateMemo = "更新しない"
              , bookUpdateUrl = Nothing
              }

      assertThrows
        (Store.updateBooks conn
          ( updateFor firstId "重複する本"
          :| [updateFor secondId "重複する本"]
          ))

      books <- Store.listBooks conn (allBooks SortCatalog)
      map bookTitle books @?= ["別の本", newTitle sampleBook]
      map bookMemo books @?= [newMemo sampleBook, newMemo sampleBook]

testLegacyMigration :: IO ()
testLegacyMigration =
  withTestConfig 2 $ \cfg ->
    withConnection cfg $ \conn -> do
      execute_ conn "CREATE TABLE categories (name TEXT PRIMARY KEY)"
      execute_ conn "CREATE TABLE series (title TEXT PRIMARY KEY)"
      execute_ conn "CREATE TABLE books (id INTEGER PRIMARY KEY, title TEXT NOT NULL, author TEXT NOT NULL, status TEXT NOT NULL CHECK (status IN ('unread', 'reading', 'finished', 'disposed')), category TEXT NOT NULL REFERENCES categories(name) ON UPDATE CASCADE, series TEXT REFERENCES series(title) ON UPDATE CASCADE, volume_no REAL, memo TEXT NOT NULL DEFAULT '', created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP, updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP)"
      execute conn "INSERT INTO categories (name) VALUES (?)" (Only ("小説" :: Text))
      execute_ conn "INSERT INTO books (id, title, author, status, category, memo, created_at, updated_at) VALUES (41, '移行前の本', '著者', 'reading', '小説', '保持するメモ', '2024-01-02 03:04:05', '2024-02-03 04:05:06')"

      Store.initDb conn
      Store.integrityCheck conn
      books <- Store.listBooks conn (allBooks SortCatalog)
      case books of
        [book] -> do
          bookId book @?= 41
          bookTitle book @?= "移行前の本"
          bookMemo book @?= "保持するメモ"
          bookUrl book @?= Nothing
          bookCreatedAt book @?= "2024-01-02 03:04:05"
          bookUpdatedAt book @?= "2024-02-03 04:05:06"
        _ -> assertFailure ("expected one migrated book, got " <> show books)

      plannedId <-
        Store.insertBook conn sampleBook
          { newTitle = "移行後の購入予定"
          , newStatus = Planned
          , newSeries = Nothing
          , newVolumeNo = Nothing
          }
      assertBool "planned books should be accepted after migration" (plannedId > 41)
      columns <- query_ conn "PRAGMA table_info(books)" :: IO [(Int, Text, Text, Int, Maybe Text, Int)]
      assertBool "url column should exist after migration" ("url" `elem` [name | (_, name, _, _, _, _) <- columns])
      oldTables <- query_ conn "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'books_old'" :: IO [Only Text]
      oldTables @?= []

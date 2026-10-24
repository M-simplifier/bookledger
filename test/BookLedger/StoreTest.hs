{-# LANGUAGE OverloadedStrings #-}

module BookLedger.StoreTest (tests) where

import BookLedger.Domain
import qualified BookLedger.Store as Store
import BookLedger.TestSupport
import Control.Exception (try)
import Data.List (sort, sortOn)
import Data.List.NonEmpty (NonEmpty((:|)))
import Data.Text (Text)
import qualified Data.Text as T
import Database.SQLite.Simple (Connection, Only(..), execute, execute_, query_)
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
    , testCase "batch identity swaps preserve ids, creation times, and untouched rows" testBatchIdentitySwap
    , testCase "collision with an untouched book rolls back rows and the identity index" testUntouchedIdentityCollision
    , testCase "duplicate or mismatched batch ids leave every book unchanged" testInvalidBatchIds
    , testCase "every editable expected field detects a concurrent change" testExpectedFieldConflicts
    , testCase "deletion of an expected book rejects the whole batch" testExpectedDeletionConflict
    , testCase "expected rows ignore timestamps and accept any id order" testExpectedIgnoresTimestamps
    , testCase "new and edited required names reject whitespace and preserve memo whitespace" testRequiredNames
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

testBatchIdentitySwap :: IO ()
testBatchIdentitySwap =
  withBatchBooks $ \conn first second untouched -> do
    indexBefore <- identityIndex conn
    let firstUpdate = (editableBook second) {bookUpdateId = bookId first}
        secondUpdate = (editableBook first) {bookUpdateId = bookId second}
    Store.updateBookBatch conn
      (BookUpdateBatch (firstUpdate :| [secondUpdate]) (Just (editableBook second :| [editableBook first])))
    after <- sortOn bookId <$> Store.listBooks conn (allBooks SortCatalog)
    case after of
      [firstAfter, secondAfter, untouchedAfter] -> do
        editableBook firstAfter @?= firstUpdate
        editableBook secondAfter @?= secondUpdate
        bookCreatedAt firstAfter @?= bookCreatedAt first
        bookCreatedAt secondAfter @?= bookCreatedAt second
        assertBool "first updated_at should change" (bookUpdatedAt firstAfter /= bookUpdatedAt first)
        assertBool "second updated_at should change" (bookUpdatedAt secondAfter /= bookUpdatedAt second)
        untouchedAfter @?= untouched
      _ -> assertFailure ("unexpected books after swap: " <> show after)
    identityIndex conn >>= (@?= indexBefore)
    assertThrows (Store.insertBook conn sampleBook)
    Store.integrityCheck conn

testUntouchedIdentityCollision :: IO ()
testUntouchedIdentityCollision =
  withBatchBooks $ \conn first second untouched -> do
    before <- Store.listBooks conn (allBooks SortCatalog)
    indexBefore <- identityIndex conn
    let colliding = (editableBook untouched) {bookUpdateId = bookId second}
    assertThrows (Store.updateBooks conn
      ((editableBook first) {bookUpdateTitle = "書き換えない本"} :| [colliding]))
    Store.listBooks conn (allBooks SortCatalog) >>= (@?= before)
    identityIndex conn >>= (@?= indexBefore)
    assertThrows (Store.insertBook conn sampleBook)
    Store.integrityCheck conn

testInvalidBatchIds :: IO ()
testInvalidBatchIds =
  withBatchBooks $ \conn first second _ -> do
    before <- Store.listBooks conn (allBooks SortCatalog)
    let firstUpdate = (editableBook first) {bookUpdateMemo = "保存しない"}
        updates = firstUpdate :| [editableBook second]
    assertThrows (Store.updateBooks conn (firstUpdate :| [firstUpdate]))
    assertThrows (Store.updateBookBatch conn
      (BookUpdateBatch updates (Just (editableBook first :| [editableBook first]))))
    assertThrows (Store.updateBookBatch conn
      (BookUpdateBatch updates (Just (editableBook first :| []))))
    Store.listBooks conn (allBooks SortCatalog) >>= (@?= before)

testExpectedFieldConflicts :: IO ()
testExpectedFieldConflicts = mapM_ checkChange
  [ \book -> book {bookUpdateTitle = "別のタイトル"}
  , \book -> book {bookUpdateAuthor = "別の著者"}
  , \book -> book {bookUpdateStatus = Finished}
  , \book -> book {bookUpdateCategory = "一般書"}
  , \book -> book {bookUpdateSeries = Just "岩波文庫"}
  , \book -> book {bookUpdateVolumeNo = Just 3.5}
  , \book -> book {bookUpdateMemo = "  メモの変更\n"}
  , \book -> book {bookUpdateUrl = Just "https://example.com/changed"}
  ]
 where
  checkChange change =
    withBatchBooks $ \conn first second _ -> do
      Store.updateBooks conn (change (editableBook first) :| [])
      before <- Store.listBooks conn (allBooks SortCatalog)
      assertConflict (Store.updateBookBatch conn
        (BookUpdateBatch
          ((editableBook second) {bookUpdateMemo = "保存しない"} :| [editableBook first])
          (Just (editableBook second :| [editableBook first]))))
      Store.listBooks conn (allBooks SortCatalog) >>= (@?= before)

testExpectedDeletionConflict :: IO ()
testExpectedDeletionConflict =
  withBatchBooks $ \conn first second _ -> do
    execute conn "DELETE FROM books WHERE id = ?" (Only (bookId second))
    before <- Store.listBooks conn (allBooks SortCatalog)
    assertConflict (Store.updateBookBatch conn
      (BookUpdateBatch
        ((editableBook first) {bookUpdateMemo = "保存しない"} :| [editableBook second])
        (Just (editableBook first :| [editableBook second]))))
    Store.listBooks conn (allBooks SortCatalog) >>= (@?= before)

testExpectedIgnoresTimestamps :: IO ()
testExpectedIgnoresTimestamps =
  withBatchBooks $ \conn first second _ -> do
    execute_ conn "UPDATE books SET updated_at = '2001-02-03 04:05:06'"
    let firstUpdate = (editableBook first) {bookUpdateMemo = "  保持する空白\n"}
    Store.updateBookBatch conn
      (BookUpdateBatch (firstUpdate :| [editableBook second]) (Just (editableBook second :| [editableBook first])))
    books <- Store.listBooks conn (allBooks SortCatalog)
    map bookMemo (filter ((== bookId first) . bookId) books) @?= ["  保持する空白\n"]

testRequiredNames :: IO ()
testRequiredNames =
  withTestConfig 2 $ \cfg ->
    withInitializedConnection cfg $ \conn -> do
      let book = sampleBook {newSeries = Nothing, newVolumeNo = Nothing, newMemo = "  新規メモ\n"}
      assertThrows (Store.insertBook conn book {newTitle = " \t\n"})
      assertThrows (Store.insertBook conn book {newAuthor = " \t\n"})
      assertThrows (Store.insertBook conn book {newCategory = " \t\n"})
      assertThrows (Store.addCategory conn " \t\n")
      assertThrows (Store.renameCategory conn "小説" " \t\n")
      assertThrows (Store.addSeries conn " \t\n")
      Store.addSeries conn "新潮文庫"
      assertThrows (Store.renameSeries conn "新潮文庫" " \t\n")
      _ <- Store.insertBook conn book
      before <- Store.listBooks conn (allBooks SortCatalog)
      case before of
        [stored] -> do
          bookMemo stored @?= "  新規メモ\n"
          let proposed = editableBook stored
          assertThrows (Store.updateBooks conn (proposed {bookUpdateTitle = " \t\n"} :| []))
          assertThrows (Store.updateBooks conn (proposed {bookUpdateAuthor = " \t\n"} :| []))
          assertThrows (Store.updateBooks conn (proposed {bookUpdateCategory = " \t\n"} :| []))
          Store.listBooks conn (allBooks SortCatalog) >>= (@?= before)
        _ -> assertFailure ("unexpected books: " <> show before)

withBatchBooks :: (Connection -> Book -> Book -> Book -> IO ()) -> IO ()
withBatchBooks action =
  withTestConfig 2 $ \cfg ->
    withInitializedConnection cfg $ \conn -> do
      Store.addSeries conn "新潮文庫"
      Store.addSeries conn "岩波文庫"
      firstId <- Store.insertBook conn sampleBook
      secondId <- Store.insertBook conn sampleBook
        {newTitle = "別の本", newAuthor = "別の著者", newSeries = Just "岩波文庫", newVolumeNo = Just 2}
      thirdId <- Store.insertBook conn sampleBook
        {newTitle = "対象外の本", newSeries = Nothing, newVolumeNo = Nothing}
      mapM_ (\identifier -> execute conn
        "UPDATE books SET created_at = ?, updated_at = '2000-01-01 00:00:00' WHERE id = ?"
        ("2000-01-0" <> T.pack (show identifier) <> " 00:00:00", identifier)) [firstId, secondId, thirdId]
      books <- sortOn bookId <$> Store.listBooks conn (allBooks SortCatalog)
      case books of
        [first, second, third] -> action conn first second third
        _ -> assertFailure ("unexpected fixture: " <> show books)

editableBook :: Book -> BookUpdate
editableBook book = BookUpdate
  { bookUpdateId = bookId book
  , bookUpdateTitle = bookTitle book
  , bookUpdateAuthor = bookAuthor book
  , bookUpdateStatus = bookStatus book
  , bookUpdateCategory = bookCategory book
  , bookUpdateSeries = bookSeries book
  , bookUpdateVolumeNo = bookVolumeNo book
  , bookUpdateMemo = bookMemo book
  , bookUpdateUrl = bookUrl book
  }

identityIndex :: Connection -> IO [Only Text]
identityIndex conn = query_ conn "SELECT sql FROM sqlite_master WHERE type = 'index' AND name = 'books_identity_idx'"

assertConflict :: IO () -> IO ()
assertConflict action = do
  result <- try action :: IO (Either Store.BookUpdateConflict ())
  result @?= Left Store.BookUpdateConflict

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

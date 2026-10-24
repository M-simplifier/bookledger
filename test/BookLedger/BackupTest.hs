{-# LANGUAGE OverloadedStrings #-}

module BookLedger.BackupTest (tests) where

import BookLedger.Backup
import BookLedger.Config (Config(..))
import BookLedger.Domain
import BookLedger.Export (renderCsv)
import qualified BookLedger.Store as Store
import BookLedger.TestSupport
import Control.Exception (bracket)
import Control.Monad (forM_, replicateM_)
import Data.Aeson (Value(..), eitherDecodeStrict', toJSON)
import qualified Data.Aeson.KeyMap as KeyMap
import qualified Data.ByteString as BS
import Data.List (isPrefixOf, sort)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Text.IO as TIO
import Data.Time (UTCTime, addUTCTime, defaultTimeLocale, getCurrentTime, parseTimeM)
import Database.SQLite.Simple (Connection, close, query_)
import System.Directory (copyFile, createDirectory, createFileLink, doesDirectoryExist, doesFileExist, listDirectory, removeDirectory, renameFile)
import System.FilePath ((</>), takeDirectory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "Backup"
    [ testCase "creates reopenable SQLite, CSV, and HTML backups" testBackupRoundTrip
    , testCase "keeps only the configured number of snapshots" testSnapshotRetention
    , testCase "restoring a snapshot preserves schema and unused catalog entries" testRestoreSchema
    , testCase "a directory at latest.html preserves the previous backup and recovers" testPublicationFailure
    , testCase "missing or corrupt source cannot replace a good backup" testInvalidSource
    , testCase "retention ignores unrelated SQLite files, invalid dates, directories, and symlinks" testManagedRetention
    ]

testBackupRoundTrip :: IO ()
testBackupRoundTrip =
  withTestConfig 2 $ \cfg -> do
    withInitializedConnection cfg $ \conn -> do
      Store.addSeries conn "新潮文庫"
      _ <- Store.insertBook conn sampleBook
      _ <- Store.insertBook conn sampleBook
        { newTitle = "箱男"
        , newSeries = Nothing
        , newVolumeNo = Nothing
        }
      pure ()

    sourceBooks <- withInitializedConnection cfg $ \conn ->
      Store.listBooks conn (allBooks SortCatalog)
    before <- getCurrentTime
    result <- backupNow cfg
    after <- getCurrentTime
    let generatedFiles =
          [ backupLatestPath result
          , backupSnapshotPath result
          , backupCsvPath result
          , backupHtmlPath result
          ]
    forM_ generatedFiles $ \path -> do
      exists <- doesFileExist path
      assertBool ("expected backup file: " <> path) exists

    copiedBooks <-
      bracket (Store.openDb (backupLatestPath result)) close $ \conn -> do
        Store.integrityCheck conn
        Store.listBooks conn (allBooks SortCatalog)
    copiedBooks @?= sourceBooks

    snapshotBooks <-
      bracket (Store.openDb (backupSnapshotPath result)) close $ \conn -> do
        Store.integrityCheck conn
        Store.listBooks conn (allBooks SortCatalog)
    snapshotBooks @?= sourceBooks

    csv <- TIO.readFile (backupCsvPath result)
    html <- TIO.readFile (backupHtmlPath result)
    csv @?= renderCsv snapshotBooks
    case htmlSnapshot html of
      Right (Object fields) -> do
        KeyMap.lookup "books" fields @?= Just (toJSON snapshotBooks)
        case KeyMap.lookup "generatedAt" fields of
          Just (String stamp) -> case parseTimeM True defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" (T.unpack stamp) :: Maybe UTCTime of
            Just generated -> assertBool "snapshot date should be the actual backup time" (generated >= addUTCTime (-1) before && generated <= after)
            Nothing -> assertFailure ("invalid snapshot date: " <> show stamp)
          other -> assertFailure ("missing snapshot date: " <> show other)
      other -> assertFailure ("invalid embedded snapshot: " <> show other)
    assertNoStaging cfg

testSnapshotRetention :: IO ()
testSnapshotRetention =
  withTestConfig 2 $ \cfg -> do
    withInitializedConnection cfg $ \conn -> do
      Store.addSeries conn "新潮文庫"
      _ <- Store.insertBook conn sampleBook
      pure ()
    replicateM_ 3 (backupNow cfg)
    snapshots <- listBackups cfg
    length snapshots @?= 2
    forM_ snapshots $ \path -> do
      exists <- doesFileExist path
      assertBool ("expected retained snapshot: " <> path) exists

testRestoreSchema :: IO ()
testRestoreSchema =
  withTestConfig 2 $ \cfg -> do
    withInitializedConnection cfg $ \conn -> do
      Store.addCategory conn "未使用カテゴリ"
      Store.addSeries conn "未使用シリーズ"
      Store.addSeries conn "新潮文庫"
      _ <- Store.insertBook conn sampleBook
        {newMemo = "  改行\n引用\"と,カンマ", newVolumeNo = Just 1.5}
      pure ()
    originalSchema <- withConnection cfg schema
    categories <- withConnection cfg Store.listCategories
    series <- withConnection cfg Store.listSeries
    originalBooks <- withConnection cfg (\conn -> Store.listBooks conn (allBooks SortCatalog))
    result <- backupNow cfg
    let restored = cfg {cfgDbPath = takeDirectory (cfgDbPath cfg) </> "restored.sqlite"}
    copyFile (backupSnapshotPath result) (cfgDbPath restored)
    withInitializedConnection restored $ \conn -> do
      Store.integrityCheck conn
      schema conn >>= (@?= originalSchema)
      Store.listCategories conn >>= (@?= categories)
      Store.listSeries conn >>= (@?= series)
      Store.listBooks conn (allBooks SortCatalog) >>= (@?= originalBooks)
      violations <- query_ conn "PRAGMA foreign_key_check" :: IO [(T.Text, Int, T.Text, Int)]
      violations @?= []
      assertThrows (Store.insertBook conn sampleBook {newVolumeNo = Just 1.5})
 where
  schema :: Connection -> IO [(T.Text, T.Text, T.Text, Maybe T.Text)]
  schema conn = query_ conn "SELECT type, name, tbl_name, sql FROM sqlite_master ORDER BY type, name"

testPublicationFailure :: IO ()
testPublicationFailure =
  withTestConfig 2 $ \cfg -> do
    seedLedger cfg
    result <- backupNow cfg
    oldLatest <- BS.readFile (backupLatestPath result)
    oldCsv <- BS.readFile (backupCsvPath result)
    oldSnapshots <- listBackups cfg
    let savedHtml = backupHtmlPath result <> ".saved"
    renameFile (backupHtmlPath result) savedHtml
    createDirectory (backupHtmlPath result)
    withConnection cfg $ \conn -> do
      books <- Store.listBooks conn (allBooks SortCatalog)
      forM_ books $ \book -> Store.updateBookMemo conn (bookId book) "新しいメモ"
    assertThrows (backupNow cfg)
    BS.readFile (backupLatestPath result) >>= (@?= oldLatest)
    BS.readFile (backupCsvPath result) >>= (@?= oldCsv)
    listBackups cfg >>= (@?= oldSnapshots)
    assertNoStaging cfg
    removeDirectory (backupHtmlPath result)
    renameFile savedHtml (backupHtmlPath result)
    _ <- backupNow cfg
    restoredBooks <- bracket (Store.openDb (backupLatestPath result)) close (\conn -> Store.listBooks conn (allBooks SortCatalog))
    map bookMemo restoredBooks @?= ["新しいメモ"]
    assertNoStaging cfg

testInvalidSource :: IO ()
testInvalidSource =
  withTestConfig 2 $ \cfg -> do
    seedLedger cfg
    result <- backupNow cfg
    oldLatest <- BS.readFile (backupLatestPath result)
    oldSnapshots <- listBackups cfg
    let missing = cfg {cfgDbPath = takeDirectory (cfgDbPath cfg) </> "missing.sqlite"}
    assertThrows (backupNow missing)
    doesFileExist (cfgDbPath missing) >>= (@?= False)
    TIO.writeFile (cfgDbPath cfg) "not a SQLite database"
    assertThrows (backupNow cfg)
    BS.readFile (backupLatestPath result) >>= (@?= oldLatest)
    listBackups cfg >>= (@?= oldSnapshots)
    assertNoStaging cfg

testManagedRetention :: IO ()
testManagedRetention =
  withTestConfig 1 $ \cfg -> do
    seedLedger cfg
    _ <- backupNow cfg
    let snapshotDir = cfgBackupDir cfg </> "snapshots"
        preserved = ["personal.sqlite", "books-not-a-date.sqlite", "books-20001399-000000-000000.sqlite"]
        oldManaged = snapshotDir </> "books-20000101-000000-000000.sqlite"
        link = snapshotDir </> "books-20000102-000000-000000.sqlite"
        directory = snapshotDir </> "books-20000103-000000-000000.sqlite"
    forM_ preserved $ \name -> TIO.writeFile (snapshotDir </> name) "unrelated"
    TIO.writeFile oldManaged "stale managed fixture"
    createFileLink (snapshotDir </> "personal.sqlite") link
    createDirectory directory
    _ <- backupNow cfg
    snapshots <- listBackups cfg
    length snapshots @?= 1
    doesFileExist oldManaged >>= (@?= False)
    forM_ preserved $ \name -> TIO.readFile (snapshotDir </> name) >>= (@?= "unrelated")
    doesFileExist link >>= (@?= True)
    doesDirectoryExist directory >>= (@?= True)
    assertNoStaging cfg

seedLedger :: Config -> IO ()
seedLedger cfg =
  withInitializedConnection cfg $ \conn -> do
    Store.addSeries conn "新潮文庫"
    _ <- Store.insertBook conn sampleBook
    pure ()

assertNoStaging :: Config -> IO ()
assertNoStaging cfg = do
  names <- listDirectory (cfgBackupDir cfg)
  sort (filter (isPrefixOf ".bookledger-publish-") names) @?= []

htmlSnapshot :: T.Text -> Either String Value
htmlSnapshot document =
  eitherDecodeStrict' (TE.encodeUtf8 payload)
 where
  marker = "<script id=\"snapshot-data\" type=\"application/json\">"
  payload = fst (T.breakOn "</script>" (T.drop (T.length marker) (snd (T.breakOn marker document))))

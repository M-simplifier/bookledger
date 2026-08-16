{-# LANGUAGE OverloadedStrings #-}

module BookLedger.BackupTest (tests) where

import BookLedger.Backup
import BookLedger.Domain
import qualified BookLedger.Store as Store
import BookLedger.TestSupport
import Control.Exception (bracket)
import Control.Monad (forM_, replicateM_)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Database.SQLite.Simple (close)
import System.Directory (doesFileExist)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "Backup"
    [ testCase "creates reopenable SQLite, CSV, and HTML backups" testBackupRoundTrip
    , testCase "keeps only the configured number of snapshots" testSnapshotRetention
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
    result <- backupNow cfg
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
    assertBool "CSV should contain every title" (all (`T.isInfixOf` csv) ["砂の女", "箱男"])
    T.count "<article class=\"book\"" html @?= 2

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

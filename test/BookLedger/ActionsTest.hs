{-# LANGUAGE OverloadedStrings #-}

module BookLedger.ActionsTest (tests) where

import BookLedger.Actions
import BookLedger.Config (Config(..))
import BookLedger.Domain
import qualified BookLedger.Store as Store
import BookLedger.TestSupport
import Control.Exception (bracket)
import Data.List (isPrefixOf)
import qualified Data.Text.IO as TIO
import Database.SQLite.Simple (close)
import System.Directory (doesDirectoryExist)
import System.FilePath ((</>))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests = testGroup "Actions"
  [ testCase "a successful write creates an exact automatic backup" testWriteBackup
  , testCase "backup failure preserves the committed write and returns a warning" testWriteBackupWarning
  , testCase "disabled automatic backup writes no backup directory" testDisabledBackup
  , testCase "a rejected write neither changes the ledger nor starts a backup" testRejectedWrite
  ]

testWriteBackup :: IO ()
testWriteBackup =
  withTestConfig 2 $ \base -> do
    let cfg = base {cfgBackupAfterWrite = True}
    (_, warning) <- addBookAction cfg sampleBook {newSeries = Nothing}
    warning @?= Nothing
    books <- listBooksAction cfg (allBooks SortCatalog)
    copied <- bracket (Store.openDb (cfgBackupDir cfg </> "latest.sqlite")) close $ \conn -> do
      Store.integrityCheck conn
      Store.listBooks conn (allBooks SortCatalog)
    copied @?= books

testWriteBackupWarning :: IO ()
testWriteBackupWarning =
  withTestConfig 2 $ \base -> do
    let cfg = base {cfgBackupAfterWrite = True}
    TIO.writeFile (cfgBackupDir cfg) "blocked destination"
    (identifier, warning) <- addBookAction cfg sampleBook {newSeries = Nothing}
    case warning of
      Just message -> assertBool "warning should identify backup failure" ("backup failed:" `isPrefixOf` message)
      Nothing -> assertFailure "backup failure was reported as success"
    books <- listBooksAction cfg (allBooks SortCatalog)
    map bookId books @?= [identifier]
    map bookTitle books @?= [newTitle sampleBook]
    TIO.readFile (cfgBackupDir cfg) >>= (@?= "blocked destination")

testDisabledBackup :: IO ()
testDisabledBackup =
  withTestConfig 2 $ \cfg -> do
    (_, warning) <- addBookAction cfg sampleBook {newSeries = Nothing}
    warning @?= Nothing
    doesDirectoryExist (cfgBackupDir cfg) >>= (@?= False)

testRejectedWrite :: IO ()
testRejectedWrite =
  withTestConfig 2 $ \base -> do
    let cfg = base {cfgBackupAfterWrite = True}
    assertThrows (addBookAction cfg sampleBook {newTitle = "  ", newSeries = Nothing})
    listBooksAction cfg (allBooks SortCatalog) >>= (@?= [])
    doesDirectoryExist (cfgBackupDir cfg) >>= (@?= False)

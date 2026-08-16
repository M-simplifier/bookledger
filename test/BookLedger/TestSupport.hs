{-# LANGUAGE OverloadedStrings #-}

module BookLedger.TestSupport
  ( allBooks
  , assertThrows
  , sampleBook
  , withConnection
  , withInitializedConnection
  , withTestConfig
  ) where

import BookLedger.Config (Config(..))
import BookLedger.Domain
import qualified BookLedger.Store as Store
import Control.Exception (SomeException, bracket, try)
import Control.Monad (void)
import Database.SQLite.Simple (Connection, close)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty.HUnit (Assertion, assertFailure)

allBooks :: BookSort -> BookFilter
allBooks sort =
  BookFilter
    { filterStatus = Nothing
    , filterCategory = Nothing
    , filterSeries = Nothing
    , filterSearch = Nothing
    , filterSort = sort
    }

sampleBook :: NewBook
sampleBook =
  NewBook
    { newTitle = "砂の女"
    , newAuthor = "安部公房"
    , newStatus = Reading
    , newCategory = "小説"
    , newSeries = Just "新潮文庫"
    , newVolumeNo = Just 1
    , newMemo = "再読したい"
    , newUrl = Just "https://example.com/suna-no-onna"
    }

withTestConfig :: Int -> (Config -> IO a) -> IO a
withTestConfig keepSnapshots action =
  withSystemTempDirectory "bookledger-test" $ \root ->
    action
      Config
        { cfgDbPath = root </> "books.sqlite"
        , cfgBackupDir = root </> "backups"
        , cfgKeepSnapshots = keepSnapshots
        , cfgBackupAfterWrite = False
        }

withConnection :: Config -> (Connection -> IO a) -> IO a
withConnection cfg =
  bracket (Store.openDb (cfgDbPath cfg)) close

withInitializedConnection :: Config -> (Connection -> IO a) -> IO a
withInitializedConnection cfg action =
  withConnection cfg $ \conn -> do
    Store.initDb conn
    action conn

assertThrows :: IO a -> Assertion
assertThrows action = do
  result <- try (void action) :: IO (Either SomeException ())
  case result of
    Left _ -> pure ()
    Right () -> assertFailure "expected an exception, but the action succeeded"

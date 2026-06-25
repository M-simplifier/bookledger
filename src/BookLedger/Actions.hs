{-# LANGUAGE OverloadedStrings #-}

module BookLedger.Actions
  ( initialize
  , addBookAction
  , setStatusAction
  , addCategoryAction
  , renameCategoryAction
  , addSeriesAction
  , renameSeriesAction
  , listBooksAction
  , listCategoriesAction
  , listSeriesAction
  , backupAction
  ) where

import BookLedger.Backup (BackupResult, backupNow)
import BookLedger.Config
import BookLedger.Domain
import qualified BookLedger.Store as Store
import Control.Exception (SomeException, bracket, try)
import Database.SQLite.Simple (close)
import qualified Database.SQLite.Simple
import qualified Data.Text

initialize :: Config -> IO ()
initialize cfg =
  withRawDb cfg Store.initDb

addBookAction :: Config -> NewBook -> IO (Int, Maybe String)
addBookAction cfg book = do
  bookId <- withDb cfg (`Store.insertBook` book)
  warning <- backupAfterWrite cfg
  pure (bookId, warning)

setStatusAction :: Config -> Int -> Status -> IO (Maybe String)
setStatusAction cfg bookId status = do
  withDb cfg $ \conn -> Store.updateBookStatus conn bookId status
  backupAfterWrite cfg

addCategoryAction :: Config -> String -> IO (Maybe String)
addCategoryAction cfg name = do
  withDb cfg $ \conn -> Store.addCategory conn (fromStringText name)
  backupAfterWrite cfg

renameCategoryAction :: Config -> String -> String -> IO (Maybe String)
renameCategoryAction cfg old new = do
  withDb cfg $ \conn -> Store.renameCategory conn (fromStringText old) (fromStringText new)
  backupAfterWrite cfg

addSeriesAction :: Config -> String -> IO (Maybe String)
addSeriesAction cfg title = do
  withDb cfg $ \conn -> Store.addSeries conn (fromStringText title)
  backupAfterWrite cfg

renameSeriesAction :: Config -> String -> String -> IO (Maybe String)
renameSeriesAction cfg old new = do
  withDb cfg $ \conn -> Store.renameSeries conn (fromStringText old) (fromStringText new)
  backupAfterWrite cfg

listBooksAction :: Config -> BookFilter -> IO [Book]
listBooksAction cfg filters =
  withDb cfg (`Store.listBooks` filters)

listCategoriesAction :: Config -> IO [String]
listCategoriesAction cfg =
  map showText <$> withDb cfg Store.listCategories

listSeriesAction :: Config -> IO [String]
listSeriesAction cfg =
  map showText <$> withDb cfg Store.listSeries

backupAction :: Config -> IO BackupResult
backupAction = backupNow

withDb :: Config -> (Database.SQLite.Simple.Connection -> IO a) -> IO a
withDb cfg action =
  withRawDb cfg $ \conn -> do
    Store.initDb conn
    action conn

withRawDb :: Config -> (Database.SQLite.Simple.Connection -> IO a) -> IO a
withRawDb cfg =
  bracket (Store.openDb (cfgDbPath cfg)) close

backupAfterWrite :: Config -> IO (Maybe String)
backupAfterWrite cfg
  | not (cfgBackupAfterWrite cfg) = pure Nothing
  | otherwise = do
      result <- try (backupNow cfg) :: IO (Either SomeException BackupResult)
      case result of
        Right _ -> pure Nothing
        Left err -> pure (Just ("backup failed: " <> show err))

fromStringText :: String -> Data.Text.Text
fromStringText = Data.Text.pack

showText :: Data.Text.Text -> String
showText = Data.Text.unpack

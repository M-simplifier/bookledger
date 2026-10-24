{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}

module BookLedger.Web
  ( runWeb
  , runWebWith
  , BrowserLaunch(..)
  , bookledgerApp
  ) where

import BookLedger.Actions
import BookLedger.Config
import BookLedger.Domain
import BookLedger.Store (BookUpdateConflict)
import Control.Exception (SomeAsyncException, SomeException, displayException, fromException, throwIO, try)
import Control.Monad (void)
import Data.Aeson (FromJSON(..), eitherDecode, encode, object, withObject, (.:), (.=))
import qualified Data.ByteString.Lazy as LBS
import Data.Maybe (fromMaybe)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import GHC.Generics (Generic)
import qualified Network.HTTP.Types as HTTP
import Network.HTTP.Types (ResponseHeaders, status200, status400, status404, status409)
import Network.Wai
import Network.Wai.Handler.Warp
import Paths_bookledger (getDataFileName)
import System.FilePath (takeExtension)
import System.Process (callProcess)

data StatusUpdate = StatusUpdate
  { statusUpdateId :: Int
  , statusUpdateStatus :: Status
  } deriving (Eq, Show, Generic)

instance FromJSON StatusUpdate where
  parseJSON = withObject "StatusUpdate" $ \obj ->
    StatusUpdate <$> obj .: "id" <*> obj .: "status"

data MemoUpdate = MemoUpdate
  { memoUpdateId :: Int
  , memoUpdateMemo :: T.Text
  } deriving (Eq, Show, Generic)

instance FromJSON MemoUpdate where
  parseJSON = withObject "MemoUpdate" $ \obj ->
    MemoUpdate <$> obj .: "id" <*> obj .: "memo"

data BrowserLaunch = OpenBrowser | LeaveBrowserClosed
  deriving (Eq, Show)

runWeb :: Config -> Int -> IO ()
runWeb = runWebWith OpenBrowser

runWebWith :: BrowserLaunch -> Config -> Int -> IO ()
runWebWith browserLaunch cfg port = do
  let url = "http://127.0.0.1:" <> show port <> "/"
  putStrLn ("Bookledger web UI: " <> url)
  case browserLaunch of
    OpenBrowser -> openBrowser url
    LeaveBrowserClosed -> pure ()
  runSettings (setHost "127.0.0.1" (setPort port defaultSettings)) (bookledgerApp cfg)

bookledgerApp :: Config -> Application
bookledgerApp cfg req respond =
  case (requestMethod req, pathInfo req) of
    ("GET", []) -> respondFilePath status200 "static/index.html" respond
    ("GET", ["static", "app.js"]) -> respondFilePath status200 "static/app.js" respond
    ("GET", ["static", "model.js"]) -> respondFilePath status200 "static/model.js" respond
    ("GET", ["static", "store.js"]) -> respondFilePath status200 "static/store.js" respond
    ("GET", ["static", "style.css"]) -> respondFilePath status200 "static/style.css" respond
    ("GET", ["api", "meta"]) -> jsonResponse respond =<< handleJson (loadMeta cfg)
    ("GET", ["api", "books"]) -> jsonResponse respond =<< handleJson (loadBooks cfg req)
    ("POST", ["api", "books"]) -> do
      body <- strictRequestBody req
      case eitherDecode body of
        Left err -> jsonError respond status400 err
        Right newBook -> jsonResponse respond =<< handleJson (createBook cfg newBook)
    ("POST", ["api", "books", "batch"]) -> do
      body <- strictRequestBody req
      case eitherDecode body of
        Left err -> jsonError respond status400 err
        Right batch -> jsonResponse respond =<< handleJson (updateBookBatch cfg batch)
    ("POST", ["api", "status"]) -> do
      body <- strictRequestBody req
      case eitherDecode body of
        Left err -> jsonError respond status400 err
        Right statusUpdate -> jsonResponse respond =<< handleJson (updateStatus cfg statusUpdate)
    ("POST", ["api", "memo"]) -> do
      body <- strictRequestBody req
      case eitherDecode body of
        Left err -> jsonError respond status400 err
        Right memoUpdate -> jsonResponse respond =<< handleJson (updateMemo cfg memoUpdate)
    ("POST", ["api", "categories"]) -> do
      body <- strictRequestBody req
      case eitherDecode body of
        Left err -> jsonError respond status400 err
        Right (NamePayload name) -> jsonResponse respond =<< handleJson (addCategoryWeb cfg name)
    ("POST", ["api", "series"]) -> do
      body <- strictRequestBody req
      case eitherDecode body of
        Left err -> jsonError respond status400 err
        Right (NamePayload name) -> jsonResponse respond =<< handleJson (addSeriesWeb cfg name)
    _ -> respond (responseLBS status404 [("content-type", "text/plain")] "not found")

data NamePayload = NamePayload T.Text

instance FromJSON NamePayload where
  parseJSON = withObject "NamePayload" $ \obj -> NamePayload <$> obj .: "name"

respondFilePath :: HTTP.Status -> FilePath -> (Response -> IO ResponseReceived) -> IO ResponseReceived
respondFilePath status path respond = do
  fullPath <- getDataFileName path
  let contentType = case takeExtension path of
        ".html" -> "text/html; charset=utf-8"
        ".js" -> "text/javascript; charset=utf-8"
        ".css" -> "text/css; charset=utf-8"
        _ -> "application/octet-stream"
  respond (responseFile status [("content-type", contentType), ("cache-control", "no-cache")] fullPath Nothing)

loadMeta :: Config -> IO LBS.ByteString
loadMeta cfg = do
  categories <- listCategoriesAction cfg
  seriesTitles <- listSeriesAction cfg
  pure (encode (object
    [ "categories" .= categories
    , "series" .= seriesTitles
    , "statuses" .= [ object ["value" .= statusText s, "label" .= statusLabel s] | s <- allStatuses ]
    ]))

loadBooks :: Config -> Request -> IO LBS.ByteString
loadBooks cfg req = do
  books <- listBooksAction cfg (filterFromRequest req)
  pure (encode books)

createBook :: Config -> NewBook -> IO LBS.ByteString
createBook cfg newBook = do
  (bookId, warning) <- addBookAction cfg newBook
  pure (encode (object ["ok" .= True, "id" .= bookId, "warning" .= warning]))

updateStatus :: Config -> StatusUpdate -> IO LBS.ByteString
updateStatus cfg statusUpdate = do
  warning <- setStatusAction cfg (statusUpdateId statusUpdate) (statusUpdateStatus statusUpdate)
  pure (encode (object ["ok" .= True, "warning" .= warning]))

updateMemo :: Config -> MemoUpdate -> IO LBS.ByteString
updateMemo cfg memoUpdate = do
  warning <- setMemoAction cfg (memoUpdateId memoUpdate) (memoUpdateMemo memoUpdate)
  pure (encode (object ["ok" .= True, "warning" .= warning]))

updateBookBatch :: Config -> BookUpdateBatch -> IO LBS.ByteString
updateBookBatch cfg batch = do
  warning <- updateBookBatchAction cfg batch
  pure (encode (object ["ok" .= True, "updated" .= length (batchBookUpdates batch), "warning" .= warning]))

addCategoryWeb :: Config -> T.Text -> IO LBS.ByteString
addCategoryWeb cfg name = do
  warning <- addCategoryAction cfg (T.unpack name)
  pure (encode (object ["ok" .= True, "warning" .= warning]))

addSeriesWeb :: Config -> T.Text -> IO LBS.ByteString
addSeriesWeb cfg name = do
  warning <- addSeriesAction cfg (T.unpack name)
  pure (encode (object ["ok" .= True, "warning" .= warning]))

filterFromRequest :: Request -> BookFilter
filterFromRequest req =
  BookFilter
    { filterStatus = queryText "status" >>= parseStatus
    , filterCategory = queryText "category"
    , filterSeries = queryText "series"
    , filterSearch = queryText "q"
    , filterSort = fromMaybe SortActive (queryText "sort" >>= parseBookSort)
    }
 where
  queryText key = do
    raw <- lookup key (queryString req) >>= id
    let value = T.strip (TE.decodeUtf8 raw)
    if T.null value then Nothing else Just value

data JsonFailure = RequestFailure String | EditConflict String

handleJson :: IO LBS.ByteString -> IO (Either JsonFailure LBS.ByteString)
handleJson action = do
  result <- try action :: IO (Either SomeException LBS.ByteString)
  case result of
    Right body -> pure (Right body)
    Left err -> case fromException err :: Maybe SomeAsyncException of
      Just async -> throwIO async
      Nothing -> pure (Left (case fromException err :: Maybe BookUpdateConflict of
        Just conflict -> EditConflict (displayException conflict)
        Nothing -> RequestFailure (displayException err)))

jsonResponse :: (Response -> IO ResponseReceived) -> Either JsonFailure LBS.ByteString -> IO ResponseReceived
jsonResponse respond result =
  case result of
    Right body -> respond (responseLBS status200 jsonHeaders body)
    Left (RequestFailure err) -> jsonError respond status400 err
    Left (EditConflict err) ->
      respond (responseLBS status409 jsonHeaders (encode (object ["ok" .= False, "error" .= err, "conflict" .= True])))

jsonError :: (Response -> IO ResponseReceived) -> HTTP.Status -> String -> IO ResponseReceived
jsonError respond status err =
  respond (responseLBS status jsonHeaders (encode (object ["ok" .= False, "error" .= err])))

jsonHeaders :: ResponseHeaders
jsonHeaders = [("content-type", "application/json; charset=utf-8")]

openBrowser :: String -> IO ()
openBrowser url = do
  result <- try (callProcess "powershell.exe" ["-NoProfile", "-Command", "Start-Process '" <> url <> "'"]) :: IO (Either SomeException ())
  case result of
    Right _ -> pure ()
    Left _ -> void (try (callProcess "xdg-open" [url]) :: IO (Either SomeException ()))

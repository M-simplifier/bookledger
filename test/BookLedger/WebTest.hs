{-# LANGUAGE OverloadedStrings #-}

module BookLedger.WebTest (tests) where

import BookLedger.Config (Config)
import BookLedger.Domain
import qualified BookLedger.Store as Store
import BookLedger.TestSupport
import BookLedger.Web (bookledgerApp)
import Control.Monad (forM_, void)
import Data.Aeson (Value(..), eitherDecode, encode, object, toJSON, (.=))
import Data.Aeson.Key (Key)
import qualified Data.Aeson.KeyMap as KeyMap
import Data.ByteString (ByteString)
import Data.ByteString.Builder (toLazyByteString)
import qualified Data.ByteString.Lazy as LBS
import Data.IORef (atomicModifyIORef', modifyIORef', newIORef, readIORef, writeIORef)
import Data.Text (Text)
import qualified Data.Text as T
import Database.SQLite.Simple (Only(..), execute)
import qualified Network.HTTP.Types as HTTP
import Network.HTTP.Types (ResponseHeaders, status200, status400, status409)
import Network.Wai (defaultRequest, pathInfo, requestMethod, responseToStream, setRequestBodyChunks)
import Network.Wai.Internal (ResponseReceived(..))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests = testGroup "Web"
  [ testCase "legacy batches and conditional batches both save" testSuccessfulBatches
  , testCase "changed editable data returns 409 and preserves the latest row" testConflictResponse
  , testCase "a deleted expected row returns 409" testDeletedExpectedResponse
  , testCase "invalid batch ids return 400 without writes" testInvalidBatchResponse
  , testCase "historical whitespace and legacy optional values can be compared" testHistoricalExpected
  , testCase "whitespace-only required names return 400" testBlankNamesResponse
  , testCase "HTML, CSS and every JavaScript module have revalidated content types" testStaticContentTypes
  ]

testSuccessfulBatches :: IO ()
testSuccessfulBatches =
  withWebBook $ \cfg original -> do
    legacy <- requestApp cfg "POST" ["api", "books", "batch"]
      (object ["books" .= [original {bookMemo = "legacy save"}]])
    responseStatus legacy @?= status200
    expectField legacy "ok" (Bool True)
    afterLegacy <- readOnlyBook cfg
    conditional <- requestApp cfg "POST" ["api", "books", "batch"]
      (object ["books" .= [afterLegacy {bookMemo = "  conditional save\n"}], "expected" .= [afterLegacy]])
    responseStatus conditional @?= status200
    expectField conditional "ok" (Bool True)
    expectField conditional "updated" (toJSON (1 :: Int))
    expectField conditional "warning" Null
    after <- readOnlyBook cfg
    bookMemo after @?= "  conditional save\n"
    bookId after @?= bookId original
    bookCreatedAt after @?= bookCreatedAt original

testConflictResponse :: IO ()
testConflictResponse =
  withWebBook $ \cfg original -> do
    withConnection cfg $ \conn -> Store.updateBookMemo conn (bookId original) "別の画面から保存"
    before <- readOnlyBook cfg
    response <- requestApp cfg "POST" ["api", "books", "batch"]
      (object ["books" .= [original {bookTitle = "保存しない"}], "expected" .= [original]])
    responseStatus response @?= status409
    expectField response "ok" (Bool False)
    expectField response "conflict" (Bool True)
    case decodeBody response of
      Right (Object fields) -> case KeyMap.lookup "error" fields of
        Just (String message) -> assertBool "conflict should explain reloading in Japanese" ("再読み込み" `T.isInfixOf` message)
        other -> assertFailure ("missing conflict explanation: " <> show other)
      other -> assertFailure ("unexpected response: " <> show other)
    readOnlyBook cfg >>= (@?= before)

testDeletedExpectedResponse :: IO ()
testDeletedExpectedResponse =
  withWebBook $ \cfg original -> do
    withConnection cfg $ \conn -> execute conn "DELETE FROM books WHERE id = ?" (Only (bookId original))
    response <- requestApp cfg "POST" ["api", "books", "batch"]
      (object ["books" .= [original {bookMemo = "保存しない"}], "expected" .= [original]])
    responseStatus response @?= status409
    expectField response "conflict" (Bool True)
    withConnection cfg (\conn -> Store.listBooks conn (allBooks SortCatalog)) >>= (@?= [])

testInvalidBatchResponse :: IO ()
testInvalidBatchResponse =
  withWebBook $ \cfg original -> do
    forM_
      [ object ["books" .= [original, original]]
      , object ["books" .= [original], "expected" .= [original, original]]
      , object ["books" .= [original], "expected" .= [original {bookId = bookId original + 1}]]
      , object ["books" .= [original], "expected" .= Null]
      ] $ \payload -> do
        response <- requestApp cfg "POST" ["api", "books", "batch"] payload
        responseStatus response @?= status400
        expectField response "ok" (Bool False)
        readOnlyBook cfg >>= (@?= original)

testHistoricalExpected :: IO ()
testHistoricalExpected =
  withWebBook $ \cfg original -> do
    withConnection cfg $ \conn -> execute conn
      "UPDATE books SET title = ?, author = ?, url = ?, volume_no = -2.5 WHERE id = ?"
      ("  旧タイトル  " :: Text, "  旧著者  " :: Text, "legacy:link " :: Text, bookId original)
    historical <- readOnlyBook cfg
    response <- requestApp cfg "POST" ["api", "books", "batch"]
      (object ["books" .= [historical {bookMemo = "メモだけ変更"}], "expected" .= [historical]])
    responseStatus response @?= status200
    after <- readOnlyBook cfg
    bookMemo after @?= "メモだけ変更"
    bookVolumeNo after @?= Just (-2.5)

testBlankNamesResponse :: IO ()
testBlankNamesResponse =
  withWebBook $ \cfg original -> do
    forM_ [["api", "categories"], ["api", "series"]] $ \path -> do
      response <- requestApp cfg "POST" path (object ["name" .= (" \t\n" :: Text)])
      responseStatus response @?= status400
    createResponse <- requestApp cfg "POST" ["api", "books"] (toJSON (original {bookTitle = " \t\n"}))
    responseStatus createResponse @?= status400
    editResponse <- requestApp cfg "POST" ["api", "books", "batch"]
      (object ["books" .= [original {bookAuthor = " \t\n"}]])
    responseStatus editResponse @?= status400
    readOnlyBook cfg >>= (@?= original)

testStaticContentTypes :: IO ()
testStaticContentTypes =
  withTestConfig 2 $ \cfg ->
    forM_
      [ ([], "text/html; charset=utf-8")
      , (["static", "app.js"], "text/javascript; charset=utf-8")
      , (["static", "model.js"], "text/javascript; charset=utf-8")
      , (["static", "store.js"], "text/javascript; charset=utf-8")
      , (["static", "style.css"], "text/css; charset=utf-8")
      ] $ \(path, contentType) -> do
        response <- requestApp cfg "GET" path Null
        responseStatus response @?= status200
        lookup "content-type" (responseHeaders response) @?= Just contentType
        lookup "cache-control" (responseHeaders response) @?= Just "no-cache"

withWebBook :: (Config -> Book -> IO ()) -> IO ()
withWebBook action =
  withTestConfig 2 $ \cfg -> do
    withInitializedConnection cfg $ \conn -> do
      Store.addSeries conn "新潮文庫"
      void (Store.insertBook conn sampleBook)
    readOnlyBook cfg >>= action cfg

readOnlyBook :: Config -> IO Book
readOnlyBook cfg =
  withConnection cfg $ \conn -> do
    books <- Store.listBooks conn (allBooks SortCatalog)
    case books of
      [book] -> pure book
      _ -> fail ("expected one book, got " <> show books)

data AppResponse = AppResponse
  { responseStatus :: HTTP.Status
  , responseHeaders :: ResponseHeaders
  , responseBody :: LBS.ByteString
  }

requestApp :: Config -> ByteString -> [Text] -> Value -> IO AppResponse
requestApp cfg method path payload = do
  requestBytes <- newIORef (LBS.toStrict (encode payload))
  result <- newIORef Nothing
  let req = setRequestBodyChunks (atomicModifyIORef' requestBytes (\bytes -> ("", bytes))) defaultRequest
        { requestMethod = method
        , pathInfo = path
        }
  void (bookledgerApp cfg req $ \response -> do
    let (status, headers, withBody) = responseToStream response
    chunks <- newIORef mempty
    withBody $ \stream -> stream (\chunk -> modifyIORef' chunks (<> chunk)) (pure ())
    bytes <- toLazyByteString <$> readIORef chunks
    writeIORef result (Just (AppResponse status headers bytes))
    pure ResponseReceived)
  captured <- readIORef result
  maybe (fail "WAI application did not respond") pure captured

decodeBody :: AppResponse -> Either String Value
decodeBody = eitherDecode . responseBody

expectField :: AppResponse -> Key -> Value -> IO ()
expectField response key expected =
  case decodeBody response of
    Right (Object fields) -> KeyMap.lookup key fields @?= Just expected
    other -> assertFailure ("unexpected JSON response: " <> show other)

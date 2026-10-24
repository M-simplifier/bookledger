{-# LANGUAGE OverloadedStrings #-}

module BookLedger.DomainTest (tests) where

import BookLedger.Domain
import Data.Aeson (eitherDecode)
import qualified Data.ByteString.Lazy as LBS
import Data.List (isInfixOf)
import Data.List.NonEmpty (NonEmpty((:|)))
import qualified Data.Text.Encoding as TE
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "Domain"
    [ testCase "decodes and normalizes an editor batch" testDecodeEditorBatch
    , testCase "rejects an empty editor batch" testRejectEmptyEditorBatch
    , testCase "decodes complete expected values without normalization" testDecodeExpectedValues
    , testCase "requires complete non-empty expected rows when supplied" testRejectIncompleteExpected
    ]

testDecodeEditorBatch :: IO ()
testDecodeEditorBatch =
  case eitherDecode payload of
    Left err -> assertFailure err
    Right (BookUpdateBatch (book :| []) Nothing) -> do
      bookUpdateId book @?= 7
      bookUpdateTitle book @?= "砂の女"
      bookUpdateAuthor book @?= "安部公房"
      bookUpdateStatus book @?= Finished
      bookUpdateCategory book @?= "小説"
      bookUpdateSeries book @?= Nothing
      bookUpdateVolumeNo book @?= Just 1.5
      bookUpdateMemo book @?= "確認メモ"
      bookUpdateUrl book @?= Nothing
    Right decoded -> assertFailure ("unexpected batch: " <> show decoded)
 where
  payload = LBS.fromStrict (TE.encodeUtf8 "{\"books\":[{\"id\":7,\"title\":\" 砂の女 \",\"author\":\" 安部公房 \",\"status\":\"finished\",\"category\":\" 小説 \",\"series\":\"  \",\"volumeNo\":1.5,\"memo\":\"確認メモ\",\"url\":\"\"}]}")

testDecodeExpectedValues :: IO ()
testDecodeExpectedValues =
  case eitherDecode payload of
    Right (BookUpdateBatch (proposed :| []) (Just (expected :| []))) -> do
      bookUpdateTitle proposed @?= "title"
      bookUpdateTitle expected @?= " title "
      bookUpdateAuthor expected @?= " author "
      bookUpdateCategory expected @?= " category "
      bookUpdateSeries expected @?= Just " series "
      bookUpdateUrl expected @?= Just " url "
      bookUpdateMemo expected @?= "  memo\n"
    other -> assertFailure ("unexpected batch: " <> show other)
 where
  payload = "{\"books\":[{\"id\":1,\"title\":\" title \",\"author\":\"author\",\"status\":\"unread\",\"category\":\"category\"}],\"expected\":[{\"id\":1,\"title\":\" title \",\"author\":\" author \",\"status\":\"unread\",\"category\":\" category \",\"series\":\" series \",\"volumeNo\":null,\"memo\":\"  memo\\n\",\"url\":\" url \"}]}"

testRejectIncompleteExpected :: IO ()
testRejectIncompleteExpected = mapM_ rejects
  [ "null"
  , "[]"
  , "[{\"id\":1,\"title\":\"title\",\"author\":\"author\",\"status\":\"unread\",\"category\":\"category\"}]"
  ]
 where
  rejects expected =
    case eitherDecode ("{\"books\":[{\"id\":1,\"title\":\"title\",\"author\":\"author\",\"status\":\"unread\",\"category\":\"category\"}],\"expected\":" <> expected <> "}") :: Either String BookUpdateBatch of
      Left _ -> pure ()
      Right decoded -> assertFailure ("unexpected batch: " <> show decoded)

testRejectEmptyEditorBatch :: IO ()
testRejectEmptyEditorBatch =
  case eitherDecode "{\"books\":[]}" :: Either String BookUpdateBatch of
    Left err -> assertBool "error should explain the non-empty contract" ("at least one" `isInfixOf` err)
    Right decoded -> assertFailure ("unexpected batch: " <> show decoded)

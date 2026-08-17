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
    ]

testDecodeEditorBatch :: IO ()
testDecodeEditorBatch =
  case eitherDecode payload of
    Left err -> assertFailure err
    Right (BookUpdateBatch (book :| [])) -> do
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

testRejectEmptyEditorBatch :: IO ()
testRejectEmptyEditorBatch =
  case eitherDecode "{\"books\":[]}" :: Either String BookUpdateBatch of
    Left err -> assertBool "error should explain the non-empty contract" ("at least one" `isInfixOf` err)
    Right decoded -> assertFailure ("unexpected batch: " <> show decoded)

{-# LANGUAGE OverloadedStrings #-}

module BookLedger.ExportTest (tests) where

import BookLedger.Domain
import BookLedger.Export (renderCsv, renderHtml)
import Control.Monad (forM_)
import qualified Data.Text as T
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "Export"
    [ testCase "quotes CSV fields without losing embedded text" testCsvEscaping
    , testCase "escapes book data in HTML and attributes" testHtmlEscaping
    , testCase "renders a self-contained read-only browsing surface" testReadOnlySurface
    ]

testCsvEscaping :: IO ()
testCsvEscaping = do
  let csv = renderCsv [dangerousBook]
  assertBool "double quotes should be doubled" ("alert(\"\"x\"\")" `T.isInfixOf` csv)
  assertBool "newlines should remain inside the quoted memo" ("\"1行目\n2行目 <em>\"" `T.isInfixOf` csv)

testHtmlEscaping :: IO ()
testHtmlEscaping = do
  let rendered = renderHtml [dangerousBook]
  assertBool
    "title markup should be escaped"
    ("&lt;script&gt;alert(&quot;x&quot;)&lt;/script&gt; &amp;" `T.isInfixOf` rendered)
  assertBool
    "raw title markup should not survive"
    (not ("<script>alert(\"x\")</script> &" `T.isInfixOf` rendered))
  assertBool
    "URL attribute should be escaped"
    ("https://example.com/?a=1&amp;b=&quot;two&quot;" `T.isInfixOf` rendered)
  assertBool
    "memo markup should be escaped while preserving line breaks"
    ("1行目<br>2行目 &lt;em&gt;" `T.isInfixOf` rendered)

testReadOnlySurface :: IO ()
testReadOnlySurface = do
  let rendered = renderHtml [dangerousBook]
      controls = ["search", "sort", "status", "category", "series", "clear"]
  forM_ controls $ \controlId ->
    assertBool
      ("missing control: " <> T.unpack controlId)
      (("id=\"" <> controlId <> "\"") `T.isInfixOf` rendered)
  T.count "<article class=\"book\"" rendered @?= 1
  assertBool "forms should not be exported" (not ("<form" `T.isInfixOf` rendered))
  assertBool "network fetches should not be exported" (not ("fetch(" `T.isInfixOf` rendered))
  assertBool "external scripts should not be exported" (not ("<script src=" `T.isInfixOf` rendered))
  assertBool "external stylesheets should not be exported" (not ("rel=\"stylesheet\"" `T.isInfixOf` rendered))

dangerousBook :: Book
dangerousBook =
  Book
    { bookId = 7
    , bookTitle = "<script>alert(\"x\")</script> &"
    , bookAuthor = "著者 > 共著者"
    , bookStatus = Reading
    , bookCategory = "A&B"
    , bookSeries = Just "x<y"
    , bookVolumeNo = Just 2
    , bookMemo = "1行目\n2行目 <em>"
    , bookUrl = Just "https://example.com/?a=1&b=\"two\""
    , bookCreatedAt = "2026-01-02 03:04:05"
    , bookUpdatedAt = "2026-02-03 04:05:06"
    }

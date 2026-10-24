{-# LANGUAGE OverloadedStrings #-}

module BookLedger.ExportTest (tests) where

import BookLedger.Domain
import BookLedger.Export (renderCsv, renderHtml, renderHtmlAt)
import Control.Monad (forM_)
import Data.Aeson (Value(..), eitherDecodeStrict', toJSON)
import qualified Data.Aeson.KeyMap as KeyMap
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Time (UTCTime(..), fromGregorian, secondsToDiffTime)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests = testGroup "Export"
  [ testCase "CSV quoting and embedded newlines retain their original semantics" $ do
      let csv = renderCsv [dangerousBook]
      assertBool "quotes doubled" ("alert(\"\"x\"\")" `T.isInfixOf` csv)
      assertBool "memo newlines preserved" ("\"1行目\n2行目 <em>\"" `T.isInfixOf` csv)
      T.lines (renderCsv []) @?= ["\"タイトル\",\"著者\",\"状態\",\"カテゴリ\",\"シリーズ\",\"巻\",\"URL\",\"メモ\",\"更新日時\""]
  , testCase "escapes fallback text and link attributes without losing readable Unicode" $ do
      let rendered = renderHtml [dangerousBook]
      assertBool "title escaped" ("&lt;script&gt;alert(&quot;x&quot;)&lt;/script&gt; &amp;" `T.isInfixOf` rendered)
      assertBool "raw title cannot become markup" (not (bookTitle dangerousBook `T.isInfixOf` rendered))
      assertBool "URL attribute escaped" ("href=\"https://example.com/?a=1&amp;b=&quot;two&quot;\"" `T.isInfixOf` rendered)
      assertBool "memo HTML escaped with raw newlines" ("1行目\n2行目 &lt;em&gt;" `T.isInfixOf` rendered)
      T.count "<article class=\"fallback-book\"" rendered @?= 1
  , testCase "JSON script data round trips script closings, quotes, Unicode and paragraph separators" $ do
      let book = dangerousBook { bookTitle = "</ScRiPt><script>alert('雪')\x2028\x2029", bookMemo = "@@SCRIPT@@\n& < > \" '" }
          rendered = renderHtmlAt snapshotTime [book]
          payload = dataScript rendered
      assertBool "no raw HTML open bracket in JSON script" (not ("<" `T.isInfixOf` payload))
      assertBool "line separators escaped" ("\\u2028\\u2029" `T.isInfixOf` payload)
      T.count "</script>" rendered @?= 2
      case eitherDecodeStrict' (TE.encodeUtf8 payload) of
        Right (Object value) -> do
          KeyMap.lookup "books" value @?= Just (toJSON [book])
          KeyMap.lookup "generatedAt" value @?= Just (String "2026-10-24T12:34:56Z")
        Right _ -> assertFailure "snapshot payload should be a JSON object"
        Left message -> assertFailure message
  , testCase "read-only viewer is self-contained and exposes no write controls" $ do
      let rendered = renderHtmlAt snapshotTime [dangerousBook]
      forM_ ["search", "sort", "status-nav", "category-nav", "series-nav", "status-filter", "category-filter", "series-filter", "filter-menu", "details", "fallback"] $ \control ->
        assertBool ("missing control " <> T.unpack control) (("id=\"" <> control <> "\"") `T.isInfixOf` rendered)
      forM_ ["<form", "<script src=", "rel=\"stylesheet\"", "fetch(", "localStorage", "sessionStorage", "data-action=\"add\"", "data-action=\"save\"", "data-action=\"undo\"", "data-action=\"table-edit\"", "data-book-status", "contenteditable="] $ \fragment ->
        assertBool ("unexpected dependency/write control " <> T.unpack fragment) (not (fragment `T.isInfixOf` rendered))
      assertBool "status is readable text" ("読書中" `T.isInfixOf` rendered)
      assertBool "offline fallback remains readable" ("<details><summary>" `T.isInfixOf` rendered)
      forM_ ["@@STYLE@@", "@@SCRIPT@@", "@@DATA@@", "@@FALLBACK@@", "@@STAMP@@"] $ \marker ->
        assertBool "all asset slots must be filled" (not (marker `T.isInfixOf` rendered))
  , testCase "snapshot generation time is explicit and does not come from a book update" $ do
      let rendered = renderHtmlAt snapshotTime [dangerousBook { bookUpdatedAt = "1999-01-01 00:00:00" }]
      assertBool "generation timestamp" ("<time datetime=\"2026-10-24T12:34:56Z\">2026-10-24 12:34 UTC</time>" `T.isInfixOf` rendered)
      assertBool "legacy API does not invent a timestamp" ("作成日時不明" `T.isInfixOf` renderHtml [dangerousBook])
  , testCase "unsafe or missing URL schemes cannot become fallback links" $
      forM_ ["javascript:alert(1)", "JaVaScRiPt:alert(1)", "data:text/html,hello", "//example.com", "https://", "http://", "https://exa mple.com", "https://example.com\\evil"] $ \url -> do
        let rendered = renderHtml [dangerousBook { bookUrl = Just url }]
            fallback = fst (T.breakOn "<script id=\"snapshot-data\"" (snd (T.breakOn "<main id=\"fallback\"" rendered)))
        assertBool ("unsafe link " <> T.unpack url) (not ("class=\"external-link\" href=" `T.isInfixOf` fallback))
  , testCase "template marker text in book fields is preserved without recursive substitution" $ do
      let rendered = renderHtml [dangerousBook { bookTitle = "@@STYLE@@", bookMemo = "@@DATA@@\n@@SCRIPT@@" }]
      assertBool "title marker is literal" ("class=\"fallback-title\">@@STYLE@@</span>" `T.isInfixOf` rendered)
      assertBool "memo markers are literal" ("@@DATA@@\n@@SCRIPT@@</p>" `T.isInfixOf` rendered)
  , testCase "an empty snapshot stays a useful read-only document" $ do
      let rendered = renderHtmlAt snapshotTime []
      assertBool "empty message" ("<p>本がありません</p>" `T.isInfixOf` rendered)
      assertBool "no add action" (not ("data-action=\"add\"" `T.isInfixOf` rendered))
  ]

dataScript :: T.Text -> T.Text
dataScript rendered =
  let (_, scriptAndRest) = T.breakOn "<script id=\"snapshot-data\"" rendered
      (_, afterOpen) = T.breakOn ">" scriptAndRest
   in T.strip (fst (T.breakOn "</script>" (T.drop 1 afterOpen)))

snapshotTime :: UTCTime
snapshotTime = UTCTime (fromGregorian 2026 10 24) (secondsToDiffTime (12 * 3600 + 34 * 60 + 56))

dangerousBook :: Book
dangerousBook = Book
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

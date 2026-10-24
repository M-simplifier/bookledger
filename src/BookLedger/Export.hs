{-# LANGUAGE OverloadedStrings #-}

module BookLedger.Export
  ( renderCsv
  , renderHtml
  , renderHtmlAt
  ) where

import BookLedger.Domain
import BookLedger.Export.Assets (viewerCss, viewerHtml, viewerScript)
import Control.Applicative ((<|>))
import Data.Aeson (encode, object, (.=))
import qualified Data.ByteString.Lazy as BL
import Data.Char (isControl, ord)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Time (UTCTime, defaultTimeLocale, formatTime)

renderCsv :: [Book] -> Text
renderCsv books =
  T.unlines (header : map renderRow books)
 where
  header =
    csvRow
      [ "タイトル"
      , "著者"
      , "状態"
      , "カテゴリ"
      , "シリーズ"
      , "巻"
      , "URL"
      , "メモ"
      , "更新日時"
      ]
  renderRow book =
    csvRow
      [ bookTitle book
      , bookAuthor book
      , statusLabel (bookStatus book)
      , bookCategory book
      , fromMaybe "" (bookSeries book)
      , maybe "" (T.pack . show) (bookVolumeNo book)
      , fromMaybe "" (bookUrl book)
      , bookMemo book
      , bookUpdatedAt book
      ]

csvRow :: [Text] -> Text
csvRow = T.intercalate "," . map csvCell

csvCell :: Text -> Text
csvCell value = "\"" <> T.replace "\"" "\"\"" value <> "\""

-- Callers without a clock retain a pure API without inventing a snapshot date.
renderHtml :: [Book] -> Text
renderHtml = renderDocument Nothing

renderHtmlAt :: UTCTime -> [Book] -> Text
renderHtmlAt generatedAt = renderDocument (Just generatedAt)

renderDocument :: Maybe UTCTime -> [Book] -> Text
renderDocument generatedAt books =
  T.unlines (map insertAsset (T.lines viewerHtml))
 where
  insertAsset line = case line of
    "@@STYLE@@" -> viewerCss
    "@@SCRIPT@@" -> viewerScript
    "@@STAMP@@" -> snapshotStamp generatedAt
    "@@FALLBACK@@" -> fallbackHtml generatedAt books
    "@@DATA@@" -> snapshotJson generatedAt books
    _ -> line

snapshotJson :: Maybe UTCTime -> [Book] -> Text
snapshotJson generatedAt books =
  scriptSafe
    ( TE.decodeUtf8 . BL.toStrict . encode $
        object
          [ "generatedAt" .= fmap generatedIso generatedAt
          , "books" .= books
          ]
    )

generatedIso :: UTCTime -> Text
generatedIso = T.pack . formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ"

scriptSafe :: Text -> Text
scriptSafe = T.concatMap escape
 where
  escape '<' = "\\u003c"
  escape '>' = "\\u003e"
  escape '&' = "\\u0026"
  escape '\x2028' = "\\u2028"
  escape '\x2029' = "\\u2029"
  escape character = T.singleton character

snapshotStamp :: Maybe UTCTime -> Text
snapshotStamp Nothing = "<span>閲覧用 · 作成日時不明</span>"
snapshotStamp (Just generatedAt) =
  "<span>閲覧用 · 作成 <time datetime=\"" <> generatedIso generatedAt <> "\">"
    <> T.pack (formatTime defaultTimeLocale "%Y-%m-%d %H:%M UTC" generatedAt)
    <> "</time></span>"

fallbackHtml :: Maybe UTCTime -> [Book] -> Text
fallbackHtml generatedAt books =
  "<main id=\"fallback\" class=\"fallback\" aria-label=\"蔵書一覧\"><header><h1>books</h1>"
    <> snapshotStamp generatedAt
    <> "<p>" <> T.pack (show (length books)) <> "冊</p></header>"
    <> T.concat (map fallbackBook books)
    <> (if null books then "<p>本がありません</p>" else "")
    <> "</main>"

fallbackBook :: Book -> Text
fallbackBook book =
  "<article class=\"fallback-book\"><details><summary><span class=\"fallback-title\">"
    <> html (bookTitle book) <> "</span><span class=\"fallback-author\">" <> html (bookAuthor book)
    <> "</span><span class=\"fallback-status\">" <> html (statusLabel (bookStatus book)) <> "</span></summary>"
    <> "<div class=\"fallback-detail\"><dl>"
    <> fact "カテゴリ" (bookCategory book)
    <> maybe "" (fact "シリーズ") (bookSeries book)
    <> maybe "" (fact "巻数" . T.pack . show) (bookVolumeNo book)
    <> "</dl>"
    <> (if T.null (bookMemo book) then "" else "<h3>メモ</h3><p class=\"fallback-memo\">" <> html (bookMemo book) <> "</p>")
    <> maybe "" safeLink (bookUrl book >>= safeHttpUrl)
    <> "</div></details></article>"
 where
  fact label value = "<div><dt>" <> label <> "</dt><dd>" <> html value <> "</dd></div>"
  safeLink url = "<a class=\"external-link\" href=\"" <> html url <> "\" target=\"_blank\" rel=\"noopener noreferrer\">登録したページを開く ↗</a>"

safeHttpUrl :: Text -> Maybe Text
safeHttpUrl raw
  | T.any forbidden value = Nothing
  | T.null authority = Nothing
  | otherwise = case scheme of
      Just _ -> Just value
      Nothing -> Nothing
 where
  value = T.strip raw
  scheme = T.stripPrefix "https://" (T.toLower value) <|> T.stripPrefix "http://" (T.toLower value)
  authority = maybe "" (T.takeWhile (`notElem` ("/?#" :: String))) scheme
  forbidden character = isControl character || ord character <= 32 || character == '\\'

html :: Text -> Text
html = T.concatMap escape
 where
  escape '&' = "&amp;"
  escape '<' = "&lt;"
  escape '>' = "&gt;"
  escape '"' = "&quot;"
  escape '\'' = "&#39;"
  escape character = T.singleton character

{-# LANGUAGE OverloadedStrings #-}

module BookLedger.Export
  ( renderCsv
  , renderHtml
  ) where

import BookLedger.Domain
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T

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
csvCell value =
  "\"" <> T.replace "\"" "\"\"" value <> "\""

renderHtml :: [Book] -> Text
renderHtml books =
  T.concat
    [ "<!doctype html>\n"
    , "<html lang=\"ja\">\n"
    , "<head>\n"
    , "  <meta charset=\"utf-8\">\n"
    , "  <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n"
    , "  <title>Bookledger Latest</title>\n"
    , "  <style>\n"
    , css
    , "  </style>\n"
    , "</head>\n"
    , "<body>\n"
    , "  <main>\n"
    , "    <header>\n"
    , "      <div>\n"
    , "        <h1>Bookledger</h1>\n"
    , "        <p><span id=\"count\">", T.pack (show (length books)), "</span> 件</p>\n"
    , "      </div>\n"
    , "    </header>\n"
    , "    <input id=\"search\" type=\"search\" placeholder=\"タイトル・著者・メモを検索\" autocomplete=\"off\">\n"
    , "    <section id=\"books\" aria-label=\"books\">\n"
    , T.concat (map renderCard books)
    , "    </section>\n"
    , "  </main>\n"
    , "  <script>\n"
    , script
    , "  </script>\n"
    , "</body>\n"
    , "</html>\n"
    ]

renderCard :: Book -> Text
renderCard book =
  T.concat
    [ "      <article class=\"book\" data-search=\""
    , attr (searchText book)
    , "\">\n"
    , "        <div class=\"title\">"
    , titleHtml book
    , "</div>\n"
    , "        <div class=\"meta\">"
    , html (bookAuthor book)
    , " / "
    , html (statusLabel (bookStatus book))
    , " / "
    , html (bookCategory book)
    , seriesHtml book
    , volumeHtml book
    , "</div>\n"
    , memoHtml book
    , "      </article>\n"
    ]

titleHtml :: Book -> Text
titleHtml book =
  case bookUrl book of
    Nothing -> html (bookTitle book)
    Just url ->
      T.concat
        [ "<a href=\""
        , attr url
        , "\">"
        , html (bookTitle book)
        , "</a>"
        ]

seriesHtml :: Book -> Text
seriesHtml book =
  case bookSeries book of
    Nothing -> ""
    Just seriesTitle -> " / " <> html seriesTitle

volumeHtml :: Book -> Text
volumeHtml book =
  case bookVolumeNo book of
    Nothing -> ""
    Just volumeNo -> " / " <> html (T.pack (show volumeNo))

memoHtml :: Book -> Text
memoHtml book
  | T.null (T.strip (bookMemo book)) = ""
  | otherwise = "        <p class=\"memo\">" <> html (bookMemo book) <> "</p>\n"

searchText :: Book -> Text
searchText book =
  T.toLower
    ( T.unwords
        [ bookTitle book
        , bookAuthor book
        , statusLabel (bookStatus book)
        , bookCategory book
        , fromMaybe "" (bookSeries book)
        , bookMemo book
        ]
    )

html :: Text -> Text
html =
  T.replace "\n" "<br>"
    . T.replace ">" "&gt;"
    . T.replace "<" "&lt;"
    . T.replace "\"" "&quot;"
    . T.replace "&" "&amp;"

attr :: Text -> Text
attr =
  T.replace "\n" " "
    . T.replace ">" "&gt;"
    . T.replace "<" "&lt;"
    . T.replace "\"" "&quot;"
    . T.replace "&" "&amp;"

css :: Text
css =
  T.unlines
    [ "    :root { color-scheme: light; --bg: #f7f8fa; --panel: #ffffff; --line: #d8dde5; --text: #17202a; --muted: #667085; --accent: #0f766e; }"
    , "    * { box-sizing: border-box; }"
    , "    body { margin: 0; background: var(--bg); color: var(--text); font: 15px/1.5 system-ui, -apple-system, BlinkMacSystemFont, \"Segoe UI\", sans-serif; }"
    , "    main { width: min(840px, calc(100vw - 24px)); margin: 18px auto 28px; }"
    , "    header { display: flex; justify-content: space-between; gap: 16px; align-items: end; margin-bottom: 12px; }"
    , "    h1 { margin: 0; font-size: 24px; letter-spacing: 0; }"
    , "    p { margin: 0; }"
    , "    header p { color: var(--muted); }"
    , "    input { width: 100%; border: 1px solid var(--line); border-radius: 8px; padding: 10px 12px; font: inherit; background: #fff; color: var(--text); margin-bottom: 12px; }"
    , "    .book { background: var(--panel); border: 1px solid var(--line); border-radius: 8px; padding: 12px 14px; margin-bottom: 10px; }"
    , "    .title { font-weight: 700; }"
    , "    .title a { color: var(--accent); text-decoration: none; }"
    , "    .title a:hover { text-decoration: underline; }"
    , "    .meta { color: var(--muted); font-size: 13px; margin-top: 4px; }"
    , "    .memo { color: #475467; margin-top: 8px; white-space: normal; }"
    , "    .hidden { display: none; }"
    ]

script :: Text
script =
  T.unlines
    [ "    const search = document.getElementById('search');"
    , "    const cards = [...document.querySelectorAll('.book')];"
    , "    const count = document.getElementById('count');"
    , "    search.addEventListener('input', () => {"
    , "      const query = search.value.trim().toLowerCase();"
    , "      let visible = 0;"
    , "      for (const card of cards) {"
    , "        const hit = !query || card.dataset.search.includes(query);"
    , "        card.classList.toggle('hidden', !hit);"
    , "        if (hit) visible += 1;"
    , "      }"
    , "      count.textContent = visible;"
    , "    });"
    ]

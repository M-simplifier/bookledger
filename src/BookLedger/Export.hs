{-# LANGUAGE OverloadedStrings #-}

module BookLedger.Export
  ( renderCsv
  , renderHtml
  ) where

import BookLedger.Domain
import Data.List (nub, sort)
import Data.Maybe (fromMaybe, mapMaybe)
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
    , "  <title>Bookledger</title>\n"
    , "  <style>\n"
    , css
    , "  </style>\n"
    , "</head>\n"
    , "<body>\n"
    , "  <main class=\"shell\">\n"
    , "    <header class=\"topbar\">\n"
    , "      <div>\n"
    , "        <h1>Bookledger</h1>\n"
    , "        <p id=\"summary\" aria-live=\"polite\">", T.pack (show (length books)), " 件</p>\n"
    , "      </div>\n"
    , "      <span class=\"mode\">閲覧専用</span>\n"
    , "    </header>\n"
    , "    <section class=\"toolbar\" aria-label=\"蔵書の検索と絞り込み\">\n"
    , "      <label class=\"field search-field\">\n"
    , "        <span>検索</span>\n"
    , "        <input id=\"search\" type=\"search\" placeholder=\"タイトル・著者・メモを検索\" autocomplete=\"off\" enterkeyhint=\"search\">\n"
    , "      </label>\n"
    , "      <div class=\"filters\">\n"
    , "        <label class=\"field\"><span>並び順</span><select id=\"sort\">\n"
    , "          <option value=\"active\">状態順</option>\n"
    , "          <option value=\"updated\">更新順</option>\n"
    , "          <option value=\"catalog\">目録順</option>\n"
    , "        </select></label>\n"
    , "        <label class=\"field\"><span>状態</span><select id=\"status\">\n"
    , "          <option value=\"\">すべての状態</option>\n"
    , T.concat (map renderStatusOption allStatuses)
    , "        </select></label>\n"
    , "        <label class=\"field\"><span>カテゴリ</span><select id=\"category\">\n"
    , "          <option value=\"\">すべてのカテゴリ</option>\n"
    , T.concat (map renderTextOption categories)
    , "        </select></label>\n"
    , "        <label class=\"field\"><span>シリーズ</span><select id=\"series\">\n"
    , "          <option value=\"\">すべてのシリーズ</option>\n"
    , T.concat (map renderTextOption seriesTitles)
    , "        </select></label>\n"
    , "        <button id=\"clear\" class=\"clear\" type=\"button\">絞り込みを解除</button>\n"
    , "      </div>\n"
    , "    </section>\n"
    , "    <section id=\"books\" class=\"books\" aria-label=\"蔵書一覧\">\n"
    , T.concat (zipWith renderCard [0 :: Int ..] books)
    , "    </section>\n"
    , "    <p id=\"empty\" class=\"empty\" hidden>該当する本はありません。</p>\n"
    , "  </main>\n"
    , "  <script>\n"
    , script
    , "  </script>\n"
    , "</body>\n"
    , "</html>\n"
    ]
 where
  categories = uniqueSorted (map bookCategory books)
  seriesTitles = uniqueSorted (mapMaybe bookSeries books)

renderStatusOption :: Status -> Text
renderStatusOption status =
  T.concat
    [ "          <option value=\""
    , attr (statusText status)
    , "\">"
    , html (statusLabel status)
    , "</option>\n"
    ]

renderTextOption :: Text -> Text
renderTextOption value =
  T.concat
    [ "          <option value=\""
    , attr value
    , "\">"
    , html value
    , "</option>\n"
    ]

uniqueSorted :: [Text] -> [Text]
uniqueSorted = nub . sort

renderCard :: Int -> Book -> Text
renderCard catalogIndex book =
  T.concat
    [ "      <article class=\"book\" data-search=\""
    , attr (searchText book)
    , "\" data-status=\""
    , attr (statusText (bookStatus book))
    , "\" data-category=\""
    , attr (bookCategory book)
    , "\" data-series=\""
    , attr (fromMaybe "" (bookSeries book))
    , "\" data-updated=\""
    , attr (bookUpdatedAt book)
    , "\" data-id=\""
    , T.pack (show (bookId book))
    , "\" data-catalog-index=\""
    , T.pack (show catalogIndex)
    , "\">\n"
    , "        <div class=\"book-heading\">\n"
    , "          <h2 class=\"title\">"
    , titleHtml book
    , "</h2>\n"
    , "          <span class=\"status status-"
    , attr (statusText (bookStatus book))
    , "\">"
    , html (statusLabel (bookStatus book))
    , "</span>\n"
    , "        </div>\n"
    , "        <p class=\"author\">"
    , html (bookAuthor book)
    , "</p>\n"
    , "        <div class=\"facts\">\n"
    , factHtml "カテゴリ" (bookCategory book)
    , maybe "" (factHtml "シリーズ") (bookSeries book)
    , maybe "" (factHtml "巻" . formatVolume) (bookVolumeNo book)
    , "        </div>\n"
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
        , "\" target=\"_blank\" rel=\"noreferrer\">"
        , html (bookTitle book)
        , "</a>"
        ]

factHtml :: Text -> Text -> Text
factHtml label value =
  T.concat
    [ "          <span class=\"fact\"><span class=\"fact-label\">"
    , html label
    , "</span> "
    , html value
    , "</span>\n"
    ]

formatVolume :: Double -> Text
formatVolume = T.pack . show

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
        , statusText (bookStatus book)
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
    [ "    :root { color-scheme: light; --bg: #f4f6f8; --panel: #ffffff; --line: #d8dde5; --text: #17202a; --muted: #667085; --accent: #0f766e; --accent-soft: #dff4f0; --shadow: 0 1px 2px rgba(16, 24, 40, 0.06); }"
    , "    * { box-sizing: border-box; }"
    , "    html { -webkit-text-size-adjust: 100%; }"
    , "    body { margin: 0; background: var(--bg); color: var(--text); font: 15px/1.55 ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, \"Segoe UI\", sans-serif; }"
    , "    button, input, select { min-height: 44px; font: inherit; }"
    , "    button, select { cursor: pointer; }"
    , "    [hidden] { display: none !important; }"
    , "    .shell { width: min(100% - 24px, 900px); margin: 14px auto 36px; }"
    , "    .topbar { display: flex; justify-content: space-between; align-items: flex-start; gap: 16px; margin-bottom: 12px; }"
    , "    h1 { margin: 0; font-size: 24px; line-height: 1.25; letter-spacing: -0.01em; }"
    , "    h2, p { margin: 0; }"
    , "    .topbar p { margin-top: 3px; color: var(--muted); }"
    , "    .mode { flex: none; border: 1px solid #9fd5ca; border-radius: 999px; background: var(--accent-soft); color: #0b5f59; padding: 4px 9px; font-size: 12px; font-weight: 700; }"
    , "    .toolbar { background: var(--panel); border: 1px solid var(--line); border-radius: 12px; box-shadow: var(--shadow); padding: 12px; margin-bottom: 12px; }"
    , "    .field { display: grid; gap: 5px; color: #475467; font-size: 12px; font-weight: 700; }"
    , "    .field input, .field select { width: 100%; border: 1px solid var(--line); border-radius: 9px; background: #fff; color: var(--text); padding: 9px 11px; font-weight: 400; }"
    , "    .field input:focus, .field select:focus { border-color: var(--accent); outline: 3px solid rgba(15, 118, 110, 0.13); }"
    , "    .search-field { margin-bottom: 10px; }"
    , "    .filters { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 9px; }"
    , "    .clear { grid-column: 1 / -1; width: 100%; border: 1px solid var(--line); border-radius: 9px; background: #fff; color: #344054; padding: 9px 11px; }"
    , "    .clear:hover { background: #f8fafc; }"
    , "    .books { display: grid; gap: 10px; }"
    , "    .book { min-width: 0; background: var(--panel); border: 1px solid var(--line); border-radius: 12px; box-shadow: var(--shadow); padding: 13px 14px; }"
    , "    .book-heading { display: flex; align-items: flex-start; justify-content: space-between; gap: 10px; }"
    , "    .title { min-width: 0; font-size: 17px; line-height: 1.4; overflow-wrap: anywhere; }"
    , "    .title a { color: #0b5f59; text-decoration: none; }"
    , "    .title a:hover, .title a:focus { text-decoration: underline; }"
    , "    .status { flex: none; border-radius: 999px; background: #eef2f6; color: #475467; padding: 3px 8px; font-size: 12px; font-weight: 700; white-space: nowrap; }"
    , "    .status-reading { background: #dff4f0; color: #0b5f59; }"
    , "    .status-planned { background: #fff1d6; color: #8a4b08; }"
    , "    .status-finished { background: #e8edff; color: #36458c; }"
    , "    .status-disposed { background: #f2f4f7; color: #667085; }"
    , "    .author { margin-top: 5px; color: #475467; overflow-wrap: anywhere; }"
    , "    .facts { display: flex; flex-wrap: wrap; gap: 5px 8px; margin-top: 9px; color: var(--muted); font-size: 12px; }"
    , "    .fact { border-radius: 6px; background: #f2f4f7; padding: 3px 7px; overflow-wrap: anywhere; }"
    , "    .fact-label { color: #344054; font-weight: 700; }"
    , "    .memo { margin-top: 10px; border-top: 1px solid #eaecf0; padding-top: 9px; color: #475467; white-space: normal; overflow-wrap: anywhere; }"
    , "    .empty { background: var(--panel); border: 1px dashed var(--line); border-radius: 12px; padding: 24px 14px; color: var(--muted); text-align: center; }"
    , "    @media (min-width: 620px) {"
    , "      .shell { margin-top: 24px; }"
    , "      .clear { align-self: end; }"
    , "    }"
    , "    @media (min-width: 860px) {"
    , "      .filters { grid-template-columns: repeat(4, minmax(0, 1fr)) auto; align-items: end; }"
    , "      .clear { grid-column: auto; width: auto; white-space: nowrap; }"
    , "      .book { padding: 15px 16px; }"
    , "    }"
    ]

script :: Text
script =
  T.unlines
    [ "    const $ = (id) => document.getElementById(id);"
    , "    const cards = [...document.querySelectorAll('.book')];"
    , "    const statusRank = { reading: 0, unread: 1, planned: 2, finished: 3, disposed: 4 };"
    , ""
    , "    function compareCards(left, right) {"
    , "      if ($('sort').value === 'catalog') {"
    , "        return Number(left.dataset.catalogIndex) - Number(right.dataset.catalogIndex);"
    , "      }"
    , "      const updated = right.dataset.updated.localeCompare(left.dataset.updated);"
    , "      if ($('sort').value === 'updated') {"
    , "        return updated || Number(right.dataset.id) - Number(left.dataset.id);"
    , "      }"
    , "      const status = (statusRank[left.dataset.status] ?? 99) - (statusRank[right.dataset.status] ?? 99);"
    , "      return status || updated || Number(right.dataset.id) - Number(left.dataset.id);"
    , "    }"
    , ""
    , "    function applyView() {"
    , "      const query = $('search').value.trim().toLocaleLowerCase('ja');"
    , "      const status = $('status').value;"
    , "      const category = $('category').value;"
    , "      const series = $('series').value;"
    , "      let visible = 0;"
    , ""
    , "      cards.sort(compareCards);"
    , "      for (const card of cards) {"
    , "        const hit ="
    , "          (!query || card.dataset.search.includes(query)) &&"
    , "          (!status || card.dataset.status === status) &&"
    , "          (!category || card.dataset.category === category) &&"
    , "          (!series || card.dataset.series === series);"
    , "        card.hidden = !hit;"
    , "        if (hit) visible += 1;"
    , "        $('books').append(card);"
    , "      }"
    , ""
    , "      $('summary').textContent = visible === cards.length"
    , "        ? cards.length + ' 件'"
    , "        : visible + ' / ' + cards.length + ' 件';"
    , "      $('empty').hidden = visible !== 0;"
    , "    }"
    , ""
    , "    $('search').addEventListener('input', applyView);"
    , "    for (const id of ['sort', 'status', 'category', 'series']) {"
    , "      $(id).addEventListener('change', applyView);"
    , "    }"
    , "    $('clear').addEventListener('click', () => {"
    , "      $('search').value = '';"
    , "      $('sort').value = 'active';"
    , "      $('status').value = '';"
    , "      $('category').value = '';"
    , "      $('series').value = '';"
    , "      applyView();"
    , "      $('search').focus();"
    , "    });"
    , ""
    , "    applyView();"
    ]

# Bookledger

A small local-first book ledger backed by SQLite, with a CLI and a web UI.

## Features

- CLI for adding and listing books
- A quiet, responsive web UI with search and navigation by status, category, or series
- Book details, separate category and series creation, and bulk changes
- Staged, atomic table editing with protection against overwriting newer edits
- SQLite storage and snapshot backups to a local folder
- CSV and searchable, read-only HTML exports

## Install

```sh
cabal install exe:books
```

To update an existing installation from this checkout:

```sh
cabal install exe:books --overwrite-policy=always
```

## Usage

```sh
books init
books add "砂の女" --author "安部公房" --category 小説
books add "Example Book" --author "Example" --category 一般書 --status planned --url "https://example.com/book"
books list
books web
books backup
```

Initial categories are `未分類`, `小説`, `専門書`, and `一般書`.
Statuses are `planned`, `unread`, `reading`, `finished`, and `disposed`.
CLI listings use plain text.

## Web UI

Run `books web` to open the local UI.

- The sidebar opens one collection at a time. Selecting `未読` opens all unread
  books, even if a category or series was selected before it.
- Use `絞り込み` above the list to combine conditions within the current
  collection. Search also stays within that collection. Opening a different
  sidebar collection clears the search and added conditions.
- Select a title to edit its details and memo or open its saved URL. Use
  `追加` to add a book; the current collection supplies relevant defaults.
- The category and series `+` buttons each open their own small creation form.
- Use `選択` for bulk status/category changes. Open `表で編集` from `…` to edit
  different fields across several books, then save them together.

Table edits remain in the browser until saved. Filtering or moving to another
collection retains pending edits, including rows currently out of view. Invalid
input blocks the whole save. The `/?mode=edit` entry point also opens table editing.

Saved changes go to SQLite and are shared with the CLI. If a book changed after
it was loaded for editing, saving is rejected rather than overwriting the newer
values. `元に戻す` reverses book edits in the current browser session using the
same check. Adding a book, category, or series clears this edit history;
creation is not an undoable deletion operation. Reloading the page also clears undo history.

Backup warnings are shown separately from successful saves. If a save result
cannot be confirmed, refresh the list before retrying.

## Backups and configuration

Backups write `latest.sqlite`, timestamped SQLite snapshots, and refreshed
`latest.csv` / `latest.html` read-only exports in the backup directory.

Config is read from `~/.config/bookledger/config.toml`.
See `example-config.toml` for the SQLite and backup paths.

## Tests

```sh
cabal test all
node --test test/web/*.test.cjs
```

The Haskell tests use fresh SQLite databases and backup directories under the
system temporary directory. They never read the configured production ledger.
The web tests use Node.js 24 and synthetic fixtures, with no package installation
or access to a running ledger. GitHub Actions runs both suites on Linux.
See the [CI performance experiment](docs/ci-performance.md) for measured Haskell
cold and cached build times.

This is a small personal tool. PRs are not accepted. Issues are welcome, but
responses and fixes are not guaranteed.

## License

MIT

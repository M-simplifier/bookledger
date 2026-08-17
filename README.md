# Bookledger

A small local-first book ledger backed by SQLite.

## Features

- CLI for adding and listing books
- Minimal local web UI
- Safe book-information editing mode with staged, atomic batch saves
- SQLite database
- Snapshot backups to a local folder
- Mobile-first, read-only HTML snapshots with the web UI's search, filters,
  and sorting

## Install

```sh
cabal install exe:books
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
Books can store an optional `url`; in the web UI, titles with URLs open that
link.
The normal web view keeps only status and memo editable. Use
`書籍情報を編集` or open `/?mode=edit` when correcting titles, authors,
categories, series, volume numbers, URLs, and other book details. Changes stay
in the browser until they are saved together.
Backups write `latest.sqlite`, timestamped SQLite snapshots, and refreshed
`latest.csv` / `latest.html` read-only exports in the backup directory.

Config is read from `~/.config/bookledger/config.toml`.
See `example-config.toml` for the SQLite and backup paths.

## Tests

```sh
cabal test all
```

The test suite uses fresh SQLite databases and backup directories under the
system temporary directory. It never reads the configured production ledger.
GitHub Actions builds all targets and runs the same test suite on Linux.
See the [CI performance experiment](docs/ci-performance.md) for measured cold
and cached build times.

This is a small personal tool. PRs are not accepted. Issues are welcome, but
responses and fixes are not guaranteed.

## License

MIT

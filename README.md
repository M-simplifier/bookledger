# Bookledger

A small local-first book ledger backed by SQLite.

## Features

- CLI for adding and listing books
- Minimal local web UI
- SQLite database
- Snapshot backups to a local folder

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

Config is read from `~/.config/bookledger/config.toml`.
See `example-config.toml` for the SQLite and backup paths.

This is a small personal tool. PRs are not accepted. Issues are welcome, but
responses and fixes are not guaranteed.

## License

MIT

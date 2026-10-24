'use strict';
const assert = require('node:assert/strict');
const test = require('node:test');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const plain = value => JSON.parse(JSON.stringify(value));
const keys = ['title', 'author', 'status', 'category', 'series', 'volumeNo', 'memo', 'url'];
const pick = book => Object.fromEntries(['id', ...keys].map(key => [key, book[key]]));
function modules() {
  const window = {};
  const context = vm.createContext({ window, URL, Intl });
  for (const name of ['model.js', 'store.js']) vm.runInContext(fs.readFileSync(path.join(__dirname, '../../static', name), 'utf8'), context);
  return window;
}
function fixture() {
  const window = modules();
  const meta = { categories: ['一般書', '専門書', '未分類'], series: ['試験シリーズ'], statuses: plain(window.BooksModel.statuses) };
  const book = (id, patch = {}) => ({ id, title: 'テスト書籍' + id, author: '著者' + id, status: 'unread', statusLabel: '未読', category: '一般書', series: null, volumeNo: null, memo: '', url: null, createdAt: '2026-01-01T00:00:00Z', updatedAt: '2026-01-01T00:00:00Z', ...patch });
  const server = { books: [book(1), book(2, { category: '専門書', series: '試験シリーズ' }), book(3, { status: 'reading' })], meta, calls: [], failRead: false, failAfterAck: false, unknown: false, warning: null, gate: null };
  const response = (status, body) => ({ status, ok: status >= 200 && status < 300, json: async () => plain(body) });
  server.fetch = async (url, init = {}) => {
    server.calls.push({ url, ...init, body: init.body && JSON.parse(init.body) });
    if (!init.method) {
      if (server.failRead) throw new Error('network down');
      if (url === '/api/meta') return response(200, server.meta);
      if (url === '/api/books') return response(200, server.books);
      throw new Error('unexpected GET');
    }
    if (server.gate) await server.gate;
    const body = JSON.parse(init.body);
    if (url === '/api/books/batch') {
      const stale = body.expected.some(before => JSON.stringify(pick(server.books.find(book => book.id === before.id) || {})) !== JSON.stringify(before));
      if (stale) return response(409, { ok: false, conflict: true, error: 'ほかの画面で変更されています。' });
      const changes = new Map(body.books.map(book => [book.id, book]));
      server.books = server.books.map(book => changes.has(book.id) ? { ...book, ...changes.get(book.id), updatedAt: '2026-10-24T12:00:00Z' } : book);
    } else if (url === '/api/books') server.books.push(book(Math.max(...server.books.map(book => book.id)) + 1, body));
    else if (url === '/api/categories') server.meta.categories.push(body.name);
    else if (url === '/api/series') server.meta.series.push(body.name);
    else throw new Error('unexpected POST');
    if (server.unknown) { server.unknown = false; throw new Error('response lost after commit'); }
    if (server.failAfterAck) server.failRead = true;
    return response(200, { ok: true, id: server.books.at(-1).id, updated: body.books?.length, warning: server.warning });
  };
  const store = window.BooksStore.createStore({ fetch: server.fetch });
  return { server, store, Model: window.BooksModel };
}

test('loads authoritative meta/books together; failed refresh keeps data and blocks writes until recovery', async () => {
  const { server, store } = fixture();
  assert.equal(store.getMeta().loaded, false);
  await store.load();
  assert.equal(store.getState().books.length, 3);
  assert.equal(store.getMeta().revision, 1);
  server.failRead = true;
  await assert.rejects(store.load(), error => error.kind === 'load');
  assert.equal(store.getState().books.length, 3);
  assert.equal(store.getMeta().blocked, true);
  await assert.rejects(store.updateBook(1, { memo: '変更' }), error => error.kind === 'blocked');
  assert.equal(server.calls.filter(call => call.method === 'POST').length, 0);
  server.failRead = false; await store.load();
  assert.equal(store.getMeta().blocked, false);
});

test('heterogeneous edits send complete expected values in one batch and refresh canonical data after acknowledgement', async () => {
  const { server, store } = fixture(); await store.load();
  const before = plain(store.getState().books);
  const result = await store.saveEdits([{ id: 1, patch: { memo: '一行目\n\n三行目' } }, { id: 2, patch: { url: 'https://example.com/book' } }]);
  assert.equal(result.acknowledged, true); assert.equal(result.refreshed, true);
  const posts = server.calls.filter(call => call.method === 'POST');
  assert.equal(posts.length, 1); assert.equal(posts[0].url, '/api/books/batch');
  assert.deepEqual(posts[0].body.expected, before.slice(0, 2).map(pick));
  assert.equal(posts[0].body.books[0].memo, '一行目\n\n三行目');
  assert.equal(store.getState().books[0].updatedAt, '2026-10-24T12:00:00Z');
  assert.equal(store.getState().books[1].url, 'https://example.com/book');
  assert.equal(store.getMeta().canUndo, true);
});

test('409 makes no client-side save, and an explicitly supplied edit baseline is not replaced by refresh', async () => {
  const { server, store } = fixture(); await store.load();
  const baseline = plain(store.getState().books[0]);
  server.books[0].memo = 'CLIの変更';
  const edits = [{ id: 1, patch: { memo: '自分の変更' }, expected: baseline }];
  await assert.rejects(store.saveEdits(edits), error => error.kind === 'conflict');
  assert.equal(store.getState().books[0].memo, '');
  assert.equal(store.getMeta().canUndo, false);
  await store.load();
  assert.equal(store.getState().books[0].memo, 'CLIの変更');
  await assert.rejects(store.saveEdits(edits), error => error.kind === 'conflict');
  const last = server.calls.filter(call => call.method === 'POST').at(-1);
  assert.equal(last.body.expected[0].memo, '');
  assert.equal(edits[0].patch.memo, '自分の変更');
  assert.equal(server.books[0].memo, 'CLIの変更');
});

test('backup warning is acknowledged success and remains visible separately from failure', async () => {
  const { server, store } = fixture(); await store.load(); server.warning = 'バックアップを保存できませんでした。';
  const result = await store.updateBook(1, { status: 'finished' });
  assert.equal(result.acknowledged, true); assert.equal(result.warning, server.warning);
  assert.equal(store.getMeta().warning, server.warning); assert.equal(store.getMeta().issue, null);
  assert.equal(store.getState().books[0].status, 'finished');
});

test('lost POST response never retries or pretends local success; a later reload reveals the authoritative outcome', async () => {
  const { server, store } = fixture(); await store.load(); server.unknown = true;
  await assert.rejects(store.updateBook(1, { memo: '応答前に保存' }), error => error.kind === 'unknown');
  assert.equal(store.getMeta().issue.kind, 'unknown'); assert.equal(store.getMeta().blocked, true);
  assert.equal(store.getState().books[0].memo, '');
  assert.equal(server.books[0].memo, '応答前に保存');
  await assert.rejects(store.updateBook(1, { memo: '再送' }), error => error.kind === 'blocked');
  assert.equal(server.calls.filter(call => call.method === 'POST').length, 1);
  server.failRead = true;
  await assert.rejects(store.load(), error => error.kind === 'unknown');
  assert.equal(store.getMeta().issue.kind, 'unknown');
  server.failRead = false; await store.load();
  assert.equal(store.getState().books[0].memo, '応答前に保存');
  assert.equal(store.getMeta().canUndo, false);
});

test('acknowledged save followed by failed refresh reports saved, blocks stale writes, and supports guarded undo after reload', async () => {
  const { server, store } = fixture(); await store.load(); server.failAfterAck = true;
  const result = await store.updateBook(1, { memo: '保存済み' });
  assert.equal(result.acknowledged, true); assert.equal(result.refreshed, false);
  assert.equal(store.getMeta().issue.kind, 'acknowledged');
  assert.match(store.getMeta().issue.message, /保存しました/);
  assert.equal(store.getMeta().canUndo, false);
  await assert.rejects(store.load(), error => error.kind === 'acknowledged');
  server.failAfterAck = false; server.failRead = false; await store.load();
  assert.equal(store.getMeta().canUndo, true);
  await store.undo();
  assert.equal(server.books[0].memo, '');
});

test('undo is one conditional inverse batch and refuses to clobber another writer', async () => {
  const { server, store } = fixture(); await store.load();
  await store.saveEdits([{ id: 1, patch: { status: 'finished' } }, { id: 2, patch: { memo: '2冊目' } }]);
  await store.undo();
  assert.equal(server.books[0].status, 'unread'); assert.equal(server.books[1].memo, '');
  assert.equal(server.calls.filter(call => call.method === 'POST').length, 2);
  await store.updateBook(1, { memo: '自分の保存' }); server.books[0].memo = '他の保存';
  await assert.rejects(store.undo(), error => error.kind === 'conflict');
  assert.equal(server.books[0].memo, '他の保存'); assert.equal(store.getMeta().canUndo, false);
});

test('add book/taxonomy clears edit undo; normalized values and raw memo are sent once', async () => {
  const { server, store } = fixture(); await store.load();
  await store.updateBook(1, { memo: '変更' });
  await store.addBook({ title: '  新しい本  ', author: '  著者  ', status: 'planned', category: '未分類', series: null, volumeNo: null, memo: '\nそのまま\n', url: null });
  assert.equal(store.getMeta().canUndo, false);
  assert.equal(server.books.at(-1).title, '新しい本'); assert.equal(server.books.at(-1).memo, '\nそのまま\n');
  await store.updateBook(1, { memo: '次の変更' }); await store.addCategory('  追加分類  ');
  assert.equal(store.getMeta().canUndo, false); assert.ok(store.getState().categories.includes('追加分類'));
  await store.updateBook(1, { memo: 'さらに変更' }); await store.addSeries('追加シリーズ');
  assert.equal(store.getMeta().canUndo, false); assert.ok(store.getState().series.includes('追加シリーズ'));
});

test('the shared request lock rejects duplicate submits and refresh races without sending a second POST', async () => {
  const { server, store } = fixture(); await store.load();
  let release; server.gate = new Promise(resolve => { release = resolve; });
  const saving = store.updateBook(1, { memo: '一回' });
  assert.equal(store.getMeta().busy, true); assert.equal(store.getMeta().saving, true);
  await assert.rejects(store.updateBook(1, { memo: '二回' }), error => error.kind === 'busy');
  await assert.rejects(store.load(), error => error.kind === 'busy');
  assert.equal(server.calls.filter(call => call.method === 'POST').length, 1);
  release(); await saving;
  assert.equal(store.getMeta().busy, false); assert.equal(server.books[0].memo, '一回');
});

test('invalid URL/numbers do not reach the server; existing legacy URL and volume are preserved on unrelated edits', async () => {
  const { server, store } = fixture(); server.books[0].url = 'legacy:link'; server.books[0].volumeNo = -2.5; await store.load();
  await store.updateBook(1, { memo: 'メモだけ' });
  assert.equal(server.books[0].url, 'legacy:link'); assert.equal(server.books[0].volumeNo, -2.5);
  const count = server.calls.filter(call => call.method === 'POST').length;
  for (const patch of [{ url: 'javascript:alert(1)' }, { volumeNo: -1 }, { volumeNo: 1.23 }, { title: ' ' }]) await assert.rejects(store.updateBook(1, patch));
  assert.equal(server.calls.filter(call => call.method === 'POST').length, count);
});

test('initial malformed/failed GET does not expose a writable fallback dataset', async () => {
  const { store } = fixture();
  await assert.rejects(store.updateBook(1, { memo: '未読込' }), error => error.kind === 'blocked');
  const { server, store: failed } = fixture(); server.failRead = true;
  await assert.rejects(failed.load());
  assert.equal(failed.getMeta().loaded, false); assert.equal(failed.getState().books.length, 0);
  const window = modules(), malformed = window.BooksStore.createStore({ fetch: async () => ({ ok: true, json: async () => ({}) }) });
  await assert.rejects(malformed.load());
  assert.equal(malformed.getMeta().loaded, false);
});

test('legacy URL normalization matches the committed payload used as undo expected, while the baseline stays exact', async () => {
  for (const [raw, normalized] of [['  legacy:link  ', 'legacy:link'], ['', null], ['   ', null]]) {
    const { server, store } = fixture(); server.books[0].url = raw; await store.load();
    await store.updateBook(1, { memo: '正規化する保存' });
    const save = server.calls.filter(call => call.method === 'POST').at(-1);
    assert.equal(save.body.expected[0].url, raw);
    assert.equal(save.body.books[0].url, normalized);
    await store.undo();
    const undo = server.calls.filter(call => call.method === 'POST').at(-1);
    assert.equal(undo.body.expected[0].url, normalized);
    assert.equal(undo.body.books[0].url, raw);
  }
});

test('known validation rejection stays editable, while malformed acknowledgements and server failures require review', async () => {
  for (const scenario of ['validation', 'malformed', 'server']) {
    const fixtureData = fixture(), { server } = fixtureData;
    const window = modules();
    const store = window.BooksStore.createStore({ fetch: (url, init = {}) => {
      if (!init.method) return server.fetch(url, init);
      if (scenario === 'validation') return Promise.resolve({ status: 400, ok: false, json: async () => ({ ok: false, error: '入力を確認してください。' }) });
      if (scenario === 'malformed') return Promise.resolve({ status: 200, ok: true, json: async () => { throw new Error('invalid JSON'); } });
      return Promise.resolve({ status: 500, ok: false, json: async () => ({ ok: false }) });
    } });
    await store.load();
    await assert.rejects(store.updateBook(1, { memo: '保持する入力' }), error => error.kind === (scenario === 'validation' ? 'validation' : 'unknown'));
    assert.equal(store.getMeta().blocked, scenario !== 'validation');
    assert.equal(store.getMeta().canUndo, false);
    assert.equal(store.getState().books[0].memo, '');
  }
});

test('legal identity swaps stay one atomic heterogeneous batch', async () => {
  const { server, store } = fixture(); await store.load();
  const [a, b] = store.getState().books;
  const identity = book => Object.fromEntries(['title', 'author', 'series', 'volumeNo'].map(key => [key, book[key]]));
  await store.saveEdits([{ id: a.id, patch: identity(b) }, { id: b.id, patch: identity(a) }]);
  assert.equal(server.calls.filter(call => call.method === 'POST').length, 1);
  assert.equal(server.books[0].title, b.title); assert.equal(server.books[1].title, a.title);
});

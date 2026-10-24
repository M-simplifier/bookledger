'use strict';
const assert = require('node:assert/strict');
const test = require('node:test');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const window = {};
vm.runInNewContext(fs.readFileSync(path.join(__dirname, '../../static/model.js'), 'utf8'), { window, URL, Intl });
const Model = window.BooksModel;
const row = (id, patch = {}) => ({ id, title: '本' + id, author: '著者', status: 'unread', category: '一般', series: null, volumeNo: null, memo: '', url: null, createdAt: '2026-01-01 00:00:00', updatedAt: '2026-01-01 00:00:00', ...patch });
const ids = rows => Array.from(rows, row => row.id);
test('NFKC multiple tokens search across fields while applying all dimensions', () => {
  const books = [row(1, { title: 'Ｃａｆｅ 第２巻', memo: '検討\n次の行', category: '専門', series: '数学ガール', status: 'reading' }), row(2)];
  assert.deepEqual(ids(Model.list(books, { query: 'cafe 第2 検討', status: 'reading', category: '専門', series: '数学ガール' })), [1]);
  assert.deepEqual(ids(Model.list(books, { query: '検討 ない語' })), []);
});
test('active/title/updated/catalog sorting handles timestamps, numbers and null volumes', () => {
  const books = [row(1, { title: '本10', status: 'reading', updatedAt: '2026-10-24 08:00:00' }), row(2, { title: '本2', status: 'reading', updatedAt: '2026-10-24T09:00:00Z' }), row(3, { series: '巻', volumeNo: 2 }), row(4, { series: '巻', volumeNo: 1 }), row(5, { series: '巻' })];
  assert.deepEqual(ids(Model.list(books, { sort: 'active' })), [2, 1, 5, 4, 3]);
  assert.deepEqual(ids(Model.list(books, { sort: 'title' })).slice(0, 2), [2, 3]);
  assert.deepEqual(ids(Model.list(books, { sort: 'catalog' })).filter(id => id >= 3), [4, 3, 5]);
  assert.deepEqual(ids(Model.list(books, { sort: 'updated' })).slice(0, 2), [2, 1]);
});
test('safe URL links accept only absolute HTTP(S); diff includes only editable changes', () => {
  assert.equal(Model.httpUrl('https://example.com/a?b=1&c=2'), true);
  for (const value of ['javascript:alert(1)', 'legacy:link', '//example.com', 'https://exa mple.com', 'https:\\example.com']) assert.equal(Model.httpUrl(value), false);
  const before = row(1), after = { ...before, memo: '一\n二', updatedAt: 'later' };
  assert.deepEqual(JSON.parse(JSON.stringify(Model.diff(before, after))), { memo: '一\n二' });
});

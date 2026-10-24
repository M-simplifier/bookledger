(function (global) {
  'use strict';
  const keys = ['title', 'author', 'status', 'category', 'series', 'volumeNo', 'memo', 'url'];
  const statuses = [
    { value: 'planned', label: '購入予定' }, { value: 'unread', label: '未読' },
    { value: 'reading', label: '読書中' }, { value: 'finished', label: '読了' }, { value: 'disposed', label: '処分' }
  ];
  const collator = new Intl.Collator('ja', { numeric: true, sensitivity: 'base' });
  const order = { reading: 0, unread: 1, planned: 2, finished: 3, disposed: 4 };
  const clone = value => JSON.parse(JSON.stringify(value));
  const pick = book => Object.fromEntries(['id', ...keys].map(key => [key, book[key]]));
  const diff = (before, after) => Object.fromEntries(keys.filter(key => before[key] !== after[key]).map(key => [key, after[key]]));
  const fail = message => { throw new Error(message); };
  function httpUrl(value) {
    if (!/^https?:\/\//i.test(value) || /[\u0000-\u0020\u007f\\]/.test(value)) return false;
    try { const url = new URL(value); return (url.protocol === 'http:' || url.protocol === 'https:') && Boolean(url.hostname); }
    catch (_) { return false; }
  }
  function fields(input, meta, baseline) {
    const result = {};
    for (const key of ['title', 'author']) {
      if (typeof input[key] !== 'string' || !input[key].trim()) fail((key === 'title' ? 'タイトル' : '著者') + 'を入力してください。');
      result[key] = input[key].trim();
    }
    if (!meta.statuses.some(status => status.value === input.status)) fail('状態を選んでください。');
    if (!meta.categories.includes(input.category)) fail('登録済みのカテゴリを選んでください。');
    if (input.series !== null && !meta.series.includes(input.series)) fail('登録済みのシリーズを選んでください。');
    if (input.volumeNo !== null) {
      if (typeof input.volumeNo !== 'number' || !Number.isFinite(input.volumeNo)) fail('巻数を確認してください。');
      if (input.volumeNo !== baseline?.volumeNo && (input.volumeNo < 0 || Math.abs(input.volumeNo * 10 - Math.round(input.volumeNo * 10)) > 1e-7)) fail('巻数は0以上の数値を0.1刻みで入力するか、空欄にしてください。');
    }
    if (typeof input.memo !== 'string') fail('メモを確認してください。');
    if (input.url !== null && typeof input.url !== 'string') fail('URLを確認してください。');
    const unchangedLegacy = baseline && input.url === baseline.url;
    const url = input.url?.trim() || null;
    if (url && !unchangedLegacy && !httpUrl(url)) fail('URLはhttpまたはhttpsで始まるアドレスを入力してください。');
    return { ...result, status: input.status, category: input.category, series: input.series, volumeNo: input.volumeNo, memo: input.memo, url };
  }
  function snapshot(meta, books) {
    if (!meta || !Array.isArray(meta.categories) || !Array.isArray(meta.series) || !Array.isArray(meta.statuses) || !Array.isArray(books)) fail('一覧のデータを読み込めませんでした。');
    if ([...meta.categories, ...meta.series].some(value => typeof value !== 'string') || !meta.statuses.length || meta.statuses.some(status => !status || typeof status.value !== 'string' || typeof status.label !== 'string')) fail('分類のデータを読み込めませんでした。');
    const ids = new Set();
    for (const book of books) {
      if (!book || !Number.isSafeInteger(book.id) || book.id < 1 || ids.has(book.id)) fail('本のデータを読み込めませんでした。');
      ids.add(book.id);
      fields(book, meta, book);
    }
    return clone({ categories: meta.categories, series: meta.series, statuses: meta.statuses, books });
  }
  function timestamp(value) {
    if (typeof value !== 'string') return 0;
    const normalized = /^\d{4}-\d\d-\d\d[ T]\d\d:\d\d:\d\d(?:\.\d+)?$/.test(value) ? value.replace(' ', 'T') + 'Z' : value;
    return Date.parse(normalized) || 0;
  }
  function list(books, filters = {}) {
    const normalized = value => String(value ?? '').normalize('NFKC').toLowerCase();
    const tokens = normalized(filters.query).trim().split(/\s+/).filter(Boolean);
    const updated = (a, b) => timestamp(b.updatedAt) - timestamp(a.updatedAt) || b.id - a.id;
    const title = (a, b) => collator.compare(a.title, b.title) || b.id - a.id;
    const catalog = (a, b) => collator.compare(a.category, b.category) || collator.compare(a.series || a.title, b.series || b.title) || (a.volumeNo === null ? (b.volumeNo === null ? 0 : 1) : b.volumeNo === null ? -1 : a.volumeNo - b.volumeNo) || title(a, b);
    const comparators = { active: (a, b) => order[a.status] - order[b.status] || updated(a, b), updated, title, catalog };
    return clone(books.filter(book => ['status', 'category', 'series'].every(key => !filters[key] || book[key] === filters[key]) && tokens.every(token => normalized([book.title, book.author, book.memo, book.category, book.series || ''].join(' ')).includes(token))).sort(comparators[filters.sort] || comparators.active));
  }
  global.BooksModel = Object.freeze({ keys, statuses, clone, pick, diff, fields, snapshot, list, httpUrl });
})(typeof window !== 'undefined' ? window : globalThis);

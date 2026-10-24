(function (global) {
  'use strict';
  const Model = global.BooksModel;
  class ApiError extends Error {
    constructor(message, kind, extra = {}) { super(message); this.name = 'ApiError'; this.kind = kind; Object.assign(this, extra); }
  }
  function createStore(options = {}) {
    const fetcher = options.fetch || global.fetch.bind(global);
    let state = { books: [], categories: [], series: [], statuses: Model.clone(Model.statuses) };
    let loaded = false, busy = false, saving = false, blocked = false, issue = null, warning = null, revision = 0;
    const listeners = new Set(), history = [];
    const meta = () => ({ loaded, busy, saving, blocked, revision, issue: issue && { ...issue }, warning, canUndo: loaded && !busy && !blocked && history.length > 0, undoLabel: history.length ? '本の変更' : null });
    const notify = () => { for (const listener of listeners) { try { listener(meta()); } catch (error) { global.console?.error(error); } } };
    function lock() {
      if (busy) throw new ApiError('処理が終わるまでお待ちください。', 'busy');
      busy = true; notify();
    }
    function writable() {
      if (busy) throw new ApiError('処理が終わるまでお待ちください。', 'busy');
      if (!loaded || blocked) throw new ApiError('一覧を再読み込みしてから操作してください。', 'blocked');
    }
    async function readSnapshot() {
      async function get(url) {
        const response = await fetcher(url, { cache: 'no-store', headers: { Accept: 'application/json' } });
        if (!response.ok) throw new Error('一覧を読み込めませんでした。');
        return response.json();
      }
      const metaData = await get('/api/meta');
      const books = await get('/api/books');
      return Model.snapshot(metaData, books);
    }
    async function load() {
      const previousIssue = issue;
      lock();
      try { const next = await readSnapshot(); state = next; revision++; loaded = true; blocked = false; issue = null; return Model.clone(state); }
      catch (_) {
        blocked = true;
        issue = previousIssue && ['unknown', 'acknowledged'].includes(previousIssue.kind) ? previousIssue : { kind: 'load', message: '一覧を読み込めませんでした。接続を確認して再読み込みしてください。' };
        throw new ApiError(issue.message, issue.kind);
      }
      finally { busy = false; notify(); }
    }
    async function post(url, payload) {
      let response, result;
      try { response = await fetcher(url, { method: 'POST', headers: { 'Content-Type': 'application/json', Accept: 'application/json' }, body: JSON.stringify(payload) }); }
      catch (_) { throw new ApiError('保存結果を確認できません。自動では再送しません。一覧を再読み込みして内容を確認してください。', 'unknown'); }
      try { result = await response.json(); }
      catch (_) { throw new ApiError('保存結果を確認できません。一覧を再読み込みして内容を確認してください。', 'unknown'); }
      if (response.status === 409 && result?.conflict) throw new ApiError(result.error || 'ほかの画面で変更されています。入力を残しています。', 'conflict', { conflict: true });
      if (response.status === 400 && result?.ok === false) throw new ApiError(result.error || '入力を確認してください。', 'validation');
      if (!response.ok || result?.ok !== true) throw new ApiError('保存結果を確認できません。一覧を再読み込みして内容を確認してください。', 'unknown');
      return result;
    }
    async function mutate(url, payload, onAcknowledged) {
      writable(); saving = true; lock(); issue = null;
      try {
        const result = await post(url, payload);
        warning = typeof result.warning === 'string' && result.warning ? result.warning : null;
        onAcknowledged(result);
        try { state = await readSnapshot(); revision++; loaded = true; blocked = false; issue = null; }
        catch (_) { blocked = true; issue = { kind: 'acknowledged', message: '保存しましたが、一覧を更新できませんでした。再読み込みしてください。' }; }
        return { ...result, acknowledged: true, refreshed: !blocked };
      } catch (error) {
        if (error.kind === 'unknown') { blocked = true; history.length = 0; }
        issue = { kind: error.kind || 'validation', message: error.message };
        throw error;
      } finally { busy = false; saving = false; notify(); }
    }
    function editsPayload(edits) {
      if (!Array.isArray(edits) || !edits.length) throw new ApiError('変更する本を選んでください。', 'validation');
      const ids = new Set(), before = [], after = [];
      for (const edit of edits) {
        if (!Number.isSafeInteger(edit.id) || ids.has(edit.id)) throw new ApiError('変更する本を確認してください。', 'validation');
        ids.add(edit.id);
        const baseline = edit.expected || state.books.find(book => book.id === edit.id);
        if (!baseline || baseline.id !== edit.id) throw new ApiError('本が見つかりません。入力を控えて、一覧を再読み込みしてください。', 'conflict');
        if (!edit.patch || Object.keys(edit.patch).some(key => !Model.keys.includes(key))) throw new ApiError('変更する項目を確認してください。', 'validation');
        before.push(Model.pick(baseline));
        after.push({ id: edit.id, ...Model.fields({ ...baseline, ...edit.patch }, state, baseline) });
      }
      return { books: after, expected: before };
    }
    async function saveEdits(edits) {
      writable(); const payload = editsPayload(edits);
      return mutate('/api/books/batch', payload, () => {
        history.push({ before: Model.clone(payload.expected), after: Model.clone(payload.books) });
        if (history.length > 20) history.shift();
      });
    }
    return {
      getState: () => Model.clone(state), getMeta: meta,
      list: filters => Model.list(state.books, filters), load,
      saveEdits,
      updateBook: (id, patch, expected) => saveEdits([{ id, patch, expected }]),
      batchUpdate: (ids, patch) => saveEdits(Array.from(new Set(ids), id => ({ id, patch }))),
      addBook: fields => { writable(); return mutate('/api/books', Model.fields(fields, state), () => { history.length = 0; }); },
      addCategory: name => addTaxonomy('categories', name),
      addSeries: name => addTaxonomy('series', name),
      undo: async () => {
        writable(); if (!history.length) return false;
        const entry = history[history.length - 1];
        try { return await mutate('/api/books/batch', { books: Model.clone(entry.before), expected: Model.clone(entry.after) }, () => { history.pop(); }); }
        catch (error) { if (error.kind === 'conflict') { history.length = 0; notify(); } throw error; }
      },
      exportData: () => { if (!loaded) throw new Error('一覧を読み込んでください。'); return JSON.stringify(state, null, 2); },
      subscribe: listener => { listeners.add(listener); return () => listeners.delete(listener); }
    };
    function addTaxonomy(key, name) {
      writable(); const value = typeof name === 'string' ? name.trim() : '';
      if (!value) throw new ApiError((key === 'categories' ? 'カテゴリ' : 'シリーズ') + '名を入力してください。', 'validation');
      if (state[key].includes(value)) throw new ApiError('同じ名前がすでにあります。', 'validation');
      return mutate('/api/' + key, { name: value }, () => { history.length = 0; });
    }
  }
  global.BooksStore = Object.freeze({ createStore, ApiError });
})(typeof window !== 'undefined' ? window : globalThis);

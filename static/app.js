
(() => {
  'use strict';

  const $ = id => document.getElementById(id);
  const esc = value => String(value ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const svg = paths => `<svg viewBox="0 0 24 24" aria-hidden="true">${paths}</svg>`;
  const icons = {
    all: svg('<rect x="4" y="3" width="16" height="18" rx="2"/><path d="M8 7h8M8 11h8M8 15h5"/>'),
    reading: svg('<path d="M12 6c-3-2-6-2-9-1v14c3-1 6-1 9 1 3-2 6-2 9-1V5c-3-1-6-1-9 1Zm0 0v14"/>'),
    unread: svg('<rect x="5" y="3" width="14" height="18" rx="2"/><path d="M9 3v18"/>'),
    finished: svg('<path d="m5 12 4 4L19 6"/>'), planned: svg('<path d="M12 5v14M5 12h14"/>'),
    disposed: svg('<path d="M5 12h14"/>'), series: svg('<path d="M7 3h13v15H7zM4 6v15h13M11 7h5M11 11h5"/>'),
    note: svg('<path d="M5 3h14v18H5zM8 8h8M8 12h8M8 16h5"/>'),
    close: svg('<path d="m6 6 12 12M18 6 6 18"/>')
  };
  const labelMap = { all: 'すべての本', reading: '読書中', unread: '未読', finished: '読了', planned: '購入予定', disposed: '処分' };
  const fieldLabels = { title: 'タイトル', author: '著者', status: '状態', category: 'カテゴリ', series: 'シリーズ', volumeNo: '巻数', memo: 'メモ', url: 'URL' };
  const navOrder = ['all', 'reading', 'unread', 'finished', 'planned', 'disposed'];
  const filterDimensions = ['status', 'category', 'series'];
  const validityKeys = ['valueMissing', 'typeMismatch', 'patternMismatch', 'tooLong', 'tooShort', 'rangeUnderflow', 'rangeOverflow', 'stepMismatch', 'badInput', 'customError'];
  const editableFields = Object.keys(fieldLabels);
  let store;
  try { store = window.BooksStore.createStore(); }
  catch (error) { document.body.innerHTML = `<main class="error-page"><h1>開けませんでした</h1><p>${esc(error.message)}</p></main>`; return; }

  const ui = {
    scope: { key: 'all', value: '' },
    query: '', status: '', category: '', series: '', sort: 'active', compact: false,
    selecting: false, selected: new Set(), editing: false, drafts: new Map(), draftBases: new Map(), invalidCells: new Map(), tableRecovery: null,
    editorOriginal: null, editorRecovery: null, editorAttempt: null, editorId: null, editorDirty: false, editorBaseline: null, sidebarOpen: false, sidebarHidden: false
  };
  let snapshot = store.getState();
  let booksById = new Map(snapshot.books.map(book => [book.id, book]));
  store.subscribe(() => { snapshot = store.getState(); booksById = new Map(snapshot.books.map(book => [book.id, book])); render(); });
  const data = () => snapshot;
  const effectiveFilters = () => {
    const filters = { query: ui.query, status: ui.status, category: ui.category, series: ui.series, sort: ui.sort };
    if (ui.scope.key !== 'all') filters[ui.scope.key] = ui.scope.value;
    return filters;
  };
  const filteredBooks = () => store.list(effectiveFilters());
  const tableDirty = () => ui.drafts.size > 0 || ui.invalidCells.size > 0;
  const changedBookIds = () => new Set([...ui.drafts.keys(), ...Array.from(ui.invalidCells.values(), cell => cell.id)]);
  const bookWithDraft = book => ({ ...(ui.draftBases.get(book.id) || book), ...ui.drafts.get(book.id) });
  const options = (values, selected, emptyLabel) => (emptyLabel === undefined ? '' : `<option value="">${esc(emptyLabel)}</option>`) + values.map(item => {
    const value = typeof item === 'string' ? item : item.value, label = typeof item === 'string' ? item : item.label;
    return `<option value="${esc(value)}"${value === selected ? ' selected' : ''}>${esc(label)}</option>`;
  }).join('');
  const statusSelect = book => `<span class="status-wrap${book.status === 'reading' ? ' is-reading' : ''}"><select class="status-select" aria-label="${esc(book.title)}の状態" data-status="${esc(book.status)}" data-book-status="${book.id}">${options(data().statuses, book.status)}</select></span>`;
  const checkbox = book => `<label class="check-wrap"><input type="checkbox" data-select="${book.id}" aria-label="${esc(book.title)}を選択"${ui.selected.has(book.id) ? ' checked' : ''}></label>`;
  const titleButton = book => `<button class="book-title-button" data-action="open" data-id="${book.id}">${esc(book.title)}</button>`;
  const seriesText = book => book.series ? `${book.series}${book.volumeNo === null ? '' : ' · ' + book.volumeNo + '巻'}` : book.volumeNo === null ? '' : book.volumeNo + '巻';
  const rowClass = (book, changed) => [ui.selected.has(book.id) ? 'is-selected' : '', changed?.has(book.id) ? 'is-draft' : ''].filter(Boolean).join(' ');
  let toastTimer, confirmation = null;
  const sidebarMedia = window.matchMedia('(max-width: 760px)');

  function notify(message, error = false, undo = true) {
    clearTimeout(toastTimer);
    const toast = $('toast');
    toast.className = 'toast' + (error ? ' error' : '');
    toast.innerHTML = `<span>${esc(message)}</span>${undo && store.getMeta().canUndo ? '<button data-action="undo">元に戻す</button>' : ''}<button class="close-toast" data-action="close-toast" aria-label="通知を閉じる">×</button>`;
    toast.hidden = false;
    toastTimer = setTimeout(() => { toast.hidden = true; }, error ? 12000 : 6500);
  }
  function mutationNotice(message, result) {
    const warning = result?.warning;
    notify(result?.refreshed === false ? '保存しました。一覧を再読み込みしてください' : message + (warning ? '。' + warning : ''), Boolean(warning) || result?.refreshed === false);
  }
  async function runMutation(action, message) {
    try { const result = await action(); render(); mutationNotice(message, result); return result; }
    catch (error) { render(); notify(error.message, true, false); return undefined; }
  }
  function canReview(recovery) {
    const meta = store.getMeta();
    return recovery && meta.loaded && !meta.busy && !meta.blocked && meta.revision > recovery.revision;
  }
  function changedElsewhere(baseline, current) {
    if (!current) return '<p>この本が一覧に見つかりません。入力を控えてから確認してください。</p>';
    const changes = editableFields.filter(field => baseline[field] !== current[field]);
    return changes.length ? changes.map(field => `<p><strong>${fieldLabels[field]}</strong><br>現在：${esc(current[field] ?? 'なし')}</p>`).join('') : '<p>現在の内容に変更はありません。</p>';
  }
  function renderConnection() {
    const meta = store.getMeta(), notice = $('connection-notice');
    const messages = [meta.issue?.message, meta.warning ? '保存しました。' + meta.warning : ''].filter(Boolean);
    notice.hidden = messages.length === 0;
    notice.innerHTML = messages.map(message => `<span>${esc(message)}</span>`).join('<br>') + (meta.issue ? `<button data-action="refresh"${meta.busy ? ' disabled' : ''}>再読み込み</button>` : '');
    const panel = $('recovery-panel');
    panel.hidden = !ui.editing || !ui.tableRecovery;
    if (panel.hidden) { panel.innerHTML = ''; return; }
    const values = Array.from(changedBookIds(), id => {
      const draft = ui.drafts.get(id) || {};
      const inputs = editableFields.filter(field => Object.hasOwn(draft, field) || ui.invalidCells.has(id + ':' + field)).map(field => `<p><strong>自分の入力・${fieldLabels[field]}</strong><br>${esc(ui.invalidCells.get(id + ':' + field)?.value ?? draft[field] ?? 'なし')}</p>`).join('');
      const comparison = canReview(ui.tableRecovery) ? changedElsewhere(ui.draftBases.get(id) || {}, booksById.get(id)) : '<p>再読み込みすると変更点を確認できます。</p>';
      return `<div><strong>${esc(ui.draftBases.get(id)?.title || '')}</strong>${comparison}${inputs}</div>`;
    }).join('');
    panel.innerHTML = `<span>入力は残っています。再読み込みして、現在の内容を確認してください。</span><button data-action="refresh"${meta.busy ? ' disabled' : ''}>再読み込み</button><div class="recovery-values">${values}</div><button data-action="rebase-table"${canReview(ui.tableRecovery) ? '' : ' disabled'}>現在の内容に入力を重ねる</button>`;
  }
  function applyWriteState() {
    const meta = store.getMeta(), unavailable = !meta.loaded || meta.busy || meta.blocked;
    document.querySelector('.main-pane').setAttribute('aria-busy', String(meta.busy));
    document.querySelectorAll('[data-book-status]').forEach(element => { element.disabled = unavailable; });
    document.querySelectorAll('.cell-input,#book-form input,#book-form textarea,#book-form select,[data-taxonomy] input').forEach(element => { element.disabled = meta.busy; });
    document.querySelectorAll('[data-taxonomy] button[type="submit"]').forEach(element => { element.disabled = unavailable || element.closest('form').dataset.unknown === 'true'; });
    document.querySelectorAll('[data-action]').forEach(element => {
      const action = element.dataset.action;
      if (['add', 'manage', 'batch'].includes(action)) element.disabled = unavailable;
      if (action === 'table-edit') element.disabled = unavailable || ui.editing;
      if (action === 'save-table') element.disabled = unavailable || !changedBookIds().size || Boolean(ui.tableRecovery);
      if (action === 'undo') element.disabled = !meta.canUndo || ui.editing;
      if (['close-editor', 'close-dialog', 'discard-table'].includes(action)) element.disabled = meta.busy;
      if (action === 'refresh') element.disabled = meta.busy;
    });
    const save = $('book-form')?.querySelector('[type="submit"]');
    if (save) save.disabled = unavailable || Boolean(ui.editorRecovery);
  }
  async function refresh() {
    if (store.getMeta().busy) return;
    try { await store.load(); if (ui.editorRecovery) showEditorRecovery(); render(); }
    catch (error) { render(); notify(error.message, true, false); }
  }
  function showEditorRecovery() {
    const recovery = ui.editorRecovery; if (!recovery) return;
    const current = booksById.get(ui.editorId), target = $('editor-error');
    let actions = `<button type="button" data-action="refresh">再読み込み</button>`;
    let values = '';
    if (recovery.kind === 'unknownAdd') {
      const attempt = ui.editorAttempt;
      const match = canReview(recovery) && data().books.find(book => ['title', 'author', 'series', 'volumeNo'].every(field => book[field] === attempt[field]));
      values = match ? `<p>同じタイトル・著者・シリーズ・巻数の本が見つかりました。</p>` : '<p>一覧を再読み込みして登録結果を確認してください。この入力は自動では再送しません。</p>';
      if (match) actions += `<button type="button" data-action="adopt-book" data-id="${match.id}">登録された本を開く</button>`;
    } else {
      values = `<div class="recovery-values">${canReview(recovery) ? changedElsewhere(ui.editorOriginal, current) : '<p>再読み込みすると変更点を確認できます。</p>'}</div>`;
      actions += `<button type="button" data-action="rebase-editor"${canReview(recovery) && current ? '' : ' disabled'}>現在の内容に入力を重ねる</button>`;
    }
    target.hidden = false; target.innerHTML = `${esc(recovery.message)}${values}${actions}`;
    applyWriteState();
  }
  async function rebaseTable() {
    if (!canReview(ui.tableRecovery)) return;
    if (Array.from(changedBookIds()).some(id => !booksById.has(id))) { notify('見つからない本があります。入力を控えてから確認してください。', true, false); return; }
    if (!await requestConfirmation('現在の内容に入力を重ねますか？', '自分で変更した項目を重ねます。保存前に内容を確認してください。', '重ねる')) return;
    for (const id of changedBookIds()) {
      const current = booksById.get(id), patch = ui.drafts.get(id) || {};
      const remaining = Object.fromEntries(Object.entries(patch).filter(([field, value]) => current[field] !== value));
      ui.draftBases.set(id, window.BooksModel.clone(current));
      if (Object.keys(remaining).length) ui.drafts.set(id, remaining); else ui.drafts.delete(id);
    }
    ui.tableRecovery = null; render();
  }
  async function rebaseEditor() {
    if (!canReview(ui.editorRecovery)) return;
    const form = $('book-form'), current = booksById.get(ui.editorId);
    if (!current || !form.reportValidity()) return;
    if (!await requestConfirmation('現在の内容に入力を重ねますか？', '自分で変更した項目を重ねます。保存前に内容を確認してください。', '重ねる')) return;
    const patch = window.BooksModel.diff(ui.editorOriginal, formValues(form));
    const fill = values => editableFields.forEach(field => { form.elements[field].value = values[field] ?? ''; });
    fill(current); ui.editorBaseline = formSignature(form);
    fill({ ...current, ...patch }); ui.editorOriginal = window.BooksModel.clone(current); ui.editorRecovery = null;
    $('editor-error').hidden = true; updateEditorDirty(); applyWriteState();
  }
  function rememberFocus() {
    const element = document.activeElement;
    return { element, id: element?.id, action: element?.dataset?.action, value: element?.dataset?.value, bookId: element?.dataset?.id, select: element?.dataset?.select };
  }
  function restoreFocus(previous) {
    if (!previous.element || previous.element.isConnected) return;
    let replacement = previous.id ? $(previous.id) : null;
    if (!replacement && previous.select) replacement = document.querySelector(`[data-select="${previous.select}"]`);
    if (!replacement && previous.action) replacement = Array.from(document.querySelectorAll('[data-action]')).find(element => element.dataset.action === previous.action && element.dataset.value === previous.value && element.dataset.id === previous.bookId);
    if (replacement && !replacement.closest('[inert]')) replacement.focus({ preventScroll: true });
  }

  function renderNav() {
    const state = data(), counts = Object.fromEntries(navOrder.map(key => [key, 0]));
    const categoryCounts = new Map(state.categories.map(category => [category, 0]));
    const seriesCounts = new Map(state.series.map(series => [series, 0]));
    counts.all = state.books.length;
    for (const book of state.books) {
      counts[book.status]++;
      categoryCounts.set(book.category, categoryCounts.get(book.category) + 1);
      if (book.series !== null) seriesCounts.set(book.series, seriesCounts.get(book.series) + 1);
    }
    $('status-nav').innerHTML = navOrder.map(key => {
      const value = key === 'all' ? '' : key;
      const active = key === 'all' ? ui.scope.key === 'all' : ui.scope.key === 'status' && ui.scope.value === key;
      return `<button class="nav-button" data-action="status-filter" data-value="${value}" aria-current="${active}"><span class="nav-symbol" aria-hidden="true">${icons[key]}</span><span class="nav-label">${labelMap[key]}</span><span class="nav-count">${counts[key]}</span></button>`;
    }).join('');
    $('category-nav').innerHTML = state.categories.map(category => `<button class="nav-button" data-action="category-filter" data-value="${esc(category)}" aria-current="${ui.scope.key === 'category' && ui.scope.value === category}"><span class="category-square" aria-hidden="true"></span><span class="nav-label">${esc(category)}</span><span class="nav-count">${categoryCounts.get(category)}</span></button>`).join('');
    $('series-nav').innerHTML = state.series.map(series => `<button class="nav-button" data-action="series-filter" data-value="${esc(series)}" aria-current="${ui.scope.key === 'series' && ui.scope.value === series}"><span class="nav-symbol" aria-hidden="true">${icons.series}</span><span class="nav-label">${esc(series)}</span><span class="nav-count">${seriesCounts.get(series)}</span></button>`).join('');
    $('status-filter').innerHTML = options(state.statuses, ui.status, 'すべて');
    $('category-filter').innerHTML = options(state.categories, ui.category, 'すべて');
    $('series-filter').innerHTML = options(state.series, ui.series, 'すべて');
    for (const dimension of filterDimensions) {
      $(`${dimension}-filter-field`).hidden = ui.scope.key === dimension;
      $(`${dimension}-filter`).disabled = ui.scope.key === dimension;
    }
    const filterCount = filterDimensions.filter(dimension => ui[dimension]).length;
    $('filter-count').textContent = filterCount;
    $('filter-count').hidden = filterCount === 0;
    $('reset-filters').disabled = filterCount === 0;
    const meta = store.getMeta();
    $('undo-button').disabled = !meta.canUndo || ui.editing;
    $('undo-button').title = meta.canUndo ? meta.undoLabel + 'を元に戻す' : '元に戻す操作はありません';
    $('storage-caption').textContent = '';
  }
  function renderHeader(books) {
    const heading = ui.scope.key === 'all' ? labelMap.all : ui.scope.key === 'status' ? labelMap[ui.scope.value] : ui.scope.value;
    $('page-title').textContent = heading;
    $('page-title').setAttribute('title', heading);
    $('search').placeholder = ui.scope.key === 'all' ? '検索' : 'この一覧を検索';
    $('heading-count').textContent = store.getMeta().loaded ? books.length : '—';
    $('heading-count').setAttribute('aria-label', store.getMeta().loaded ? books.length + '冊' : '読み込み中');
    $('sort').value = ui.sort;
    const filters = [['query', ui.query], ['status', ui.status ? labelMap[ui.status] : ''], ['category', ui.category], ['series', ui.series]].filter(([, value]) => value);
    $('filter-chips').innerHTML = filters.map(([key, value]) => `<button class="filter-chip" data-action="clear-filter" data-key="${key}" aria-label="${esc(value)}の条件を解除">${esc(key === 'query' ? '検索: ' + value : value)} <span aria-hidden="true">×</span></button>`).join('') + (filters.length ? '<button class="clear-filters" data-action="clear-all">すべて解除</button>' : '');
  }
  function renderList(books) {
    const header = '<div class="list-header"><label class="check-wrap"><input id="select-all" type="checkbox" aria-label="表示中の本をすべて選択"></label><span>タイトル / 著者</span><span class="meta-heading">カテゴリ / シリーズ</span><span>状態</span><span class="memo-heading"></span></div>';
    const rows = values => values.map(book => `<article class="book-row ${rowClass(book)}" data-row="${book.id}">${checkbox(book)}<div>${titleButton(book)}<div class="book-author">${esc(book.author)}</div></div><div class="book-meta"><span class="category-tag">${esc(book.category)}</span><span class="series-label">${esc(seriesText(book))}</span></div>${statusSelect(book)}<button class="memo-button${book.memo ? ' has-memo' : ''}" data-action="memo" data-id="${book.id}" title="${esc(book.memo || 'メモ')}" aria-label="${esc(book.title)}のメモ">${icons.note}</button></article>`).join('');
    if (effectiveFilters().status || ui.sort !== 'active') return header + rows(books);
    const groups = new Map();
    for (const book of books) { if (!groups.has(book.status)) groups.set(book.status, []); groups.get(book.status).push(book); }
    return header + Array.from(groups, ([status, values]) => `<section class="book-group" aria-labelledby="group-${status}"><h2 id="group-${status}" class="group-heading">${labelMap[status]}</h2>${rows(values)}</section>`).join('');
  }
  function cellInput(book, field, type = 'text') {
    const invalid = ui.invalidCells.get(book.id + ':' + field), value = invalid ? invalid.value : book[field];
    const attributes = `id="cell-${book.id}-${field}" class="cell-input" data-edit-id="${book.id}" data-field="${field}" aria-label="${esc(book.title)}の${fieldLabels[field]}"${invalid ? ' aria-invalid="true"' : ''}`;
    if (type === 'select') {
      const values = field === 'status' ? data().statuses : field === 'category' ? data().categories : data().series;
      return `<select ${attributes}>${options(values, value, field === 'series' ? 'なし' : undefined)}</select>`;
    }
    if (field === 'memo' || field === 'title' || field === 'author') return `<textarea ${attributes} rows="2"${field === 'memo' ? '' : ' required'}>${esc(value)}</textarea>`;
    // Keep numeric edits as text so partial input survives filters/redraws.
    // cellProblem checks the range and step before any numeric conversion.
    return `<input ${attributes} type="${type === 'number' ? 'text' : type}"${type === 'number' ? ' inputmode="decimal"' : ''} value="${esc(value)}">`;
  }
  function renderCatalog(books) {
    const changed = changedBookIds();
    return `<div class="catalog-scroll"><table class="catalog-table editing-table"><thead><tr><th aria-hidden="true"></th><th scope="col">タイトル / URL</th><th scope="col">著者</th><th scope="col">状態</th><th scope="col">カテゴリ</th><th scope="col">シリーズ</th><th scope="col">巻</th><th scope="col">メモ</th></tr></thead><tbody>${books.map(original => {
      const book = bookWithDraft(original);
      return `<tr class="${rowClass(book, changed)}" data-row="${book.id}"><td></td><td>${cellInput(book, 'title')}${cellInput(book, 'url', 'url')}</td><td class="author-cell">${cellInput(book, 'author')}</td><td>${cellInput(book, 'status', 'select')}</td><td class="table-secondary">${cellInput(book, 'category', 'select')}</td><td class="table-secondary">${cellInput(book, 'series', 'select')}</td><td class="table-secondary">${cellInput(book, 'volumeNo', 'number')}</td><td>${cellInput(book, 'memo')}</td></tr>`;
    }).join('')}</tbody></table></div>`;
  }
  function renderEditToolbar(books = filteredBooks()) {
    const bar = $('edit-toolbar'); bar.hidden = !ui.editing;
    if (!ui.editing) { bar.innerHTML = ''; return; }
    const changed = changedBookIds(), visible = new Set(books.map(book => book.id));
    const hidden = Array.from(changed).filter(id => !visible.has(id)).length;
    const description = [changed.size ? changed.size + '冊に未保存の変更' : '', hidden ? '表示外 ' + hidden + '冊' : '', ui.invalidCells.size ? '入力を確認してください' : ''].filter(Boolean).join(' · ');
    bar.innerHTML = `<div><strong>表の編集</strong>${description ? `<span>${description}</span>` : ''}</div><div><button class="text-button" data-action="discard-table">${changed.size ? '変更を破棄' : '終了'}</button><button class="primary-button" data-action="save-table"${changed.size ? '' : ' disabled'}>保存</button></div>`;
  }
  function renderSelection(books) {
    const bar = $('selection-bar'); bar.hidden = !ui.selecting || !ui.selected.size || ui.editing;
    if (bar.hidden) { bar.innerHTML = ''; return; }
    const visible = new Set(books.map(book => book.id)), hidden = Array.from(ui.selected).filter(id => !visible.has(id)).length;
    bar.innerHTML = `<strong>${ui.selected.size}冊を選択${hidden ? '（表示外 ' + hidden + '冊）' : ''}</strong><select id="batch-status" aria-label="選択した本の状態">${options(data().statuses, '', '状態')}</select><select id="batch-category" aria-label="選択した本のカテゴリ">${options(data().categories, '', 'カテゴリ')}</select><button class="primary-button" data-action="batch">適用</button><button class="text-button" data-action="clear-selection">選択解除</button>`;
  }
  function renderResults() {
    const previous = rememberFocus(), scroll = $('content-scroll').scrollTop, books = filteredBooks();
    const hasConditions = Boolean(ui.query || ui.status || ui.category || ui.series);
    renderHeader(books);
    $('book-list').innerHTML = books.length ? (ui.editing ? renderCatalog(books) : renderList(books)) : `<div class="empty-state"><h2>${hasConditions ? '本が見つかりません' : '本がありません'}</h2>${hasConditions ? '<button class="secondary-button" data-action="clear-all">条件を解除</button>' : '<button class="secondary-button" data-action="add">本を追加</button>'}</div>`;
    const all = $('select-all');
    if (all) { const count = books.filter(book => ui.selected.has(book.id)).length; all.checked = count > 0 && count === books.length; all.indeterminate = count > 0 && count < books.length; }
    if (!store.getMeta().loaded) $('book-list').innerHTML = `<div class="empty-state" role="status"><h2>${store.getMeta().busy ? '読み込み中…' : '一覧を読み込めませんでした'}</h2>${store.getMeta().busy ? '' : '<button class="secondary-button" data-action="refresh">再読み込み</button>'}</div>`;
    renderSelection(books); renderEditToolbar(books); renderConnection(); applyWriteState();
    $('content-scroll').scrollTop = scroll;
    restoreFocus(previous);
  }
  function ensureScopeExists() {
    const { key, value } = ui.scope;
    const exists = key === 'all' || (key === 'status' ? data().statuses.some(status => status.value === value) : key === 'category' ? data().categories.includes(value) : key === 'series' && data().series.includes(value));
    if (exists) return;
    ui.scope = { key: 'all', value: '' };
    ui.query = ''; ui.status = ''; ui.category = ''; ui.series = '';
    ui.selecting = false; ui.selected.clear();
  }
  function render() {
    ensureScopeExists();
    const previous = rememberFocus();
    document.body.dataset.view = ui.editing ? 'catalog' : 'list';
    document.body.classList.toggle('compact', ui.compact);
    document.body.classList.toggle('selecting', ui.selecting && !ui.editing);
    $('selection-toggle').hidden = ui.editing;
    $('selection-toggle').textContent = ui.selecting ? '完了' : '選択';
    $('selection-toggle').setAttribute('aria-pressed', String(ui.selecting));
    $('density-button').setAttribute('aria-pressed', String(ui.compact));
    $('density-button').innerHTML = `<span>${ui.compact ? '行にゆとりを' : '行をコンパクトに'}</span><span id="density-mark">${ui.compact ? '✓' : ''}</span>`;
    const tableButton = document.querySelector('[data-action="table-edit"]'); if (tableButton) tableButton.disabled = ui.editing;
    $('search').value = ui.query;
    renderNav(); renderResults(); syncSidebar(); restoreFocus(previous);
  }

  function hideMenu() {
    for (const id of ['more-menu', 'filter-menu']) {
      try { $(id).hidePopover?.(); } catch (_) { /* Already closed. */ }
    }
  }
  function syncSidebar() {
    const mobile = sidebarMedia.matches; if (!mobile) ui.sidebarOpen = false;
    const open = mobile && ui.sidebarOpen, sidebar = $('sidebar');
    document.body.classList.toggle('sidebar-open', open);
    document.body.classList.toggle('sidebar-hidden', !mobile && ui.sidebarHidden);
    sidebar.inert = mobile ? !open : ui.sidebarHidden;
    document.querySelector('.main-pane').inert = open;
    $('more-menu').inert = open;
    $('filter-menu').inert = open;
    document.querySelector('.skip-link').inert = open;
    document.querySelector('.sidebar-shade').hidden = !open;
    document.querySelectorAll('.sidebar-toggle').forEach(button => button.setAttribute('aria-expanded', String(mobile ? open : !ui.sidebarHidden)));
    if (sidebar.inert && sidebar.contains(document.activeElement)) document.querySelector('.sidebar-toggle').focus({ preventScroll: true });
  }
  function closeSidebar(focus = 'toggle') {
    if (!sidebarMedia.matches || !ui.sidebarOpen) return;
    ui.sidebarOpen = false; syncSidebar();
    if (focus === 'collection') { $('page-title').tabIndex = -1; $('page-title').focus({ preventScroll: true }); }
    else if (focus === 'toggle') document.querySelector('.sidebar-toggle').focus({ preventScroll: true });
  }
  function toggleSidebar() {
    hideMenu();
    if (sidebarMedia.matches) {
      if (ui.sidebarOpen) { closeSidebar(); return; }
      ui.sidebarOpen = true; syncSidebar(); $('sidebar').querySelector('[aria-current="true"]')?.focus({ preventScroll: true });
    } else { ui.sidebarHidden = !ui.sidebarHidden; syncSidebar(); }
  }
  function requestConfirmation(title, description, acceptLabel = '破棄する') {
    if (confirmation) return confirmation;
    const dialog = $('confirm-dialog');
    dialog.innerHTML = `<form method="dialog"><div class="dialog-body"><h2 id="confirm-heading">${esc(title)}</h2>${description ? `<p class="dialog-copy">${esc(description)}</p>` : ''}<div class="confirm-actions"><button class="secondary-button" type="submit" value="cancel" autofocus>キャンセル</button><button class="primary-button" type="submit" value="confirm">${esc(acceptLabel)}</button></div></div></form>`;
    dialog.returnValue = 'cancel';
    confirmation = new Promise(resolve => {
      const cancel = event => { event.preventDefault(); dialog.close('cancel'); };
      const close = () => { dialog.removeEventListener('cancel', cancel); dialog.removeEventListener('close', close); confirmation = null; resolve(dialog.returnValue === 'confirm'); };
      dialog.addEventListener('cancel', cancel); dialog.addEventListener('close', close); dialog.showModal(); dialog.querySelector('[value="cancel"]').focus();
    });
    return confirmation;
  }

  function formSignature(form) {
    return JSON.stringify(editableFields.map(name => { const control = form.elements[name]; return [name, control.value, validityKeys.filter(key => control.validity?.[key])]; }));
  }
  function updateEditorDirty() {
    ui.editorDirty = formSignature($('book-form')) !== ui.editorBaseline;
    $('draft-state').textContent = ui.editorDirty ? '未保存' : '';
    $('draft-state').classList.toggle('dirty', ui.editorDirty);
  }
  function newBookDefaults() {
    const filters = effectiveFilters(), state = data();
    return {
      title: '', author: '', status: filters.status || 'unread',
      category: filters.category || (state.categories.includes('未分類') ? '未分類' : state.categories[0]),
      series: filters.series || null, volumeNo: null, memo: '', url: null
    };
  }
  function openEditor(id = null, memo = false) {
    if (!store.getMeta().loaded || store.getMeta().busy || store.getMeta().blocked) { notify('一覧を読み込んでから操作してください', false, false); return; }
    if (ui.editing) { notify('表の編集を保存するか、終了してください', false, false); return; }
    const state = data(), saved = id === null ? null : booksById.get(id);
    if (id !== null && !saved) return;
    hideMenu(); closeSidebar('none'); ui.editorId = id; ui.editorDirty = false;
    ui.editorOriginal = saved ? window.BooksModel.clone(saved) : null; ui.editorRecovery = null; ui.editorAttempt = null;
    const book = saved || newBookDefaults();
    const input = (name, label, type = 'text', required = false) => `<label class="form-field"><span>${label}${required ? '<span class="required">必須</span>' : ''}</span><input name="${name}" type="${type}" value="${esc(book[name])}"${required ? ' required' : ''}${type === 'number' ? (Number(book.volumeNo) < 0 ? '' : ' min="0"') + ' step="any"' : ''}></label>`;
    $('editor').innerHTML = `<form id="book-form" class="editor-form"><div class="dialog-top"><h2 id="editor-heading">${saved ? '本の詳細' : '本を追加'}</h2><button class="icon-button" type="button" data-action="close-editor" aria-label="詳細を閉じる">${icons.close}</button></div><div class="editor-body"><div id="editor-error" class="field-error" role="alert" hidden></div><label class="form-field"><span>タイトル<span class="required">必須</span></span><textarea name="title" rows="2" required>${esc(book.title)}</textarea></label>${input('author', '著者', 'text', true)}<div class="form-grid"><label class="form-field">状態<select name="status">${options(state.statuses, book.status)}</select></label><label class="form-field">カテゴリ<select name="category">${options(state.categories, book.category)}</select></label><label class="form-field">シリーズ<select name="series">${options(state.series, book.series, 'なし')}</select></label>${input('volumeNo', '巻数', 'number')}</div><label class="form-field">メモ<textarea name="memo" rows="5">${esc(book.memo)}</textarea></label>${input('url', 'URL', 'url')}${saved?.url && httpUrl(saved.url) ? `<a class="external-link" href="${esc(saved.url)}" target="_blank" rel="noopener noreferrer">登録したページを開く ↗</a>` : ''}</div><footer class="editor-footer"><span id="draft-state" class="draft-state"></span><button class="secondary-button" type="button" data-action="close-editor">閉じる</button><button class="primary-button" type="submit">${saved ? '保存' : '追加'}</button></footer></form>`;
    ui.editorBaseline = formSignature($('book-form'));
    $('editor').showModal(); applyWriteState();
    const control = $('book-form').elements[memo ? 'memo' : 'title']; control.focus(); if (memo) control.scrollIntoView({ block: 'center' });
  }
  async function closeEditor() {
    if (!$('editor').open || store.getMeta().busy) return false;
    const unknown = ui.editorRecovery && ['unknown', 'unknownAdd'].includes(ui.editorRecovery.kind);
    if (ui.editorDirty && !await requestConfirmation(unknown ? '入力を閉じますか？' : '変更を破棄して閉じますか？', unknown ? '保存結果を確認できていません。表示中の入力は失われます。' : '未保存の変更は失われます。', unknown ? '閉じる' : '破棄する')) return false;
    ui.editorDirty = false; ui.editorBaseline = null; ui.editorId = null; ui.editorOriginal = null; ui.editorRecovery = null; $('editor').close(); return true;
  }
  function formValues(form) {
    const values = Object.fromEntries(new FormData(form));
    values.volumeNo = values.volumeNo === '' ? null : Number(values.volumeNo);
    values.series = values.series || null; values.url = values.url || null; return values;
  }
  async function saveBook(event) {
    event.preventDefault(); const form = event.target;
    if (store.getMeta().busy || store.getMeta().blocked || ui.editorRecovery || !form.reportValidity()) return;
    const added = ui.editorId === null;
    try {
      const values = window.BooksModel.fields(formValues(form), data(), ui.editorOriginal); ui.editorAttempt = values;
      const result = added ? await store.addBook(values) : await store.updateBook(ui.editorId, values, ui.editorOriginal);
      ui.editorDirty = false; ui.editorBaseline = null; ui.editorId = null; ui.editorOriginal = null; ui.editorRecovery = null;
      $('editor').close(); render(); mutationNotice(added ? '本を追加しました' : '保存しました', result);
    } catch (error) {
      if (error.kind === 'conflict' || error.kind === 'unknown') {
        ui.editorRecovery = { kind: added && error.kind === 'unknown' ? 'unknownAdd' : error.kind, message: error.message, revision: store.getMeta().revision };
        showEditorRecovery();
      } else { $('editor-error').textContent = error.message; $('editor-error').hidden = false; }
      applyWriteState(); $('editor-error').scrollIntoView({ block: 'nearest' });
    }
  }
  function openManage(kind) {
    hideMenu(); closeSidebar('none'); const state = data();
    const single = kind === 'category' || kind === 'series';
    $('manage-dialog').classList.toggle('taxonomy-add-dialog', single);
    if (single) {
      const label = kind === 'category' ? 'カテゴリ' : 'シリーズ';
      $('manage-dialog').innerHTML = `<div class="dialog-top"><h2 id="manage-heading">${label}を追加</h2><button class="icon-button" data-action="close-dialog" aria-label="管理を閉じる">${icons.close}</button></div><div class="dialog-body"><div id="manage-error" class="field-error" role="alert" hidden></div><form data-taxonomy="${kind}" data-mode="add"><label class="form-field">${label}名<input name="name" required aria-label="新しい${label}" autocomplete="off"></label><div class="confirm-actions"><button class="secondary-button" type="button" data-action="close-dialog">キャンセル</button><button class="primary-button" type="submit">追加</button></div></form></div>`;
    } else {
      $('manage-dialog').innerHTML = `<div class="dialog-top"><h2 id="manage-heading">カテゴリ・シリーズ</h2><button class="icon-button" data-action="close-dialog" aria-label="管理を閉じる">${icons.close}</button></div><div class="dialog-body"><div id="manage-error" class="field-error" role="alert" hidden></div>${[['category', 'カテゴリ', state.categories], ['series', 'シリーズ', state.series]].map(([type, label, items]) => `<section class="manage-group"><h3>${label}</h3><div class="taxonomy-tags">${items.map(item => `<span>${esc(item)}</span>`).join('')}</div><form class="manage-form" data-taxonomy="${type}"><input name="name" required aria-label="新しい${label}" placeholder="新しい${label}"><button class="secondary-button" type="submit">追加</button></form></section>`).join('')}</div>`;
    }
    if (!$('manage-dialog').open) $('manage-dialog').showModal();
    applyWriteState();
    if (kind === 'category' || kind === 'series') $('manage-dialog').querySelector(`[data-taxonomy="${kind}"] input`).focus();
  }

  function clearFilters() { ui.query = ''; ui.status = ''; ui.category = ''; ui.series = ''; render(); $('content-scroll').scrollTop = 0; }
  function resetFilters() { ui.status = ''; ui.category = ''; ui.series = ''; render(); }
  function navigateScope(key, value = '') {
    hideMenu();
    ui.scope = { key, value };
    ui.selecting = false; ui.selected.clear();
    clearFilters();
    closeSidebar('collection');
  }

  function httpUrl(value) {
    if (!/^https?:\/\//i.test(value) || /[\u0000-\u0020\u007f\\]/.test(value)) return false;
    try { const url = new URL(value); return (url.protocol === 'http:' || url.protocol === 'https:') && Boolean(url.hostname); }
    catch (_) { return false; }
  }
  function cellProblem(target, value) {
    const field = target.dataset.field, reasons = validityKeys.filter(key => target.validity?.[key]);
    const add = reason => { if (!reasons.includes(reason)) reasons.push(reason); };
    if ((field === 'title' || field === 'author') && !value.trim()) add('valueMissing');
    if (field === 'url' && value.trim() && !httpUrl(value.trim())) add('typeMismatch');
    if (field === 'volumeNo' && value !== '') {
      const number = Number(value);
      if (!/^[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:e[+-]?\d+)?$/i.test(value) || !Number.isFinite(number)) add('badInput');
      else if (number < 0) add('rangeUnderflow');
      else if (Math.abs(number * 10 - Math.round(number * 10)) > 1e-7) add('stepMismatch');
    }
    if (target.validity?.valid === false && !reasons.length) add('customError');
    if (!reasons.length) return null;
    const help = field === 'volumeNo' ? '0以上の数値を0.1刻みで入力するか、空欄にしてください。' : field === 'url' ? 'httpまたはhttpsのURLを入力するか、空欄にしてください。' : fieldLabels[field] + 'を入力してください。';
    return { reasons, message: `「${booksById.get(Number(target.dataset.editId)).title}」の${fieldLabels[field]}を確認してください。${help}` };
  }
  function updateDraft(target) {
    const id = Number(target.dataset.editId), field = target.dataset.field, original = ui.draftBases.get(id) || booksById.get(id);
    if (!original || !editableFields.includes(field)) return;
    if (!ui.draftBases.has(id)) ui.draftBases.set(id, window.BooksModel.clone(original));
    const key = id + ':' + field, raw = target.value;
    const problem = cellProblem(target, raw);
    if (problem) { ui.invalidCells.set(key, { id, field, value: raw, ...problem }); target.setAttribute('aria-invalid', 'true'); }
    else {
      ui.invalidCells.delete(key); target.removeAttribute('aria-invalid'); let value = raw;
      if (field === 'volumeNo') value = value === '' ? null : Number(value);
      if (field === 'series' || field === 'url') value = value || null;
      const patch = { ...ui.drafts.get(id) }; if (value === original[field]) delete patch[field]; else patch[field] = value;
      if (Object.keys(patch).length) ui.drafts.set(id, patch); else ui.drafts.delete(id);
    }
    if (!changedBookIds().has(id)) ui.draftBases.delete(id);
    target.closest('[data-row]')?.classList.toggle('is-draft', changedBookIds().has(id)); renderEditToolbar(); applyWriteState();
  }
  async function saveTable() {
    if (store.getMeta().busy || ui.tableRecovery) return false;
    if (ui.invalidCells.size) { const invalid = ui.invalidCells.values().next().value; notify(invalid.message, true, false); $(`cell-${invalid.id}-${invalid.field}`)?.focus(); return false; }
    const edits = Array.from(ui.drafts, ([id, patch]) => ({ id, patch, expected: ui.draftBases.get(id) }));
    if (!edits.length) return false;
    try {
      const result = await store.saveEdits(edits);
      ui.drafts.clear(); ui.draftBases.clear(); ui.invalidCells.clear(); ui.tableRecovery = null; ui.editing = false;
      render(); mutationNotice(edits.length + '冊の変更を保存しました', result); return true;
    } catch (error) {
      if (error.kind === 'conflict' || error.kind === 'unknown') ui.tableRecovery = { kind: error.kind, revision: store.getMeta().revision };
      render(); notify(error.message, true, false); return false;
    }
  }
  async function discardTable() {
    if (store.getMeta().busy) return false;
    const unknown = ui.tableRecovery?.kind === 'unknown';
    if (tableDirty() && !await requestConfirmation('表の入力を破棄しますか？', unknown ? '保存結果を確認できていません。表示中の入力は失われます。' : '未保存の変更は失われます。')) return false;
    ui.drafts.clear(); ui.draftBases.clear(); ui.invalidCells.clear(); ui.tableRecovery = null; ui.editing = false; render(); return true;
  }
  function exportJSON() {
    const blob = new Blob([store.exportData()], { type: 'application/json;charset=utf-8' }), url = URL.createObjectURL(blob), link = document.createElement('a');
    link.href = url; link.download = 'books-' + new Date().toISOString().slice(0, 10) + '.json';
    document.body.append(link); link.click(); link.remove(); setTimeout(() => URL.revokeObjectURL(url), 1000); notify('JSONを書き出しました', false, false);
  }

  document.addEventListener('click', async event => {
    const button = event.target.closest('[data-action]'); if (!button || button.disabled) return;
    const action = button.dataset.action; if (button.closest('#more-menu')) hideMenu();
    if (action === 'toggle-sidebar') toggleSidebar();
    else if (action === 'status-filter') navigateScope(button.dataset.value ? 'status' : 'all', button.dataset.value);
    else if (action === 'category-filter') navigateScope('category', button.dataset.value);
    else if (action === 'series-filter') navigateScope('series', button.dataset.value);
    else if (action === 'clear-filter') {
      if (['query', ...filterDimensions].includes(button.dataset.key)) ui[button.dataset.key] = '';
      render();
    }
    else if (action === 'clear-all') clearFilters();
    else if (action === 'reset-filters') resetFilters();
    else if (action === 'add') openEditor();
    else if (action === 'open' || action === 'memo') openEditor(Number(button.dataset.id), action === 'memo');
    else if (action === 'close-editor') await closeEditor();
    else if (action === 'close-dialog') button.closest('dialog').close();
    else if (action === 'manage') openManage(button.dataset.kind);
    else if (action === 'refresh') await refresh();
    else if (action === 'rebase-table') await rebaseTable();
    else if (action === 'rebase-editor') await rebaseEditor();
    else if (action === 'adopt-book') { ui.editorDirty = false; $('editor').close(); openEditor(Number(button.dataset.id)); }
    else if (action === 'density') { ui.compact = !ui.compact; render(); }
    else if (action === 'select-mode') { ui.selecting = !ui.selecting; if (!ui.selecting) ui.selected.clear(); render(); }
    else if (action === 'clear-selection') { ui.selected.clear(); renderResults(); }
    else if (action === 'batch') {
      const patch = {}; if ($('batch-status').value) patch.status = $('batch-status').value; if ($('batch-category').value) patch.category = $('batch-category').value;
      if (!Object.keys(patch).length) { notify('状態かカテゴリを選んでください', false, false); return; }
      const count = ui.selected.size;
      if (await runMutation(() => store.batchUpdate([...ui.selected], patch), count + '冊を変更しました')) { ui.selected.clear(); renderResults(); }
    } else if (action === 'undo') {
      if (ui.editing) return;
      if (await runMutation(() => store.undo(), '元に戻しました')) { ui.selected.clear(); render(); }
    } else if (action === 'table-edit') {
      if (ui.editing) return; ui.editing = true; ui.selecting = false; ui.selected.clear(); render();
    } else if (action === 'discard-table') await discardTable(); else if (action === 'save-table') await saveTable();
    else if (action === 'export') exportJSON();
    else if (action === 'close-toast') { $('toast').hidden = true; clearTimeout(toastTimer); }
  });
  document.addEventListener('change', event => {
    const target = event.target;
    if (filterDimensions.some(dimension => target.id === dimension + '-filter') || target.id === 'sort') {
      const dimension = target.id === 'sort' ? 'sort' : target.id.replace('-filter', '');
      ui[dimension] = ui.scope.key === dimension ? '' : target.value;
      render(); $('content-scroll').scrollTop = 0;
    } else if (target.dataset.bookStatus) runMutation(() => store.updateBook(Number(target.dataset.bookStatus), { status: target.value }), '「' + labelMap[target.value] + '」に変更しました');
    else if (target.dataset.select) { const id = Number(target.dataset.select); if (target.checked) ui.selected.add(id); else ui.selected.delete(id); renderResults(); }
    else if (target.id === 'select-all') { for (const book of filteredBooks()) { if (target.checked) ui.selected.add(book.id); else ui.selected.delete(book.id); } renderResults(); }
    if (target.dataset.editId) updateDraft(target); if (target.closest('#book-form')) updateEditorDirty();
  });
  document.addEventListener('input', event => {
    const target = event.target;
    if (target.id === 'search') { ui.query = target.value; renderResults(); $('content-scroll').scrollTop = 0; }
    if (target.closest('#book-form')) updateEditorDirty(); if (target.dataset.editId) updateDraft(target);
  });
  document.addEventListener('submit', async event => {
    const form = event.target;
    if (form.id === 'book-form') await saveBook(event);
    else if (form.dataset.taxonomy) {
      event.preventDefault();
      if (store.getMeta().busy || store.getMeta().blocked) return;
      try {
        const kind = form.dataset.taxonomy;
        const result = kind === 'category' ? await store.addCategory(form.elements.name.value) : await store.addSeries(form.elements.name.value);
        if (form.dataset.mode === 'add') $('manage-dialog').close();
        else { openManage(); $('manage-dialog').querySelector(`[data-taxonomy="${kind}"] input`).focus(); }
        render(); mutationNotice((kind === 'category' ? 'カテゴリ' : 'シリーズ') + 'を追加しました', result);
      } catch (error) {
        $('manage-error').textContent = error.message; $('manage-error').hidden = false;
        if (error.kind === 'unknown') {
          form.dataset.unknown = 'true';
          $('manage-error').innerHTML = `${esc(error.message)}<button type="button" data-action="refresh">再読み込み</button><p>結果を確認してから、この画面を閉じてください。</p>`;
        }
        applyWriteState();
      }
    }
  });
  $('manage-dialog').addEventListener('cancel', event => { if (store.getMeta().busy) event.preventDefault(); });

  $('editor').addEventListener('cancel', event => { event.preventDefault(); closeEditor(); });
  document.addEventListener('keydown', event => {
    if (document.querySelector('dialog[open]')) return;
    if (sidebarMedia.matches && ui.sidebarOpen) {
      if (event.key === 'Escape') { event.preventDefault(); closeSidebar(); return; }
      if (event.key === 'Tab') {
        const controls = Array.from($('sidebar').querySelectorAll('button, a, input, select, [tabindex]')).filter(element => !element.disabled && !element.hidden && element.tabIndex >= 0);
        const first = controls[0], last = controls[controls.length - 1];
        if (event.shiftKey && document.activeElement === first) { event.preventDefault(); last?.focus(); }
        else if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first?.focus(); }
      }
      return;
    }
    if (event.ctrlKey || event.metaKey || event.altKey || event.target.closest('input,textarea,select,[contenteditable]')) return;
    if (event.key === '/') { event.preventDefault(); hideMenu(); $('search').focus(); }
    if (event.key.toLowerCase() === 'n') { event.preventDefault(); hideMenu(); openEditor(); }
  });
  sidebarMedia.addEventListener?.('change', syncSidebar);
  window.addEventListener('resize', syncSidebar);
  window.addEventListener('beforeunload', event => { if (ui.editorDirty || tableDirty() || store.getMeta().saving) { event.preventDefault(); event.returnValue = ''; } });

  render();
  refresh().then(() => { if (store.getMeta().loaded && new URLSearchParams(window.location.search).get('mode') === 'edit') { ui.editing = true; render(); } });
})();

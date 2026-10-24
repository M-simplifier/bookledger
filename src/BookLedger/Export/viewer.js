(() => {
  'use strict';
  const $ = id => document.getElementById(id);
  const snapshot = JSON.parse($('snapshot-data').textContent);
  const books = snapshot.books;
  const esc = value => String(value ?? '').replace(/[&<>"']/g, character => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[character]));
  const labels = { all: 'すべての本', reading: '読書中', unread: '未読', finished: '読了', planned: '購入予定', disposed: '処分' };
  const navOrder = ['all', 'reading', 'unread', 'finished', 'planned', 'disposed'];
  const dimensions = ['status', 'category', 'series'];
  const rank = { reading: 0, unread: 1, planned: 2, finished: 3, disposed: 4 };
  const collator = new Intl.Collator('ja', { numeric: true, sensitivity: 'base' });
  const categories = [...new Set(books.map(book => book.category))].sort(collator.compare);
  const series = [...new Set(books.map(book => book.series).filter(value => value !== null))].sort(collator.compare);
  const ui = { scope: { key: 'all', value: '' }, query: '', status: '', category: '', series: '', sort: 'active', compact: false, sidebarOpen: false, sidebarHidden: false };
  const mobile = window.matchMedia('(max-width: 760px)');
  const svg = paths => `<svg viewBox="0 0 24 24" aria-hidden="true">${paths}</svg>`;
  const icons = {
    all: svg('<rect x="4" y="3" width="16" height="18" rx="2"/><path d="M8 7h8M8 11h8M8 15h5"/>'),
    reading: svg('<path d="M12 6c-3-2-6-2-9-1v14c3-1 6-1 9 1 3-2 6-2 9-1V5c-3-1-6-1-9 1Zm0 0v14"/>'),
    unread: svg('<rect x="5" y="3" width="14" height="18" rx="2"/><path d="M9 3v18"/>'),
    finished: svg('<path d="m5 12 4 4L19 6"/>'), planned: svg('<path d="M12 5v14M5 12h14"/>'),
    disposed: svg('<path d="M5 12h14"/>'), series: svg('<path d="M7 3h13v15H7zM4 6v15h13M11 7h5M11 11h5"/>'),
    note: svg('<path d="M5 3h14v18H5zM8 8h8M8 12h8M8 16h5"/>'), close: svg('<path d="m6 6 12 12M18 6 6 18"/>')
  };
  const normalized = value => String(value ?? '').normalize('NFKC').toLowerCase();
  const options = (values, selected, statusLabels = false) => '<option value="">すべて</option>' + values.map(value => `<option value="${esc(value)}"${value === selected ? ' selected' : ''}>${esc(statusLabels ? labels[value] : value)}</option>`).join('');
  function effectiveFilters() {
    const filters = { query: ui.query, status: ui.status, category: ui.category, series: ui.series };
    if (ui.scope.key !== 'all') filters[ui.scope.key] = ui.scope.value;
    return filters;
  }
  function timestamp(value) {
    const normalized = /^\d{4}-\d\d-\d\d[ T]\d\d:\d\d:\d\d(?:\.\d+)?$/.test(value) ? value.replace(' ', 'T') + 'Z' : value;
    return Date.parse(normalized) || 0;
  }
  function filteredBooks() {
    const filters = effectiveFilters(), tokens = normalized(filters.query).trim().split(/\s+/).filter(Boolean);
    const updated = (a, b) => timestamp(b.updatedAt) - timestamp(a.updatedAt) || b.id - a.id;
    const title = (a, b) => collator.compare(a.title, b.title) || b.id - a.id;
    const catalog = (a, b) => collator.compare(a.category, b.category) || collator.compare(a.series || a.title, b.series || b.title) || (a.volumeNo === null ? (b.volumeNo === null ? 0 : 1) : b.volumeNo === null ? -1 : a.volumeNo - b.volumeNo) || title(a, b);
    const comparators = { active: (a, b) => rank[a.status] - rank[b.status] || updated(a, b), updated, title, catalog };
    return books.filter(book => dimensions.every(key => !filters[key] || book[key] === filters[key]) && tokens.every(token => normalized([book.title, book.author, book.memo, book.category, book.series || ''].join(' ')).includes(token))).sort(comparators[ui.sort]);
  }
  function safeUrl(value) {
    const candidate = value?.trim();
    if (!candidate || !/^https?:\/\//i.test(candidate) || /[\u0000-\u0020\u007f\\]/.test(candidate)) return null;
    try { const url = new URL(candidate); return ['http:', 'https:'].includes(url.protocol) && url.hostname ? candidate : null; }
    catch (_) { return null; }
  }
  const seriesText = book => [book.series, book.volumeNo === null ? '' : book.volumeNo + '巻'].filter(Boolean).join(' · ');
  function renderNav() {
    $('status-nav').innerHTML = navOrder.map(key => {
      const active = key === 'all' ? ui.scope.key === 'all' : ui.scope.key === 'status' && ui.scope.value === key;
      const count = key === 'all' ? books.length : books.filter(book => book.status === key).length;
      return `<button id="nav-status-${key}" class="nav-button" data-action="scope" data-key="${key === 'all' ? 'all' : 'status'}" data-value="${key === 'all' ? '' : key}" aria-current="${active}"><span class="nav-symbol" aria-hidden="true">${icons[key]}</span><span class="nav-label">${labels[key]}</span><span class="nav-count">${count}</span></button>`;
    }).join('');
    for (const [key, values] of [['category', categories], ['series', series]]) {
      $(key + '-nav').innerHTML = values.map((value, index) => `<button id="nav-${key}-${index}" class="nav-button" data-action="scope" data-key="${key}" data-value="${esc(value)}" aria-current="${ui.scope.key === key && ui.scope.value === value}">${key === 'series' ? `<span class="nav-symbol" aria-hidden="true">${icons.series}</span>` : '<span class="category-square" aria-hidden="true"></span>'}<span class="nav-label">${esc(value)}</span><span class="nav-count">${books.filter(book => book[key] === value).length}</span></button>`).join('');
    }
  }
  function renderFilters() {
    $('status-filter').innerHTML = options(navOrder.slice(1), ui.status, true);
    $('category-filter').innerHTML = options(categories, ui.category);
    $('series-filter').innerHTML = options(series, ui.series);
    for (const key of dimensions) {
      $(key + '-filter-field').hidden = ui.scope.key === key;
      $(key + '-filter').disabled = ui.scope.key === key;
    }
    const count = dimensions.filter(key => ui[key]).length;
    $('filter-count').textContent = count; $('filter-count').hidden = count === 0;
    $('reset-filters').disabled = count === 0;
    const filters = [['query', ui.query], ...dimensions.map(key => [key, key === 'status' ? labels[ui[key]] : ui[key]])].filter(([, value]) => value);
    $('filter-chips').innerHTML = filters.map(([key, value]) => `<button class="filter-chip" data-action="clear-filter" data-key="${key}" aria-label="${esc(value)}の条件を解除">${esc(key === 'query' ? '検索: ' + value : value)}<span aria-hidden="true">×</span></button>`).join('') + (filters.length ? '<button class="clear-filters" data-action="clear-all">すべて解除</button>' : '');
  }
  function renderRows(values) {
    return values.map(book => `<article class="book-row" data-row="${book.id}"><div><button class="book-title-button" data-action="open" data-id="${book.id}">${esc(book.title)}</button><div class="book-author">${esc(book.author)}</div></div><div class="book-meta"><span class="category-tag">${esc(book.category)}</span><span class="series-label">${esc(seriesText(book))}</span></div><span class="status-wrap${book.status === 'reading' ? ' is-reading' : ''}"><span class="status-label">${labels[book.status]}</span></span>${book.memo ? `<button class="memo-button has-memo" data-action="open" data-id="${book.id}" aria-label="${esc(book.title)}のメモを読む" title="メモを読む">${icons.note}</button>` : '<span class="memo-space" aria-hidden="true"></span>'}</article>`).join('');
  }
  function renderList(values) {
    const header = '<div class="list-header"><span>タイトル / 著者</span><span class="meta-heading">カテゴリ / シリーズ</span><span>状態</span><span class="memo-heading"></span></div>';
    if (effectiveFilters().status || ui.sort !== 'active') return header + renderRows(values);
    const groups = new Map();
    for (const book of values) { if (!groups.has(book.status)) groups.set(book.status, []); groups.get(book.status).push(book); }
    return header + Array.from(groups, ([status, members]) => `<section class="book-group" aria-labelledby="group-${status}"><h2 id="group-${status}" class="group-heading">${labels[status]}</h2>${renderRows(members)}</section>`).join('');
  }
  function render() {
    const scroll = $('content-scroll').scrollTop, active = document.activeElement;
    const values = filteredBooks(), heading = ui.scope.key === 'all' ? labels.all : ui.scope.key === 'status' ? labels[ui.scope.value] : ui.scope.value;
    $('page-title').textContent = heading; $('page-title').title = heading;
    $('heading-count').textContent = values.length; $('heading-count').setAttribute('aria-label', values.length + '冊');
    $('search').value = ui.query; $('search').placeholder = ui.scope.key === 'all' ? '検索' : 'この一覧を検索'; $('sort').value = ui.sort;
    document.body.classList.toggle('compact', ui.compact);
    $('density-button').setAttribute('aria-pressed', String(ui.compact));
    $('density-button').innerHTML = `<span>${ui.compact ? '行にゆとりを' : '行をコンパクトに'}</span><span id="density-mark">${ui.compact ? '✓' : ''}</span>`;
    renderNav(); renderFilters();
    const hasConditions = Boolean(ui.query || ui.status || ui.category || ui.series);
    $('book-list').innerHTML = values.length ? renderList(values) : `<div class="empty-state"><h2>${hasConditions ? '本が見つかりません' : '本がありません'}</h2>${hasConditions ? '<button class="secondary-button" data-action="clear-all">条件を解除</button>' : ''}</div>`;
    $('content-scroll').scrollTop = scroll;
    syncSidebar();
    if (active?.id && !active.isConnected) $(active.id)?.focus({ preventScroll: true });
  }
  function hideMenus() {
    for (const id of ['filter-menu', 'more-menu']) { try { $(id).hidePopover?.(); } catch (_) { /* Closed. */ } }
  }
  function clearFilters(query = true) {
    if (query) ui.query = '';
    for (const key of dimensions) ui[key] = '';
    render(); $('content-scroll').scrollTop = 0;
  }
  function navigateScope(key, value) {
    hideMenus(); ui.scope = { key, value }; clearFilters(); closeSidebar('collection');
  }
  function syncSidebar() {
    if (!mobile.matches) ui.sidebarOpen = false;
    const open = mobile.matches && ui.sidebarOpen;
    document.body.classList.toggle('sidebar-open', open); document.body.classList.toggle('sidebar-hidden', !mobile.matches && ui.sidebarHidden);
    $('sidebar').inert = mobile.matches ? !open : ui.sidebarHidden;
    document.querySelector('.main-pane').inert = open;
    for (const id of ['filter-menu', 'more-menu']) $(id).inert = open;
    document.querySelector('.skip-link').inert = open; document.querySelector('.sidebar-shade').hidden = !open;
    document.querySelector('.sidebar-toggle').setAttribute('aria-expanded', String(mobile.matches ? open : !ui.sidebarHidden));
    if ($('sidebar').inert && $('sidebar').contains(document.activeElement)) document.querySelector('.sidebar-toggle').focus({ preventScroll: true });
  }
  function closeSidebar(focus = 'toggle') {
    if (!mobile.matches || !ui.sidebarOpen) return;
    ui.sidebarOpen = false; syncSidebar();
    if (focus === 'collection') { $('page-title').tabIndex = -1; $('page-title').focus({ preventScroll: true }); }
    else if (focus === 'toggle') document.querySelector('.sidebar-toggle').focus({ preventScroll: true });
  }
  function toggleSidebar() {
    hideMenus();
    if (mobile.matches) {
      if (ui.sidebarOpen) { closeSidebar(); return; }
      ui.sidebarOpen = true; syncSidebar(); $('sidebar').querySelector('[aria-current="true"]')?.focus({ preventScroll: true });
    } else { ui.sidebarHidden = !ui.sidebarHidden; syncSidebar(); }
  }
  function openDetails(id) {
    const book = books.find(book => book.id === id); if (!book) return;
    hideMenus(); closeSidebar('none');
    const fact = (label, value) => `<div><dt>${label}</dt><dd>${esc(value)}</dd></div>`;
    const url = safeUrl(book.url);
    $('details').innerHTML = `<div class="detail-panel"><div class="dialog-top"><h2 id="detail-heading">本の詳細</h2><button class="icon-button" data-action="close-details" aria-label="詳細を閉じる">${icons.close}</button></div><div class="editor-body"><h3 class="detail-title">${esc(book.title)}</h3><p class="detail-author">${esc(book.author)}</p><dl class="detail-facts">${fact('状態', labels[book.status])}${fact('カテゴリ', book.category)}${book.series === null ? '' : fact('シリーズ', book.series)}${book.volumeNo === null ? '' : fact('巻数', book.volumeNo)}</dl>${book.memo ? `<div class="detail-memo"><h3>メモ</h3><p>${esc(book.memo)}</p></div>` : ''}${url ? `<a class="external-link" href="${esc(url)}" target="_blank" rel="noopener noreferrer">登録したページを開く ↗</a>` : ''}</div><footer class="detail-footer"><span>${esc(snapshot.generatedAt ? '閲覧用 · 作成 ' + snapshot.generatedAt.replace('T', ' ').replace('Z', ' UTC') : '閲覧用 · 作成日時不明')}</span><button class="secondary-button" data-action="close-details">閉じる</button></footer></div>`;
    $('details').showModal();
  }
  document.addEventListener('click', event => {
    const button = event.target.closest('[data-action]'); if (!button || button.disabled) return;
    const action = button.dataset.action;
    if (action === 'scope') navigateScope(button.dataset.key, button.dataset.value);
    else if (action === 'clear-filter' && ['query', ...dimensions].includes(button.dataset.key)) { ui[button.dataset.key] = ''; render(); }
    else if (action === 'clear-all') clearFilters();
    else if (action === 'reset-filters') clearFilters(false);
    else if (action === 'toggle-sidebar') toggleSidebar();
    else if (action === 'open') openDetails(Number(button.dataset.id));
    else if (action === 'close-details') $('details').close();
    else if (action === 'density') { hideMenus(); ui.compact = !ui.compact; render(); }
  });
  document.addEventListener('change', event => {
    const key = event.target.id === 'sort' ? 'sort' : dimensions.find(key => event.target.id === key + '-filter');
    if (!key) return;
    ui[key] = ui.scope.key === key ? '' : event.target.value;
    render(); $('content-scroll').scrollTop = 0;
  });
  document.addEventListener('input', event => { if (event.target.id === 'search') { ui.query = event.target.value; render(); $('content-scroll').scrollTop = 0; } });
  document.addEventListener('keydown', event => {
    if ($('details').open) return;
    if (mobile.matches && ui.sidebarOpen) {
      if (event.key === 'Escape') { event.preventDefault(); closeSidebar(); }
      if (event.key === 'Tab') {
        const controls = Array.from($('sidebar').querySelectorAll('button, a, [tabindex]')).filter(element => !element.disabled && !element.hidden && element.tabIndex >= 0);
        const first = controls[0], last = controls[controls.length - 1];
        if (event.shiftKey && document.activeElement === first) { event.preventDefault(); last?.focus(); }
        else if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first?.focus(); }
      }
      return;
    }
    if (event.ctrlKey || event.metaKey || event.altKey || event.target.closest('input,textarea,select,[contenteditable]')) return;
    if (event.key === '/') { event.preventDefault(); hideMenus(); $('search').focus(); }
  });
  mobile.addEventListener?.('change', syncSidebar); window.addEventListener('resize', syncSidebar);
  render(); document.body.classList.add('js-ready'); $('fallback').hidden = true;
  document.querySelector('.skip-link').href = '#search'; document.querySelector('.skip-link').textContent = '検索へ移動';
})();

'use strict';
const assert = require('node:assert/strict');
const test = require('node:test');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const asset = name => fs.readFileSync(path.join(__dirname, '../../src/BookLedger/Export', name), 'utf8');
const script = asset('viewer.js'), shell = asset('viewer.html');
class Events {
  constructor() { this.listeners = new Map(); }
  addEventListener(type, listener) { if (!this.listeners.has(type)) this.listeners.set(type, []); this.listeners.get(type).push(listener); }
  fire(type, event) { for (const listener of this.listeners.get(type) || []) listener(event); }
}
class Element extends Events {
  constructor(document, id = '') {
    super(); this.document = document; this.id = id; this.dataset = {}; this.innerHTML = ''; this.textContent = ''; this.attributes = new Map();
    this.hidden = false; this.inert = false; this.open = false; this.disabled = false; this.scrollTop = 0; this.tabIndex = 0; this.isConnected = true;
    this.classes = new Set();
    this.classList = { add: key => this.classes.add(key), contains: key => this.classes.has(key), toggle: (key, enabled = !this.classes.has(key)) => { enabled ? this.classes.add(key) : this.classes.delete(key); return enabled; } };
  }
  setAttribute(name, value) { this.attributes.set(name, String(value)); }
  getAttribute(name) { return this.attributes.get(name); }
  focus() { this.document.activeElement = this; }
  contains(element) { return element === this || element?.parent === this; }
  closest(selector) { return selector === '[data-action]' && this.dataset.action ? this : null; }
  querySelector() { return this.document.navButton; }
  querySelectorAll() { return this.document.sidebarControls; }
  showModal() { this.open = true; }
  close() { this.open = false; }
  hidePopover() { this.popoverHidden = true; }
}
function fixture() {
  const book = (id, values) => ({ id, title: '本' + id, author: '著者', status: 'unread', category: '専門書', series: '試験シリーズ', volumeNo: null, memo: '', url: null, createdAt: '2026-01-01 00:00:00', updatedAt: '2026-10-24 09:00:00', ...values });
  return [
    book(1, { title: 'Ｃａｆｅ 第２巻', author: '山田', status: 'reading', volumeNo: 2, memo: '検討\n\n次の行 <em>', url: 'https://example.com/?a=1&b="two"', updatedAt: '2026-10-24T10:00:00Z' }),
    book(2, { title: '本10', volumeNo: 10, url: 'javascript:alert(1)' }),
    book(3, { title: '本2', volumeNo: 2 }),
    book(4, { title: '散歩', category: '一般書', series: null }),
    book(5, { title: '終わり', status: 'finished', category: '一般書', series: '別のシリーズ', volumeNo: 0 }),
    book(6, { title: '次の本', status: 'planned', category: '未分類', series: null })
  ];
}
function boot(books = fixture()) {
  const document = new Events(), elements = new Map();
  document.activeElement = null;
  document.add = id => { const element = new Element(document, id); elements.set(id, element); return element; };
  document.getElementById = id => elements.get(id) || null;
  for (const match of shell.matchAll(/\bid="([^"]+)"/g)) document.add(match[1]);
  document.body = document.add('body'); document.add('fallback');
  document.getElementById('snapshot-data').textContent = JSON.stringify({ generatedAt: '2026-10-24T12:34:56Z', books });
  const surfaces = Object.fromEntries(['.main-pane', '.sidebar-toggle', '.sidebar-shade', '.skip-link'].map(key => [key, new Element(document)]));
  document.querySelector = selector => surfaces[selector] || null;
  document.navButton = new Element(document); document.navButton.parent = elements.get('sidebar');
  document.sidebarControls = [document.navButton, new Element(document)];
  const window = new Events(), mobile = { matches: false, addEventListener() {} };
  window.matchMedia = () => mobile;
  const context = vm.createContext({ window, document, URL, Intl });
  const exposed = ['ui', 'books', 'render', 'filteredBooks', 'effectiveFilters', 'safeUrl', 'navigateScope', 'clearFilters', 'openDetails', 'syncSidebar', 'toggleSidebar', 'closeSidebar'];
  vm.runInContext(script.replace(/\}\)\(\);\s*$/, `window.__viewer={${exposed}};\n})();`), context);
  return { ...window.__viewer, document, elements, surfaces, mobile };
}
function action(h, name, extra = {}) { const target = new Element(h.document); target.dataset = { action: name, ...extra }; h.document.fire('click', { target }); }
function change(h, id, value) { const target = h.elements.get(id); target.value = value; h.document.fire('change', { target }); }
const nav = h => ['status-nav', 'category-nav', 'series-nav'].map(id => h.elements.get(id).innerHTML).join('');
const ids = values => Array.from(values, book => book.id);

test('left navigation selects exactly one collection and clears prior search/extra filters', () => {
  const h = boot();
  assert.equal(h.elements.get('heading-count').textContent, 6);
  action(h, 'scope', { key: 'category', value: '専門書' }); assert.equal(h.elements.get('heading-count').textContent, 3);
  change(h, 'status-filter', 'reading'); h.ui.query = 'cafe'; h.ui.sort = 'title'; h.ui.compact = true;
  action(h, 'scope', { key: 'status', value: 'unread' });
  assert.equal(h.elements.get('heading-count').textContent, 3); assert.equal(h.ui.query, ''); assert.equal(h.ui.category, ''); assert.equal(h.ui.status, '');
  assert.equal(h.ui.sort, 'title'); assert.equal(h.ui.compact, true);
  assert.equal((nav(h).match(/aria-current="true"/g) || []).length, 1);
  action(h, 'scope', { key: 'category', value: '専門書' }); action(h, 'scope', { key: 'category', value: '専門書' });
  assert.equal(h.elements.get('heading-count').textContent, 3);
});

test('extra conditions intersect the current collection and clear/reset preserve its meaning', () => {
  const h = boot(); action(h, 'scope', { key: 'category', value: '専門書' });
  change(h, 'status-filter', 'unread'); assert.equal(h.elements.get('heading-count').textContent, 2);
  assert.equal(h.elements.get('page-title').textContent, '専門書'); assert.equal(h.elements.get('page-title').title, '専門書');
  assert.equal(h.elements.get('category-filter-field').hidden, true); assert.equal(h.elements.get('filter-count').textContent, 1);
  assert.doesNotMatch(h.elements.get('filter-chips').innerHTML, /専門書/);
  h.ui.query = '本'; h.render(); action(h, 'reset-filters');
  assert.equal(h.ui.query, '本'); assert.equal(h.elements.get('filter-count').hidden, true);
  action(h, 'clear-all'); assert.equal(h.elements.get('heading-count').textContent, 3); assert.equal(h.ui.scope.value, '専門書');
  change(h, 'category-filter', '一般書'); assert.equal(h.ui.category, ''); assert.equal(h.effectiveFilters().category, '専門書');
});

test('NFKC multi-token search combines title, author and memo without mutating the snapshot', () => {
  const books = fixture(), before = JSON.stringify(books), h = boot(books);
  h.ui.query = 'cafe 山田 第2 検討'; h.render(); assert.deepEqual(ids(h.filteredBooks()), [1]);
  assert.equal(h.elements.get('page-title').textContent, 'すべての本');
  h.ui.query = '専門書 試験シリーズ'; h.render(); assert.deepEqual(ids(h.filteredBooks()), [1, 3, 2]);
  assert.equal(JSON.stringify(books), before);
  assert.equal(JSON.stringify(h.books), before);
});

test('all four sorts preserve natural numbers, dates, volume order, and status grouping rules', () => {
  const h = boot();
  assert.equal((h.elements.get('book-list').innerHTML.match(/class="book-group"/g) || []).length, 4);
  change(h, 'sort', 'title'); const titles = h.filteredBooks().map(book => book.title);
  assert.ok(titles.indexOf('本2') < titles.indexOf('本10')); assert.doesNotMatch(h.elements.get('book-list').innerHTML, /class="book-group"/);
  change(h, 'sort', 'updated'); assert.equal(h.filteredBooks()[0].id, 1);
  change(h, 'sort', 'catalog'); const volumes = ids(h.filteredBooks()).filter(id => [2, 3].includes(id)); assert.deepEqual(volumes, [3, 2]);
  change(h, 'sort', 'active'); action(h, 'scope', { key: 'status', value: 'unread' }); assert.doesNotMatch(h.elements.get('book-list').innerHTML, /class="book-group"/);
});

test('details preserve raw memo, expose safe links explicitly, and contain no editing controls', () => {
  const h = boot(); h.openDetails(1);
  const detail = h.elements.get('details').innerHTML;
  assert.match(detail, /検討\n\n次の行 &lt;em&gt;/); assert.match(detail, /href="https:\/\/example.com\/\?a=1&amp;b=&quot;two&quot;"/);
  assert.match(detail, /2026-10-24 12:34:56 UTC/);
  assert.doesNotMatch(detail, /<form|<input|<textarea|<select|data-action="save"/);
  h.elements.get('details').close(); h.openDetails(2); assert.doesNotMatch(h.elements.get('details').innerHTML, /href=/);
  h.elements.get('details').close(); h.openDetails(5); assert.match(h.elements.get('details').innerHTML, /<dt>巻数<\/dt><dd>0<\/dd>/);
  action(h, 'close-details'); assert.equal(h.elements.get('details').open, false);
  assert.match(h.elements.get('book-list').innerHTML, /<button class="book-title-button"/);
  assert.doesNotMatch(h.elements.get('book-list').innerHTML, /status-select|data-book-status|<a /);
});

test('safe links reject dangerous/ambiguous schemes and preserve outer-whitespace HTTP URLs', () => {
  const h = boot();
  for (const value of ['javascript:alert(1)', 'data:text/html,hi', '//example.com', 'https://', 'https://exa mple.com', 'https:\\example.com']) assert.equal(h.safeUrl(value), null);
  assert.equal(h.safeUrl('  HTTPS://example.com/a  '), 'HTTPS://example.com/a');
});

test('category and series text is never translated as a status label; empty results have no write affordance', () => {
  const books = fixture(); books[0].category = 'reading'; books[0].series = 'unread';
  const h = boot(books); assert.match(h.elements.get('category-filter').innerHTML, /value="reading">reading<\/option>/);
  assert.match(h.elements.get('series-filter').innerHTML, /value="unread">unread<\/option>/);
  h.ui.query = '存在しない語'; h.render(); assert.match(h.elements.get('book-list').innerHTML, /本が見つかりません/);
  assert.match(h.elements.get('book-list').innerHTML, /条件を解除/); assert.doesNotMatch(h.elements.get('book-list').innerHTML, /data-action="add"/);
  const empty = boot([]); assert.match(empty.elements.get('book-list').innerHTML, /本がありません/); assert.doesNotMatch(empty.elements.get('book-list').innerHTML, /条件を解除|data-action="add"/);
});

test('filter changes stay open, density is optional, and collection navigation closes both popovers', () => {
  const h = boot(), filter = h.elements.get('filter-menu'), more = h.elements.get('more-menu');
  change(h, 'status-filter', 'unread'); assert.equal(filter.popoverHidden, undefined);
  action(h, 'density'); assert.equal(h.ui.compact, true); assert.equal(h.document.body.classList.contains('compact'), true);
  assert.equal(h.elements.get('density-button').getAttribute('aria-pressed'), 'true'); assert.match(h.elements.get('density-button').innerHTML, /✓/);
  assert.equal(filter.popoverHidden, true); assert.equal(more.popoverHidden, true);
});

test('mobile sidebar controls focus/inert state, traps Tab, restores focus, and responds to Escape', () => {
  const h = boot(); h.mobile.matches = true; h.syncSidebar();
  assert.equal(h.elements.get('sidebar').inert, true); h.toggleSidebar();
  assert.equal(h.surfaces['.main-pane'].inert, true); assert.equal(h.elements.get('filter-menu').inert, true); assert.equal(h.elements.get('sidebar').inert, false);
  const [first, last] = h.document.sidebarControls; last.focus(); let trapped = false;
  h.document.fire('keydown', { key: 'Tab', target: last, preventDefault() { trapped = true; } }); assert.equal(trapped, true); assert.equal(h.document.activeElement, first);
  h.document.fire('keydown', { key: 'Escape', target: first, preventDefault() {} });
  assert.equal(h.elements.get('sidebar').inert, true); assert.equal(h.surfaces['.main-pane'].inert, false); assert.equal(h.document.activeElement, h.surfaces['.sidebar-toggle']);
  h.toggleSidebar(); action(h, 'scope', { key: 'series', value: '試験シリーズ' }); assert.equal(h.document.activeElement, h.elements.get('page-title'));
});

test('the offline viewer needs no network, storage, form submission or companion files', () => {
  assert.doesNotMatch(script, /\bfetch\s*\(|XMLHttpRequest|WebSocket|localStorage|sessionStorage|document\.cookie|\.submit\(/);
  assert.doesNotMatch(shell, /<script src=|<link |<form|data-action="(?:add|save|undo|reset|table-edit)"/);
  const h = boot(); assert.equal(h.elements.get('fallback').hidden, true); assert.equal(h.document.body.classList.contains('js-ready'), true);
  const ids = new Set(Array.from((shell + script).matchAll(/\bid="([^"]+)"/g), match => match[1])); ids.add('fallback');
  for (const match of script.matchAll(/\$\('([^']+)'\)/g)) assert.ok(ids.has(match[1]), match[1]);
});

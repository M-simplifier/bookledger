'use strict';
const assert = require('node:assert/strict');
const test = require('node:test');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const asset = name => fs.readFileSync(path.join(__dirname, '../../static', name), 'utf8');
const source = asset('app.js'), shell = asset('index.html');
const plain = value => JSON.parse(JSON.stringify(value));
const fields = ['title', 'author', 'status', 'category', 'series', 'volumeNo', 'memo', 'url'];
const decode = value => String(value ?? '').replace(/&(amp|lt|gt|quot|#39);/g, (_, entity) => ({ amp: '&', lt: '<', gt: '>', quot: '"', '#39': "'" }[entity]));
class Events {
  constructor() { this.listeners = new Map(); }
  addEventListener(type, listener) { if (!this.listeners.has(type)) this.listeners.set(type, new Set()); this.listeners.get(type).add(listener); }
  removeEventListener(type, listener) { this.listeners.get(type)?.delete(listener); }
  fire(type, event = {}) { return Promise.all(Array.from(this.listeners.get(type) || [], fn => fn(event))); }
}
class Element extends Events {
  constructor(document, id = '') {
    super(); this.ownerDocument = document; this.id = id; this.dataset = {}; this.attributes = new Map(); this.classes = new Set();
    this.value = ''; this.textContent = ''; this.hidden = false; this.inert = false; this.open = false; this.isConnected = true; this.scrollTop = 0; this.tabIndex = 0; this.disabled = false;
    this.classList = { add: key => this.classes.add(key), remove: key => this.classes.delete(key), contains: key => this.classes.has(key), toggle: (key, on = !this.classes.has(key)) => { on ? this.classes.add(key) : this.classes.delete(key); return on; } };
  }
  set innerHTML(value) { this.html = value; this.ownerDocument?.parse?.(this, value); }
  get innerHTML() { return this.html || ''; }
  setAttribute(name, value) { this.attributes.set(name, String(value)); }
  getAttribute(name) { return this.attributes.get(name); }
  removeAttribute(name) { this.attributes.delete(name); }
  focus() { this.ownerDocument.activeElement = this; }
  scrollIntoView() {}
  contains(element) { return element === this || element?.parent === this; }
  closest(selector) {
    if (selector === '[data-action]') return this.dataset.action ? this : null;
    if (selector === '[data-row]') return this.row || null;
    if (selector === '#book-form') return this.form?.id === 'book-form' ? this.form : null;
    if (selector === 'form') return this.form || null;
    if (selector === 'dialog') return this.dialog || null;
    return null;
  }
  querySelector(selector) {
    if (selector === '[type="submit"]') return this.submit || null;
    if (selector === '[value="cancel"]') return this.cancelButton ||= new Element(this.ownerDocument);
    if (selector === '[aria-current="true"]') return this.ownerDocument.navButton;
    const taxonomy = selector.match(/data-taxonomy="(category|series)"/);
    return taxonomy ? this.ownerDocument.taxonomyForms[taxonomy[1]]?.elements.name : null;
  }
  querySelectorAll() { return []; }
  showModal() { this.open = true; }
  close(value) { this.open = false; if (value !== undefined) this.returnValue = value; this.fire('close'); }
  hidePopover() { this.popoverHidden = true; }
}
async function harness(options = {}) {
  const document = new Events(), elements = new Map(), taxonomyForms = {};
  document.taxonomyForms = taxonomyForms;
  document.activeElement = null;
  document.getElementById = id => elements.get(id) || null;
  document.add = id => { const element = new Element(document, id); elements.set(id, element); return element; };
  document.parse = (container, html) => {
    for (const match of html.matchAll(/\bid="([^"]+)"/g)) if (match[1] !== container.id) document.add(match[1]);
    if (!['editor', 'manage-dialog'].includes(container.id)) return;
    for (const match of html.matchAll(/<form\b([^>]*)>([\s\S]*?)<\/form>/g)) {
      const [, attrs, content] = match;
      const formId = attrs.match(/id="([^"]+)"/)?.[1];
      const form = formId ? elements.get(formId) : new Element(document);
      form.dataset.taxonomy = attrs.match(/data-taxonomy="([^"]+)"/)?.[1];
      form.dataset.mode = attrs.match(/data-mode="([^"]+)"/)?.[1];
      form.elements = {};
      for (const control of content.matchAll(/<(input|textarea|select)\b([^>]*\bname="([^"]+)"[^>]*)>/g)) {
        const [, tag, attributes, name] = control, element = new Element(document);
        const inner = tag === 'input' ? '' : content.slice(control.index + control[0].length, content.indexOf('</' + tag + '>', control.index));
        element.form = form; element.type = attributes.match(/type="([^"]+)"/)?.[1] || tag;
        element.required = /\brequired\b/.test(attributes); element.validity = { valid: true };
        if (tag === 'select') {
          const choices = Array.from(inner.matchAll(/<option value="([^"]*)"([^>]*)>/g));
          element.value = decode((choices.find(choice => /selected/.test(choice[2])) || choices[0] || [null, ''])[1]);
        } else element.value = decode(tag === 'textarea' ? inner : attributes.match(/value="([^"]*)"/)?.[1] || '');
        form.elements[name] = element;
      }
      form.submit = new Element(document); form.submit.form = form;
      form.reportValidity = () => Object.values(form.elements).every(element => (!element.required || Boolean(element.value)) && element.validity.valid);
      if (form.dataset.taxonomy) taxonomyForms[form.dataset.taxonomy] = form;
    }
  };
  for (const match of shell.matchAll(/\bid="([^"]+)"/g)) document.add(match[1]);
  document.body = document.add('body');
  const surfaces = Object.fromEntries(['.main-pane', '.sidebar-shade', '.sidebar-toggle', '.skip-link'].map(key => [key, new Element(document)]));
  const tableButton = new Element(document); tableButton.dataset.action = 'table-edit';
  document.navButton = new Element(document); document.navButton.parent = elements.get('sidebar');
  document.querySelector = selector => selector === 'dialog[open]' ? Array.from(elements.values()).find(element => element.open) || null : selector === '[data-action="table-edit"]' ? tableButton : surfaces[selector] || null;
  document.querySelectorAll = selector => selector === '.sidebar-toggle' ? [surfaces[selector]] : selector === '[data-taxonomy] button[type="submit"]' ? Object.values(taxonomyForms).map(form => form.submit) : [];
  const window = new Events(), media = { matches: false, addEventListener() {} }, errors = [];
  window.matchMedia = () => media; window.location = { search: options.search || '' }; window.console = { error: error => errors.push(error) };
  const FormData = class { constructor(form) { this.items = fields.map(name => [name, form.elements[name].value]); } [Symbol.iterator]() { return this.items[Symbol.iterator](); } };
  const context = vm.createContext({ window, document, URL, URLSearchParams, Intl, FormData, Blob, setTimeout: () => 1, clearTimeout() {} });
  vm.runInContext(asset('model.js'), context);
  const meta = { categories: ['一般書', '専門書', '未分類'], series: ['試験シリーズ'], statuses: plain(window.BooksModel.statuses) };
  const book = (id, values) => ({ id, title: '試験書籍' + id, author: '著者', status: 'unread', category: '専門書', series: null, volumeNo: null, memo: '', url: null, createdAt: '2026-01-01', updatedAt: '2026-01-01', ...values });
  const server = { meta, books: [book(1, { series: '試験シリーズ' }), book(2, { category: '一般書' }), book(3, { status: 'reading', url: 'legacy:link' })], posts: [], unknown: false, failRead: options.failRead || false };
  const response = (status, value) => ({ status, ok: status === 200, json: async () => plain(value) });
  window.fetch = async (url, init = {}) => {
    if (!init.method) { if (server.failRead) throw new Error('offline'); return response(200, url === '/api/meta' ? server.meta : server.books); }
    const body = JSON.parse(init.body); server.posts.push({ url, body });
    if (url === '/api/books/batch') {
      if (body.expected.some(before => JSON.stringify(window.BooksModel.pick(server.books.find(book => book.id === before.id))) !== JSON.stringify(before))) return response(409, { ok: false, conflict: true, error: 'ほかの画面で変更されています。' });
      server.books = server.books.map(book => ({ ...book, ...(body.books.find(after => after.id === book.id) || {}) }));
    } else if (url === '/api/books') server.books.push(book(server.books.length + 1, body));
    else if (url === '/api/series') server.meta.series.push(body.name);
    else if (url === '/api/categories') server.meta.categories.push(body.name);
    if (server.unknown) { server.unknown = false; throw new Error('response lost'); }
    return response(200, { ok: true, warning: null });
  };
  vm.runInContext(asset('store.js'), context);
  const exposed = ['ui', 'store', 'data', 'render', 'refresh', 'newBookDefaults', 'openEditor', 'openManage', 'updateDraft', 'saveTable', 'saveBook', 'rebaseEditor', 'rebaseTable', 'updateEditorDirty', 'syncSidebar', 'toggleSidebar', 'closeSidebar'];
  vm.runInContext(source.replace(/\}\)\(\);\s*$/, `window.__view={${exposed}};\n})();`), context);
  for (let count = 0; count < 40; count++) await Promise.resolve();
  assert.deepEqual(errors, []);
  return { ...window.__view, document, elements, surfaces, media, server, taxonomyForms };
}
function action(h, name, extra = {}) { const button = new Element(h.document); button.dataset = { action: name, ...extra }; return h.document.fire('click', { target: button }); }
function input(h, form, name, value) { const target = form.elements[name]; target.value = value; return h.document.fire('input', { target }); }
function cell(h, id, field, value) { const target = new Element(h.document); target.dataset = { editId: String(id), field }; target.value = value; target.validity = { valid: true }; target.row = new Element(h.document); return target; }
const nav = h => ['status-nav', 'category-nav', 'series-nav'].map(id => h.elements.get(id).innerHTML).join('');

test('production view loads server data and preserves navigation scope, extra filters, and series defaults', async () => {
  const h = await harness();
  assert.equal(h.elements.get('heading-count').textContent, 3);
  await action(h, 'category-filter', { value: '専門書' });
  assert.equal(h.elements.get('heading-count').textContent, 2);
  h.elements.get('status-filter').value = 'unread'; await h.document.fire('change', { target: h.elements.get('status-filter') });
  assert.equal(h.elements.get('heading-count').textContent, 1); assert.equal(h.elements.get('page-title').textContent, '専門書');
  await action(h, 'clear-all'); assert.equal(h.elements.get('heading-count').textContent, 2);
  h.ui.query = '検索語'; h.ui.selecting = true; h.ui.selected.add(1);
  await action(h, 'status-filter', { value: 'unread' });
  assert.equal(h.elements.get('heading-count').textContent, 2); assert.equal(h.ui.query, ''); assert.equal(h.ui.selected.size, 0);
  await action(h, 'series-filter', { value: '試験シリーズ' });
  assert.equal(h.newBookDefaults().series, '試験シリーズ');
  assert.equal((nav(h).match(/aria-current="true"/g) || []).length, 1);
  h.openEditor(3); assert.doesNotMatch(h.elements.get('editor').innerHTML, /href="legacy:/);
});

test('initial loading failure exposes retry and never a writable demo; mode=edit is preserved', async () => {
  const failed = await harness({ failRead: true });
  assert.equal(failed.store.getMeta().loaded, false); assert.match(failed.elements.get('book-list').innerHTML, /再読み込み/);
  failed.server.failRead = false; await failed.refresh(); assert.equal(failed.elements.get('heading-count').textContent, 3);
  const edit = await harness({ search: '?mode=edit' }); assert.equal(edit.document.body.dataset.view, 'catalog');
});

test('detail conflict keeps raw memo/original baseline; explicit review preserves another writer field and saves conditionally', async () => {
  const h = await harness(); h.openEditor(1);
  const form = h.elements.get('book-form'); await input(h, form, 'memo', '一行目\n\n三行目');
  h.server.books[0].author = '別画面の著者';
  await h.saveBook({ target: form, preventDefault() {} });
  assert.equal(h.ui.editorRecovery.kind, 'conflict'); assert.equal(form.elements.memo.value, '一行目\n\n三行目');
  assert.match(h.elements.get('editor-error').innerHTML, /再読み込みすると変更点を確認できます/);
  assert.doesNotMatch(h.elements.get('editor-error').innerHTML, /現在の内容に変更はありません/);
  assert.equal(h.ui.editorOriginal.author, '著者');
  await h.refresh(); assert.equal(h.ui.editorOriginal.author, '著者');
  assert.match(h.elements.get('editor-error').innerHTML, /別画面の著者/);
  const review = h.rebaseEditor(); h.elements.get('confirm-dialog').close('confirm'); await review;
  assert.equal(form.elements.author.value, '別画面の著者'); assert.equal(form.elements.memo.value, '一行目\n\n三行目');
  await h.saveBook({ target: form, preventDefault() {} });
  assert.equal(h.server.posts.at(-1).body.expected[0].author, '別画面の著者');
  assert.equal(h.server.books[0].memo, '一行目\n\n三行目'); assert.equal(h.elements.get('editor').open, false);
});

test('table hidden drafts/invalid numbers survive scopes and reload; explicit recovery keeps independent external edits', async () => {
  const h = await harness(); h.ui.editing = true; h.render();
  h.updateDraft(cell(h, 1, 'memo', '自分のメモ\n続き')); h.updateDraft(cell(h, 2, 'volumeNo', '1e'));
  await action(h, 'category-filter', { value: '専門書' });
  assert.match(h.elements.get('edit-toolbar').innerHTML, /表示外 1冊/);
  assert.equal(await h.saveTable(), false); assert.equal(h.server.posts.length, 0);
  h.updateDraft(cell(h, 2, 'volumeNo', '4.2')); h.server.books[0].author = '別の著者';
  assert.equal(await h.saveTable(), false); assert.equal(h.ui.tableRecovery.kind, 'conflict');
  assert.match(h.elements.get('recovery-panel').innerHTML, /再読み込みすると変更点を確認できます/);
  assert.doesNotMatch(h.elements.get('recovery-panel').innerHTML, /現在の内容に変更はありません/);
  await h.refresh(); assert.equal(h.ui.draftBases.get(1).author, '著者'); assert.equal(h.ui.drafts.get(1).memo, '自分のメモ\n続き');
  const review = h.rebaseTable(); h.elements.get('confirm-dialog').close('confirm'); await review;
  assert.equal(await h.saveTable(), true); assert.equal(h.server.books[0].author, '別の著者');
  assert.equal(h.server.books[0].memo, '自分のメモ\n続き'); assert.equal(h.server.books[1].volumeNo, 4.2);
  assert.equal(h.document.body.dataset.view, 'list');
});

test('unknown add never automatically resubmits and can adopt the canonical book after reload', async () => {
  const h = await harness(); h.openEditor(); const form = h.elements.get('book-form');
  await input(h, form, 'title', '  新規試験  '); await input(h, form, 'author', ' 著者 '); await input(h, form, 'memo', '新しい\nメモ');
  h.server.unknown = true; await h.saveBook({ target: form, preventDefault() {} });
  assert.equal(h.ui.editorRecovery.kind, 'unknownAdd'); assert.equal(form.elements.title.value, '  新規試験  '); assert.equal(form.submit.disabled, true);
  await h.refresh(); assert.equal(h.server.posts.length, 1);
  assert.match(h.elements.get('editor-error').innerHTML, /登録された本を開く/);
  await action(h, 'adopt-book', { id: '4' }); assert.equal(h.ui.editorId, 4); assert.equal(h.ui.editorDirty, false);
  assert.equal(h.server.posts.length, 1);
});

test('small taxonomy add dialogs focus the single input and close only after acknowledged save', async () => {
  const h = await harness(); await action(h, 'manage', { kind: 'series' });
  const form = h.taxonomyForms.series; assert.equal(form.dataset.mode, 'add'); assert.equal(h.document.activeElement, form.elements.name);
  assert.match(h.elements.get('manage-dialog').innerHTML, /シリーズを追加/);
  form.elements.name.value = '追加シリーズ'; await h.document.fire('submit', { target: form, preventDefault() {} });
  assert.equal(h.elements.get('manage-dialog').open, false);
  assert.match(h.elements.get('series-nav').innerHTML, /追加シリーズ<\/span><span class="nav-count">0<\/span>/);
  await action(h, 'series-filter', { value: '追加シリーズ' });
  assert.match(h.elements.get('book-list').innerHTML, /本がありません/);
  assert.match(h.elements.get('book-list').innerHTML, /data-action="add"/);
});

test('mobile navigation keeps offscreen/sidebar and main/filter controls inert in the correct state', async () => {
  const h = await harness(); h.media.matches = true; h.syncSidebar();
  assert.equal(h.elements.get('sidebar').inert, true); h.toggleSidebar();
  assert.equal(h.elements.get('sidebar').inert, false); assert.equal(h.elements.get('filter-menu').inert, true);
  assert.equal(h.surfaces['.main-pane'].inert, true);
  h.closeSidebar('collection'); assert.equal(h.surfaces['.main-pane'].inert, false); assert.equal(h.elements.get('sidebar').inert, true);
  assert.equal(h.document.activeElement, h.elements.get('page-title'));
});

test('shipped assets contain no captured data, browser persistence, reset, prototype copy, or unsafe external links', () => {
  const shipped = shell + source + asset('model.js') + asset('store.js');
  assert.doesNotMatch(shipped, /BOOKS_SEED|localStorage|data\.js|books-minimal|resetPrototype|この試作|試作データ|developer\.apple\.com|reading-section|\.variants/);
  assert.doesNotMatch(source, /\b(?:window\.)?confirm\s*\(/);
  const ids = new Set(Array.from((shell + source).matchAll(/\bid="([^"]+)"/g), match => match[1]));
  for (const match of source.matchAll(/\$\('([^']+)'\)/g)) assert.ok(ids.has(match[1]), match[1]);
});

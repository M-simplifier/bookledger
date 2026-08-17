const state = {
  meta: { categories: [], series: [], statuses: [] },
  books: [],
  editMode: new URL(window.location.href).searchParams.get("mode") === "edit",
  drafts: new Map(),
  saving: false
};

const editableFields = [
  "title",
  "author",
  "status",
  "category",
  "series",
  "volumeNo",
  "memo",
  "url"
];

const $ = (id) => document.getElementById(id);

async function api(path, options = {}) {
  const res = await fetch(path, {
    headers: { "content-type": "application/json" },
    ...options
  });
  const data = await res.json();
  if (!res.ok || data.ok === false) {
    throw new Error(data.error || `HTTP ${res.status}`);
  }
  return data;
}

async function loadMeta() {
  state.meta = await api("/api/meta");
  fillSelect($("status"), [{ value: "", label: "すべての状態" }, ...state.meta.statuses]);
  fillSelect($("category"), [{ value: "", label: "すべてのカテゴリ" }, ...state.meta.categories.map(name => ({ value: name, label: name }))]);
  fillSelect($("series"), [{ value: "", label: "すべてのシリーズ" }, ...state.meta.series.map(name => ({ value: name, label: name }))]);

  const addStatus = document.querySelector('[name="status"]');
  fillSelect(addStatus, state.meta.statuses);
  addStatus.value = "unread";
  fillSelect(document.querySelector('[name="category"]'), state.meta.categories.map(name => ({ value: name, label: name })));
  fillSelect(document.querySelector('[name="series"]'), [{ value: "", label: "なし" }, ...state.meta.series.map(name => ({ value: name, label: name }))]);
}

function fillSelect(select, options) {
  select.replaceChildren(...options.map(opt => {
    const el = document.createElement("option");
    if (typeof opt === "string") {
      el.value = opt;
      el.textContent = opt;
    } else {
      el.value = opt.value;
      el.textContent = opt.label;
    }
    return el;
  }));
}

async function loadBooks() {
  const params = new URLSearchParams();
  if ($("search").value.trim()) params.set("q", $("search").value.trim());
  if ($("status").value) params.set("status", $("status").value);
  if ($("category").value) params.set("category", $("category").value);
  if ($("series").value) params.set("series", $("series").value);
  params.set("sort", $("sort").value);
  state.books = await api(`/api/books?${params.toString()}`);
  renderBooks();
}

function renderBooks() {
  $("summary").textContent = `${state.books.length} 件`;
  $("books").replaceChildren(...state.books.map(book => {
    const tr = document.createElement("tr");
    tr.dataset.bookId = book.id;
    tr.classList.toggle("dirty", state.drafts.has(book.id));
    if (state.editMode) {
      renderEditableRow(tr, book);
    } else {
      tr.append(
        titleCell(book),
        cell(book.author),
        statusCell(book),
        cell(book.category, "category"),
        cell(book.series || ""),
        cell(book.volumeNo ?? ""),
        memoCell(book)
      );
    }
    return tr;
  }));
}

function cell(text, className = "") {
  const td = document.createElement("td");
  td.textContent = text;
  if (className) td.className = className;
  return td;
}

function titleCell(book) {
  const td = document.createElement("td");
  td.className = "title";
  if (book.url) {
    const link = document.createElement("a");
    link.href = book.url;
    link.target = "_blank";
    link.rel = "noreferrer";
    link.textContent = book.title;
    td.append(link);
  } else {
    td.textContent = book.title;
  }
  return td;
}

function statusCell(book) {
  const td = document.createElement("td");
  const select = selectControl(state.meta.statuses, book.status, "状態");
  select.addEventListener("change", async () => {
    const previous = book.status;
    select.disabled = true;
    try {
      await api("/api/status", {
        method: "POST",
        body: JSON.stringify({ id: book.id, status: select.value })
      });
      await loadBooks();
    } catch (error) {
      select.value = previous;
      select.disabled = false;
      window.alert(`状態を保存できませんでした: ${error.message}`);
    }
  });
  td.append(select);
  return td;
}

function memoCell(book) {
  const td = document.createElement("td");
  td.className = "memo";
  const view = document.createElement("div");
  view.className = book.memo ? "memo-view" : "memo-view memo-empty";
  view.textContent = book.memo || "メモを追加";
  view.tabIndex = 0;
  view.setAttribute("role", "button");
  view.title = "クリックしてメモを編集";
  const openEditor = () => editMemoCell(td, book);
  view.addEventListener("click", openEditor);
  view.addEventListener("keydown", (event) => {
    if (event.key === "Enter" || event.key === " ") {
      event.preventDefault();
      openEditor();
    }
  });
  td.append(view);
  return td;
}

function editMemoCell(td, book) {
  td.classList.add("editing");
  const textarea = document.createElement("textarea");
  textarea.className = "memo-editor";
  textarea.value = book.memo || "";
  textarea.rows = 4;

  const actions = document.createElement("div");
  actions.className = "memo-edit-actions";
  const save = document.createElement("button");
  save.type = "button";
  save.className = "memo-save";
  save.textContent = "保存";
  const cancel = document.createElement("button");
  cancel.type = "button";
  cancel.className = "memo-cancel";
  cancel.textContent = "キャンセル";
  const message = document.createElement("div");
  message.className = "memo-error";
  actions.append(save, cancel);

  const saveMemo = async () => {
    save.disabled = true;
    cancel.disabled = true;
    message.textContent = "";
    try {
      await api("/api/memo", {
        method: "POST",
        body: JSON.stringify({ id: book.id, memo: textarea.value })
      });
      await loadBooks();
    } catch (error) {
      message.textContent = error.message;
      save.disabled = false;
      cancel.disabled = false;
    }
  };

  save.addEventListener("click", saveMemo);
  cancel.addEventListener("click", renderBooks);
  textarea.addEventListener("keydown", (event) => {
    if ((event.metaKey || event.ctrlKey) && event.key === "Enter") {
      event.preventDefault();
      saveMemo();
    } else if (event.key === "Escape") {
      event.preventDefault();
      renderBooks();
    }
  });

  td.replaceChildren(textarea, actions, message);
  textarea.focus();
  textarea.setSelectionRange(textarea.value.length, textarea.value.length);
}

function editableBook(book) {
  return {
    id: book.id,
    title: book.title,
    author: book.author,
    status: book.status,
    category: book.category,
    series: book.series || null,
    volumeNo: book.volumeNo ?? null,
    memo: book.memo || "",
    url: book.url || null
  };
}

function draftValue(book) {
  return state.drafts.get(book.id)?.value || editableBook(book);
}

function sameBook(left, right) {
  return editableFields.every(field => left[field] === right[field]);
}

function setDraft(book, field, value) {
  const existing = state.drafts.get(book.id);
  const original = existing?.original || editableBook(book);
  const next = { ...(existing?.value || original), [field]: value };
  if (sameBook(original, next)) {
    state.drafts.delete(book.id);
  } else {
    state.drafts.set(book.id, { original, value: next });
  }
  const row = document.querySelector(`tr[data-book-id="${book.id}"]`);
  row?.classList.toggle("dirty", state.drafts.has(book.id));
  setEditMessage("");
  updateEditToolbar();
}

function bindDraft(control, book, field, readValue, eventName = "input") {
  control.addEventListener(eventName, () => setDraft(book, field, readValue(control)));
  return control;
}

function textControl(value, label, options = {}) {
  const input = document.createElement("input");
  input.value = value;
  input.setAttribute("aria-label", label);
  if (options.type) input.type = options.type;
  if (options.placeholder) input.placeholder = options.placeholder;
  if (options.required) input.required = true;
  if (options.step) input.step = options.step;
  return input;
}

function selectControl(options, value, label) {
  const select = document.createElement("select");
  select.setAttribute("aria-label", label);
  fillSelect(select, options);
  select.value = value;
  return select;
}

function editorCell(control, className = "") {
  const td = document.createElement("td");
  td.className = `book-editor ${className}`.trim();
  td.append(control);
  return td;
}

function renderEditableRow(tr, book) {
  const draft = draftValue(book);

  const titleWrap = document.createElement("div");
  titleWrap.className = "book-editor-title";
  const title = bindDraft(
    textControl(draft.title, "タイトル", { required: true }),
    book,
    "title",
    control => control.value
  );
  const url = bindDraft(
    textControl(draft.url || "", "URL", { type: "url", placeholder: "URL（任意）" }),
    book,
    "url",
    control => control.value || null
  );
  titleWrap.append(title, url);

  const author = bindDraft(
    textControl(draft.author, "著者", { required: true }),
    book,
    "author",
    control => control.value
  );
  const status = bindDraft(
    selectControl(state.meta.statuses, draft.status, "状態"),
    book,
    "status",
    control => control.value,
    "change"
  );
  const category = bindDraft(
    selectControl(state.meta.categories, draft.category, "カテゴリ"),
    book,
    "category",
    control => control.value,
    "change"
  );
  const series = bindDraft(
    selectControl([{ value: "", label: "なし" }, ...state.meta.series.map(name => ({ value: name, label: name }))], draft.series || "", "シリーズ"),
    book,
    "series",
    control => control.value || null,
    "change"
  );
  const volume = bindDraft(
    textControl(draft.volumeNo ?? "", "巻", { type: "number", step: "0.1" }),
    book,
    "volumeNo",
    control => control.value === "" ? null : Number(control.value)
  );
  const memo = document.createElement("textarea");
  memo.value = draft.memo;
  memo.rows = 4;
  memo.setAttribute("aria-label", "メモ");
  bindDraft(memo, book, "memo", control => control.value);

  tr.append(
    editorCell(titleWrap, "title"),
    editorCell(author),
    editorCell(status),
    editorCell(category, "category"),
    editorCell(series),
    editorCell(volume),
    editorCell(memo, "memo")
  );
}

function setModeInUrl(enabled) {
  const url = new URL(window.location.href);
  if (enabled) {
    url.searchParams.set("mode", "edit");
  } else {
    url.searchParams.delete("mode");
  }
  window.history.replaceState({}, "", url);
}

function applyEditMode() {
  document.body.classList.toggle("editing-mode", state.editMode);
  $("edit-toolbar").hidden = !state.editMode;
  $("edit-toggle").textContent = state.editMode ? "編集を終了" : "書籍情報を編集";
  updateEditToolbar();
  renderBooks();
}

function enterEditMode() {
  state.editMode = true;
  setModeInUrl(true);
  applyEditMode();
}

function exitEditMode() {
  if (state.drafts.size > 0 && !window.confirm("未保存の変更を破棄して編集を終了しますか？")) {
    return;
  }
  state.drafts.clear();
  state.editMode = false;
  setModeInUrl(false);
  setEditMessage("");
  applyEditMode();
}

function toggleEditMode() {
  if (state.editMode) {
    exitEditMode();
  } else {
    enterEditMode();
  }
}

function discardEdits() {
  if (state.drafts.size === 0) return;
  if (!window.confirm("未保存の変更をすべて破棄しますか？")) return;
  state.drafts.clear();
  setEditMessage("変更を破棄しました", true);
  updateEditToolbar();
  renderBooks();
}

function setEditMessage(message, success = false) {
  $("edit-message").textContent = message;
  $("edit-message").classList.toggle("success", success);
}

function updateEditToolbar() {
  const count = state.drafts.size;
  $("edit-summary").textContent = count === 0 ? "変更はありません" : `${count}件の変更があります`;
  $("save-edits").disabled = count === 0 || state.saving;
  $("discard-edits").disabled = count === 0 || state.saving;
  $("edit-toggle").disabled = state.saving;
  $("refresh").disabled = state.saving;
}

async function saveEdits() {
  if (state.drafts.size === 0 || state.saving) return;
  const invalid = document.querySelector("#books input:invalid");
  if (invalid) {
    invalid.reportValidity();
    return;
  }

  state.saving = true;
  setEditMessage("");
  updateEditToolbar();
  let saved = false;
  try {
    const books = Array.from(state.drafts.values(), draft => draft.value);
    const result = await api("/api/books/batch", {
      method: "POST",
      body: JSON.stringify({ books })
    });
    saved = true;
    state.drafts.clear();
    await loadBooks();
    if (result.warning) {
      setEditMessage(`保存しました。ただしバックアップに失敗しました: ${result.warning}`);
    } else {
      setEditMessage(`${result.updated}件を保存しました`, true);
    }
  } catch (error) {
    setEditMessage(saved ? `保存済みですが再読み込みに失敗しました: ${error.message}` : `保存できませんでした: ${error.message}`);
  } finally {
    state.saving = false;
    updateEditToolbar();
  }
}

async function addBook(event) {
  event.preventDefault();
  const form = event.currentTarget;
  const data = Object.fromEntries(new FormData(form).entries());
  const payload = {
    title: data.title,
    author: data.author,
    status: data.status,
    category: data.category,
    series: data.series || null,
    volumeNo: data.volumeNo ? Number(data.volumeNo) : null,
    memo: data.memo || "",
    url: data.url || null
  };
  try {
    await api("/api/books", { method: "POST", body: JSON.stringify(payload) });
    form.reset();
    form.elements.status.value = "unread";
    $("form-message").textContent = "";
    await loadMeta();
    await loadBooks();
  } catch (error) {
    $("form-message").textContent = error.message;
  }
}

async function addNamed(event, path) {
  event.preventDefault();
  const form = event.currentTarget;
  const name = new FormData(form).get("name").trim();
  if (!name) return;
  await api(path, { method: "POST", body: JSON.stringify({ name }) });
  form.reset();
  await loadMeta();
  renderBooks();
}

function debounce(fn, ms) {
  let timer;
  return () => {
    clearTimeout(timer);
    timer = setTimeout(fn, ms);
  };
}

async function boot() {
  await loadMeta();
  await loadBooks();
  $("refresh").addEventListener("click", loadBooks);
  $("edit-toggle").addEventListener("click", toggleEditMode);
  $("save-edits").addEventListener("click", saveEdits);
  $("discard-edits").addEventListener("click", discardEdits);
  $("search").addEventListener("input", debounce(loadBooks, 180));
  for (const id of ["sort", "status", "category", "series"]) {
    $(id).addEventListener("change", loadBooks);
  }
  $("add-book").addEventListener("submit", addBook);
  $("add-category").addEventListener("submit", (event) => addNamed(event, "/api/categories"));
  $("add-series").addEventListener("submit", (event) => addNamed(event, "/api/series"));
  window.addEventListener("beforeunload", (event) => {
    if (state.drafts.size === 0) return;
    event.preventDefault();
    event.returnValue = "";
  });
  applyEditMode();
}

boot().catch(error => {
  $("summary").textContent = error.message;
});

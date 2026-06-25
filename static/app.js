const state = {
  meta: { categories: [], series: [], statuses: [] },
  books: []
};

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
    tr.append(
      titleCell(book),
      cell(book.author),
      statusCell(book),
      cell(book.category, "category"),
      cell(book.series || ""),
      cell(book.volumeNo ?? ""),
      memoCell(book)
    );
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
  const select = document.createElement("select");
  for (const status of state.meta.statuses) {
    const option = document.createElement("option");
    option.value = status.value;
    option.textContent = status.label;
    option.selected = status.value === book.status;
    select.append(option);
  }
  select.addEventListener("change", async () => {
    await api("/api/status", {
      method: "POST",
      body: JSON.stringify({ id: book.id, status: select.value })
    });
    await loadBooks();
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
  $("search").addEventListener("input", debounce(loadBooks, 180));
  for (const id of ["sort", "status", "category", "series"]) {
    $(id).addEventListener("change", loadBooks);
  }
  $("add-book").addEventListener("submit", addBook);
  $("add-category").addEventListener("submit", (event) => addNamed(event, "/api/categories"));
  $("add-series").addEventListener("submit", (event) => addNamed(event, "/api/series"));
}

boot().catch(error => {
  $("summary").textContent = error.message;
});

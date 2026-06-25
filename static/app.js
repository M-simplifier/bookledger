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
      cell(book.memo || "", "memo")
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

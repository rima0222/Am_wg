const API = "";
let TOKEN = localStorage.getItem("awg_token") || "";
let currentConfigPeerId = null;
let pollTimer = null;

function authHeaders() {
  return { Authorization: "Bearer " + TOKEN, "Content-Type": "application/json" };
}

async function doLogin() {
  const username = document.getElementById("login-username").value;
  const password = document.getElementById("login-password").value;
  const errEl = document.getElementById("login-error");
  errEl.textContent = "";
  try {
    const res = await fetch("/api/login", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ username, password }),
    });
    if (!res.ok) {
      const e = await res.json();
      errEl.textContent = e.detail || "ورود ناموفق بود";
      return;
    }
    const data = await res.json();
    TOKEN = data.token;
    localStorage.setItem("awg_token", TOKEN);
    showApp();
  } catch (e) {
    errEl.textContent = "خطا در اتصال به سرور";
  }
}

function logout() {
  TOKEN = "";
  localStorage.removeItem("awg_token");
  clearInterval(pollTimer);
  document.getElementById("app-screen").classList.add("hidden");
  document.getElementById("login-screen").classList.remove("hidden");
}

function showApp() {
  document.getElementById("login-screen").classList.add("hidden");
  document.getElementById("app-screen").classList.remove("hidden");
  loadPeers();
  loadSummary();
  pollTimer = setInterval(() => {
    loadPeers();
    loadSummary();
  }, 3000);
}

function fmtBytes(bytes) {
  if (!bytes) return "0 B";
  const units = ["B", "KB", "MB", "GB", "TB"];
  let i = 0;
  let v = bytes;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return v.toFixed(1) + " " + units[i];
}

function fmtDate(ts) {
  if (!ts) return "نامحدود";
  const d = new Date(ts * 1000);
  return d.toLocaleDateString("fa-IR");
}

async function loadSummary() {
  const res = await fetch("/api/system", { headers: authHeaders() });
  if (res.status === 401) return logout();
  const s = await res.json();
  document.getElementById("summary").innerHTML =
    `کل کاربران: <b>${s.total_peers}</b> &nbsp; آنلاین: <b>${s.online_peers}</b> &nbsp; ترافیک کل: <b>${fmtBytes(s.total_traffic_bytes)}</b>`;
}

async function loadPeers() {
  const res = await fetch("/api/peers", { headers: authHeaders() });
  if (res.status === 401) return logout();
  const peers = await res.json();
  const body = document.getElementById("peers-body");
  body.innerHTML = "";
  for (const p of peers) {
    const tr = document.createElement("tr");
    const limitText = p.data_limit_bytes ? fmtBytes(p.data_limit_bytes) : "نامحدود";
    tr.innerHTML = `
      <td><span class="dot ${p.online ? "online" : "offline"}"></span>${p.online ? "آنلاین" : "آفلاین"}</td>
      <td>${p.name}${p.enabled ? "" : " (غیرفعال)"}</td>
      <td>${p.ip_address}</td>
      <td>${fmtBytes(p.used_bytes)}</td>
      <td>${limitText}</td>
      <td>${fmtDate(p.expires_at)}</td>
      <td>
        <button class="btn-secondary btn-small" onclick="viewConfig(${p.id})">کانفیگ</button>
        <button class="btn-secondary btn-small" onclick="toggleEnabled(${p.id}, ${!p.enabled})">${p.enabled ? "غیرفعال" : "فعال"}</button>
        <button class="btn-danger btn-small" onclick="deletePeer(${p.id})">حذف</button>
      </td>`;
    body.appendChild(tr);
  }
}

function openCreateModal() {
  document.getElementById("new-name").value = "";
  document.getElementById("new-note").value = "";
  document.getElementById("new-limit").value = "";
  document.getElementById("new-expire-days").value = "";
  document.getElementById("create-modal").classList.remove("hidden");
}

function closeModal(id) {
  document.getElementById(id).classList.add("hidden");
}

async function submitCreate() {
  const name = document.getElementById("new-name").value.trim();
  if (!name) return alert("نام کاربر رو وارد کن");
  const note = document.getElementById("new-note").value;
  const limitVal = document.getElementById("new-limit").value;
  const daysVal = document.getElementById("new-expire-days").value;

  const body = { name, note };
  if (limitVal) body.data_limit_gb = parseFloat(limitVal);
  if (daysVal) body.expires_at = Math.floor(Date.now() / 1000) + parseInt(daysVal) * 86400;

  const res = await fetch("/api/peers", {
    method: "POST",
    headers: authHeaders(),
    body: JSON.stringify(body),
  });
  if (!res.ok) {
    const e = await res.json();
    return alert(e.detail || "خطا در ایجاد کاربر");
  }
  const data = await res.json();
  closeModal("create-modal");
  loadPeers();
  loadSummary();
  showConfigContent(data.id, data.config);
}

async function viewConfig(peerId) {
  const res = await fetch(`/api/peers/${peerId}/config`, { headers: authHeaders() });
  const text = await res.text();
  showConfigContent(peerId, text);
}

function showConfigContent(peerId, text) {
  currentConfigPeerId = peerId;
  document.getElementById("config-text").value = text;
  document.getElementById("config-qr").src = `/api/peers/${peerId}/qr?t=${TOKEN}`;
  fetch(`/api/peers/${peerId}/qr`, { headers: authHeaders() })
    .then((r) => r.blob())
    .then((blob) => {
      document.getElementById("config-qr").src = URL.createObjectURL(blob);
    });
  document.getElementById("config-modal").classList.remove("hidden");
}

function downloadConfig() {
  const text = document.getElementById("config-text").value;
  const blob = new Blob([text], { type: "text/plain" });
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = `peer-${currentConfigPeerId}.conf`;
  a.click();
}

async function toggleEnabled(id, enable) {
  await fetch(`/api/peers/${id}`, {
    method: "PUT",
    headers: authHeaders(),
    body: JSON.stringify({ enabled: enable }),
  });
  loadPeers();
}

async function deletePeer(id) {
  if (!confirm("مطمئنی می‌خوای این کاربر رو حذف کنی؟")) return;
  await fetch(`/api/peers/${id}`, { method: "DELETE", headers: authHeaders() });
  loadPeers();
  loadSummary();
}

// اگه توکن موجود بود مستقیم وارد شو
if (TOKEN) {
  showApp();
}

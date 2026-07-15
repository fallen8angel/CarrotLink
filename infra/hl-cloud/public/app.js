const unlockForm = document.querySelector("#unlock-form");
const passwordInput = document.querySelector("#password");
const showPassword = document.querySelector("#show-password");
const unlockButton = document.querySelector("#unlock-button");
const downloadActions = document.querySelector("#download-actions");
const downloadLink = document.querySelector("#download-link");
const lockButton = document.querySelector("#lock-button");
const statusLine = document.querySelector(".status-line");
const statusText = document.querySelector("#status-text");
const message = document.querySelector("#message");

function formatBytes(bytes) {
  if (!Number.isFinite(bytes)) return "-";
  const mib = bytes / (1024 * 1024);
  return `${mib.toFixed(1)} MB`;
}

function setMessage(text = "", success = false) {
  message.textContent = text;
  message.classList.toggle("success", success);
}

function renderStatus(data) {
  document.querySelector("#hero-version").textContent = `${data.releaseBuild} · ${data.version}`;
  document.querySelector("#download-title").textContent = `최신 APK · ${data.releaseBuild}`;
  document.querySelector(".latest-badge").textContent = `최신 ${data.releaseBuild}`;
  document.querySelector("#release-version").textContent = data.version;
  document.querySelector("#release-build").textContent = data.releaseBuild;
  document.querySelector("#release-date").textContent = data.releaseDate.replaceAll("-", ".");
  document.querySelector("#source-commit").textContent = data.sourceCommit;
  document.querySelector("#file-name").textContent = data.fileName;
  document.querySelector("#file-size").textContent = formatBytes(data.fileSize);
  document.querySelector("#sha256").textContent = data.sha256;
  downloadLink.href = `/download/${encodeURIComponent(data.fileName)}`;
  downloadLink.download = data.fileName;
  downloadLink.textContent = `${data.releaseBuild} APK 다운로드`;

  unlockForm.hidden = data.unlocked;
  downloadActions.hidden = !data.unlocked;
  statusLine.classList.toggle("unlocked", data.unlocked);
  statusText.textContent = data.unlocked ? "다운로드 가능" : "잠김";
  if (data.unlocked) {
    setMessage("인증 완료. 세션은 30분간 유지됩니다.", true);
  } else if (message.classList.contains("success")) {
    setMessage();
  }
}

async function loadStatus() {
  try {
    const response = await fetch("/api/status", { cache: "no-store" });
    if (!response.ok) throw new Error("status");
    renderStatus(await response.json());
  } catch {
    setMessage("서버 상태를 불러오지 못했습니다.");
  }
}

showPassword.addEventListener("change", () => {
  passwordInput.type = showPassword.checked ? "text" : "password";
});

unlockForm.addEventListener("submit", async (event) => {
  event.preventDefault();
  setMessage();
  unlockButton.disabled = true;
  unlockButton.textContent = "확인 중";

  try {
    const response = await fetch("/api/unlock", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ password: passwordInput.value }),
    });
    const data = await response.json();
    if (!response.ok) throw new Error(data.error || "인증에 실패했습니다.");
    passwordInput.value = "";
    await loadStatus();
  } catch (error) {
    setMessage(error.message);
    passwordInput.select();
  } finally {
    unlockButton.disabled = false;
    unlockButton.textContent = "잠금 해제";
  }
});

lockButton.addEventListener("click", async () => {
  setMessage();
  try {
    await fetch("/api/lock", { method: "POST" });
  } finally {
    await loadStatus();
    passwordInput.focus();
  }
});

loadStatus();

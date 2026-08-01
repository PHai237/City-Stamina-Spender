const app = document.getElementById("app");

const state = {
  title: "Owner's Selection",
  selectedStage: "Stage 1-9",
  stageOptions: ["Stage 1-9", "Stage 1-1"],
  targetStamina: "",
  spentSoFar: "--",
  elapsed: "00:00",
  ordersDetected: "0 / 0",
  ordersDone: "0",
  logText: "",
  searchQuery: "",
  automationCount: "1",
  readyModulesCount: "1",
  runningNowCount: "0",
  runsTodayCount: "0",
  gamesCount: "1",
  isHubVisible: true,
  isDetailVisible: false,
  isRunning: false,
  stageDropdownOpen: false,
  currentVersion: "1.2.6",
  latestVersion: "1.2.6",
  updateState: "checking",
  updateMessage: "Checking for updates...",
  isUpdateAvailable: false,
};

function icon(name, size = 14) {
  const attrs = `width="${size}" height="${size}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"`;
  const paths = {
    search: '<circle cx="11" cy="11" r="7"></circle><path d="m20 20-3.5-3.5"></path>',
    plus: '<path d="M12 5v14"></path><path d="M5 12h14"></path>',
    zap: '<path d="M13 2 4 14h7l-1 8 10-13h-7l1-7Z"></path>',
    box: '<path d="m21 8-9-5-9 5 9 5 9-5Z"></path><path d="M3 8v8l9 5 9-5V8"></path><path d="M12 13v8"></path>',
    play: '<path d="m8 5 11 7-11 7V5Z"></path>',
    square: '<rect x="7" y="7" width="10" height="10"></rect>',
    chart: '<path d="M4 19V5"></path><path d="M4 19h16"></path><path d="M8 16v-5"></path><path d="M12 16V8"></path><path d="M16 16v-3"></path>',
    layers: '<path d="m12 2 9 5-9 5-9-5 9-5Z"></path><path d="m3 12 9 5 9-5"></path><path d="m3 17 9 5 9-5"></path>',
    left: '<path d="m15 18-6-6 6-6"></path>',
    chevron: '<path d="m6 9 6 6 6-6"></path>',
  };

  return `<svg ${attrs}>${paths[name] || ""}</svg>`;
}

function escapeHtml(value) {
  return String(value ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#039;");
}

function post(message) {
  if (window.chrome && window.chrome.webview) {
    window.chrome.webview.postMessage(message);
  }
}

function metric(label, value, note, iconName) {
  return `
    <div class="metric-card">
      <div class="metric-head">
        <span>${escapeHtml(label)}</span>
        ${icon(iconName, 12)}
      </div>
      <div class="metric-value">${escapeHtml(value)}</div>
      <div class="metric-note">${escapeHtml(note)}</div>
    </div>
  `;
}

function header() {
  const indicatorClass = state.updateState === "available" || state.updateState === "error"
    ? "danger"
    : state.updateState === "checking" || state.updateState === "updating"
      ? "pending"
      : "latest";
  const indicatorText = state.updateState === "latest" ? "OK" : "!";
  const updateText = state.updateState === "updating" ? "Updating..." : "Update";
  const showUpdatePopup = state.updateState === "available" || state.updateState === "error";

  return `
    <div class="topbar">
      <div class="brand">
        <div class="logo">${icon("zap", 12)}</div>
        <div class="brand-title">City Stamina Spender</div>
      </div>
      <div class="header-actions">
        <div class="search-wrap">
          <span class="search-icon">${icon("search", 12)}</span>
          <input id="searchInput" class="search-input" value="${escapeHtml(state.searchQuery)}" placeholder="Search automations" />
        </div>
        <div class="update-wrap">
          <button id="updateButton" class="update-button">${escapeHtml(updateText)}</button>
          <button id="updateIndicator" class="update-indicator ${indicatorClass}" title="${escapeHtml(state.updateMessage)}">${indicatorText}</button>
          ${showUpdatePopup ? `
            <div class="update-popover">
              <div class="update-popover-title">${state.updateState === "available" ? "Update available" : "Update check failed"}</div>
              <div class="update-popover-text">${escapeHtml(state.updateMessage)}</div>
              ${state.updateState === "available" ? `<div class="update-popover-meta">Current ${escapeHtml(state.currentVersion)} -> ${escapeHtml(state.latestVersion)}</div>` : ""}
            </div>
          ` : ""}
        </div>
      </div>
    </div>
  `;
}

function statusbar() {
  const statusText = state.isRunning ? "NTE running" : "idle";
  const dotColor = state.isRunning ? "var(--warning)" : "var(--primary)";
  return `
    <div class="statusbar">
      <span class="mono">v${escapeHtml(state.currentVersion)} - engine online</span>
      <span class="inline mono"><span class="dot" style="color:${dotColor}"></span>${statusText}</span>
    </div>
  `;
}

function hubView() {
  return `
    ${header()}
    <div class="content">
      <div class="metrics">
        ${metric("Automations", state.automationCount, "available", "zap")}
        ${metric("Ready modules", state.readyModulesCount, "ready", "box")}
        ${metric("Running now", state.runningNowCount, "active", "play")}
        ${metric("Runs today", state.runsTodayCount, "today", "chart")}
      </div>

      <section>
        <div class="section-title">
          <span>Games</span>
          <div class="divider"></div>
        </div>

        <div class="automation-grid">
          <button id="ownerCard" class="automation-card">
            <div class="card-top">
              <div class="card-title-wrap">
                <div class="card-icon">${icon("layers", 13)}</div>
                <div>
                  <div class="card-tag mono">NTE</div>
                  <div class="card-name">Owner's Selection</div>
                </div>
              </div>
              <div class="badge mono"><span class="dot"></span>Ready</div>
            </div>

            <div class="stage-pill stage-pill-center">
              <span>Stage 1-9 / 1-1</span>
            </div>
          </button>
        </div>
      </section>
    </div>
    ${statusbar()}
  `;
}

function detailHeader() {
  const options = state.stageOptions
    .map((stage) => {
      const selected = stage === state.selectedStage;
      return `
        <button class="stage-option ${selected ? "active" : ""}" data-stage="${escapeHtml(stage)}">
          <span>${escapeHtml(stage)}</span>
          ${selected ? '<span class="stage-check">OK</span>' : ""}
        </button>
      `;
    })
    .join("");

  return `
    <div class="topbar">
      <div class="header-left">
        <button id="backToHub" class="back-button">${icon("left", 13)} Back to hub</button>
        <span class="separator">|</span>
        <div class="small-logo">${icon("zap", 10)}</div>
        <span class="brand-title">Owner's Selection</span>
        <span class="app-chip mono">NTE</span>
      </div>
      <div class="stage-dropdown ${state.stageDropdownOpen ? "open" : ""}">
        <button id="stageToggle" class="stage-select" ${state.isRunning ? "disabled" : ""}>
          <span>${escapeHtml(state.selectedStage)}</span>
          <span class="stage-chevron">${icon("chevron", 11)}</span>
        </button>
        <div class="stage-menu">
          ${options}
        </div>
      </div>
    </div>
  `;
}
function controlCards() {
  const isStageOneOne = state.selectedStage === "Stage 1-1";
  const secondMetric = isStageOneOne
    ? { label: "Visible orders", value: state.ordersDetected, note: "NPC / orders" }
    : { label: "Spent so far", value: state.spentSoFar, note: "City Stamina" };
  const thirdMetric = isStageOneOne
    ? { label: "Orders done", value: state.ordersDone, note: "served" }
    : { label: "Elapsed", value: state.elapsed, note: "mm:ss" };
  return `
    <div class="detail-controls">
      <div class="control-card">
        <div class="control-label">Target stamina</div>
        <input id="targetInput" class="target-input" inputmode="numeric" value="${escapeHtml(state.targetStamina)}" placeholder="Amount" ${state.isRunning ? "disabled" : ""} />
        <div class="metric-note">City Stamina</div>
      </div>

      <div class="control-card">
        <div class="control-label">${escapeHtml(secondMetric.label)}</div>
        <div class="big-value">${escapeHtml(secondMetric.value)}</div>
        <div class="metric-note">${escapeHtml(secondMetric.note)}</div>
      </div>

      <div class="control-card">
        <div class="control-label">${escapeHtml(thirdMetric.label)}</div>
        <div class="big-value time-value">${escapeHtml(thirdMetric.value)}</div>
        <div class="metric-note">${escapeHtml(thirdMetric.note)}</div>
      </div>

      <div class="control-card action-card">
        <div class="control-label">Actions</div>
        <div class="action-stack">
          <button id="runButton" class="primary-action" ${state.isRunning ? "disabled" : ""}>${icon("play", 12)} Run</button>
          <button id="stopButton" class="danger-action" ${state.isRunning ? "" : "disabled"}>${icon("square", 11)} Stop</button>
        </div>
      </div>
    </div>
  `;
}

function classifyLog(line) {
  const text = line.toLowerCase();
  if (text.includes("failed") || text.includes("error")) return "err";
  if (text.includes("stopped") || text.includes("waiting")) return "warn";
  if (text.includes("found") || text.includes("ready") || text.includes("completed") || text.includes("claimed")) return "ok";
  return "info";
}

function logPanel() {
  const lines = String(state.logText || "")
    .split(/\r?\n/)
    .map((line) => line.trimEnd())
    .filter(Boolean);

  const body = lines.length
    ? lines
        .map((line) => {
          const type = classifyLog(line);
          const tag = type === "ok" ? "OK" : type === "warn" ? "WARN" : type === "err" ? "ERR" : "INFO";
          return `<div class="log-line ${type}"><span class="log-tag">${tag}</span><span>${escapeHtml(line)}</span></div>`;
        })
        .join("")
    : '<span class="empty-log">Waiting for run...</span>';

  return `
    <div class="log-area">
      <div class="log-head">
        <span>Log</span>
        <div class="divider"></div>
        ${state.isRunning ? '<span class="running-indicator"><span class="dot"></span>Running</span>' : ""}
      </div>
      <div class="log-wrap">
        <div id="logBox" class="log-box">${body}</div>
      </div>
    </div>
  `;
}

function detailView() {
  return `
    ${detailHeader()}
    <div class="detail">
      ${controlCards()}
      ${logPanel()}
    </div>
    ${statusbar()}
  `;
}

function render() {
  app.innerHTML = `<main class="shell">${state.isDetailVisible ? detailView() : hubView()}</main>`;
  bindEvents();
  const logBox = document.getElementById("logBox");
  if (logBox) {
    logBox.scrollTop = logBox.scrollHeight;
  }
}

function bindEvents() {
  const ownerCard = document.getElementById("ownerCard");
  if (ownerCard) ownerCard.addEventListener("click", () => post({ type: "openOwner" }));

  const updateButton = document.getElementById("updateButton");
  if (updateButton) updateButton.addEventListener("click", () => post({ type: "update" }));

  const updateIndicator = document.getElementById("updateIndicator");
  if (updateIndicator) updateIndicator.addEventListener("click", () => post({ type: "checkUpdate" }));

  const searchInput = document.getElementById("searchInput");
  if (searchInput) {
    searchInput.addEventListener("input", (event) => {
      state.searchQuery = event.target.value;
    });
  }

  const backToHub = document.getElementById("backToHub");
  if (backToHub) backToHub.addEventListener("click", () => post({ type: "back" }));

  const stageToggle = document.getElementById("stageToggle");
  if (stageToggle) {
    stageToggle.addEventListener("click", () => {
      state.stageDropdownOpen = !state.stageDropdownOpen;
      render();
    });
  }

  document.querySelectorAll(".stage-option").forEach((option) => {
    option.addEventListener("click", () => {
      state.selectedStage = option.dataset.stage;
      state.stageDropdownOpen = false;
      post({ type: "setStage", value: state.selectedStage });
      render();
    });
  });

  const targetInput = document.getElementById("targetInput");
  if (targetInput) {
    targetInput.addEventListener("input", (event) => {
      state.targetStamina = event.target.value;
    });
  }

  const runButton = document.getElementById("runButton");
  if (runButton) runButton.addEventListener("click", () => post({ type: "run", amount: state.targetStamina }));

  const stopButton = document.getElementById("stopButton");
  if (stopButton) stopButton.addEventListener("click", () => post({ type: "stop" }));

}

if (window.chrome && window.chrome.webview) {
  window.chrome.webview.addEventListener("message", (event) => {
    Object.assign(state, event.data || {});
    render();
  });
}

render();

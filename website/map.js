// File map: a simulation of StreamDisk's download scheduler (Sources/StreamDiskCore/Cache).
// Same rules as the app, at a coarser scale so the whole file fits on screen:
// urgent reads first, the file's tail fetched on open, a readahead window that doubles while
// playback is sequential, readahead dropped on a seek, least recently used parts evicted.

(() => {
  const MB = 1e6;
  const MiB = 1024 * 1024;
  const FILE = 61_372_118_016;
  const CELL = 8 * MiB;                 // one square
  const N = Math.ceil(FILE / CELL);
  const BITRATE = 100e6 / 8;            // 4K video, bytes per second
  const LINE = 300e6 / 8;               // connection, bytes per second
  const LATENCY = 0.6;                  // seconds before a request's first byte (Google Drive)
  const SPEED = 30;                     // simulated seconds per real second
  const SLOTS = 6;                      // downloads at once, one kept for urgent reads
  const MAX_WINDOW = 16;                // 128 MB readahead, as in the app
  const CAPACITY = (256 * MiB) / CELL;  // 256 MB memory cache
  const DURATION = FILE / BITRATE;

  const canvas = document.querySelector(".cells");
  const button = document.querySelector(".play");
  const timeEl = document.querySelector("[data-time]");
  const statusEl = document.querySelector("[data-status]");
  const heldEl = document.querySelector("[data-held]");
  const fetchedEl = document.querySelector("[data-fetched]");
  const ctx = canvas.getContext("2d");
  canvas.tabIndex = 0;

  // Simulation state
  const cached = new Map();      // cell -> last use (sim time)
  const running = new Map();     // cell -> { left, wait, urgent }
  const queued = new Map();      // cell -> urgent
  let pos = 0;                   // playback position in bytes
  let playing = false;
  let opened = false;
  let ahead = 1;
  let lastCell = -1;
  let now = 0;
  let fetched = 0;
  let waitStart = null;     // when playback began waiting for data
  let pendingLabel = null;  // "Opened" or "Jumped", reported once with its wait time
  let message = "";

  const cellSize = (i) => (i === N - 1 ? FILE - CELL * (N - 1) : CELL);
  const urgentRunning = () => [...running.values()].some((d) => d.urgent);

  function request(i, urgent) {
    if (i < 0 || i >= N) return;
    if (cached.has(i)) { cached.set(i, now); return; }
    const d = running.get(i);
    if (d) { if (urgent) d.urgent = true; return; }
    if (urgent || !queued.has(i)) queued.set(i, urgent || queued.get(i) || false);
  }

  // Free slots go to urgent requests first, then the earliest readahead. Readahead waits while
  // anything urgent downloads and never takes the reserved slot.
  function schedule() {
    while (queued.size) {
      let best = null;
      for (const [i, urgent] of queued) {
        if (best === null || (urgent && !best.urgent) || (urgent === best.urgent && i < best.i)) best = { i, urgent };
      }
      const can = best.urgent ? running.size < SLOTS : !urgentRunning() && running.size < SLOTS - 1;
      if (!can) return;
      queued.delete(best.i);
      running.set(best.i, { left: cellSize(best.i), wait: LATENCY, urgent: best.urgent });
    }
  }

  function evict() {
    while (cached.size > CAPACITY) {
      let oldest = null;
      for (const [i, t] of cached) if (oldest === null || t < cached.get(oldest)) oldest = i;
      cached.delete(oldest);
    }
  }

  function noteAccess(cell) {
    if (!opened) {
      opened = true;
      request(N - 1, true);              // index at the end of MP4/MOV files
      ahead = 1;
    } else if (cell === lastCell + 1) {
      ahead = Math.min(MAX_WINDOW, ahead * 2);
    } else if (cell !== lastCell) {
      ahead = 1;
      // Seek: drop readahead that no longer helps, cancel running readahead elsewhere.
      const keep = (i) => i >= cell && i <= cell + MAX_WINDOW;
      for (const [i, urgent] of queued) if (!urgent && !keep(i)) queued.delete(i);
      for (const [i, d] of running) if (!d.urgent && !keep(i)) running.delete(i);
    }
    lastCell = cell;
    for (let i = cell + 1; i <= Math.min(N - 1, cell + ahead); i++) request(i, false);
  }

  function step(dt) {
    now += dt;
    // Downloads share the line equally once their first byte arrives.
    const active = [...running.values()].filter((d) => d.wait <= 0).length;
    for (const [i, d] of running) {
      if (d.wait > 0) { d.wait -= dt; continue; }
      const got = Math.min(d.left, (LINE / Math.max(1, active)) * dt);
      d.left -= got;
      fetched += got;
      if (d.left <= 0) {
        running.delete(i);
        cached.set(i, now);
        evict();
      }
    }
    schedule();

    if (!playing) return;
    const cell = Math.min(N - 1, Math.floor(pos / CELL));
    if (cell !== lastCell) noteAccess(cell);
    if (cached.has(cell)) {
      if (waitStart !== null) {
        if (pendingLabel) message = `${pendingLabel} in ${(now - waitStart).toFixed(1)} s`;
        pendingLabel = null;
        waitStart = null;
      }
      cached.set(cell, now);
      pos += BITRATE * dt;
      if (pos >= FILE) { pos = FILE - 1; setPlaying(false); message = "Finished"; }
    } else {
      request(cell, true);
      if (waitStart === null) waitStart = now;
    }
  }

  function seek(cell) {
    pos = cell * CELL;
    pendingLabel = opened ? "Jumped" : "Opened";
    waitStart = now;
    if (!playing) setPlaying(true);
    noteAccess(cell);
  }

  function setPlaying(on) {
    playing = on;
    button.textContent = on ? "Pause" : "Play";
    button.setAttribute("aria-pressed", String(on));
    if (on && !opened) { pendingLabel = "Opened"; waitStart = now; }
  }

  // Drawing

  let cols = 0, rows = 0, pitch = 0, gap = 0;
  let colors = {};

  function readColors() {
    const s = getComputedStyle(document.documentElement);
    colors = {
      empty: s.getPropertyValue("--faint").trim(),
      on: s.getPropertyValue("--accent").trim(),
      head: s.getPropertyValue("--text").trim(),
    };
  }

  function layout() {
    const width = canvas.clientWidth;
    pitch = width >= 560 ? 7 : 5;
    gap = 1;
    cols = Math.floor(width / pitch);
    rows = Math.ceil(N / cols);
    const dpr = window.devicePixelRatio || 1;
    canvas.style.height = rows * pitch + "px";
    canvas.width = Math.round(width * dpr);
    canvas.height = Math.round(rows * pitch * dpr);
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  }

  function draw() {
    ctx.clearRect(0, 0, canvas.width, canvas.height);
    const head = Math.min(N - 1, Math.floor(pos / CELL));
    const size = pitch - gap;
    for (let i = 0; i < N; i++) {
      const x = (i % cols) * pitch;
      const y = Math.floor(i / cols) * pitch;
      if (opened && i === head) {
        ctx.fillStyle = colors.head;
        ctx.globalAlpha = 1;
      } else if (cached.has(i)) {
        ctx.fillStyle = colors.on;
        ctx.globalAlpha = 1;
      } else if (running.has(i)) {
        ctx.fillStyle = colors.on;
        ctx.globalAlpha = 0.35;
      } else {
        ctx.fillStyle = colors.empty;
        ctx.globalAlpha = 1;
      }
      ctx.fillRect(x, y, size, size);
    }
    ctx.globalAlpha = 1;

    const t = Math.floor((pos / FILE) * DURATION);
    timeEl.textContent = `${Math.floor(t / 3600)}:${String(Math.floor(t / 60) % 60).padStart(2, "0")}:${String(t % 60).padStart(2, "0")}`;
    let held = 0;
    for (const i of cached.keys()) held += cellSize(i);
    heldEl.textContent = `${Math.round(held / MB).toLocaleString("en-US")} MB`;
    fetchedEl.textContent = `${Math.round(fetched / MB).toLocaleString("en-US")} MB`;
    statusEl.textContent = waitStart !== null ? "Waiting for this part" : message;
  }

  // Loop: fixed sub-steps keep the simulation stable at any frame rate.
  let last = null;
  function frame(ts) {
    if (last !== null) {
      let dt = Math.min(0.1, (ts - last) / 1000) * SPEED;
      while (dt > 0) { const h = Math.min(dt, 0.05); step(h); dt -= h; }
    }
    last = ts;
    draw();
    requestAnimationFrame(frame);
  }

  canvas.addEventListener("click", (e) => {
    const r = canvas.getBoundingClientRect();
    const i = Math.floor((e.clientY - r.top) / pitch) * cols + Math.floor((e.clientX - r.left) / pitch);
    if (i >= 0 && i < N) seek(i);
  });

  canvas.addEventListener("keydown", (e) => {
    const jump = Math.round(N / 50);
    const cur = Math.floor(pos / CELL);
    if (e.key === "ArrowRight") seek(Math.min(N - 1, cur + jump));
    else if (e.key === "ArrowLeft") seek(Math.max(0, cur - jump));
    else if (e.key === " ") setPlaying(!playing);
    else return;
    e.preventDefault();
  });

  button.addEventListener("click", () => setPlaying(!playing));
  matchMedia("(prefers-color-scheme: dark)").addEventListener("change", readColors);
  new ResizeObserver(layout).observe(canvas);

  readColors();
  layout();
  requestAnimationFrame(frame);
})();

/* Fleet dashboard renderer — shared by --html and --serve. */
(function (global) {
  "use strict";

  var REFRESH_MS = 10000;
  var TIME_SOURCE_LABEL = {
    dispatched_at: "jobs.tsv dispatched_at (exact job start, stamped at bin/cp dispatch)",
    br_updated_at: "br.updated_at (approximate dispatch proxy for legacy rows, not exact job start)"
  };

  var ORCH_X = 16;
  var ORCH_Y = 300;
  var ORCH_W = 252;
  var ORCH_PORT = { x: ORCH_X + ORCH_W + 16, y: ORCH_Y + 80 };
  var COL_W = 336;
  var ROW_H = 168;
  var CARD_W = 276;

  var ICONS = {
    done: "<svg width=\"13\" height=\"13\" viewBox=\"0 0 256 256\" fill=\"currentColor\" aria-hidden=\"true\"><path d=\"M232.5 72.5l-128 128a12 12 0 0 1-17 0l-56-56a12 12 0 0 1 17-17L96 175.5 215.5 55.5a12 12 0 0 1 17 17Z\"></path></svg>",
    ghost: "<svg width=\"12\" height=\"12\" viewBox=\"0 0 24 24\" stroke=\"currentColor\" stroke-width=\"2\" stroke-linecap=\"round\" fill=\"none\" aria-hidden=\"true\"><path d=\"M17 4 7 20\"></path></svg>",
    folder: "<svg width=\"12\" height=\"12\" viewBox=\"0 0 256 256\" fill=\"currentColor\" aria-hidden=\"true\"><path d=\"M216 72h-84.7L104 44.7A16 16 0 0 0 92.7 40H40a16 16 0 0 0-16 16v144a8 8 0 0 0 8 8h185a15 15 0 0 0 15-15V88a16 16 0 0 0-16-16ZM40 56h52.7l16 16H40Zm176 141H40V88h176Z\"></path></svg>",
    minus: "<svg width=\"16\" height=\"16\" viewBox=\"0 0 256 256\" fill=\"currentColor\" aria-hidden=\"true\"><path d=\"M128 28a100 100 0 1 0 100 100A100.1 100.1 0 0 0 128 28Zm0 176a76 76 0 1 1 76-76 76.1 76.1 0 0 1-76 76Zm40-76a12 12 0 0 1-12 12h-56a12 12 0 0 1 0-24h56a12 12 0 0 1 12 12Z\"></path></svg>"
  };

  function parseTs(s) {
    if (!s) return null;
    var t = Date.parse(s);
    return isNaN(t) ? null : t;
  }

  function age(ts, nowMs) {
    if (!ts || !nowMs) return "\u2014";
    var delta = Math.max(0, Math.floor((nowMs - ts) / 1000));
    if (delta < 60) return delta + "s";
    if (delta < 3600) return Math.floor(delta / 60) + "m";
    if (delta < 86400) return Math.floor(delta / 3600) + "h";
    return Math.floor(delta / 86400) + "d";
  }

  function esc(s) {
    if (s == null || s === "") return "\u2014";
    var d = document.createElement("div");
    d.textContent = String(s);
    return d.innerHTML;
  }

  function kindClass(cli) {
    var k = (cli || "").toLowerCase();
    if (k === "claude") return "fleet-kind-claude";
    if (k === "codex") return "fleet-kind-codex";
    if (k === "cursor") return "fleet-kind-cursor";
    return "fleet-kind-generic";
  }

  function kindLabel(cli) {
    var k = (cli || "").toLowerCase();
    if (k === "claude" || k === "codex" || k === "cursor") return k;
    return cli ? String(cli) : "generic";
  }

  function statusIcon(phase, brokerOk) {
    if (phase === "working") {
      var stale = brokerOk ? "" : " stale";
      return "<span class=\"fleet-status-dot" + stale + "\"></span>";
    }
    if (phase === "waiting") return "<span class=\"fleet-status-wait\"></span>";
    if (phase === "held") return "<span class=\"fleet-status-held\"></span>";
    if (phase === "stalled") return "<span class=\"fleet-status-stalled\" title=\"stalled\">\u2717</span>";
    if (phase === "done") return "<span class=\"fleet-status-done\">" + ICONS.done + "</span>";
    if (phase === "ghost") return "<span class=\"fleet-status-ghost\">" + ICONS.ghost + "</span>";
    if (phase === "orphaned") return "<span class=\"fleet-status-stalled\" title=\"orphaned\">\u26a0</span>";
    if (phase === "untracked") return "<span class=\"fleet-status-wait\" style=\"border-style:dashed\"></span>";
    return "<span class=\"fleet-status-wait\"></span>";
  }

  function rosterDotStyle(phase) {
    if (phase === "working") return "background:var(--st-working)";
    if (phase === "done") return "background:var(--st-done)";
    if (phase === "stalled") return "background:var(--st-fail)";
    if (phase === "orphaned") return "background:var(--st-warn)";
    return "";
  }

  function layoutNodes(nodes, edges, orch) {
    var positions = {};
    var workers = nodes.filter(function (n) { return n.role !== "orchestrator"; });
    if (orch) {
      positions[orch.id] = { x: ORCH_X, y: ORCH_Y, w: ORCH_W, orch: true };
    }

    var children = {};
    edges.forEach(function (e) {
      if (!children[e.from]) children[e.from] = [];
      children[e.from].push(e.to);
    });

    var depths = {};
    var queue = [];
    if (orch) {
      depths[orch.id] = 0;
      queue.push(orch.id);
    }
    while (queue.length) {
      var cur = queue.shift();
      (children[cur] || []).forEach(function (child) {
        if (depths[child] != null) return;
        depths[child] = depths[cur] + 1;
        queue.push(child);
      });
    }

    var maxDepth = 0;
    workers.forEach(function (w) {
      if (depths[w.id] == null) depths[w.id] = orch ? 1 : 0;
      if (depths[w.id] > maxDepth) maxDepth = depths[w.id];
    });

    var colRows = {};
    workers.forEach(function (w) {
      var d = depths[w.id];
      if (!colRows[d]) colRows[d] = 0;
      var row = colRows[d]++;
      var x = orch ? ORCH_X + ORCH_W + 84 + (d - 1) * COL_W : 16 + d * COL_W;
      if (!orch && d === 0) x = 16;
      positions[w.id] = { x: x, y: 8 + row * ROW_H, w: CARD_W, orch: false };
    });

    var worldW = Math.max(900, (orch ? ORCH_X + ORCH_W : 0) + (maxDepth + 1) * COL_W + 80);
    var worldH = Math.max(560, workers.length * ROW_H + 40);
    return { positions: positions, worldW: worldW, worldH: worldH };
  }

  function edgePath(from, to, positions) {
    var a = positions[from];
    var b = positions[to];
    if (!a || !b) return null;
    var x1 = b.x - 3;
    var y1 = b.y + 26;
    var px = a.orch ? ORCH_PORT.x : a.x + a.w + 12;
    var py = a.orch ? ORCH_PORT.y : a.y + 40;
    var c = Math.max(70, (x1 - px) * 0.45);
    return "M " + px + " " + py + " C " + (px + c) + " " + py + ", " + (x1 - c) + " " + y1 + ", " + x1 + " " + y1;
  }

  function headerCounts(nodes) {
    var workers = nodes.filter(function (n) { return n.role === "worker"; });
    var inFlight = workers.filter(function (n) {
      return n.phase === "working" || n.phase === "waiting" || n.phase === "held" || n.phase === "stalled";
    }).length;
    var dispatched = workers.filter(function (n) { return n.br_id; }).length;
    var unmatched = workers.filter(function (n) {
      return n.phase === "untracked" || n.phase === "ghost";
    }).length;
    if (!workers.length) {
      return "no agents dispatched \u00b7 " + nodes.length + " panes attached";
    }
    return dispatched + " dispatched \u00b7 " + inFlight + " in flight \u00b7 " + unmatched + " unmatched";
  }

  function renderNodeCard(n, brokerOk, selected) {
    var phase = n.phase || "untracked";
    var ghosty = phase === "ghost" || phase === "untracked" || phase === "orphaned";
    var task = n.title || (phase === "untracked" ? "No matching job" : "\u2014");
    var taskCls = ghosty ? " fleet-node-task muted" : " fleet-node-task";
    var aliasCls = phase === "untracked" ? " fleet-node-alias mono" : " fleet-node-alias";

    var html = "<div class=\"card fleet-node-card elev-sm\">";
    html += "<div class=\"fleet-node-head phase-" + esc(phase) + "\">";
    html += "<span class=\"fleet-status-icon\">" + statusIcon(phase, brokerOk) + "</span>";
    html += "<span class=\"" + aliasCls.trim() + "\">" + esc(n.alias) + "</span>";

    if (n.cli) {
      html += "<span class=\"fleet-kind-badge " + kindClass(n.cli) + "\">" + esc(kindLabel(n.cli)) + "</span>";
    }
    if (phase === "orphaned") {
      html += "<span class=\"fleet-flag\">no pane</span>";
    }
    if (phase === "untracked") {
      html += "<span class=\"fleet-flag\">untracked</span>";
    }
    html += "</div>";

    html += "<div class=\"" + taskCls.trim() + "\">" + esc(task) + "</div>";

    html += "<div class=\"fleet-node-meta\">";
    if (n.branch) html += "<span>" + esc(n.branch) + "</span>";
    if (n.pane) html += "<span style=\"flex:none;color:color-mix(in srgb,var(--color-text) 32%, transparent)\">" + esc(n.pane) + "</span>";
    html += "</div>";

    html += "<div class=\"fleet-node-project\">";
    html += ICONS.folder;
    html += "<span class=\"ellipsis\">" + esc(n.project) + "</span>";
    if (n.phase) {
      html += "<span class=\"tag tag-neutral\" style=\"font-size:10px;padding:1px 6px\">" + esc(phase) + "</span>";
    }
    html += "</div>";
    html += "</div>";
    return html;
  }

  function renderOrchestrator(orch, brokerOk) {
    if (!orch) return "";
    var stateLabel = orch.phase === "working" ? "active" : orch.phase;
    var html = "<div class=\"fleet-node-wrap\" data-node-id=\"" + esc(orch.id) + "\" style=\"left:" + ORCH_X + "px;top:" + ORCH_Y + "px;width:" + ORCH_W + "px\">";
    html += "<div class=\"card fleet-node-card fleet-orch-card elev-md\">";
    html += "<div class=\"fleet-node-head phase-" + esc(orch.phase) + "\">";
    html += "<span class=\"fleet-status-icon\">" + statusIcon(orch.phase, brokerOk) + "</span>";
    html += "<span class=\"card-kicker\">Orchestrator</span>";
    html += "</div>";
    html += "<div class=\"card-title\" style=\"font-size:19px;margin-top:7px\">" + esc(orch.alias) + "</div>";
    html += "<div class=\"card-meta\" style=\"margin-top:3px\">" + esc(orch.pane || "\u2014") + " \u00b7 " + esc(stateLabel) + "</div>";
    if (orch.cli) {
      html += "<div class=\"fleet-node-meta\"><span class=\"fleet-kind-badge " + kindClass(orch.cli) + "\">" + esc(kindLabel(orch.cli)) + "</span></div>";
    }
    html += "</div></div>";
    return html;
  }

  function renderFleet(data, opts) {
    opts = opts || {};
    var app = document.getElementById("app");
    if (!app) return;

    var nodes = data.nodes || [];
    var edges = data.edges || [];
    var broker = data.broker || {};
    var brokerOk = !!broker.ok;
    var nowMs = parseTs(data.generated_at);
    var livePrefix = opts.live ? "Live \u00b7 " : "Snapshot \u00b7 ";

    var orch = null;
    nodes.forEach(function (n) {
      if (n.role === "orchestrator") orch = n;
    });

    var layout = layoutNodes(nodes, edges, orch);
    var workers = nodes.filter(function (n) { return n.role !== "orchestrator"; });
    var selected = opts.selected || null;

    var html = "<div class=\"fleet-shell\">";
    html += "<header class=\"nav fleet-header\">";
    html += "<span class=\"nav-brand\">Command post</span>";
    html += "<span class=\"fleet-header-count\">" + esc(headerCounts(nodes)) + "</span>";
    html += "<span class=\"fleet-header-meta\">";
    html += "<span class=\"snapshot-meta\">" + esc(livePrefix + data.generated_at) + "</span>";
    if (brokerOk) {
      html += "<span class=\"broker-pill ok\"><span class=\"dot\"></span>Broker ok</span>";
    } else {
      html += "<span class=\"broker-pill degraded\"><span class=\"dot\"></span>Broker degraded</span>";
    }
    html += "</span></header>";

    html += "<div class=\"fleet-main\">";
    html += "<div class=\"fleet-canvas\" id=\"fleet-canvas\">";
    html += "<div class=\"fleet-canvas-inner\" style=\"width:" + layout.worldW + "px;height:" + layout.worldH + "px\">";
    html += "<div class=\"fleet-dot-grid\"></div>";

    html += "<svg class=\"fleet-edges\" width=\"" + layout.worldW + "\" height=\"" + layout.worldH + "\">";
    edges.forEach(function (e) {
      var d = edgePath(e.from, e.to, layout.positions);
      if (!d) return;
      var dash = e.source === "inferred" ? "5 6" : "none";
      var stroke = e.source === "inferred" ? "var(--edge)" : "var(--edge)";
      html += "<path d=\"" + d + "\" fill=\"none\" stroke=\"" + stroke + "\" stroke-width=\"1.3\" stroke-dasharray=\"" + dash + "\" stroke-linecap=\"round\"></path>";
    });
    html += "</svg>";

    html += renderOrchestrator(orch, brokerOk);

    workers.forEach(function (n) {
      var pos = layout.positions[n.id];
      if (!pos) return;
      var sel = selected === n.id ? " selected" : "";
      html += "<div class=\"fleet-node-wrap phase-" + esc(n.phase) + sel + "\" data-node-id=\"" + esc(n.id) + "\" style=\"left:" + pos.x + "px;top:" + pos.y + "px;width:" + pos.w + "px\">";
      html += renderNodeCard(n, brokerOk, sel);
      html += "</div>";
    });

    if (!workers.length && !orch) {
      html += "<div class=\"fleet-empty\"><div class=\"fleet-empty-inner\">";
      html += "<span class=\"fleet-empty-icon\">" + ICONS.minus + "</span>";
      html += "<h4 style=\"margin:16px 0 6px\">No fleet data</h4>";
      html += "<p class=\"text-muted\" style=\"font-size:13px;line-height:1.6\">No muxa panes matched the current snapshot.</p>";
      html += "</div></div>";
    }

    html += "</div></div>";

    html += "<aside class=\"fleet-aside\">";
    html += "<div class=\"fleet-aside-head\">";
    html += "<div style=\"display:flex;align-items:center;gap:8px\">";
    html += "<h6 class=\"fleet-aside-title\">Message broker</h6>";
    html += "<span style=\"margin-left:auto;display:flex;align-items:center;gap:7px;font-size:12px\">";
    if (brokerOk) {
      html += "<span class=\"broker-pill ok\" style=\"border:0;padding:0\"><span class=\"dot\"></span>Healthy</span>";
    } else {
      html += "<span class=\"broker-pill down\" style=\"border:0;padding:0\"><span class=\"dot\"></span>Unreachable</span>";
    }
    html += "</span></div>";

    html += "<div class=\"fleet-metrics\">";
    if (brokerOk) {
      html += "<span>queued <b>" + esc(broker.queued) + "</b></span>";
      html += "<span>done <b>" + esc(broker.done) + "</b></span>";
      var failedCls = broker.failed ? " failed-warn" : "";
      html += "<span>failed <b class=\"" + failedCls.trim() + "\">" + esc(broker.failed) + "</b></span>";
    } else {
      html += "<span>queued <b>\u2014</b></span><span>done <b>\u2014</b></span><span>failed <b>\u2014</b></span>";
    }
    html += "</div>";

    if (!brokerOk) {
      html += "<p class=\"fleet-broker-note\">Broker unavailable \u2014 graph shows last known muxa state; statuses may be stale.</p>";
    }

    var drawing = broker.drawing || [];
    html += "<div class=\"fleet-drawing-row\">";
    html += "<span class=\"fleet-drawing-label\">Drawing</span>";
    if (drawing.length) {
      drawing.forEach(function (alias) {
        html += "<span class=\"fleet-drawing-btn\"><span class=\"fleet-drawing-bars\"><span></span><span></span><span></span></span>" + esc(alias) + "</span>";
      });
    } else {
      html += "<span class=\"text-muted\" style=\"font-size:11px\">" + (brokerOk ? "no panes drawing" : "unknown while unreachable") + "</span>";
    }
    html += "</div>";
    html += "</div>";

    html += "<div class=\"hr\" style=\"margin:0\"></div>";

    html += "<div class=\"fleet-roster-wrap\">";
    html += "<div class=\"fleet-roster-head\">";
    html += "<h6 class=\"fleet-aside-title\">Roster</h6>";
    html += "<span style=\"margin-left:auto;font-size:10px;color:color-mix(in srgb,var(--color-text) 38%, transparent)\">" + workers.length + " workers</span>";
    html += "</div>";
    html += "<div class=\"fleet-roster-scroll\" id=\"fleet-roster\">";

    workers.forEach(function (n) {
      var ts = parseTs(n.timestamp);
      var ageStr = age(ts, nowMs);
      var ageTitle = n.time_source ? (TIME_SOURCE_LABEL[n.time_source] || n.time_source) : "";
      var dotExtra = rosterDotStyle(n.phase);
      var btnSel = selected === n.id ? " selected" : "";
      html += "<button type=\"button\" class=\"fleet-roster-btn phase-" + esc(n.phase) + btnSel + "\" data-roster-id=\"" + esc(n.id) + "\">";
      html += "<span class=\"fleet-roster-dot\" style=\"" + dotExtra + "\"></span>";
      html += "<span class=\"fleet-roster-alias\">" + esc(n.alias) + "</span>";
      html += "<span class=\"fleet-roster-model\">" + esc(n.branch || n.cli || "\u2014") + "</span>";
      if (ageTitle) {
        html += "<span class=\"fleet-roster-time age-proxy\" title=\"" + esc(ageTitle) + "\">" + esc(ageStr) + "</span>";
      } else {
        html += "<span class=\"fleet-roster-time\">" + esc(ageStr) + "</span>";
      }
      html += "</button>";
    });

    if (!workers.length) {
      html += "<p class=\"text-muted\" style=\"font-size:12px;line-height:1.55;margin:8px 8px 0\">No worker panes in this snapshot.</p>";
    }
    html += "</div></div>";

    if (edges.length) {
      html += "<div class=\"hr\" style=\"margin:0\"></div>";
      html += "<div class=\"fleet-edges-section\"><h6 class=\"fleet-aside-title\">Edges</h6>";
      html += "<ul class=\"fleet-edges-list\">";
      edges.forEach(function (e) {
        var inf = e.source === "inferred" ? " <span class=\"inferred\">(inferred)</span>" : "";
        html += "<li>" + esc(e.from) + " \u2192 " + esc(e.to) + inf + "</li>";
      });
      html += "</ul></div>";
    }

    html += "</aside></div></div>";

    app.innerHTML = html;

    var roster = document.getElementById("fleet-roster");
    if (roster) {
      roster.addEventListener("click", function (ev) {
        var btn = ev.target.closest("[data-roster-id]");
        if (!btn) return;
        var id = btn.getAttribute("data-roster-id");
        renderFleet(data, { live: opts.live, selected: id });
        var wrap = document.querySelector("[data-node-id=\"" + id + "\"]");
        if (wrap) wrap.scrollIntoView({ behavior: "smooth", block: "center", inline: "center" });
      });
    }
  }

  function showError(msg) {
    var banner = document.getElementById("error-banner");
    if (!banner) return;
    banner.textContent = msg;
    banner.classList.remove("hidden");
  }

  function hideError() {
    var banner = document.getElementById("error-banner");
    if (banner) banner.classList.add("hidden");
  }

  function boot(options) {
    options = options || {};
    if (options.live) {
      function refresh() {
        fetch("/api/status")
          .then(function (r) {
            if (!r.ok) throw new Error("HTTP " + r.status);
            return r.json();
          })
          .then(function (data) {
            hideError();
            renderFleet(data, { live: true });
          })
          .catch(function (err) {
            showError("Unable to refresh fleet status: " + (err.message || String(err)) +
              ". The server may have stopped or status --json failed.");
          });
      }
      refresh();
      setInterval(refresh, REFRESH_MS);
      return;
    }

    var el = document.getElementById("fleet-data");
    if (!el) {
      showError("Missing embedded fleet payload.");
      return;
    }
    renderFleet(JSON.parse(el.textContent), { live: false });
  }

  global.CPStatusDashboard = { boot: boot, renderFleet: renderFleet };
})(typeof window !== "undefined" ? window : globalThis);

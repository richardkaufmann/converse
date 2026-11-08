// View → Group. Data arrives only through GroupMap.apply; everything is written
// with textContent, so a session title can never become markup.
(function () {
  "use strict";
  const STATES = {
    queued: { label: "Queued", glyph: "◷" },
    sent: { label: "Sent", glyph: "↗" },
    delivered: { label: "Delivered", glyph: "✓" },
    awaitingAnswer: { label: "Awaiting answer", glyph: "…" },
    answered: { label: "Answered", glyph: "↩" },
    failed: { label: "Failed", glyph: "✕" },
    unknown: { label: "Unknown", glyph: "?" },
  };
  // A busy map keeps the mesh out of the way until a node is hovered.
  const MESH_LIMIT = 900;
  const MAX_LISTED = 6;
  const PULSE_MS = 900;

  const devices = new Map(), nodes = new Map(), edges = new Map(), deliveries = new Map();
  const dragged = new Map(), deviceOffsets = new Map();
  let groupName = null, clockOffset = 0, paused = false, userMoved = false, fitted = false;
  let showMesh = true, hovered = null, pinned = null, tipTimer = null;
  let pulses = [], pulseTimer = null, lastAnnounce = 0, frameQueued = false;
  const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)");

  const svg = d3.select("#canvas"), root = d3.select("#root");
  const layerDevices = d3.select("#devices"), layerEdges = d3.select("#edges");
  const layerFlows = d3.select("#flows"), layerPulses = d3.select("#pulses"), layerNodes = d3.select("#nodes");
  const tip = document.getElementById("tip"), detail = document.getElementById("detail");
  const announceEl = document.getElementById("announce"), stage = document.getElementById("stage");

  function post(message) {
    const bridge = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.groupMap;
    if (bridge) bridge.postMessage(message);
  }
  window.addEventListener("error", (e) => post({ type: "error", message: String(e.message) }));
  window.addEventListener("unhandledrejection", (e) => post({ type: "error", message: String(e.reason) }));
  document.addEventListener("securitypolicyviolation", (e) => post({ type: "error", message: "CSP: " + e.violatedDirective + " " + e.blockedURI }));

  const zoom = d3.zoom().scaleExtent([0.05, 6]).on("zoom", (event) => {
    root.attr("transform", event.transform);
    if (event.sourceEvent) userMoved = true;
  });
  svg.call(zoom).on("dblclick.zoom", null);
  svg.on("click", (event) => { if (event.target === svg.node()) setPinned(null); });

  // MARK: Geometry

  function offset(deviceID) { return deviceOffsets.get(deviceID) || { dx: 0, dy: 0 }; }
  function pos(id) {
    const node = nodes.get(id);
    if (!node) return { x: 0, y: 0 };
    const own = dragged.get(id) || node, shift = offset(node.device);
    return { x: own.x + shift.dx, y: own.y + shift.dy };
  }
  function sideShift(a, b, amount) {
    const dx = b.x - a.x, dy = b.y - a.y, length = Math.hypot(dx, dy) || 1;
    return { x: (-dy / length) * amount, y: (dx / length) * amount };
  }

  // MARK: Rendering

  function flowData() {
    const groups = new Map();
    for (const item of deliveries.values()) {
      if (!item.edge || !["queued", "sent", "awaitingAnswer"].includes(item.state)) continue;
      const key = item.edge + ">" + item.from;
      const group = groups.get(key) || { id: key, edge: item.edge, from: item.from, to: item.to, state: item.state };
      // Show the state furthest from done when a direction has several.
      if (item.state === "queued" || (item.state === "sent" && group.state === "awaitingAnswer")) group.state = item.state;
      groups.set(key, group);
    }
    return [...groups.values()];
  }

  function render() {
    const allDevices = [...devices.values()], allNodes = [...nodes.values()], allEdges = [...edges.values()];
    document.getElementById("empty").hidden = allNodes.length > 0;
    document.getElementById("title").textContent = groupName ? "Group · " + groupName : "Group";
    const pending = [...deliveries.values()].filter((d) => ["queued", "sent", "awaitingAnswer"].includes(d.state)).length;
    document.getElementById("summary").textContent =
      allDevices.length + (allDevices.length === 1 ? " device · " : " devices · ") +
      allNodes.length + (allNodes.length === 1 ? " session · " : " sessions · ") + pending + " pending";

    const deviceGroups = layerDevices.selectAll("g.device-group").data(allDevices, (d) => d.id).join((enter) => {
      const g = enter.append("g").attr("class", "device-group");
      g.append("circle").attr("class", "device");
      g.append("text").attr("class", "device-label").call(deviceDrag);
      return g;
    });
    deviceGroups.classed("offline", (d) => !d.online);
    deviceGroups.select("circle").attr("r", (d) => d.r);
    deviceGroups.select("text").attr("y", (d) => -d.r - 8).text((d) => d.name + (d.local ? " (this device)" : d.online ? "" : " · offline"));

    const hits = allEdges.length <= MESH_LIMIT;
    layerEdges.classed("mesh-off", !showMesh);
    const edgeGroups = layerEdges.selectAll("g.edge-group").data(allEdges, (d) => d.id).join((enter) => {
      const g = enter.append("g").attr("class", "edge-group");
      g.append("line").attr("class", "edge");
      g.append("line").attr("class", "edge-hit");
      return g;
    });
    edgeGroups.select("line.edge")
      .attr("class", edgeClass)
      .attr("marker-end", (d) => (d.ab && !d.ba ? "url(#arrow)" : null))
      .attr("marker-start", (d) => (d.ba && !d.ab ? "url(#arrow)" : null));
    edgeGroups.select("line.edge-hit")
      .attr("display", (d) => (hits || d.total > 0 ? null : "none"))
      .attr("tabindex", (d) => (d.total > 0 ? 0 : null))
      .attr("role", (d) => (d.total > 0 ? "button" : null))
      .attr("aria-label", (d) => edgeAria(d))
      .on("mouseenter", (event, d) => hover({ kind: "edge", id: d.id }, event))
      .on("mousemove", (event) => moveTip(event))
      .on("mouseleave", () => hover(null))
      .on("focus", (event, d) => hover({ kind: "edge", id: d.id }, event))
      .on("blur", () => hover(null))
      .on("click", (event, d) => { event.stopPropagation(); setPinned({ kind: "edge", id: d.id }); })
      .on("keydown", keyActivate((d) => ({ kind: "edge", id: d.id })));

    layerFlows.selectAll("line.flow").data(flowData(), (d) => d.id).join("line")
      .attr("class", (d) => "flow state-" + d.state);

    const nodeGroups = layerNodes.selectAll("g.node").data(allNodes, (d) => d.id).join((enter) => {
      const g = enter.append("g").attr("class", "node").attr("tabindex", 0).attr("role", "button").call(nodeDrag);
      g.append("circle").attr("r", 13);
      g.append("text").attr("class", "glyph").attr("y", 3.5);
      g.append("text").attr("class", "name").attr("y", 26);
      g.append("circle").attr("class", "badge").attr("r", 4).attr("cx", 10).attr("cy", -10);
      return g;
    });
    nodeGroups
      .attr("class", (d) => "node " + d.kind + (d.busy ? " busy" : "") + (d.online ? "" : " offline") + (d.messaging ? "" : " no-messaging") + (d.pendingIn + d.pendingOut > 0 ? " pending" : "") + (isSelected("node", d.id) ? " selected" : ""))
      .attr("aria-label", nodeAria)
      .on("mouseenter", (event, d) => hover({ kind: "node", id: d.id }, event))
      .on("mousemove", (event) => moveTip(event))
      .on("mouseleave", () => hover(null))
      .on("focus", (event, d) => hover({ kind: "node", id: d.id }, event))
      .on("blur", () => hover(null))
      .on("click", (event, d) => { event.stopPropagation(); setPinned({ kind: "node", id: d.id }); })
      .on("keydown", keyActivate((d) => ({ kind: "node", id: d.id })));
    nodeGroups.select("text.glyph").text((d) => (d.kind === "agent" ? "A" : ""));
    nodeGroups.select("text.name").text((d) => (d.label.length > 24 ? d.label.slice(0, 23) + "…" : d.label));
    nodeGroups.select("circle.badge").attr("display", (d) => (d.pendingIn + d.pendingOut > 0 ? null : "none"));

    place();
    refreshHighlights();
    refreshTip();
    if (!fitted && allNodes.length) { fit(false); fitted = true; }
  }

  function edgeClass(d) {
    const reach = d.ab === "can" || d.ba === "can" ? "can" : d.ab === "offline" || d.ba === "offline" ? "offline" : d.ab || d.ba ? "unknown" : "historic";
    return "edge " + (reach === "historic" ? "historic" : "reach-" + reach) + (d.total > 0 ? " active" : "");
  }

  function place() {
    layerDevices.selectAll("g.device-group").attr("transform", (d) => {
      const shift = offset(d.id);
      return "translate(" + (d.x + shift.dx) + "," + (d.y + shift.dy) + ")";
    });
    layerNodes.selectAll("g.node").attr("transform", (d) => { const p = pos(d.id); return "translate(" + p.x + "," + p.y + ")"; });
    layerEdges.selectAll("g.edge-group").selectAll("line")
      .attr("x1", function () { return pos(d3.select(this.parentNode).datum().a).x; })
      .attr("y1", function () { return pos(d3.select(this.parentNode).datum().a).y; })
      .attr("x2", function () { return pos(d3.select(this.parentNode).datum().b).x; })
      .attr("y2", function () { return pos(d3.select(this.parentNode).datum().b).y; });
    layerFlows.selectAll("line.flow").each(function (d) {
      const a = pos(d.from), b = pos(d.to), s = sideShift(a, b, 3);
      d3.select(this).attr("x1", a.x + s.x).attr("y1", a.y + s.y).attr("x2", b.x + s.x).attr("y2", b.y + s.y);
    });
  }
  function schedulePlace() {
    if (frameQueued) return;
    frameQueued = true;
    requestAnimationFrame(() => { frameQueued = false; place(); });
  }

  function refreshHighlights() {
    const focus = pinned || hovered;
    const dense = edges.size > MESH_LIMIT;
    layerEdges.selectAll("g.edge-group").select("line.edge")
      .classed("hot", (d) => !!focus && ((focus.kind === "node" && (d.a === focus.id || d.b === focus.id)) || (focus.kind === "edge" && d.id === focus.id)))
      .classed("dim", (d) => (dense && !focus && d.total === 0) || (!!focus && focus.kind === "node" && d.a !== focus.id && d.b !== focus.id));
    layerNodes.selectAll("g.node").classed("selected", (d) => isSelected("node", d.id));
  }
  function isSelected(kind, id) { return !!pinned && pinned.kind === kind && pinned.id === id; }

  // MARK: Dragging

  const nodeDrag = d3.drag()
    .on("start", function () { d3.select(this).style("cursor", "grabbing"); })
    .on("drag", function (event, d) {
      const shift = offset(d.device);
      dragged.set(d.id, { x: event.x - shift.dx, y: event.y - shift.dy });
      userMoved = true; schedulePlace();
    })
    .on("end", function () { d3.select(this).style("cursor", null); })
    .subject((event, d) => { const p = pos(d.id); return { x: p.x, y: p.y }; });
  const deviceDrag = d3.drag()
    .on("drag", (event, d) => {
      const shift = offset(d.id);
      deviceOffsets.set(d.id, { dx: shift.dx + event.dx, dy: shift.dy + event.dy });
      userMoved = true; schedulePlace();
    });

  // MARK: Fit

  function fit(animate) {
    const box = stage.getBoundingClientRect();
    if (!box.width || !box.height || (!devices.size && !nodes.size)) return;
    let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
    for (const device of devices.values()) {
      const shift = offset(device.id);
      x0 = Math.min(x0, device.x + shift.dx - device.r); x1 = Math.max(x1, device.x + shift.dx + device.r);
      y0 = Math.min(y0, device.y + shift.dy - device.r - 24); y1 = Math.max(y1, device.y + shift.dy + device.r);
    }
    for (const id of nodes.keys()) {
      const p = pos(id);
      x0 = Math.min(x0, p.x - 40); x1 = Math.max(x1, p.x + 40); y0 = Math.min(y0, p.y - 20); y1 = Math.max(y1, p.y + 40);
    }
    const margin = 24, width = Math.max(x1 - x0, 1), height = Math.max(y1 - y0, 1);
    const scale = Math.min(1.5, Math.max(0.05, Math.min((box.width - 2 * margin) / width, (box.height - 2 * margin) / height)));
    const transform = d3.zoomIdentity.translate(box.width / 2 - (scale * (x0 + x1)) / 2, box.height / 2 - (scale * (y0 + y1)) / 2).scale(scale);
    if (animate && !reduceMotion.matches && !paused) svg.transition().duration(350).call(zoom.transform, transform);
    else svg.call(zoom.transform, transform);
  }
  document.getElementById("fit").addEventListener("click", () => { userMoved = false; fit(true); });
  document.getElementById("mesh").addEventListener("click", (event) => {
    showMesh = !showMesh;
    event.currentTarget.setAttribute("aria-pressed", String(showMesh));
    layerEdges.classed("mesh-off", !showMesh);
  });
  new ResizeObserver(() => { if (!paused && !userMoved && fitted) fit(false); }).observe(stage);

  // MARK: Pulses

  function startPulses(items) {
    if (paused || reduceMotion.matches) return;
    const started = performance.now();
    items.forEach((item, index) => {
      if (edges.has(item.edge) && nodes.has(item.from) && nodes.has(item.to)) {
        pulses.push({ key: item.delivery + "/" + item.state + "/" + started, item, start: started + index * 60 });
      }
    });
    if (!pulseTimer && pulses.length) pulseTimer = d3.timer(stepPulses);
  }
  function stepPulses() {
    const now = performance.now();
    pulses = pulses.filter((p) => now - p.start < PULSE_MS);
    const live = pulses.filter((p) => now >= p.start);
    layerPulses.selectAll("circle.pulse").data(live, (p) => p.key).join("circle")
      .attr("class", (p) => "pulse pulse-" + p.item.state).attr("r", 5.5)
      .attr("cx", (p) => locate(p, now).x).attr("cy", (p) => locate(p, now).y);
    if (!pulses.length) stopPulses();
  }
  function locate(p, now) {
    const a = pos(p.item.from), b = pos(p.item.to), t = d3.easeCubicInOut(Math.min((now - p.start) / PULSE_MS, 1));
    return { x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t };
  }
  function stopPulses() {
    if (pulseTimer) { pulseTimer.stop(); pulseTimer = null; }
    layerPulses.selectAll("circle.pulse").remove();
  }

  // MARK: Hover and detail

  function age(fromMs) {
    if (fromMs == null) return "age unknown";
    const seconds = Math.max(0, Math.round((Date.now() + clockOffset - fromMs) / 1000));
    if (seconds < 60) return seconds + "s";
    if (seconds < 3600) return Math.floor(seconds / 60) + "m " + (seconds % 60) + "s";
    return Math.floor(seconds / 3600) + "h " + Math.floor((seconds % 3600) / 60) + "m";
  }
  function make(tag, className, text) {
    const element = document.createElement(tag);
    if (className) element.className = className;
    if (text != null) element.textContent = text;
    return element;
  }
  function row(parent, name, value) {
    const line = make("div", "t-row");
    line.append(make("span", null, name), make("span", null, value));
    parent.append(line);
  }
  function reachText(reach, why) {
    if (!reach) return "Not permitted";
    return ({ can: "Can message", offline: "Device offline", unknown: "Unknown" })[reach] + (why ? " — " + why : "");
  }
  function deliveryRow(list, item, perspective) {
    const state = STATES[item.state];
    const li = make("li");
    const head = make("div");
    head.append(make("span", "t-state t-state-" + item.state, state.glyph + " " + state.label), document.createTextNode(" · " + item.kind));
    const who = make("div", null, perspective === item.from ? "→ " + item.toName : perspective === item.to ? "← " + item.fromName : item.fromName + " → " + item.toName);
    const pending = ["queued", "sent", "awaitingAnswer"].includes(item.state);
    const when = make("div", "t-detail", (pending ? "Pending " : "") + age(item.createdAt) + (pending ? "" : " ago"));
    li.append(head, who, make("div", "t-detail", item.detail), when);
    if (item.recipient === "unknown") li.append(make("div", "t-detail", "Recipient's progress: unknown"));
    list.append(li);
  }
  function deliveriesFor(selection) {
    const list = [...deliveries.values()].filter((d) => (selection.kind === "edge" ? d.edge === selection.id : d.from === selection.id || d.to === selection.id));
    list.sort((a, b) => Number(["queued", "sent", "awaitingAnswer"].includes(b.state)) - Number(["queued", "sent", "awaitingAnswer"].includes(a.state)) || (b.createdAt || 0) - (a.createdAt || 0));
    return list;
  }
  function fill(container, selection) {
    container.replaceChildren();
    const nameOf = (id) => (nodes.get(id) ? nodes.get(id).label : "Unavailable");
    if (selection.kind === "node") {
      const node = nodes.get(selection.id);
      if (!node) return false;
      const device = devices.get(node.device);
      container.append(make("div", "t-title", node.label));
      container.append(make("div", "t-sub", (node.kind === "agent" ? "Agent" : "Session") + " · " + node.assistant + (device ? " · " + device.name : "")));
      row(container, "Device", node.online ? "Online" : "Offline");
      row(container, "Messaging", node.messaging ? (node.taught === false ? "On, not taught" : "On") : "Off");
      row(container, "Activity", node.busy ? "Working" : "Idle");
      row(container, "Queued prompts", node.queued + (node.paused ? " (paused)" : ""));
      row(container, "Pending", node.pendingIn + " in · " + node.pendingOut + " out");
      if (node.oldestPendingAt != null) row(container, "Oldest pending", age(node.oldestPendingAt));
    } else {
      const edge = edges.get(selection.id);
      if (!edge) return false;
      container.append(make("div", "t-title", nameOf(edge.a) + " ↔ " + nameOf(edge.b)));
      container.append(make("div", "t-sub", nameOf(edge.a) + " → " + nameOf(edge.b) + ": " + reachText(edge.ab, edge.abWhy)));
      container.append(make("div", "t-sub", nameOf(edge.b) + " → " + nameOf(edge.a) + ": " + reachText(edge.ba, edge.baWhy)));
      if (edge.total > 0) {
        row(container, "Messages", String(edge.total));
        row(container, "Pending", String(edge.pending));
        if (edge.oldestPendingAt != null) row(container, "Oldest pending", age(edge.oldestPendingAt));
        for (const key of Object.keys(STATES)) if (edge.counts[key]) row(container, STATES[key].label, String(edge.counts[key]));
      } else container.append(make("div", "t-sub", "No messages recorded."));
    }
    const items = deliveriesFor(selection).slice(0, MAX_LISTED);
    if (items.length) {
      const list = make("ul", "t-list");
      for (const item of items) deliveryRow(list, item, selection.kind === "node" ? selection.id : null);
      container.append(list);
    }
    return true;
  }
  function hover(selection, event) {
    hovered = selection;
    refreshHighlights();
    if (!selection || pinned) { tip.hidden = true; updateTipTimer(); return; }
    tip.hidden = !fill(tip, selection);
    if (event && event.clientX != null && event.type !== "focus") moveTip(event);
    else if (event && event.target) anchorTip(event.target);
    updateTipTimer();
  }
  function moveTip(event) { position(event.clientX, event.clientY); }
  function anchorTip(element) { const box = element.getBoundingClientRect(); position(box.left + box.width / 2, box.top); }
  function position(clientX, clientY) {
    const box = stage.getBoundingClientRect(), width = tip.offsetWidth, height = tip.offsetHeight;
    tip.style.left = Math.min(Math.max(clientX - box.left + 14, 4), box.width - width - 4) + "px";
    tip.style.top = Math.min(Math.max(clientY - box.top + 14, 4), box.height - height - 4) + "px";
  }
  function setPinned(selection) {
    pinned = selection;
    detail.hidden = !selection || !fill(detail, selection);
    if (selection) tip.hidden = true;
    refreshHighlights();
    updateTipTimer();
  }
  function refreshTip() {
    if (pinned) { if (!fill(detail, pinned)) setPinned(null); }
    else if (hovered && !tip.hidden) { if (!fill(tip, hovered)) tip.hidden = true; }
  }
  // Pending ages tick only while someone is looking at one.
  function updateTipTimer() {
    const active = !paused && (pinned || (hovered && !tip.hidden));
    if (active && !tipTimer) tipTimer = setInterval(refreshTip, 1000);
    if (!active && tipTimer) { clearInterval(tipTimer); tipTimer = null; }
  }
  function keyActivate(select) {
    return (event, d) => {
      if (event.key === "Enter" || event.key === " ") { event.preventDefault(); setPinned(select(d)); }
      if (event.key === "Escape") setPinned(null);
    };
  }
  document.addEventListener("keydown", (event) => { if (event.key === "Escape") setPinned(null); });
  function nodeAria(d) {
    return (d.kind === "agent" ? "Agent " : "Session ") + d.label + (d.online ? "" : ", offline") + ", " + d.pendingIn + " pending in, " + d.pendingOut + " pending out";
  }
  function edgeAria(d) {
    const a = nodes.get(d.a), b = nodes.get(d.b);
    return (a ? a.label : "Unavailable") + " and " + (b ? b.label : "Unavailable") + ": " + d.total + " messages, " + d.pending + " pending";
  }
  function announce(items) {
    const now = Date.now();
    if (!items.length || now - lastAnnounce < 1500) return;
    lastAnnounce = now;
    const item = deliveries.get(items[items.length - 1].delivery);
    if (item) announceEl.textContent = item.fromName + " to " + item.toName + ": " + STATES[item.state].label;
  }

  // MARK: Bridge

  function mergeInto(map, list, removed) {
    for (const id of removed) map.delete(id);
    for (const item of list) map.set(item.id, item);
  }
  function apply(json) {
    const payload = JSON.parse(json);
    if (payload.v !== 1) throw new Error("Unsupported group map payload");
    if (payload.full) { devices.clear(); nodes.clear(); edges.clear(); deliveries.clear(); }
    clockOffset = payload.now - Date.now();
    groupName = payload.groupName || null;
    mergeInto(devices, payload.devices, payload.removedDevices);
    mergeInto(nodes, payload.nodes, payload.removedNodes);
    mergeInto(edges, payload.edges, payload.removedEdges);
    mergeInto(deliveries, payload.deliveries, payload.removedDeliveries);
    render();
    startPulses(payload.pulses);
    announce(payload.pulses);
    return true;
  }
  function setPaused(value) {
    paused = value;
    document.body.classList.toggle("paused", value);
    if (value) { pulses = []; stopPulses(); tip.hidden = true; }
    updateTipTimer();
  }
  function stats() {
    return {
      nodes: nodes.size, edges: edges.size, deliveries: deliveries.size, devices: devices.size,
      flows: layerFlows.selectAll("line.flow").size(), pulses: pulses.length,
      resources: performance.getEntriesByType("resource").map((entry) => entry.name), page: location.href,
    };
  }

  const legend = document.getElementById("legend");
  for (const [key, state] of Object.entries(STATES)) {
    const li = make("li", "t-state-" + key);
    li.append(document.createTextNode(state.glyph + " "), make("span", null, state.label));
    legend.append(li);
  }

  window.GroupMap = { apply, setPaused, stats };
  post({ type: "ready" });
})();

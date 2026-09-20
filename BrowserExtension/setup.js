import { WorkbenchError, validID, cleanName, validEnvelope } from "./core.js";

const KEY = "browserSetup";
const TOKEN_LIFETIME = 300_000;
const safeKey = /^[a-z0-9-]+$/;
const secretKey = /^(token|access_token|refresh_token|id_token|password|passwd|secret|auth|authorization|session|sessionid|signature|sig|key|api_key|apikey|code)$/i;
const failure = code => { throw new WorkbenchError(code); };
const clone = value => structuredClone(value);
const equal = (left, right) => JSON.stringify(left) === JSON.stringify(right);
const own = (object, key) => object && Object.hasOwn(object, key) ? object[key] : undefined;
const put = (object, key, value) => Object.defineProperty(object, key, { value, enumerable: true, configurable: true, writable: true });
const entryKey = setup => `${setup.packID}:${setup.roleID}`;
const nodeRecord = node => node ? { id: node.id, parentId: node.parentId, title: node.title, ...(node.url === undefined ? {} : { url: node.url }) } : null;

export function setupURL(value) {
  if (typeof value !== "string" || value.length > 4096 || !/^https?:\/\/[^/?#]+/i.test(value)
      || /[\s\u0000-\u001f\u007f\\]/u.test(value)) failure("setupInvalid");
  let url;
  try { url = new URL(value); } catch { failure("setupInvalid"); }
  if (!url.hostname || url.username || url.password || value.slice(value.indexOf("//") + 2).split(/[/?#]/, 1)[0].includes("@")) failure("setupInvalid");
  // Inspect percent-decoded keys, including fragment query strings, without
  // discarding ordinary filters or client-side routes.
  const fragment = url.hash.slice(1);
  for (const part of [url.search.slice(1), /[=?]/.test(fragment) ? fragment.split("?").at(-1) : ""]) {
    for (const [key] of new URLSearchParams(part)) if (secretKey.test(key)) failure("setupInvalid");
  }
  if (url.href.length > 4096) failure("setupInvalid");
  return url.href;
}

export function cleanSetup(input) {
  try {
    if (!input || Array.isArray(input) || !validID(input.packID) || input.packID !== input.packID.toLowerCase()
        || typeof input.roleID !== "string" || !safeKey.test(input.roleID) || input.roleID.length > 40
        || !Array.isArray(input.bookmarks) || input.bookmarks.length > 60
        || !Array.isArray(input.launchURLs) || input.launchURLs.length > 8) failure("setupInvalid");
    const ids = new Set();
    const bookmarks = input.bookmarks.map(item => {
      if (!item || typeof item.id !== "string" || !safeKey.test(item.id) || item.id.length > 64 || ids.has(item.id)) failure("setupInvalid");
      ids.add(item.id);
      return { id: item.id, title: cleanName(item.title), url: setupURL(item.url), folder: cleanName(item.folder) };
    });
    return { packID: input.packID, title: cleanName(input.title), roleID: input.roleID,
      roleTitle: cleanName(input.roleTitle), bookmarks, launchURLs: input.launchURLs.map(setupURL), defaultURL: setupURL(input.defaultURL) };
  } catch { failure("setupInvalid"); }
}

export class SetupController {
  constructor(api, { now = () => Date.now(), uuid = () => crypto.randomUUID() } = {}) {
    this.api = api; this.now = now; this.uuid = uuid;
    this.busy = false; this.reviews = new Map(); this.generation = 0;
  }
  cancel() { this.generation++; this.reviews.clear(); }
  async locked(action) {
    if (this.busy) failure("busy");
    this.busy = true;
    try { return await action(); } finally { this.busy = false; }
  }
  async load() {
    const value = (await this.api.storage.local.get(KEY))[KEY];
    if (value === undefined) return { version: 1, rootID: null, receipts: {}, launches: {}, journal: null };
    if (!value || value.version !== 1 || !value.receipts || !value.launches || Array.isArray(value.receipts)
        || Array.isArray(value.launches) || (value.rootID !== null && typeof value.rootID !== "string")) failure("setupUncertain");
    return clone(value);
  }
  async save(state) { await this.api.storage.local.set({ [KEY]: clone(state) }); }
  async tree() {
    if (!await this.api.permissions.contains({ permissions: ["bookmarks"] })) failure("setupPermission");
    if (!this.api.bookmarks?.getTree) failure("setupUnsupported");
    const tree = await this.api.bookmarks.getTree();
    const nodes = new Map();
    const visit = node => { nodes.set(node.id, node); for (const child of node.children ?? []) visit(child); };
    for (const node of tree) visit(node);
    const roots = (tree[0]?.children ?? []).filter(node => ["bookmarks-bar", "other"].includes(node.folderType)
      && node.syncing === false && !node.unmodifiable && node.url === undefined);
    // Metadata was introduced in Chrome 134. Missing metadata is never guessed.
    if (!(tree[0]?.children ?? []).some(node => typeof node.syncing === "boolean" && typeof node.folderType === "string")) failure("setupUnsupported");
    return { nodes, roots };
  }
  async state() {
    const stored = await this.load();
    if (!await this.api.permissions.contains({ permissions: ["bookmarks"] })) return { permission: false, roots: [], rootID: stored.rootID, uncertain: Boolean(stored.journal) };
    const { roots } = await this.tree();
    return { permission: true, roots: roots.map(node => ({ id: node.id, title: node.title })), rootID: stored.rootID, uncertain: Boolean(stored.journal) };
  }
  async selectRoot(id) {
    return this.locked(async () => {
      const state = await this.load();
      if (state.journal) failure("setupUncertain");
      const { roots } = await this.tree();
      if (!roots.some(node => node.id === id)) failure("setupRoot");
      state.rootID = id; await this.save(state); this.reviews.clear();
      return this.state();
    });
  }
  guard(message, generation) {
    if (generation !== this.generation) failure("setupUncertain");
    if (!Number.isFinite(message.expiresAt) || message.expiresAt <= this.now() || message.expiresAt > this.now() + 60_000) failure("timeout");
  }
  async inspect(setup, state) {
    if (state.journal) failure("setupUncertain");
    const { nodes, roots } = await this.tree();
    const root = roots.find(node => node.id === state.rootID);
    if (!root) failure("setupRoot");
    const receipt = state.receipts[entryKey(setup)];
    if (receipt && receipt.rootID !== root.id) failure("setupRoot");
    const matches = record => Boolean(record && nodes.get(record.id)?.syncing === false && !nodes.get(record.id)?.unmodifiable
      && equal(nodeRecord(nodes.get(record.id)), record));
    const containerOK = !receipt || matches(receipt.container);
    const result = { create: 0, update: 0, unchanged: 0, conflicts: 0, root: [...root.title].slice(0, 160).join(""), notes: [] };
    const actions = [];
    for (const item of setup.bookmarks) {
      const previous = own(receipt?.items, item.id);
      const group = own(receipt?.groups, item.folder);
      const oldGroup = previous && Object.values(receipt.groups ?? {}).find(record => record.id === previous.parentId);
      if (!containerOK || (group && !matches(group)) || (previous && (!matches(previous) || !oldGroup || !matches(oldGroup)))) {
        result.conflicts++; continue;
      }
      if (!previous) { result.create++; actions.push({ type: "create", item }); }
      else if (previous.title === item.title && previous.url === item.url && previous.parentId === group?.id) result.unchanged++;
      else { result.update++; actions.push({ type: "update", item }); }
    }
    if (result.conflicts) result.notes.push("Manually changed or missing managed bookmarks/folders are preserved as conflicts.");
    if (receipt && receipt.container.title !== `${setup.title} — ${setup.roleTitle}`) result.notes.push("The existing pack folder keeps its original name.");
    result.notes.push("Only local bookmarks are supported. Use Chrome Sync for profiles sharing synced bookmarks.");
    const records = receipt ? [receipt.container, ...Object.values(receipt.groups ?? {}), ...Object.values(receipt.items ?? {})] : [];
    const snapshot = JSON.stringify({ root: nodeRecord(root), rootSyncing: root.syncing, receipt,
      nodes: records.map(record => ({ node: nodeRecord(nodes.get(record.id)), syncing: nodes.get(record.id)?.syncing, unmodifiable: nodes.get(record.id)?.unmodifiable })) });
    return { result, snapshot, actions, receipt };
  }
  async command(message) {
    return this.locked(async () => {
      if (!validEnvelope(message) || !["setupPreview", "setupApply", "setupLaunch"].includes(message.type)) failure("setupInvalid");
      const generation = this.generation;
      this.guard(message, generation);
      const setup = cleanSetup(message.setup);
      const state = await this.load();
      if (message.type === "setupLaunch") return this.launch(message, setup, state, generation);
      const inspection = await this.inspect(setup, state);
      this.guard(message, generation);
      if (message.type === "setupPreview") {
        for (const [token, review] of this.reviews) if (review.expiresAt <= this.now()) this.reviews.delete(token);
        if (this.reviews.size >= 20) this.reviews.delete(this.reviews.keys().next().value);
        const reviewToken = this.uuid();
        this.reviews.set(reviewToken, { setup, snapshot: inspection.snapshot, expiresAt: this.now() + TOKEN_LIFETIME });
        return { ok: true, setupResult: { ...inspection.result, reviewToken } };
      }
      const review = this.reviews.get(message.reviewToken);
      this.reviews.delete(message.reviewToken);
      if (!validID(message.reviewToken) || !review || review.expiresAt <= this.now() || !equal(review.setup, setup)
          || review.snapshot !== inspection.snapshot) failure("setupChanged");
      return this.apply(message, setup, state, inspection, generation);
    });
  }
  async apply(message, setup, state, inspection, generation) {
    const key = entryKey(setup);
    const result = { ...inspection.result, create: 0, update: 0 };
    let receipt = state.receipts[key];
    const perform = async (operation, call, record) => {
      this.guard(message, generation);
      // Re-read the actual tree immediately before every write. This narrows
      // but cannot make Chrome's read/write API atomic with manual browser edits.
      const { nodes, roots } = await this.tree();
      if (!roots.some(node => node.id === state.rootID)) failure("setupChanged");
      for (const expected of operation.expected ?? []) {
        const node = nodes.get(expected.id);
        if (node?.syncing !== false || node.unmodifiable || !equal(nodeRecord(node), expected)) failure("setupChanged");
      }
      this.guard(message, generation);
      state.journal = { id: message.id, pack: key, operation: operation.type, entry: operation.entry ?? null, startedAt: this.now() };
      await this.save(state); // Must commit BEFORE Chrome can mutate anything.
      this.guard(message, generation);
      const node = await call();
      if (!node || typeof node.id !== "string" || !node.id || node.syncing !== false || node.unmodifiable
          || Object.entries(operation.result ?? {}).some(([key, value]) => node[key] !== value)) failure("setupUncertain");
      record(nodeRecord(node));
      state.journal = null;
      await this.save(state); // A failed receipt commit leaves durable uncertainty.
    };
    try {
      if (inspection.actions.length && !receipt) {
        await perform({ type: "container", result: { parentId: state.rootID, title: `${setup.title} — ${setup.roleTitle}`, url: undefined } }, () => this.api.bookmarks.create({ parentId: state.rootID, title: `${setup.title} — ${setup.roleTitle}` }), node => {
          receipt = { rootID: state.rootID, container: node, groups: {}, items: {} }; state.receipts[key] = receipt;
        });
      }
      for (const action of inspection.actions) {
        const item = action.item;
        let group = own(receipt.groups, item.folder);
        if (!group) {
          await perform({ type: "folder", expected: [receipt.container], result: { parentId: receipt.container.id, title: item.folder, url: undefined } }, () => this.api.bookmarks.create({ parentId: receipt.container.id, title: item.folder }), node => {
            group = node; put(receipt.groups, item.folder, node);
          });
        }
        if (action.type === "create") {
          await perform({ type: "create", entry: item.id, expected: [receipt.container, group], result: { parentId: group.id, title: item.title, url: item.url } }, () => this.api.bookmarks.create({ parentId: group.id, title: item.title, url: item.url }), node => { put(receipt.items, item.id, node); });
          result.create++;
        } else {
          let previous = receipt.items[item.id];
          const oldGroup = Object.values(receipt.groups).find(record => record.id === previous.parentId);
          if (previous.parentId !== group.id) {
            await perform({ type: "move", entry: item.id, expected: [receipt.container, oldGroup, group, previous], result: { id: previous.id, parentId: group.id, title: previous.title, url: previous.url } }, () => this.api.bookmarks.move(previous.id, { parentId: group.id }), node => { put(receipt.items, item.id, node); });
            previous = receipt.items[item.id];
          }
          if (previous.title !== item.title || previous.url !== item.url) {
            await perform({ type: "update", entry: item.id, expected: [receipt.container, group, previous], result: { id: previous.id, parentId: group.id, title: item.title, url: item.url } }, () => this.api.bookmarks.update(previous.id, { title: item.title, url: item.url }), node => { put(receipt.items, item.id, node); });
          }
          result.update++;
        }
      }
      this.guard(message, generation);
      // Verify all reported completed entries against their durable receipts.
      const { nodes, roots } = await this.tree();
      if (!roots.some(node => node.id === state.rootID)) failure("setupChanged");
      const completed = inspection.actions.length ? [receipt.container,
        ...inspection.actions.flatMap(({ item }) => [own(receipt.groups, item.folder), own(receipt.items, item.id)])] : [];
      for (const expected of completed) {
        if (!equal(nodeRecord(nodes.get(expected.id)), expected) || nodes.get(expected.id)?.syncing !== false || nodes.get(expected.id)?.unmodifiable) failure("setupChanged");
      }
      return { ok: true, setupResult: result };
    } catch (error) {
      const persisted = await this.load().catch(() => ({ journal: true }));
      return { ok: false, error: persisted.journal ? "setupUncertain" : error instanceof WorkbenchError ? error.code : "setupUncertain",
        setupResult: { ...result, notes: [...result.notes, "Some work may have completed. Review Chrome before another apply; no operation was retried."] } };
    }
  }
  async launch(message, setup, state, generation) {
    if (!setup.launchURLs.length) failure("setupInvalid");
    if (Object.hasOwn(state.launches, message.id)) failure("setupUncertain");
    if (Object.keys(state.launches).length >= 512) failure("setupUnsupported");
    this.guard(message, generation);
    state.launches[message.id] = { state: "started", at: this.now() };
    await this.save(state);
    try {
      this.guard(message, generation);
      const window = await this.api.windows.create({ url: setup.launchURLs, type: "normal", focused: true, incognito: false });
      if (!Number.isInteger(window?.id) || window.incognito || !Array.isArray(window.tabs) || window.tabs.length !== setup.launchURLs.length) failure("setupUncertain");
      state.launches[message.id] = { state: "completed", at: this.now() };
      await this.save(state);
      this.guard(message, generation);
      return { ok: true, setupResult: { create: setup.launchURLs.length, update: 0, unchanged: 0, conflicts: 0, root: "New Chrome window",
        notes: ["Launch tabs were created. This does not verify page loading or sign-in, or change startup or New Tab settings."] } };
    } catch { failure("setupUncertain"); }
  }
}

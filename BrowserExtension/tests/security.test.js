import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { createHash } from "node:crypto";

const read = name => readFile(new URL(`../${name}`, import.meta.url), "utf8");

test("manifest retains minimal adapter permissions, fixed identity and strict MV3 isolation", async () => {
  const manifest = JSON.parse(await read("manifest.json"));
  assert.equal(manifest.manifest_version, 3);
  assert.equal(manifest.incognito, "not_allowed");
  assert.deepEqual(manifest.permissions.sort(), ["activeTab", "alarms", "nativeMessaging", "storage"]);
  assert.deepEqual(manifest.optional_host_permissions, ["http://*/*", "https://*/*"]);
  for (const key of ["host_permissions", "content_scripts", "externally_connectable", "web_accessible_resources"]) assert.equal(manifest[key], undefined);
  const digest = createHash("sha256").update(Buffer.from(manifest.key, "base64")).digest("hex").slice(0, 32);
  const extensionID = [...digest].map(char => String.fromCharCode(97 + parseInt(char, 16))).join("");
  assert.equal(extensionID, "ajafaiojgpdgmeblldllnhhfnafiiieo");
  assert.equal(manifest.background.type, "module");
  assert.match(manifest.content_security_policy.extension_pages, /script-src 'self'/);
  assert.doesNotMatch(manifest.content_security_policy.extension_pages, /unsafe|https:/);
});

test("popup uses local assets and text-only rendering without inline execution", async () => {
  const html = await read("popup.html");
  const js = await read("popup.js");
  assert.doesNotMatch(html, /\son\w+\s*=|<script(?![^>]*\bsrc=)|\bsrc=["']https?:/i);
  assert.match(html, /href="privacy.html"[^>]*rel="noopener noreferrer"/);
  assert.match(html, /Requires Workbench Preview for macOS/);
  assert.match(html, /profile labels and saved addresses stay on this device/);
  assert.doesNotMatch(js, /innerHTML|outerHTML|insertAdjacentHTML|eval\(|new Function/);
  assert.match(js, /chrome\.permissions\.request/);
  assert.match(html, /aria-live="polite"/);
  assert.match(html, /label for="destination-title"/);
});

test("runtime has no sync storage, content inspection, navigation of existing tabs or logging", async () => {
  const source = (await Promise.all(["core.js", "native.js", "background.js", "popup.js"].map(read))).join("\n");
  assert.doesNotMatch(source, /storage\.sync|console\.|scripting\.|executeScript|cookies\.|passwords\.|history\.|fetch\(|XMLHttpRequest/);
  assert.doesNotMatch(source, /tabs\.update\([^\n]*\burl\s*:/);
  assert.doesNotMatch(source, /tabs\.remove\(/);
});

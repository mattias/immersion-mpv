// SPDX-License-Identifier: GPL-3.0-or-later
// Drives the real Settings window through Chrome DevTools: saves a key and
// settings, and takes a picture. Needs Node's --experimental-websocket below 22.
//
//   node --experimental-websocket test/settings-window.mjs <electron.exe> <picture.png>
import { spawn } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const [electron, picture] = process.argv.slice(2);
const here = path.dirname(fileURLToPath(import.meta.url));
const work = fs.mkdtempSync(path.join(os.tmpdir(), "immersion-window-"));
const port = 9471;
const LONG_KEY = "FAKE-0123456789abcdefWXYZ";

const child = spawn(electron, [path.join(here, "..", "scripts", "immersion-mpv", "settings"),
  `--immersion-config-dir=${work}`, `--immersion-data-dir=${work}`, `--remote-debugging-port=${port}`]);

let target;
for (let tries = 0; tries < 50 && !target; tries += 1) {
  await new Promise(resolve => setTimeout(resolve, 200));
  try {
    const list = await (await fetch(`http://127.0.0.1:${port}/json`)).json();
    target = list.find(entry => entry.type === "page");
  } catch {}
}
if (!target) throw new Error("the window did not open");

const socket = new WebSocket(target.webSocketDebuggerUrl);
await new Promise(resolve => socket.addEventListener("open", resolve));
let id = 0;
const pending = new Map();
socket.addEventListener("message", event => {
  const reply = JSON.parse(event.data);
  pending.get(reply.id)?.(reply.result);
});
const send = (method, params = {}) => new Promise(resolve => {
  id += 1;
  pending.set(id, resolve);
  socket.send(JSON.stringify({ id, method, params }));
});
const page = async expression =>
  (await send("Runtime.evaluate", { expression, awaitPromise: true, returnByValue: true })).result.value;
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));

await pause(800);
let failures = 0;
const check = (condition, label, detail = "") => {
  console.log(`${condition ? "ok  " : "FAIL"} ${label}${condition ? "" : ` ${detail}`}`);
  if (!condition) failures += 1;
};

await page(`(() => { const i = document.getElementById("f-jimaku_key"); i.value = ${JSON.stringify(LONG_KEY)};
  i.parentElement.querySelector("button").click(); })()`);
await pause(400);
const stored = JSON.parse(fs.readFileSync(path.join(work, "secrets.json"), "utf8"));
check(stored.jimaku_key === LONG_KEY, "the key is saved");
const body = await page("document.body.innerText");
const values = await page(`[...document.querySelectorAll("input")].map(i => i.value).join("|")`);
check(!body.includes(LONG_KEY) && !values.includes(LONG_KEY), "the page never holds it afterwards");
check(body.includes("••••••••WXYZ"), "it is shown masked", body.slice(0, 300));
check(await page(`document.getElementById("f-anilist_token").type`) === "password", "the fields are password fields");

await page(`(() => { const i = document.getElementById("f-anilist_dry_run"); i.click(); })()`);
await page(`(() => { const i = document.getElementById("f-anilist_threshold"); i.value = 90;
  i.dispatchEvent(new Event("change")); })()`);
await pause(400);
const conf = fs.readFileSync(path.join(work, "script-opts", "immersion-mpv.conf"), "utf8");
check(conf.includes("anilist_dry_run=no") && conf.includes("anilist_threshold=90"), "settings go to the conf", conf);
check(!conf.includes(LONG_KEY), "the key stays out of the conf");

await send("Page.enable");
const shot = await send("Page.captureScreenshot", { format: "png" });
fs.writeFileSync(picture, Buffer.from(shot.data, "base64"));
child.kill();
await pause(300);
fs.rmSync(work, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 });
process.exit(failures ? 1 : 0);

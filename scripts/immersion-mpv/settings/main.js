// SPDX-License-Identifier: GPL-3.0-or-later
// The plugin's Settings window. Every change is saved at once; mpv notices
// the files changed and applies them. Nothing here is logged.
"use strict";

const { app, BrowserWindow, ipcMain, shell } = require("electron");
const fs = require("node:fs/promises");
const path = require("node:path");
const { saveConf } = require("./conf-file.js");
const { readSecrets, saveSecret, maskedSecrets } = require("./secrets.js");

const DEFAULTS = {
  stats_enabled: true,
  stats_japanese_only: true,
  jimaku_enabled: true,
  anilist_enabled: true,
  anilist_threshold: 85,
  anilist_dry_run: true,
  anilist_client_id: "",
  anilist_url: "https://graphql.anilist.co",
  jimaku_url: "https://jimaku.cc",
};

function argument(name) {
  const prefix = `--${name}=`;
  const found = process.argv.find(entry => entry.startsWith(prefix));
  return found ? found.slice(prefix.length) : "";
}

const configDir = argument("immersion-config-dir");
const dataDir = argument("immersion-data-dir");
app.setPath("userData", path.join(dataDir || app.getPath("temp"), "electron"));

let settingsWindow = null;

function readConfValue(text, key) {
  const line = text.split(/\r?\n/).find(entry => new RegExp(`^\\s*${key}\\s*=`).test(entry));
  return line ? line.slice(line.indexOf("=") + 1).trim() : undefined;
}

async function readOptions() {
  let text = "";
  try { text = await fs.readFile(path.join(configDir, "script-opts", "immersion-mpv.conf"), "utf8"); } catch {}
  const options = {};
  for (const [key, fallback] of Object.entries(DEFAULTS)) {
    const value = readConfValue(text, key);
    if (value === undefined) options[key] = fallback;
    else if (typeof fallback === "boolean") options[key] = value === "yes" || value === "true";
    else if (typeof fallback === "number") options[key] = Number(value) || fallback;
    else options[key] = value;
  }
  return options;
}

function openWindow() {
  if (settingsWindow) {
    settingsWindow.show();
    settingsWindow.focus();
    return;
  }
  settingsWindow = new BrowserWindow({ width: 860, height: 680, minWidth: 640, minHeight: 440,
    title: "immersion-mpv settings", backgroundColor: "#1b1a22", autoHideMenuBar: true,
    webPreferences: { preload: path.join(__dirname, "preload.js"), contextIsolation: true, nodeIntegration: false } });
  settingsWindow.removeMenu();
  settingsWindow.loadFile(path.join(__dirname, "settings.html"));
  settingsWindow.on("closed", () => { settingsWindow = null; });
}

ipcMain.handle("immersion-settings:load", async () => ({
  options: await readOptions(),
  keys: await maskedSecrets(dataDir),
  confPath: path.join(configDir, "script-opts", "immersion-mpv.conf"),
  dataDir,
}));

ipcMain.handle("immersion-settings:save", async (_event, changes) => {
  const accepted = {};
  for (const [key, value] of Object.entries(changes ?? {})) {
    if (!Object.hasOwn(DEFAULTS, key) || typeof value !== typeof DEFAULTS[key]) continue;
    if (typeof value === "number" && !Number.isFinite(value)) continue;
    accepted[key] = value;
  }
  await saveConf(configDir, accepted);
  return true;
});

// AniList shows the token on its own page when the client's redirect URL is
// https://anilist.co/api/v2/oauth/pin.
ipcMain.handle("immersion-settings:open-anilist", async (_event, clientId) => {
  if (!/^\d+$/.test(String(clientId))) throw new Error("The client ID is a number");
  await shell.openExternal(`https://anilist.co/api/v2/oauth/authorize?client_id=${clientId}&response_type=token`);
});

ipcMain.handle("immersion-settings:save-key",(_event, name, value) => saveSecret(dataDir, name, value));

async function testAniList(token, url) {
  const response = await fetch(url, { method: "POST",
    headers: { "Content-Type": "application/json", Accept: "application/json", Authorization: `Bearer ${token}` },
    body: JSON.stringify({ query: "query { Viewer { name } }" }) });
  const reply = await response.json().catch(() => null);
  const name = reply?.data?.Viewer?.name;
  if (name) return `Signed in as ${name}`;
  throw new Error(response.status === 401 || response.status === 400 ? "AniList refused the token" : `AniList answered ${response.status}`);
}

async function testJimaku(key, url) {
  const response = await fetch(`${url}/api/entries/search?anilist_id=154587`,
    { headers: { Authorization: key, "User-Agent": "immersion-mpv/0.1" } });
  if (response.ok) return "Jimaku accepted the key";
  throw new Error(response.status === 401 ? "Jimaku refused the key" : `Jimaku answered ${response.status}`);
}

ipcMain.handle("immersion-settings:test-key", async (_event, name) => {
  const secrets = await readSecrets(dataDir);
  const options = await readOptions();
  if (!secrets[name]) throw new Error("No key is saved");
  if (name === "anilist_token") return testAniList(secrets[name], options.anilist_url);
  if (name === "jimaku_key") return testJimaku(secrets[name], options.jimaku_url);
  throw new Error("unknown key");
});

if (!app.requestSingleInstanceLock()) {
  app.quit();
} else {
  app.on("second-instance", openWindow);
  app.whenReady().then(openWindow);
  app.on("window-all-closed", () => app.quit());
}

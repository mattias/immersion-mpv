// SPDX-License-Identifier: GPL-3.0-or-later
// The AniList token and the Jimaku key, in secrets.json in the data folder.
// Only this file and main.lua read them. The window is told a masked form.
"use strict";

const fs = require("node:fs/promises");
const path = require("node:path");

const NAMES = ["anilist_token", "jimaku_key"];

function mask(value) {
  if (!value) return "";
  return `••••••••${value.length >= 16 ? value.slice(-4) : ""}`;
}

async function readSecrets(dataDir) {
  try {
    const parsed = JSON.parse(await fs.readFile(path.join(dataDir, "secrets.json"), "utf8"));
    return parsed && typeof parsed === "object" ? parsed : {};
  } catch (error) {
    if (error.code === "ENOENT" || error instanceof SyntaxError) return {};
    throw error;
  }
}

async function saveSecret(dataDir, name, value) {
  if (!NAMES.includes(name)) throw new Error("unknown key");
  const clean = String(value ?? "").trim();
  if (/[\r\n]/.test(clean)) throw new Error("a key cannot hold a line break");
  const secrets = await readSecrets(dataDir);
  if (clean) secrets[name] = clean;
  else delete secrets[name];
  await fs.mkdir(dataDir, { recursive: true });
  const file = path.join(dataDir, "secrets.json");
  await fs.writeFile(`${file}.tmp`, JSON.stringify(secrets), { mode: 0o600 });
  await fs.rename(`${file}.tmp`, file);
  return mask(clean);
}

async function maskedSecrets(dataDir) {
  const secrets = await readSecrets(dataDir);
  return Object.fromEntries(NAMES.map(name => [name, mask(secrets[name])]));
}

module.exports = { NAMES, mask, readSecrets, saveSecret, maskedSecrets };

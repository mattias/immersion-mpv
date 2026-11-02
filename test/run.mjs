// SPDX-License-Identifier: GPL-3.0-or-later
// Tests in a real mpv against a local stand-in for AniList and Jimaku, so no
// real list or account is touched. Everything goes in a temporary folder.
//
//   node test/run.mjs [--mpv D:\mpv\mpv.com] [--ffmpeg D:\mpv\ffmpeg.exe] [--both]
//
// --both also runs beside your real hachidori-mpv, from mpv's own config.
import { execFileSync, spawn } from "node:child_process";
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const scriptDir = path.join(here, "..", "scripts", "immersion-mpv");
const option = (name, fallback) => {
  const index = process.argv.indexOf(`--${name}`);
  return index >= 0 ? process.argv[index + 1] : fallback;
};
const mpv = option("mpv", "mpv");
const ffmpeg = option("ffmpeg", "ffmpeg");
const FAKE_TOKEN = "FAKE-ANILIST-TOKEN-must-not-appear";
const FAKE_KEY = "FAKE-JIMAKU-KEY-must-not-appear";

const work = fs.mkdtempSync(path.join(os.tmpdir(), "immersion-e2e-"));
let failures = 0;
function check(condition, label, detail = "") {
  console.log(`${condition ? "ok  " : "FAIL"} ${label}${condition ? "" : ` ${detail}`}`);
  if (!condition) failures += 1;
}

// The stand-in.
const media = (id, romaji, episodes, format = "TV") => ({ id, title: { romaji }, synonyms: [], format, episodes, seasonYear: 2024 });
const lists = { 1001: { id: 1, status: "CURRENT", progress: 2 }, 2001: { id: 2, status: "CURRENT", progress: 5 } };
const requests = [];
const srt = "1\n00:00:01,000 --> 00:00:05,000\nジマクのテストです\n";
const server = http.createServer((request, response) => {
  let body = "";
  request.on("data", chunk => { body += chunk; });
  request.on("end", () => {
    const url = new URL(request.url, "http://localhost");
    const record = { method: request.method, path: url.pathname, query: url.search, auth: request.headers.authorization ?? null };
    requests.push(record);
    const json = (value, status = 200) => {
      response.writeHead(status, { "Content-Type": "application/json" });
      response.end(JSON.stringify(value));
    };
    if (url.pathname === "/graphql") {
      const { query, variables } = JSON.parse(body);
      record.query = query;
      record.variables = variables;
      if (query.includes("mutation")) {
        if (record.auth !== `Bearer ${FAKE_TOKEN}`) return json({ errors: [{ status: 401 }] }, 401);
        lists[variables.mediaId] = { id: 9, status: variables.status, progress: variables.progress };
        return json({ data: { SaveMediaListEntry: lists[variables.mediaId] } });
      }
      if (query.includes("mediaListEntry")) {
        return json({ data: { Media: { episodes: 12, mediaListEntry: lists[variables.id] ?? null } } });
      }
      if (query.includes("Page")) {
        const results = /beta/i.test(variables.search)
          ? [media(2001, "Testshow Beta Prime", 12), media(2002, "Testshow Beta Zero", 12)]
          : /alpha/i.test(variables.search) ? [media(1001, "Testshow Alpha", 12), media(1002, "Testshow Alpha Season 2", 12)] : [];
        return json({ data: { Page: { media: results } } });
      }
      return json({ data: {} });
    }
    if (url.pathname.startsWith("/api/") && request.headers.authorization !== FAKE_KEY) return json({ error: "no" }, 401);
    if (url.pathname === "/api/entries/search") return json([{ id: 77, name: "Testshow Alpha", flags: {} }]);
    if (url.pathname === "/api/entries/77/files" && url.searchParams.get("episode") === "3") {
      const base = `http://127.0.0.1:${server.address().port}/dl`;
      return json([
        { name: "[Z] Testshow Alpha - 04.srt", url: `${base}/wrong.srt`, size: 10, last_modified: "2026-01-01T00:00:00Z" },
        { name: "[Z] Testshow Alpha - 03.srt", url: `${base}/right.srt`, size: 10, last_modified: "2025-01-01T00:00:00Z" },
      ]);
    }
    if (url.pathname === "/api/entries/77/files" && url.searchParams.get("episode") === "8") {
      return json([{ name: "[Z] Testshow Alpha - 08.srt", url: `http://127.0.0.1:${server.address().port}/dl/eight.srt`, size: 10, last_modified: "2025-01-01T00:00:00Z" }]);
    }
    if (url.pathname === "/dl/eight.srt") {
      response.writeHead(200);
      return response.end(subtitleAt(2.5, n => `日本語の行${n + 1}です`));
    }
    if (url.pathname === "/dl/right.srt") {
      response.writeHead(200);
      return response.end(srt);
    }
    response.writeHead(404);
    response.end();
  });
});
await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
const stub = `http://127.0.0.1:${server.address().port}`;

// The videos.
// embedded: {text, lang} puts a subtitle track inside the file.
function video(name, seconds, subtitle, embedded) {
  const file = path.join(work, name);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const inside = [];
  if (embedded) {
    fs.writeFileSync(`${file}.inside.srt`, embedded.text);
    inside.push("-i", `${file}.inside.srt`);
  }
  execFileSync(ffmpeg, ["-v", "error", "-y", "-f", "lavfi", "-i", `testsrc2=s=320x180:r=10:d=${seconds}`,
    "-f", "lavfi", "-i", `sine=d=${seconds}`, ...inside, "-map", "0", "-map", "1", ...(embedded ? ["-map", "2", "-c:s", "srt",
      "-metadata:s:s:0", `language=${embedded.lang}`] : []),
    "-shortest", "-c:v", "libx264", "-preset", "ultrafast", "-c:a", "aac", file]);
  if (embedded) fs.rmSync(`${file}.inside.srt`);
  if (subtitle) fs.writeFileSync(`${file.replace(/\.mkv$/, "")}.ja.srt`, subtitle);
  return file;
}
const stamp = seconds => {
  const millis = Math.round(seconds * 1000);
  const two = value => String(value).padStart(2, "0");
  return `00:${two(Math.floor(millis / 60000))}:${two(Math.floor(millis / 1000) % 60)},${String(millis % 1000).padStart(3, "0")}`;
};
// Lines at irregular times, as speech has, for timing tests.
const spoken = [];
for (let n = 0, at = 2; n < 40; n += 1) { spoken.push(at); at += 1.5 + ((n * 37) % 11) / 2.5; }
const subtitleAt = (shift, text) => spoken.map((at, n) => `${n + 1}\n${stamp(at + shift)} --> ${stamp(at + shift + 1.2)}\n${text(n)}\n`).join("\n");
let lines = "";
for (let n = 1; n <= 15; n += 1) lines += `${n}\n${stamp((n - 1) * 2)} --> ${stamp(n * 2 - 0.2)}\n行${n}です\n\n`;

function run(file, mode, { data, extra = [], config = false } = {}) {
  const args = [
    ...(config ? ["--save-position-on-quit=no", "--resume-playback=no"] : ["--no-config"]),
    "--ao=null", "--geometry=320x180", "--force-window=yes", "--keep-open=yes", "--pause=no", "--msg-level=all=v",
    ...(config ? [] : [`--script=${scriptDir}`]), `--script=${path.join(here, "e2e-driver.lua")}`, "--sub-auto=fuzzy",
    `--script-opts=e2e-mode=${mode},immersion-mpv-anilist_url=${stub}/graphql,immersion-mpv-jimaku_url=${stub},immersion-mpv-sync_whisper=no`,
    ...extra, file];
  return new Promise(resolve => {
    const child = spawn(mpv, args, { env: { ...process.env, IMMERSION_MPV_DATA: data } });
    let log = "";
    child.stdout.on("data", chunk => { log += chunk; });
    child.stderr.on("data", chunk => { log += chunk; });
    const limit = setTimeout(() => child.kill(), 90000);
    child.on("close", () => {
      clearTimeout(limit);
      const seen = {};
      for (const match of log.matchAll(/E2E ([\w-]+)=(.*?)\r?$/gm)) (seen[match[1]] ??= []).push(match[2]);
      resolve({ log, seen });
    });
  });
}

const rows = data => {
  try {
    return fs.readFileSync(path.join(data, "stats.jsonl"), "utf8").trim().split("\n").filter(Boolean).map(line => JSON.parse(line));
  } catch { return []; }
};
const sum = (list, key) => list.reduce((total, row) => total + row[key], 0);
function dataDir(name, secrets) {
  const dir = path.join(work, `data-${name}`);
  fs.mkdirSync(dir, { recursive: true });
  if (secrets) fs.writeFileSync(path.join(dir, "secrets.json"), JSON.stringify({ anilist_token: FAKE_TOKEN, jimaku_key: FAKE_KEY }));
  return dir;
}
const mutations = () => requests.filter(entry => String(entry.query).includes("mutation"));
const allLogs = [];

try {
  console.log("-- statistics");
  const statsData = dataDir("stats");
  const statsFile = video("Immersion Test - 01.mkv", 30, lines);
  let result = await run(statsFile, "stats", { data: statsData });
  allLogs.push(result.log);
  let list = rows(statsData);
  check(sum(list, "lines") === 4, "only the four lines that played count", fs.readdirSync(statsData).filter(name => name.startsWith("seen-")).map(name => fs.readFileSync(path.join(statsData, name), "utf8")).join());
  check(sum(list, "chars") === 4 + 4 + 5 + 5, "their characters count", `${sum(list, "chars")}`);
  const seconds = sum(list, "seconds");
  check(seconds > 9 && seconds < 13, "pause time is not listening time", `${seconds}`);
  check(list.every(row => /^\d{4}-\d\d-\d\d$/.test(row.date) && row.file === "Immersion Test - 01.mkv"), "rows hold date and file");
  check(result.seen["sub-visibility"]?.[0] === "yes", "sub-visibility is untouched");
  check(requests.length === 0, "without keys nothing goes to the network", `${requests.length}`);

  result = await run(statsFile, "again", { data: statsData });
  list = rows(statsData);
  check(sum(list, "lines") === 4, "reopening the file the same day adds no lines", JSON.stringify(list));
  check(sum(list, "seconds") > seconds + 2, "reopening still adds listening time");

  console.log("-- Jimaku and AniList");
  const alpha = dataDir("alpha", true);
  const three = video("Series/[Z] Testshow Alpha - 03 (1080p).mkv", 10);
  result = await run(three, "play", { data: alpha });
  allLogs.push(result.log);
  if (process.env.E2E_DUMP) console.log(result.log.split("\n").filter(line => /immersion|E2E|curl|rror/i.test(line)).slice(0, 60).join("\n"));
  check(result.seen["sub-track"]?.[0] === "Jimaku|ja|true", "Jimaku's subtitle is added and selected", JSON.stringify(result.seen));
  check(requests.some(entry => entry.path === "/api/entries/search" && entry.query === "?anilist_id=1001"), "Jimaku is asked by AniList ID");
  check(requests.some(entry => entry.path === "/api/entries/77/files" && entry.query === "?episode=3"), "and by episode");
  check(requests.some(entry => entry.path === "/dl/right.srt") && !requests.some(entry => entry.path === "/dl/wrong.srt"), "the right episode is downloaded");
  check(fs.existsSync(path.join(alpha, "subs", "1001", "ep003.srt")), "it is saved locally");
  check(!requests.some(entry => entry.path.startsWith("/dl/") && entry.auth), "the key does not go to the download");
  check(mutations().length === 0, "test mode sends nothing", JSON.stringify(mutations()));
  check(/would set Testshow Alpha episode 3/.test(result.log), "test mode says what it would send");
  check(lists[1001].progress === 2, "the list is unchanged");

  const live = ["--script-opts-append=immersion-mpv-anilist_dry_run=no"];
  const downloads = requests.filter(entry => entry.path.startsWith("/dl/")).length;
  result = await run(three, "play", { data: alpha, extra: live });
  allLogs.push(result.log);
  check(result.seen["sub-track"]?.[0] === "Jimaku|ja|true", "the saved subtitle is added again");
  check(requests.filter(entry => entry.path.startsWith("/dl/")).length === downloads, "without another download");
  check(mutations().length === 1 && mutations()[0].variables.progress === 3, "live mode sets episode 3", JSON.stringify(mutations()));
  check(mutations()[0].auth === `Bearer ${FAKE_TOKEN}`, "with the token");

  await run(video("Series/[Z] Testshow Alpha - 02 (1080p).mkv", 10), "play", { data: alpha, extra: live });
  check(mutations().length === 1 && lists[1001].progress === 3, "an earlier episode never moves progress back");

  await run(video("Series/[Z] Testshow Alpha - 04 (1080p).mkv", 20), "skip", { data: alpha, extra: live });
  check(mutations().length === 1, "seeking past 85 % does not count as watching");

  console.log("-- an uncertain match");
  const beta = dataDir("beta", true);
  const searches = () => requests.filter(entry => String(entry.query).includes("Page")).length;
  let before = searches();
  result = await run(video("Beta/Testshow Beta - 06.mkv", 8), "escape", { data: beta });
  check(!fs.existsSync(path.join(beta, "choices.json")), "closing the question stores no choice");
  check(!result.log.includes("identified:"), "and no series is guessed");

  result = await run(video("Beta/Testshow Beta - 01.mkv", 8), "ask", { data: beta, extra: live });
  allLogs.push(result.log);
  const choices = JSON.parse(fs.readFileSync(path.join(beta, "choices.json"), "utf8"));
  check(Object.values(choices)[0]?.testshowbeta?.id === 2001, "the choice is remembered per folder", JSON.stringify(choices));
  check(mutations().length === 1, "episode 1 with progress 5 stays where it was", JSON.stringify(mutations()));
  before = searches();
  await run(path.join(work, "Beta", "Testshow Beta - 06.mkv"), "play", { data: beta, extra: live });
  check(searches() === before, "the folder is not asked about again");
  check(mutations().length === 2 && mutations()[1].variables.mediaId === 2001 && mutations()[1].variables.progress === 6, "the remembered series moves forward", JSON.stringify(mutations()));

  console.log("-- timing and untagged tracks");
  const timing = dataDir("timing", true);
  const eight = video("Series/[Z] Testshow Alpha - 08 (1080p).mkv", 130, null, { text: subtitleAt(0, n => `English line ${n + 1}`), lang: "eng" });
  result = await run(eight, "both", { data: timing, extra: ["--script-opts-append=e2e-wait=8"] });
  check((result.seen["sub-track"] ?? []).includes("Jimaku (timed)|ja|true"), "Jimaku's subtitle is timed by the English track and selected", JSON.stringify(result.seen));
  check(!(result.seen["sub-track"] ?? []).some(entry => entry.startsWith("Jimaku|")), "the untimed one is gone");
  const timedFile = fs.readdirSync(path.join(timing, "subs", "1001")).find(name => /^ep008-[0-9a-f]{8}\.srt$/.test(name));
  check(timedFile && fs.readFileSync(path.join(timing, "subs", "1001", timedFile), "utf8").includes(`${stamp(spoken[0])} -->`), "its lines now start with the video's", timedFile);
  const downloads8 = requests.filter(entry => entry.path === "/dl/eight.srt").length;
  result = await run(eight, "both", { data: timing, extra: ["--script-opts-append=e2e-wait=3"] });
  check((result.seen["sub-track"] ?? []).includes("Jimaku (timed)|ja|true") && requests.filter(entry => entry.path === "/dl/eight.srt").length === downloads8, "next time the timed copy comes at once", JSON.stringify(result.seen));

  const nine = video("Series/[Z] Testshow Alpha - 09 (1080p).mkv", 20, null, { text: subtitleAt(0, n => `字幕の行${n + 1}`), lang: "und" });
  result = await run(nine, "both", { data: timing, extra: ["--script-opts-append=e2e-wait=5"] });
  check(!requests.some(entry => entry.query === "?episode=9"), "an untagged Japanese track is recognised: no Jimaku", JSON.stringify(result.seen));

  console.log("-- two sittings");
  const split = dataDir("split", true);
  const seven = video("Series/[Z] Testshow Alpha - 07 (1080p).mkv", 10);
  const already = mutations().length;
  await run(seven, "first", { data: split, extra: live });
  check(mutations().length === already, "half an episode marks nothing");
  await run(seven, "second", { data: split, extra: live });
  check(mutations().length === already + 1 && mutations().at(-1).variables.progress === 7, "the rest in another sitting does", JSON.stringify(mutations()));

  console.log("-- settings while playing");
  const late = dataDir("late");
  before = searches();
  const playing = run(path.join(work, "Series", "[Z] Testshow Alpha - 02 (1080p).mkv"), "play", { data: late });
  await new Promise(resolve => setTimeout(resolve, 2500));
  check(searches() === before, "without keys, no request");
  fs.writeFileSync(path.join(late, "secrets.json"), JSON.stringify({ anilist_token: FAKE_TOKEN, jimaku_key: FAKE_KEY }));
  await playing;
  check(searches() > before, "keys saved in the Settings window apply at once");

  console.log("-- keys");
  const everything = allLogs.join("\n") + fs.readFileSync(path.join(alpha, "stats.jsonl"), "utf8");
  check(!everything.includes(FAKE_TOKEN) && !everything.includes(FAKE_KEY), "keys appear in no log, even verbose");

  if (process.argv.includes("--both")) {
    // This runs mpv's own config, so it tests the installed copy: install first.
    console.log("-- beside hachidori-mpv");
    const installed = path.join(process.env.APPDATA ?? path.join(os.homedir(), ".config"), "mpv", "scripts", "immersion-mpv");
    for (const name of fs.readdirSync(scriptDir).filter(file => file.endsWith(".lua"))) {
      const copy = path.join(installed, name);
      check(fs.existsSync(copy) && fs.readFileSync(copy, "utf8") === fs.readFileSync(path.join(scriptDir, name), "utf8"),
        `the installed ${name} is this one (run the installer)`);
    }
    const both = dataDir("both");
    result = await run(statsFile, "both", { data: both, config: true, extra: ["--script-opts-append=e2e-wait=14"] });
    list = rows(both);
    check(result.seen["sub-visibility"]?.[0] === "no", "hachidori-mpv hides mpv's subtitles", JSON.stringify(result.seen));
    check(sum(list, "lines") >= 5, "lines count while hachidori-mpv hides them", JSON.stringify(list));
    const bindings = (result.seen.bindings?.[0] ?? "").split(",");
    const keys = bindings.map(entry => entry.split(":").slice(1).join(":").toLowerCase());
    const mine = bindings.filter(entry => entry.startsWith("immersion_mpv:")).map(entry => entry.split(":")[1]);
    check(mine.includes("Alt+i") && mine.includes("Alt+I") && mine.includes("Alt+a"), "our keys are bound", bindings.join());
    check(!mine.some(key => ["Alt+h", "Alt+H", "Alt+o", "LEFT", "RIGHT", "r"].includes(key)), "none of hachidori-mpv's keys");
    check(bindings.some(entry => entry.startsWith("hachidori_mpv:")) && keys.length > 3, "hachidori-mpv kept its own", bindings.join());

    const beside = dataDir("beside", true);
    result = await run(three, "both", { data: beside, config: true, extra: ["--script-opts-append=e2e-wait=14"] });
    check(result.seen["sub-track"]?.[0] === "Jimaku|ja|true", "Jimaku's subtitle arrives", result.log.split("\n").filter(line => /immersion_mpv|hachidori/.test(line) && !/Setting option|Command line/.test(line)).slice(-25).join("\n"));
    check(result.seen["input-ipc-server"]?.[0]?.includes("hachidori-mpv"), "hachidori-mpv is started for it", JSON.stringify(result.seen));
    check(result.seen["sub-visibility"]?.[0] === "no", "and draws it");
  }
} finally {
  server.close();
  server.closeAllConnections?.();
  fs.rmSync(work, { recursive: true, force: true });
}
console.log(failures ? `${failures} failed` : "all passed");
process.exit(failures ? 1 : 0);

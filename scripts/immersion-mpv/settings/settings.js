// SPDX-License-Identifier: GPL-3.0-or-later
// The plugin's Settings window. Every change is saved at once and every open
// mpv picks it up within a few seconds. A key is only ever written here,
// never shown: the page is told a masked form.
"use strict";

(() => {
  const KEYS = [
    { name: "anilist_token", label: "AniList access token",
      help: "Get one with the steps below. A token lasts a year." },
    { name: "jimaku_key", label: "Jimaku API key", help: "Generate one on your jimaku.cc account page." },
  ];

  const SECTIONS = [
    {
      id: "features", title: "Features",
      intro: "Each part works on its own. Without its key, a part stays quiet.",
      fields: [
        { key: "stats_enabled", type: "switch", label: "Listening statistics", help: "Time, subtitle lines and characters per file and day. Needs no key." },
        { key: "stats_japanese_only", type: "switch", label: "Count Japanese lines only", help: "Lines without Japanese are not counted. Listening time always is." },
        { key: "jimaku_enabled", type: "switch", label: "Jimaku subtitles", help: "Fetch the episode's subtitle when a file has no Japanese one." },
        { key: "sync_enabled", type: "switch", label: "Time Jimaku subtitles to the video",
          help: "By another subtitle track of the file, in any language. Once per video; the timed copy is kept." },
        { key: "sync_whisper", type: "switch", label: "Time by the speech when there is no track",
          help: "Whisper listens to the episode once, about a minute on a GPU. Needs install-whisper.ps1." },
        { key: "anilist_enabled", type: "switch", label: "AniList progress", help: "Mark an episode when enough of it has played." },
      ],
    },
    {
      id: "anilist", title: "AniList",
      intro: "Progress only moves forward. A series that is not a certain match is asked about once per folder.",
      fields: [
        { key: "anilist_threshold", type: "range", label: "Watched at", min: 50, max: 100, step: 1, unit: "%",
          help: "How much of the episode must really have played. Skipped parts do not count." },
        { key: "anilist_dry_run", type: "switch", label: "Test mode", help: "Say what would be sent, and send nothing. Your list does not change." },
      ],
    },
  ];

  const status = document.getElementById("status");
  let options = {};

  function el(tag, props = {}, children = []) {
    const node = Object.assign(document.createElement(tag), props);
    for (const child of [].concat(children)) if (child) node.append(child);
    return node;
  }

  function saved(text = "Saved") {
    status.textContent = text;
    status.className = "ok";
  }

  function failed(prefix, error) {
    status.textContent = `${prefix}: ${error.message}`;
    status.className = "error";
  }

  function save(changes) {
    Object.assign(options, changes);
    window.immersionSettings.save(changes).then(() => saved(), error => failed("Not saved", error));
  }

  function control(field) {
    const id = `f-${field.key}`;
    if (field.type === "switch") {
      const input = el("input", { type: "checkbox", id, checked: options[field.key] === true });
      input.addEventListener("change", () => save({ [field.key]: input.checked }));
      return el("span", { className: "switch" }, [input, el("span")]);
    }
    const input = el("input", { type: "range", id, min: field.min, max: field.max, step: field.step, value: options[field.key] });
    const out = el("span", { className: "unit", textContent: `${options[field.key]}${field.unit}` });
    input.addEventListener("input", () => { out.textContent = `${input.value}${field.unit}`; });
    input.addEventListener("change", () => save({ [field.key]: Number(input.value) }));
    return el("span", { className: "control-inner" }, [input, out]);
  }

  function keyRow(key, masked) {
    const state = el("span", { className: "key-state" });
    const result = el("div", { className: "key-result" });
    const input = el("input", { type: "password", id: `f-${key.name}`, autocomplete: "off", spellcheck: false });
    const show = value => {
      state.textContent = value || "Not set";
      input.placeholder = value ? "Paste a new key to replace it" : "Paste the key here";
    };
    const store = value => window.immersionSettings.saveKey(key.name, value).then(next => {
      input.value = "";
      show(next);
      result.textContent = "";
      saved();
    }, error => failed("Not saved", error));
    const saveButton = el("button", { type: "button", className: "small", textContent: "Save" });
    const testButton = el("button", { type: "button", className: "small", textContent: "Test" });
    const removeButton = el("button", { type: "button", className: "small", textContent: "Remove" });
    saveButton.addEventListener("click", () => { if (input.value.trim()) void store(input.value); });
    input.addEventListener("keydown", event => { if (event.key === "Enter" && input.value.trim()) void store(input.value); });
    removeButton.addEventListener("click", () => { void store(""); });
    testButton.addEventListener("click", () => {
      result.textContent = "Testing…";
      result.className = "key-result";
      window.immersionSettings.testKey(key.name).then(text => {
        result.textContent = text;
        result.className = "key-result ok";
      }, error => {
        result.textContent = error.message.replace(/^Error invoking remote method '[^']+': (Error: )?/, "");
        result.className = "key-result error";
      });
    });
    show(masked);
    return el("div", { className: "field key-row" }, [
      el("label", { htmlFor: input.id, textContent: key.label }),
      el("div", { className: "control" }, [input, saveButton, testButton, removeButton]),
      el("div", { className: "help" }, [state, document.createTextNode("  "), document.createTextNode(key.help)]),
      result,
    ]);
  }

  // The way to an AniList token: an API client of your own, whose redirect URL
  // makes AniList show the token instead of sending it anywhere.
  function tokenSteps() {
    const clientId = el("input", { type: "text", id: "f-anilist_client_id", placeholder: "e.g. 12345",
      value: options.anilist_client_id || "", spellcheck: false });
    const open = el("button", { type: "button", className: "small", textContent: "Open AniList" });
    const result = el("div", { className: "key-result" });
    clientId.addEventListener("change", () => save({ anilist_client_id: clientId.value.trim() }));
    open.addEventListener("click", () => {
      const id = clientId.value.trim();
      save({ anilist_client_id: id });
      window.immersionSettings.openAniList(id).then(() => {
        result.textContent = "Approve in the browser, then copy the token and paste it above.";
        result.className = "key-result ok";
      }, error => {
        result.textContent = error.message.replace(/^Error invoking remote method '[^']+': (Error: )?/, "");
        result.className = "key-result error";
      });
    });
    const steps = el("ol", { className: "help steps" }, [
      el("li", { textContent: "On anilist.co, open Settings → Apps → Developer and press Create New Application." }),
      el("li", { textContent: "Any name; Redirect URL: https://anilist.co/api/v2/oauth/pin. Save." }),
      el("li", { textContent: "Copy the client's ID (the number, not the secret) here and press Open AniList." }),
      el("li", { textContent: "Approve. AniList shows a long token: copy all of it into the field above and press Save, then Test." }),
    ]);
    return el("div", { className: "field key-row" }, [
      el("label", { htmlFor: clientId.id, textContent: "Getting an AniList token" }),
      steps,
      el("div", { className: "control" }, [clientId, open]),
      result,
    ]);
  }

  function render(loaded) {
    const nav = document.getElementById("nav");
    const container = document.getElementById("sections");
    const keys = el("section", { id: "keys" }, [el("h2", { textContent: "Keys" }),
      el("p", { textContent: "They are stored once and shown masked from then on." }),
      el("div", { className: "group" }, [keyRow(KEYS[0], loaded.keys[KEYS[0].name]), tokenSteps(),
        keyRow(KEYS[1], loaded.keys[KEYS[1].name])])]);
    nav.append(el("a", { href: "#keys", textContent: "Keys" }));
    container.append(keys);
    for (const section of SECTIONS) {
      nav.append(el("a", { href: `#${section.id}`, textContent: section.title }));
      const box = el("div", { className: "group" }, section.fields.map(field => el("div", { className: "field" }, [
        el("label", { htmlFor: `f-${field.key}`, textContent: field.label }),
        el("div", { className: "control" }, control(field)),
        field.help ? el("div", { className: "help", textContent: field.help }) : null,
      ])));
      container.append(el("section", { id: section.id }, [el("h2", { textContent: section.title }),
        el("p", { textContent: section.intro }), box]));
    }
    document.getElementById("conf-path").textContent = loaded.confPath;
  }

  window.immersionSettings.load().then(loaded => {
    options = loaded.options;
    render(loaded);
  }, error => failed("Could not read the settings", error));
})();

// SPDX-License-Identifier: GPL-3.0-or-later
"use strict";

const test = require("node:test");
const assert = require("node:assert");
const fs = require("node:fs/promises");
const os = require("node:os");
const path = require("node:path");
const { updateConfText } = require("../conf-file.js");
const { mask, saveSecret, maskedSecrets, readSecrets } = require("../secrets.js");

test("a conf line goes below its documented default", () => {
  assert.equal(updateConfText("#anilist_threshold=85\nother=1\n", { anilist_threshold: 90 }),
    "#anilist_threshold=85\nanilist_threshold=90\nother=1\n");
});

test("a mask shows nothing of a short key and the end of a long one", () => {
  assert.equal(mask(""), "");
  assert.equal(mask("short"), "••••••••");
  assert.equal(mask("0123456789abcdefWXYZ"), "••••••••WXYZ");
});

test("keys are saved, masked and removed", async () => {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), "immersion-secrets-"));
  try {
    const masked = await saveSecret(dir, "jimaku_key", "  0123456789abcdefWXYZ\n");
    assert.equal(masked, "••••••••WXYZ");
    assert.equal((await readSecrets(dir)).jimaku_key, "0123456789abcdefWXYZ");
    assert.deepEqual(await maskedSecrets(dir), { anilist_token: "", jimaku_key: "••••••••WXYZ" });
    await saveSecret(dir, "jimaku_key", "");
    assert.equal((await readSecrets(dir)).jimaku_key, undefined);
    await assert.rejects(saveSecret(dir, "other", "x"));
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

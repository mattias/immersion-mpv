// SPDX-License-Identifier: GPL-3.0-or-later
"use strict";

const { contextBridge, ipcRenderer } = require("electron");

contextBridge.exposeInMainWorld("immersionSettings", {
  load: () => ipcRenderer.invoke("immersion-settings:load"),
  save: changes => ipcRenderer.invoke("immersion-settings:save", changes),
  saveKey: (name, value) => ipcRenderer.invoke("immersion-settings:save-key", name, value),
  testKey: name => ipcRenderer.invoke("immersion-settings:test-key", name),
  openAniList: clientId => ipcRenderer.invoke("immersion-settings:open-anilist", clientId),
});

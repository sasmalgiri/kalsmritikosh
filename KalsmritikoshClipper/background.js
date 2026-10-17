// X-4 — context-menu entries for clipping. Everything happens on this Mac.
import { clip } from "./clip.js";

browser.runtime.onInstalled.addListener(() => {
    browser.contextMenus.create({ id: "kals-page", title: "Clip page to Kalsmritikosh", contexts: ["page"] });
    browser.contextMenus.create({ id: "kals-selection", title: "Clip selection to Kalsmritikosh", contexts: ["selection"] });
});

browser.contextMenus.onClicked.addListener((info, tab) => {
    if (!tab || tab.id === undefined) { return; }
    clip(info.menuItemId === "kals-selection" ? "selection" : "page", tab.id);
});

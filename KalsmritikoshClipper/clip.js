// X-4 — shared by the popup and the context menu: read the active tab and hand the clip
// to the app through the extension's native handler. No network request is ever made.
const APP = "ecosanskritiinnovation.Kalsmritikosh.KalsmritikoshClipper";

export async function clip(kind, tabId) {
    const [result] = await browser.scripting.executeScript({ target: { tabId }, files: ["content.js"] });
    const page = result && result.result;
    if (!page) { return { ok: false, error: "This page cannot be clipped." }; }
    const selection = kind === "selection";
    if (selection && !page.selectionText && !page.selectionHTML) {
        return { ok: false, error: "Select some text on the page first." };
    }
    const message = {
        action: "clip",
        kind,
        title: page.title,
        url: page.url,
        html: selection ? page.selectionHTML : page.html,
        text: selection ? page.selectionText : ""
    };
    return await browser.runtime.sendNativeMessage(APP, message);
}

export async function status() {
    try {
        const reply = await browser.runtime.sendNativeMessage(APP, { action: "status" });
        return reply && reply.saved === "on";
    } catch (e) {
        return false;
    }
}

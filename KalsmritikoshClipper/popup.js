// X-4 — the toolbar popup.
import { clip, status } from "./clip.js";

const out = document.getElementById("status");

async function run(kind) {
    out.textContent = "Clipping…";
    const [tab] = await browser.tabs.query({ active: true, currentWindow: true });
    if (!tab || tab.id === undefined) { out.textContent = "No page to clip."; return; }
    try {
        const reply = await clip(kind, tab.id);
        out.textContent = reply && reply.ok ? "Saved to your archive: " + reply.saved : (reply && reply.error) || "Not saved.";
    } catch (e) {
        out.textContent = "Kalsmritikosh could not be reached. Open the app once, then try again.";
    }
}

for (const id of ["page", "selection", "markdown"]) {
    document.getElementById(id).addEventListener("click", () => run(id));
}

status().then(on => {
    if (!on) {
        out.textContent = "Clipping is off. Turn on “Share and capture” in Kalsmritikosh ▸ Settings ▸ Modules.";
    }
});

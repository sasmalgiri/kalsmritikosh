// X-4 — serialise what the browser already shows. Runs only when the person clips
// (activeTab + scripting), never in the background, and never fetches anything.
(() => {
    const selection = window.getSelection();
    let selectionHTML = "";
    let selectionText = "";
    if (selection && selection.rangeCount > 0 && !selection.isCollapsed) {
        const holder = document.createElement("div");
        for (let i = 0; i < selection.rangeCount; i++) {
            holder.appendChild(selection.getRangeAt(i).cloneContents());
        }
        selectionHTML = holder.innerHTML;
        selectionText = selection.toString();
    }
    return {
        title: document.title || "",
        url: location.href,
        html: "<!DOCTYPE html>\n" + document.documentElement.outerHTML,
        selectionHTML: selectionHTML,
        selectionText: selectionText
    };
})();

// Progressive enhancement only: the page, links and FAQs work without JS.
"use strict";
document.documentElement.classList.add("js");

const menu = document.querySelector(".menu-toggle");
const navigation = document.querySelector("#navigation");
function closeMenu() {
  menu.setAttribute("aria-expanded", "false");
  navigation.dataset.open = "false";
}
menu.addEventListener("click", () => {
  const open = menu.getAttribute("aria-expanded") !== "true";
  menu.setAttribute("aria-expanded", String(open));
  navigation.dataset.open = String(open);
});
navigation.addEventListener("click", (event) => {
  if (event.target.closest("a")) closeMenu();
});
document.addEventListener("keydown", (event) => {
  if (event.key === "Escape" && menu.getAttribute("aria-expanded") === "true") {
    closeMenu();
    menu.focus();
  }
});

const tablist = document.querySelector(".code-tabs");
const tabs = [...tablist.querySelectorAll("button")];
tablist.setAttribute("role", "tablist");
function selectTab(selected, focus = false) {
  for (const tab of tabs) {
    const active = tab === selected;
    tab.setAttribute("aria-selected", String(active));
    tab.tabIndex = active ? 0 : -1;
    document.getElementById(tab.dataset.panel).hidden = !active;
  }
  if (focus) selected.focus();
}
for (const tab of tabs) {
  tab.setAttribute("role", "tab");
  tab.setAttribute("aria-controls", tab.dataset.panel);
  const panel = document.getElementById(tab.dataset.panel);
  panel.setAttribute("role", "tabpanel");
  panel.tabIndex = 0;
  tab.addEventListener("click", () => selectTab(tab));
  tab.addEventListener("keydown", (event) => {
    const index = tabs.indexOf(tab);
    let next;
    if (event.key === "ArrowRight") next = tabs[(index + 1) % tabs.length];
    if (event.key === "ArrowLeft")
      next = tabs[(index + tabs.length - 1) % tabs.length];
    if (event.key === "Home") next = tabs[0];
    if (event.key === "End") next = tabs[tabs.length - 1];
    if (next) {
      event.preventDefault();
      selectTab(next, true);
    }
  });
}
selectTab(tabs[0]);

const copy = document.querySelector("#copy-start");
if (navigator.clipboard && navigator.clipboard.writeText) {
  copy.hidden = false;
  copy.addEventListener("click", async () => {
    const status = document.querySelector("#copy-status");
    try {
      await navigator.clipboard.writeText(
        document.querySelector("#start-commands").textContent,
      );
      status.textContent =
        "Copied. Run these commands from your Flux checkout.";
    } catch (_) {
      status.textContent =
        "Clipboard unavailable. Select and copy the commands above.";
    }
  });
}

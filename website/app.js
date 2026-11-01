"use strict";
import { getReleaseDownload } from "./release.mjs";
import { matchesAction } from "./catalog.mjs";

const search = document.getElementById("action-search");
const groups = [...document.querySelectorAll(".action-group")];
const categoryButtons = [...document.querySelectorAll(".action-filters button")];
const defaultOpen = new Map(groups.map((group) => [group, group.open]));
let selectedCategory = "all";
function filterActions() {
  let total = 0;
  const filtering = Boolean(search.value.trim()) || selectedCategory !== "all";
  for (const group of groups) {
    let visible = 0;
    for (const action of group.querySelectorAll("[data-action-id]")) {
      const matches = matchesAction(`${action.textContent} ${action.dataset.keywords || ""}`,
        search.value, group.dataset.category, selectedCategory);
      action.hidden = !matches;
      if (matches) visible++;
    }
    total += visible;
    group.hidden = visible === 0;
    group.open = filtering ? visible > 0 : defaultOpen.get(group);
    group.querySelector(".category-count").textContent = String(visible).padStart(2, "0");
  }
  document.getElementById("action-count").textContent = filtering
    ? `${total} matching ${total === 1 ? "action" : "actions"}`
    : "51 actions · plus Off for any edge";
  document.getElementById("action-empty").hidden = total !== 0;
  for (const button of categoryButtons)
    button.setAttribute("aria-pressed", String(button.dataset.category === selectedCategory));
}
search.addEventListener("input", filterActions);
for (const button of categoryButtons) button.addEventListener("click", () => {
  selectedCategory = button.dataset.category;
  filterActions();
});
document.getElementById("clear-action-search").addEventListener("click", () => {
  search.value = "";
  selectedCategory = "all";
  filterActions();
  search.focus();
});
document.getElementById("library-toolbar").hidden = false;

// This preview never reads the trackpad or changes system settings.
const defaults = { brightness: 68, volume: 42 };
for (const name of Object.keys(defaults)) {
  const slider = document.getElementById(name);
  const edge = slider.closest(".edge");
  const bubble = document.querySelector(`.${name}-bubble`);
  const render = () => {
    document.getElementById(`${name}-fill`).style.height = `${slider.value}%`;
    document.getElementById(`${name}-bubble-value`).textContent = slider.value;
    slider.setAttribute("aria-valuetext", `${slider.value} percent`);
  };
  const activate = () => {
    edge.classList.add("is-active");
    bubble.classList.add("is-active");
  };
  const deactivate = () => {
    edge.classList.remove("is-active");
    bubble.classList.remove("is-active");
  };
  slider.addEventListener("input", render);
  slider.addEventListener("pointerdown", activate);
  slider.addEventListener("pointerup", deactivate);
  slider.addEventListener("pointercancel", deactivate);
  slider.addEventListener("lostpointercapture", deactivate);
  slider.addEventListener("focus", activate);
  slider.addEventListener("blur", deactivate);
  render();
}
document.getElementById("reset-demo").addEventListener("click", () => {
  for (const [name, value] of Object.entries(defaults)) {
    const slider = document.getElementById(name);
    slider.value = value;
    slider.dispatchEvent(new Event("input"));
  }
});

const hapticCopy = {
  soft: "A soft, subtle acknowledgement.",
  standard: "A balanced, familiar tap.",
  crisp: "A crisp, distinct confirmation.",
};
for (const button of document.querySelectorAll("[data-haptic]")) {
  button.addEventListener("click", () => {
    for (const item of document.querySelectorAll("[data-haptic]"))
      item.setAttribute("aria-pressed", String(item === button));
    document.querySelector(".haptics-card").dataset.style =
      button.dataset.haptic;
    document.getElementById("haptic-description").textContent =
      hapticCopy[button.dataset.haptic];
  });
}

// A single public request, no token, cookies, analytics, or persistent storage.
// The verified static DMG remains usable offline or if GitHub rate-limits requests.
async function refreshRelease() {
  try {
    const response = await fetch(
      "https://api.github.com/repos/0x1p0/sway-application/releases/latest",
      {
        credentials: "omit",
        referrerPolicy: "no-referrer",
        signal: AbortSignal.timeout(5000),
      },
    );
    if (!response.ok) return;
    const release = getReleaseDownload(await response.json());
    if (!release) return;
    for (const link of document.querySelectorAll(".download-link"))
      link.href = release.url;
    for (const label of document.querySelectorAll(".release-version"))
      label.textContent = release.version;
  } catch {
    /* Static release links are the intentional fallback. */
  }
}
refreshRelease();

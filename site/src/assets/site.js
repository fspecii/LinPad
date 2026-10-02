(() => {
  const root = document.documentElement;
  const themeBtn = document.getElementById("theme-toggle");
  const prefersLight = window.matchMedia("(prefers-color-scheme: light)");

  const effectiveTheme = () => root.dataset.theme || (prefersLight.matches ? "light" : "dark");
  const syncThemeButton = () => {
    if (!themeBtn) return;
    const next = effectiveTheme() === "dark" ? "light" : "dark";
    themeBtn.setAttribute("aria-label", `Switch to ${next} theme`);
  };

  themeBtn?.addEventListener("click", () => {
    const next = effectiveTheme() === "dark" ? "light" : "dark";
    root.dataset.theme = next;
    try { localStorage.setItem("linpad-theme", next); } catch (_) { /* storage blocked: keep the in-page choice */ }
    syncThemeButton();
  });
  syncThemeButton();

  const menuBtn = document.getElementById("menu-toggle");
  const links = document.getElementById("nav-links");
  menuBtn?.addEventListener("click", () => {
    const open = links.classList.toggle("open");
    menuBtn.setAttribute("aria-expanded", String(open));
  });

  document.querySelectorAll("[data-copy]").forEach((button) => {
    button.addEventListener("click", async () => {
      const text = document.getElementById(button.dataset.copy)?.textContent?.trim();
      if (!text) return;
      try {
        await navigator.clipboard.writeText(text);
        button.textContent = "Copied";
      } catch (_) {
        button.textContent = "Select and copy";
      }
      setTimeout(() => { button.textContent = "Copy"; }, 1800);
    });
  });

  const filters = document.querySelectorAll("[data-filter]");
  filters.forEach((button) => {
    button.addEventListener("click", () => {
      const value = button.dataset.filter;
      filters.forEach((b) => b.setAttribute("aria-pressed", String(b === button)));
      document.querySelectorAll("[data-kind]").forEach((card) => {
        card.hidden = value !== "all" && !card.dataset.kind.split(" ").includes(value);
      });
    });
  });
})();

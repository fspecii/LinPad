(() => {
  const root = document.documentElement;
  const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)");

  const themeBtn = document.getElementById("theme-toggle");
  const currentTheme = () => (root.dataset.theme === "light" ? "light" : "dark");
  const syncThemeButton = () => {
    themeBtn?.setAttribute("aria-label", `Switch to ${currentTheme() === "dark" ? "light" : "dark"} theme`);
  };
  themeBtn?.addEventListener("click", () => {
    const next = currentTheme() === "dark" ? "light" : "dark";
    if (next === "light") root.dataset.theme = "light";
    else delete root.dataset.theme;
    try { localStorage.setItem("linpad-theme", next); } catch (_) { /* storage blocked: the choice lasts for this page */ }
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

  // Hero sequence. CSS drives --p from a scroll timeline where supported; otherwise this sets it.
  // Either way, .is-done makes the final buttons reachable only once they are visible.
  const seq = document.querySelector(".seq");
  if (seq) {
    const cssDriven = CSS.supports("animation-timeline: view()");
    let queued = false;
    const update = () => {
      queued = false;
      if (reducedMotion.matches) {
        seq.classList.add("is-done");
        return;
      }
      const rect = seq.getBoundingClientRect();
      const travel = rect.height - window.innerHeight;
      const progress = travel > 0 ? Math.min(1, Math.max(0, -rect.top / travel)) : 1;
      if (!cssDriven) seq.style.setProperty("--p", progress.toFixed(4));
      seq.classList.toggle("is-done", progress > 0.89);
    };
    const queue = () => {
      if (!queued) { queued = true; requestAnimationFrame(update); }
    };
    window.addEventListener("scroll", queue, { passive: true });
    window.addEventListener("resize", queue);
    reducedMotion.addEventListener?.("change", queue);
    update();
  }

  // Real apps: the sticky tablet shows the screen of the step in the middle of the viewport.
  const steps = document.querySelectorAll(".story-step");
  const screens = document.querySelectorAll(".story-screen");
  if (steps.length && "IntersectionObserver" in window) {
    const activate = (index) => {
      steps.forEach((step) => step.classList.toggle("is-active", step.dataset.step === index));
      screens.forEach((screen) => screen.classList.toggle("is-active", screen.dataset.step === index));
    };
    const observer = new IntersectionObserver((entries) => {
      entries.forEach((entry) => { if (entry.isIntersecting) activate(entry.target.dataset.step); });
    }, { rootMargin: "-45% 0px -45% 0px" });
    steps.forEach((step) => observer.observe(step));
    activate("0");
  }

  // Desktop looks.
  const lookImg = document.getElementById("look-img");
  const lookButtons = document.querySelectorAll("[data-look]");
  if (lookImg && lookButtons.length) {
    const picture = lookImg.parentElement;
    const [avifSource, webpSource] = picture.querySelectorAll("source");
    lookButtons.forEach((button) => {
      button.addEventListener("click", () => {
        lookButtons.forEach((b) => b.setAttribute("aria-pressed", String(b === button)));
        lookImg.classList.add("is-loading");
        avifSource.srcset = button.dataset.avif;
        webpSource.srcset = button.dataset.webp;
        lookImg.src = `/media/${button.dataset.look}-960.webp`;
        lookImg.alt = button.dataset.alt;
        document.getElementById("look-name").textContent = button.textContent;
        document.getElementById("look-text").textContent = button.dataset.caption;
      });
    });
    lookImg.addEventListener("load", () => lookImg.classList.remove("is-loading"));
  }

  // Colour palettes: recolour the preview terminal; T cycles, as on Omarchy.
  const palTerm = document.getElementById("pal-term");
  const palButtons = [...document.querySelectorAll("[data-palette]")];
  if (palTerm && palButtons.length) {
    const status = document.getElementById("pal-status");
    const apply = (button, announce) => {
      const palette = JSON.parse(button.dataset.palette);
      palTerm.style.setProperty("--t-bg", palette.bg);
      palTerm.style.setProperty("--t-fg", palette.fg);
      palette.ansi.forEach((color, i) => palTerm.style.setProperty(`--t-c${i}`, color));
      palButtons.forEach((b) => b.setAttribute("aria-pressed", String(b === button)));
      if (announce && status) status.textContent = `Palette: ${button.textContent}`;
    };
    palButtons.forEach((button) => button.addEventListener("click", () => apply(button, false)));
    document.addEventListener("keydown", (event) => {
      if (event.key !== "t" && event.key !== "T") return;
      if (event.metaKey || event.ctrlKey || event.altKey) return;
      const target = event.target;
      if (target instanceof HTMLElement && (target.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(target.tagName))) return;
      const current = palButtons.findIndex((b) => b.getAttribute("aria-pressed") === "true");
      const step = event.shiftKey ? -1 : 1;
      apply(palButtons[(current + step + palButtons.length) % palButtons.length], true);
    });
  }
})();

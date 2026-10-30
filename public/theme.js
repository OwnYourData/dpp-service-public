// Light/dark switch of the start page and the privacy policy. The choice is
// shared with the Knowledge Base on the same host (same key in localStorage):
// without a choice the page follows the system setting; a choice that equals
// the system setting is not stored. Loaded in <head> without defer, so that
// the theme is set before the page is drawn.
(function () {
  "use strict";
  var KEY = "kb-theme";
  var root = document.documentElement;
  try {
    var stored = window.localStorage.getItem(KEY);
    if (stored === "light" || stored === "dark") root.setAttribute("data-theme", stored);
  } catch (e) {
    // Without storage the page follows the system setting.
  }

  function wire() {
    var button = document.getElementById("theme-toggle");
    if (!button) return;
    var media = window.matchMedia("(prefers-color-scheme: dark)");
    function system() { return media.matches ? "dark" : "light"; }
    function current() { return root.getAttribute("data-theme") || system(); }
    function show() {
      var dark = current() === "dark";
      button.setAttribute("data-mode", dark ? "dark" : "light");
      button.setAttribute("aria-label", dark ? "Switch to light mode" : "Switch to dark mode");
      button.title = button.getAttribute("aria-label");
    }
    button.addEventListener("click", function () {
      var next = current() === "dark" ? "light" : "dark";
      try {
        if (next === system()) {
          root.removeAttribute("data-theme");
          window.localStorage.removeItem(KEY);
        } else {
          root.setAttribute("data-theme", next);
          window.localStorage.setItem(KEY, next);
        }
      } catch (e) {
        root.setAttribute("data-theme", next);
      }
      show();
    });
    if (media.addEventListener) media.addEventListener("change", show);
    button.hidden = false;
    show();
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", wire);
  } else {
    wire();
  }
})();

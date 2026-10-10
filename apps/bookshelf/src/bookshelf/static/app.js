// Progressive enhancement only: every page works with this file absent.

(() => {
  "use strict";

  const debounce = (fn, wait) => {
    let timer;
    return (...args) => {
      clearTimeout(timer);
      timer = setTimeout(() => fn(...args), wait);
    };
  };

  // Search as you type, but only on the local catalogue -- identification hits external
  // services and stays an explicit submit.
  const form = document.getElementById("live-search");
  const results = document.getElementById("results");

  if (form && results) {
    const input = form.querySelector("input[name=q]");
    let inFlight = null;

    const run = debounce(async () => {
      const query = input.value.trim();
      if (query.length < 2) return;

      if (inFlight) inFlight.abort();
      inFlight = new AbortController();
      try {
        const response = await fetch(
          `/search?partial=1&q=${encodeURIComponent(query)}`,
          { signal: inFlight.signal, headers: { "HX-Request": "1" } },
        );
        if (!response.ok) return;
        results.innerHTML = await response.text();
        history.replaceState(null, "", `/search?q=${encodeURIComponent(query)}`);
      } catch (error) {
        if (error.name !== "AbortError") throw error;
      }
    }, 220);

    input.addEventListener("input", run);
    form.addEventListener("submit", (event) => {
      // Already showing live results; no need to reload the page.
      if (results.childElementCount) event.preventDefault();
    });
  }
})();

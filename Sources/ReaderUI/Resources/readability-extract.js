(function () {
  try {
    if (typeof Readability !== "function") {
      return JSON.stringify({ error: "Readability is not loaded" });
    }
    var source = document.cloneNode(true);
    var parsed = new Readability(source).parse();
    if (!parsed || !parsed.content) {
      var body = document.body ? document.body.innerHTML : "";
      if (!body) {
        return JSON.stringify({ error: "Could not extract an article from this page." });
      }
      return JSON.stringify({
        title: document.title || "",
        byline: "",
        content: body,
        textContent: document.body ? (document.body.innerText || "") : "",
        excerpt: "",
        lang: document.documentElement.lang || ""
      });
    }
    return JSON.stringify({
      title: parsed.title || document.title || "",
      byline: parsed.byline || "",
      content: parsed.content || "",
      textContent: parsed.textContent || "",
      excerpt: parsed.excerpt || "",
      lang: parsed.lang || document.documentElement.lang || ""
    });
  } catch (e) {
    return JSON.stringify({ error: e && e.message ? e.message : String(e) });
  }
})();

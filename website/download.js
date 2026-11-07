const LATEST_INSTALLER = "https://github.com/dev-olly/kodi-reader/releases/latest/download/KodiReader.dmg";
const RELEASES_API = "https://api.github.com/repos/dev-olly/kodi-reader/releases/latest";

(function wireDownload() {
  const buttons = document.querySelectorAll("[data-download]");
  const versionEl = document.getElementById("version");
  if (!buttons.length) return;

  buttons.forEach((button) => { button.href = LATEST_INSTALLER; });

  fetch(RELEASES_API, {
    headers: { Accept: "application/vnd.github+json" },
  })
    .then(function (res) {
      if (!res.ok) return null;
      return res.json();
    })
    .then(function (release) {
      if (!release) return;

      var assets = release.assets || [];
      var dmg = null;
      for (var i = 0; i < assets.length; i++) {
        if (String(assets[i].name).toLowerCase().endsWith(".dmg")) {
          dmg = assets[i];
          break;
        }
      }

      if (dmg && dmg.browser_download_url) {
        buttons.forEach((button) => { button.href = dmg.browser_download_url; });
      }

      if (release.tag_name && versionEl) {
        versionEl.textContent = " · " + release.tag_name;
      }
    })
    .catch(function () {
      // Keep the direct latest-installer link if release metadata is unavailable.
    });
})();

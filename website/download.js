(function wireDownloads() {
  "use strict";

  const MAC_INSTALLER = "https://github.com/dev-olly/kodi-reader/releases/download/v0.4.11/KodiReader.dmg";
  const RELEASES_API = "https://api.github.com/repos/dev-olly/kodi-reader/releases?per_page=30";
  const REPOSITORY_PATH = "/dev-olly/kodi-reader/releases/download/";
  const macLinks = document.querySelectorAll('[data-download-platform="macos"], [data-download]');
  const config = readConfig();

  // This immutable installer also works without JavaScript or release metadata.
  macLinks.forEach(link => { link.href = MAC_INSTALLER; });

  Promise.all([
    fetchJson(RELEASES_API, { Accept: "application/vnd.github+json" }),
    config.manifest ? Promise.resolve(config.manifest) : fetchJson(config.manifestUrl),
  ]).then(([releases, manifest]) => {
    if (!Array.isArray(releases)) return;
    updateMac(releases);
    updateDesktop(releases, manifest);
  }).catch(() => {
    // Static availability and the known Mac installer remain usable offline.
  });

  function readConfig() {
    const defaults = { manifestUrl: "/api/desktop-update", channel: "stable" };
    try {
      const element = document.getElementById("desktop-download-config");
      if (!element) return defaults;
      const value = JSON.parse(element.textContent);
      const manifestUrl = new URL(value.manifestUrl || defaults.manifestUrl, window.location.href);
      // A release manifest is supplied by this website, never an arbitrary host.
      if (manifestUrl.origin !== window.location.origin || !/^https?:$/.test(manifestUrl.protocol)) return defaults;
      const beta = value.channel === "beta" && /^desktop-v\d+\.\d+\.\d+-(?:alpha|beta|rc)[A-Za-z0-9.-]*$/.test(value.releaseTag || "");
      return {
        manifestUrl: manifestUrl.href,
        channel: beta ? "beta" : "stable",
        releaseTag: beta ? value.releaseTag : undefined,
        // An explicitly selected beta may use metadata embedded by the release
        // publisher. It must still match published GitHub artifacts below.
        manifest: beta && value.manifest && typeof value.manifest === "object" ? value.manifest : undefined,
      };
    } catch {
      return defaults;
    }
  }

  async function fetchJson(url, headers) {
    try {
      const response = await fetch(url, { headers, signal: AbortSignal.timeout(10000) });
      if (!response.ok || response.status === 204) return null;
      return await response.json();
    } catch {
      return null;
    }
  }

  function safeAsset(asset, tag, pattern) {
    if (!asset || typeof asset.name !== "string" || !pattern.test(asset.name) || typeof asset.browser_download_url !== "string") return false;
    try {
      const url = new URL(asset.browser_download_url);
      const segments = url.pathname.slice(REPOSITORY_PATH.length).split("/");
      return url.origin === "https://github.com" && !url.username && !url.password && !url.search && !url.hash &&
        url.pathname.startsWith(REPOSITORY_PATH) && segments.length === 2 &&
        decodeURIComponent(segments[0]) === tag && decodeURIComponent(segments[1]) === asset.name;
    } catch {
      return false;
    }
  }

  function assetsFor(release) {
    return Array.isArray(release.assets) ? release.assets : [];
  }

  function updateMac(releases) {
    for (const release of releases) {
      if (!release || release.draft || release.prerelease || !/^v\d+\.\d+\.\d+$/.test(release.tag_name || "")) continue;
      const dmg = assetsFor(release).find(asset => safeAsset(asset, release.tag_name, /^KodiReader\.dmg$/i));
      if (!dmg) continue;
      macLinks.forEach(link => { link.href = dmg.browser_download_url; });
      setCardText("macos", "[data-platform-version]", release.tag_name);
      return;
    }
  }

  function updateDesktop(releases, manifest) {
    if (!manifest || typeof manifest.version !== "string" || !manifest.platforms || typeof manifest.platforms !== "object") return;
    const tag = "desktop-v" + manifest.version;
    const beta = config.channel === "beta";
    if (beta ? tag !== config.releaseTag : !/^desktop-v\d+\.\d+\.\d+$/.test(tag)) return;
    const release = releases.find(item => item && item.tag_name === tag && !item.draft && (beta ? item.prerelease === true : !item.prerelease));
    if (!release) return;
    const assets = assetsFor(release);
    if (!assets.some(asset => safeAsset(asset, tag, /^latest\.json$/))) return;

    const windows = signedTarget("windows-x86_64", /(?:x64|x86_64)[-_]setup\.exe$/i);
    const linux = signedTarget("linux-x86_64", /(?:amd64|x86_64|x64)\.AppImage$/i);
    // Public desktop editions launch together, after both signed updater
    // artifacts are present in the same published release.
    if (!windows || !linux) return;

    enablePackage("windows", "nsis", windows.browser_download_url, "Download for Windows");
    enablePackage("linux", "appimage", linux.browser_download_url, "Download AppImage");
    const deb = assets.find(asset => safeAsset(asset, tag, /(?:amd64|x86_64|x64)\.deb$/i));
    const rpm = assets.find(asset => safeAsset(asset, tag, /(?:amd64|x86_64|x64)\.rpm$/i));
    if (deb) enablePackage("linux", "deb", deb.browser_download_url);
    if (rpm) enablePackage("linux", "rpm", rpm.browser_download_url);

    for (const platform of ["windows", "linux"]) {
      setCardText(platform, "[data-platform-status]", beta ? "Public beta" : "Available now");
      setCardText(platform, "[data-platform-version]", "v" + manifest.version);
      const card = document.querySelector('[data-platform-card="' + platform + '"]');
      const status = card && card.querySelector("[data-platform-status]");
      if (status) {
        status.classList.remove("release-status-testing");
        status.classList.toggle("release-status-beta", beta);
      }
      const summary = document.querySelector('[data-platform-summary="' + platform + '"]');
      if (summary) summary.textContent = beta ? "Public beta" : "Available now";
    }
    setCardText("windows", "[data-platform-note]", beta ? "A preview edition. Read the release notes before installing." : "Signed installer for Windows 11. Open the download to install Kodi Reader.");
    const packageNote = document.querySelector(".linux-packages > span");
    if (packageNote) packageNote.textContent = deb || rpm ? "Choose the package for your distribution" : "More package formats will appear here when available";
    const availability = document.querySelector(".download-heading > p > span");
    if (availability) availability.textContent = beta ? "Mac is available now. Windows and Linux are available as a public beta." : "Available for Mac, Windows 11, and Linux.";

    function signedTarget(key, pattern) {
      const target = manifest.platforms[key];
      if (!target || typeof target.url !== "string" || typeof target.signature !== "string" || !target.signature.trim() || target.signature.length > 16384) return null;
      const artifact = assets.find(asset => asset.browser_download_url === target.url && safeAsset(asset, tag, pattern));
      if (!artifact) return null;
      return assets.some(asset => asset.name === artifact.name + ".sig" && safeAsset(asset, tag, /\.sig$/)) ? artifact : null;
    }
  }

  function setCardText(platform, selector, value) {
    const card = document.querySelector('[data-platform-card="' + platform + '"]');
    const element = card && card.querySelector(selector);
    if (element) element.textContent = value;
  }

  function enablePackage(platform, kind, url, label) {
    document.querySelectorAll('[data-download-platform="' + platform + '"][data-download-package="' + kind + '"]').forEach(link => {
      link.href = url;
      link.removeAttribute("aria-disabled");
      link.removeAttribute("tabindex");
      link.removeAttribute("role");
      link.classList.remove("button-pending");
      if (label) {
        link.textContent = label + " ↓";
        link.setAttribute("aria-label", label + (config.channel === "beta" ? " public beta" : ""));
      }
    });
  }
})();

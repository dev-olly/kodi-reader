const requiredChecks = ['windows11', 'ubuntu2404Wayland', 'ubuntu2404X11', 'ubuntu2604Wayland', 'fedoraWayland', 'macDriveRoundTrip', 'offlineAudio', 'signedUpdateUpgrade', 'installerDataRetention'];

export function bundleConfiguration({ platform, release = false, env = {}, acceptance }) {
  if (!['win32', 'linux'].includes(platform)) throw new Error('This packaging path builds Windows and Linux only. The public Mac app uses its existing signed native release.');
  const windows = platform === 'win32';
  const config = {
    bundle: {
      targets: windows ? ['nsis'] : ['appimage', 'deb', 'rpm'],
      externalBin: ['binaries/kodi-ffmpeg'],
      resources: { 'resources/ffmpeg/': 'ffmpeg/', 'resources/licenses/': 'licenses/', '../THIRD_PARTY_NOTICES.md': 'THIRD_PARTY_NOTICES.md' },
      createUpdaterArtifacts: false,
    },
  };
  if (!release) {
    config.productName = 'Kodi Reader Preview';
    config.identifier = 'com.olly.KodiReader.Desktop.Preview';
    return config;
  }
  for (const name of ['KODI_SUPABASE_URL', 'KODI_SUPABASE_PUBLISHABLE_KEY', 'KODI_GOOGLE_CLIENT_ID']) {
    if (!env[name]?.trim()) throw new Error(`${name} is required in a public release with account and Drive support.`);
  }
  const authURL = new URL(env.KODI_SUPABASE_URL);
  if (authURL.protocol !== 'https:' || authURL.username || authURL.password) throw new Error('The public sign-in URL must use HTTPS without credentials.');
  const key = env.KODI_UPDATER_PUBLIC_KEY;
  const endpoint = env.KODI_UPDATER_ENDPOINT || 'https://www.kodi-reader.app/api/desktop-update';
  if (!key || !endpoint || !env.TAURI_SIGNING_PRIVATE_KEY) throw new Error('A public updater key, HTTPS endpoint, and signing key are required.');
  const url = new URL(endpoint.replaceAll('{{target}}', 'target').replaceAll('{{arch}}', 'arch').replaceAll('{{current_version}}', 'version'));
  if (url.protocol !== 'https:' || url.username || url.password) throw new Error('Updater endpoint must be HTTPS without credentials.');
  if (requiredChecks.some(name => acceptance?.checks?.[name]?.passed !== true || !acceptance.checks[name].evidence)
      || Object.values(acceptance.checks).some(check => check.passed !== true || !check.evidence)) throw new Error('Native release acceptance is incomplete.');
  config.bundle.createUpdaterArtifacts = true;
  config.plugins = { updater: { pubkey: key, endpoints: [endpoint] } };
  if (windows) {
    const thumbprint = env.KODI_WINDOWS_CERTIFICATE_THUMBPRINT;
    const timestamp = env.KODI_WINDOWS_TIMESTAMP_URL;
    if (!thumbprint || !timestamp) throw new Error('Windows Authenticode certificate and timestamp service are required.');
    if (!/^https?:\/\//.test(timestamp)) throw new Error('Windows timestamp service must be an HTTP(S) URL.');
    config.bundle.windows = { certificateThumbprint: thumbprint, digestAlgorithm: 'sha256', timestampUrl: timestamp };
  }
  return config;
}

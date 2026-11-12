fn main() {
    // These are public client configuration, never server API keys. Google's
    // optional installed Desktop app client secret is also a public-client value.
    for name in [
        "KODI_SUPABASE_URL",
        "KODI_SUPABASE_PUBLISHABLE_KEY",
        "KODI_AI_BASE_URL",
        "KODI_AI_MODEL",
        "KODI_PAYMENTS_ENABLED",
        "KODI_GOOGLE_CLIENT_ID",
        "KODI_GOOGLE_CLIENT_SECRET",
    ] {
        println!("cargo:rerun-if-env-changed={name}");
        if let Ok(value) = std::env::var(name) {
            if !value.contains(['\r', '\n']) {
                println!("cargo:rustc-env={name}={value}");
            }
        }
    }
}

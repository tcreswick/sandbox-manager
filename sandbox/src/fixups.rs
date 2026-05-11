//! Fix-up script management: lookup, fetch-once caching, mapping parsing,
//! and distro → script selection.
//!
//! Files are fetched from a canonical GitHub raw URL on first need and
//! cached under `~/.config/sandbox/fixups/`. After the first fetch the
//! local copy is canonical and is never overwritten by sandbox.

use anyhow::{Context, Result, anyhow};
use regex::Regex;
use std::path::PathBuf;
use std::time::Duration;

/// Base URL for fetching fix-up scripts on first need.
/// Override at runtime with the `SANDBOX_FIXUPS_URL` env var.
const DEFAULT_BASE_URL: &str =
    "https://raw.githubusercontent.com/tcreswick/sandbox-manager/main/fixups/";

const HTTP_TIMEOUT_SECS: u64 = 15;

/// Resolve the local cache directory: `$XDG_CONFIG_HOME/sandbox/fixups/`
/// (falling back to `~/.config/sandbox/fixups/`).
pub fn cache_dir() -> Result<PathBuf> {
    let mut dir = dirs::config_dir()
        .ok_or_else(|| anyhow!("Could not resolve XDG config directory"))?;
    dir.push("sandbox");
    dir.push("fixups");
    Ok(dir)
}

fn base_url() -> String {
    std::env::var("SANDBOX_FIXUPS_URL").unwrap_or_else(|_| DEFAULT_BASE_URL.to_string())
}

/// Return the local cached path for `name`, fetching it from the canonical
/// GitHub URL on first need. After a successful fetch a one-time message is
/// printed to stdout. Subsequent calls are silent.
pub fn ensure_local(name: &str) -> Result<PathBuf> {
    let dir = cache_dir()?;
    let path = dir.join(name);
    if path.exists() {
        return Ok(path);
    }

    std::fs::create_dir_all(&dir)
        .with_context(|| format!("Failed to create {}", dir.display()))?;

    let url = format!("{}{}", base_url(), name);
    let body = fetch(&url).with_context(|| {
        format!(
            "Could not fetch {} and no local copy at {}.\n\
             Hint: place the file manually, check network connectivity, or set SANDBOX_FIXUPS_URL.",
            url,
            path.display()
        )
    })?;

    std::fs::write(&path, &body)
        .with_context(|| format!("Failed to write {}", path.display()))?;

    // Make .sh files executable for clarity even though we pipe via stdin.
    if name.ends_with(".sh") {
        use std::os::unix::fs::PermissionsExt;
        let mut perms = std::fs::metadata(&path)?.permissions();
        perms.set_mode(0o755);
        let _ = std::fs::set_permissions(&path, perms);
    }

    println!("[sandbox] Fetched {} → {}", name, path.display());
    println!(
        "[sandbox] This file is yours now — edit freely; sandbox will not overwrite it."
    );

    Ok(path)
}

fn fetch(url: &str) -> Result<Vec<u8>> {
    let agent = ureq::AgentBuilder::new()
        .timeout(Duration::from_secs(HTTP_TIMEOUT_SECS))
        .build();
    let response = agent
        .get(url)
        .call()
        .with_context(|| format!("HTTP request to {} failed", url))?;
    let mut buf = Vec::new();
    response
        .into_reader()
        .read_to_end(&mut buf)
        .with_context(|| format!("Failed to read response body from {}", url))?;
    Ok(buf)
}

/// One entry in the mapping table: a regex matched against
/// `/etc/os-release`'s `PRETTY_NAME` and the script file to use on match.
pub struct MappingEntry {
    pub pattern: Regex,
    pub script: String,
}

/// Load and parse `mapping.conf` from the cache (fetching it if absent).
///
/// Order is preserved; first match wins at selection time.
pub fn load_mapping() -> Result<Vec<MappingEntry>> {
    let path = ensure_local("mapping.conf")?;
    let text = std::fs::read_to_string(&path)
        .with_context(|| format!("Failed to read {}", path.display()))?;
    parse_mapping(&text, &path.display().to_string())
}

fn parse_mapping(text: &str, source: &str) -> Result<Vec<MappingEntry>> {
    let mut out = Vec::new();
    for (lineno, raw) in text.lines().enumerate() {
        let line = raw.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        // The last whitespace-separated token is the script filename;
        // everything before it is the regex (which may legitimately contain spaces).
        let (regex_src, script) = match line.rsplit_once(char::is_whitespace) {
            Some((r, s)) => (r.trim_end(), s.trim()),
            None => ("", ""),
        };
        if regex_src.is_empty() || script.is_empty() {
            return Err(anyhow!(
                "{}:{}: expected '<regex> <script>', got: {}",
                source,
                lineno + 1,
                raw
            ));
        }
        let pattern = Regex::new(regex_src).with_context(|| {
            format!("{}:{}: invalid regex '{}'", source, lineno + 1, regex_src)
        })?;
        out.push(MappingEntry {
            pattern,
            script: script.to_string(),
        });
    }
    Ok(out)
}

/// Return the script filename whose regex first matches `pretty_name`,
/// or `None` if no entry matches (in practice the trailing `.*` line in
/// the default mapping makes this always-Some).
pub fn select_script<'a>(
    pretty_name: &str,
    mapping: &'a [MappingEntry],
) -> Option<&'a str> {
    mapping
        .iter()
        .find(|m| m.pattern.is_match(pretty_name))
        .map(|m| m.script.as_str())
}

#[cfg(test)]
mod tests {
    use super::*;

    const SAMPLE: &str = r#"
# comment
^Ubuntu\b       debian.sh
^Debian\b       debian.sh
^Arch\b         arch.sh
^Alpine\b       alpine.sh
.*              default.sh
"#;

    fn parsed() -> Vec<MappingEntry> {
        parse_mapping(SAMPLE, "test").expect("parse")
    }

    #[test]
    fn parses_and_skips_comments_and_blanks() {
        assert_eq!(parsed().len(), 5);
    }

    #[test]
    fn matches_ubuntu() {
        let m = parsed();
        assert_eq!(select_script("Ubuntu 24.04.1 LTS", &m), Some("debian.sh"));
    }

    #[test]
    fn matches_debian() {
        let m = parsed();
        assert_eq!(
            select_script("Debian GNU/Linux 12 (bookworm)", &m),
            Some("debian.sh")
        );
    }

    #[test]
    fn matches_alpine() {
        let m = parsed();
        assert_eq!(select_script("Alpine Linux v3.20", &m), Some("alpine.sh"));
    }

    #[test]
    fn falls_back_to_default() {
        let m = parsed();
        assert_eq!(select_script("Some Weird Distro 7", &m), Some("default.sh"));
    }

    #[test]
    fn first_match_wins() {
        let text = "^Ubuntu 22\\.   ubuntu-22.sh\n^Ubuntu\\b       debian.sh\n";
        let m = parse_mapping(text, "test").unwrap();
        assert_eq!(select_script("Ubuntu 22.04.4 LTS", &m), Some("ubuntu-22.sh"));
        assert_eq!(select_script("Ubuntu 24.04.1 LTS", &m), Some("debian.sh"));
    }

    #[test]
    fn rejects_malformed_lines() {
        assert!(parse_mapping("just-one-token\n", "test").is_err());
    }
}

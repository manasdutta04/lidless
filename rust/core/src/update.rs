//! Checks GitHub for a newer release. The only network request Lidless makes.

use serde::{Deserialize, Serialize};

use crate::error::{LidlessError, Result};

pub const REPOSITORY: &str = "manasdutta04/lidless";
pub const VERSION: &str = env!("CARGO_PKG_VERSION");

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ReleaseInfo {
    pub version: String,
    pub page_url: String,
    pub download_url: Option<String>,
    pub download_name: Option<String>,
    pub notes: String,
}

#[derive(Debug, Clone, PartialEq)]
pub enum UpdateCheck {
    UpToDate(String),
    Available(ReleaseInfo),
    NoReleases,
}

fn parts(v: &str) -> Vec<u64> {
    let v = v.strip_prefix('v').unwrap_or(v);
    let core = v.split('-').next().unwrap_or(v);
    core.split('.').map(|p| p.parse().unwrap_or(0)).collect()
}

/// Numeric dotted-version comparison ("0.10.0" > "0.9.3").
pub fn is_newer(candidate: &str, current: &str) -> bool {
    let a = parts(candidate);
    let b = parts(current);
    for i in 0..a.len().max(b.len()) {
        let x = a.get(i).copied().unwrap_or(0);
        let y = b.get(i).copied().unwrap_or(0);
        if x != y {
            return x > y;
        }
    }
    false
}

/// The asset name suffix for this platform's installer.
pub fn asset_suffix() -> &'static str {
    match (std::env::consts::OS, std::env::consts::ARCH) {
        ("windows", _) => "-windows-x64.msi",
        ("linux", "aarch64") => "-linux-arm64.AppImage",
        ("linux", _) => "-linux-x64.AppImage",
        ("macos", _) => ".dmg",
        _ => "",
    }
}

pub fn parse(json: &serde_json::Value) -> Result<ReleaseInfo> {
    let tag = json["tag_name"]
        .as_str()
        .ok_or_else(|| LidlessError::System("Unexpected response from GitHub.".into()))?;
    let page = json["html_url"]
        .as_str()
        .ok_or_else(|| LidlessError::System("Unexpected response from GitHub.".into()))?;
    let suffix = asset_suffix();
    let asset = json["assets"].as_array().and_then(|a| {
        a.iter().find(|x| {
            x["name"]
                .as_str()
                .map(|n| !suffix.is_empty() && n.ends_with(suffix))
                .unwrap_or(false)
        })
    });
    Ok(ReleaseInfo {
        version: tag.strip_prefix('v').unwrap_or(tag).to_string(),
        page_url: page.to_string(),
        download_url: asset.and_then(|a| a["browser_download_url"].as_str().map(str::to_string)),
        download_name: asset.and_then(|a| a["name"].as_str().map(str::to_string)),
        notes: json["body"].as_str().unwrap_or("").to_string(),
    })
}

#[cfg(not(feature = "updates"))]
pub fn check(_current: &str) -> Result<UpdateCheck> {
    Err(LidlessError::System(
        "This build has no update checker.".into(),
    ))
}

#[cfg(not(feature = "updates"))]
pub fn download(_release: &ReleaseInfo) -> Result<std::path::PathBuf> {
    Err(LidlessError::System(
        "This build has no update checker.".into(),
    ))
}

#[cfg(feature = "updates")]
pub fn check(current: &str) -> Result<UpdateCheck> {
    let url = format!("https://api.github.com/repos/{REPOSITORY}/releases/latest");
    let response = ureq::get(&url)
        .set("Accept", "application/vnd.github+json")
        .set("User-Agent", &format!("Lidless/{current}"))
        .timeout(std::time::Duration::from_secs(15))
        .call();
    match response {
        Ok(r) => {
            let json: serde_json::Value = r
                .into_json()
                .map_err(|e| LidlessError::system("GitHub", e))?;
            let release = parse(&json)?;
            Ok(if is_newer(&release.version, current) {
                UpdateCheck::Available(release)
            } else {
                UpdateCheck::UpToDate(release.version)
            })
        }
        Err(ureq::Error::Status(404, _)) => Ok(UpdateCheck::NoReleases),
        Err(e) => Err(LidlessError::System(format!("Could not reach GitHub: {e}"))),
    }
}

/// Downloads the platform asset into the user's Downloads folder.
#[cfg(feature = "updates")]
pub fn download(release: &ReleaseInfo) -> Result<std::path::PathBuf> {
    let url = release.download_url.as_ref().ok_or_else(|| {
        LidlessError::System("This release has no installer for your platform.".into())
    })?;
    let dir = dirs::download_dir()
        .or_else(dirs::home_dir)
        .ok_or_else(|| LidlessError::System("No Downloads folder.".into()))?;
    let dest = dir.join(
        release
            .download_name
            .clone()
            .unwrap_or_else(|| format!("Lidless-{}", release.version)),
    );
    let resp = ureq::get(url)
        .timeout(std::time::Duration::from_secs(600))
        .call()
        .map_err(|e| LidlessError::System(format!("The download failed: {e}")))?;
    let mut file = std::fs::File::create(&dest)?;
    std::io::copy(&mut resp.into_reader(), &mut file)?;
    Ok(dest)
}

//! Browser profile registry.
//!
//! This file is the single source of truth for every browser constant exposed
//! to Dart. Profiles are thin wrappers around `wreq-util` presets, so TLS
//! parameters, HTTP/2 settings, header order and user agents all come from one
//! maintained upstream table.
//!
//! Note: `wreq-util`'s `safari_ios_26_2` preset ships a mismatched UA
//! (`CPU iPhone OS 18_7 ... Version/26.2`), so it is deliberately not exposed.

use serde::{Deserialize, Serialize};
use wreq::IntoEmulation;
use wreq::header::{HeaderMap, USER_AGENT};
use wreq_util::{Emulation as UtilEmulation, Platform, Profile};

/// A header name/value pair. Avoids tuples in the FFI surface.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HeaderPair {
    pub name: String,
    pub value: String,
}

/// Identity defaults owned by a native profile.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProfileInfo {
    pub profile_id: String,
    /// `safari` | `chrome`
    pub family: String,
    pub user_agent: String,
    /// Empty for Safari: Safari does not send `sec-ch-ua*`.
    pub client_hints: Vec<HeaderPair>,
}

/// Lightweight description used by `list_profiles`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProfileSummary {
    pub id: String,
    pub family: String,
    pub browser: String,
    pub version: String,
    /// Only Safari profiles can be paired with WKWebView on iOS.
    pub ios_compatible: bool,
}

struct Spec {
    id: &'static str,
    family: &'static str,
    browser: &'static str,
    version: &'static str,
    profile: Profile,
    platform: Platform,
    ios_compatible: bool,
}

const SPECS: &[Spec] = &[
    Spec {
        id: "safari_ios_26",
        family: "safari",
        browser: "Safari",
        version: "26.0",
        profile: Profile::SafariIos26,
        platform: Platform::IOS,
        ios_compatible: true,
    },
    Spec {
        id: "safari_ios_18_1_1",
        family: "safari",
        browser: "Safari",
        version: "18.1.1",
        profile: Profile::SafariIos18_1_1,
        platform: Platform::IOS,
        ios_compatible: true,
    },
    Spec {
        id: "safari_ios_17_4_1",
        family: "safari",
        browser: "Safari",
        version: "17.4.1",
        profile: Profile::SafariIos17_4_1,
        platform: Platform::IOS,
        ios_compatible: true,
    },
    Spec {
        id: "chrome_windows_149",
        family: "chrome",
        browser: "Chrome",
        version: "149",
        profile: Profile::Chrome149,
        platform: Platform::Windows,
        ios_compatible: false,
    },
    Spec {
        id: "chrome_windows_144",
        family: "chrome",
        browser: "Chrome",
        version: "144",
        profile: Profile::Chrome144,
        platform: Platform::Windows,
        ios_compatible: false,
    },
    Spec {
        id: "chrome_android_149",
        family: "chrome",
        browser: "Chrome",
        version: "149",
        profile: Profile::Chrome149,
        platform: Platform::Android,
        ios_compatible: false,
    },
    Spec {
        id: "chrome_android_144",
        family: "chrome",
        browser: "Chrome",
        version: "144",
        profile: Profile::Chrome144,
        platform: Platform::Android,
        ios_compatible: false,
    },
];

fn spec(profile_id: &str) -> Result<&'static Spec, String> {
    SPECS
        .iter()
        .find(|s| s.id == profile_id)
        .ok_or_else(|| format!("fingerprint.unsupported_profile:unknown profile {profile_id}"))
}

/// Builds the native emulation for a profile id.
pub(crate) fn emulation(profile_id: &str) -> Result<wreq::Emulation, String> {
    let spec = spec(profile_id)?;
    Ok(UtilEmulation::builder()
        .profile(spec.profile)
        .platform(spec.platform)
        .build()
        .into_emulation())
}

fn header_value(headers: &HeaderMap, name: &str) -> Option<String> {
    headers
        .get(name)
        .and_then(|value| value.to_str().ok())
        .map(ToOwned::to_owned)
}

/// Returns the user agent and client hints for a profile.
pub fn profile_info(profile_id: String) -> Result<ProfileInfo, String> {
    let spec = spec(&profile_id)?;
    let emulation = emulation(&profile_id)?;

    let user_agent = header_value(&emulation.headers, USER_AGENT.as_str())
        .ok_or_else(|| format!("fingerprint.unsupported_profile:{profile_id} has no user agent"))?;

    let mut client_hints = Vec::new();
    for name in ["sec-ch-ua", "sec-ch-ua-mobile", "sec-ch-ua-platform"] {
        if let Some(value) = header_value(&emulation.headers, name) {
            client_hints.push(HeaderPair {
                name: name.to_string(),
                value,
            });
        }
    }

    Ok(ProfileInfo {
        profile_id: profile_id.clone(),
        family: spec.family.to_string(),
        user_agent,
        client_hints,
    })
}

/// Lists every profile available to Dart.
pub fn list_profiles() -> Vec<ProfileSummary> {
    SPECS
        .iter()
        .map(|s| ProfileSummary {
            id: s.id.to_string(),
            family: s.family.to_string(),
            browser: s.browser.to_string(),
            version: s.version.to_string(),
            ios_compatible: s.ios_compatible,
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_profile_resolves() {
        for spec in SPECS {
            let info = profile_info(spec.id.to_string()).expect(spec.id);
            assert!(!info.user_agent.is_empty());
        }
    }

    #[test]
    fn safari_profiles_have_no_client_hints() {
        let info = profile_info("safari_ios_26".to_string()).unwrap();
        assert!(info.client_hints.is_empty());
        assert!(info.user_agent.contains("Version/26"));
        assert!(info.user_agent.contains("iPhone"));
    }

    #[test]
    fn chrome_profiles_expose_client_hints() {
        let info = profile_info("chrome_windows_149".to_string()).unwrap();
        let names: Vec<&str> = info.client_hints.iter().map(|h| h.name.as_str()).collect();
        assert_eq!(
            names,
            vec!["sec-ch-ua", "sec-ch-ua-mobile", "sec-ch-ua-platform"]
        );
        assert!(info.user_agent.contains("Chrome/149"));
    }

    #[test]
    fn android_and_windows_differ() {
        let windows = profile_info("chrome_windows_149".to_string()).unwrap();
        let android = profile_info("chrome_android_149".to_string()).unwrap();
        assert_ne!(windows.user_agent, android.user_agent);
        assert!(android.user_agent.contains("Android"));
    }

    #[test]
    fn unknown_profile_is_rejected() {
        let error = profile_info("netscape_4".to_string()).unwrap_err();
        assert!(error.starts_with("fingerprint.unsupported_profile:"));
    }
}

import Foundation

/// ─────────────────────────────────────────────────────────────────────────
///  BUILD CONFIGURATION — the only file a fork needs to touch.
///
///  Griasa is open source; these are the values that identify *whose* build
///  this is. Change them before running ./build.sh and the app is yours:
///  your feedback inbox, your donate page, your update feed. Every value is
///  optional — leave one empty and the related UI simply doesn't appear.
///
///  Code signing and bundle identity are configured elsewhere:
///  - signing identity: `CODESIGN_IDENTITY` env var for ./build.sh,
///    `DIST_SIGN_IDENTITY` for ./dist.sh (defaults: local dev cert / ad-hoc)
///  - bundle id + version: Support/Info.plist
/// ─────────────────────────────────────────────────────────────────────────
enum BuildConfig {
    /// Where the "Send Feedback" mail draft goes.
    /// Empty string → feedback buttons are hidden.
    static let supportEmail = "hayk@stari.am"

    /// Donation page opened by the ♥ button (Ko-fi, GitHub Sponsors, …).
    /// Empty string → donate buttons are hidden.
    static let donateURL = "https://ko-fi.com/griasa"

    /// GitHub repository ("owner/name") whose Releases feed powers the
    /// daily update check. Empty string → update checking is disabled.
    static let updateRepo = "Stari-am/griasa"

    /// Shown in the About/Welcome contexts and mail subjects.
    static let appName = "Griasa"
}

import Foundation

/// When to look for a new version, and how this copy is updated. Foundation
/// only, so `test.sh` can reach the rules.
enum UpdateRules {
    /// Griasa sits in the menu bar for weeks without a restart, so the check
    /// runs once a day while it is running, not only at launch.
    static let interval: TimeInterval = 86_400
    /// How often the running app asks whether the day has passed.
    static let tick: TimeInterval = 3_600
    static let caskName = "griasa"

    static func isDue(lastCheck: Date?, now: Date) -> Bool {
        guard let lastCheck else { return true }
        // A clock set back must not stop the checks until it catches up.
        return now.timeIntervalSince(lastCheck) >= interval || lastCheck > now
    }

    /// "v1.0.26" → "1.0.26".
    static func version(fromTag tag: String) -> String {
        tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    }

    static func isNewer(_ latest: String, than current: String) -> Bool {
        latest.compare(current, options: .numeric) == .orderedDescending
    }

    enum Install: Equatable {
        /// Installed with `brew install --cask griasa`: Homebrew updates it.
        case homebrew(brew: String)
        /// Installed from the DMG: the new one is downloaded from the release page.
        case direct
    }

    /// Homebrew's two usual places, Apple silicon first.
    static let brewPrefixes = ["/opt/homebrew", "/usr/local"]

    /// A copy in /Applications with a Griasa cask in Homebrew's Caskroom was
    /// installed by Homebrew, and updating it any other way would leave brew
    /// believing the old version is installed.
    static func install(appPath: String, exists: (String) -> Bool) -> Install {
        guard appPath.hasPrefix("/Applications/") else { return .direct }
        for prefix in brewPrefixes {
            let brew = prefix + "/bin/brew"
            if exists(prefix + "/Caskroom/" + caskName), exists(brew) { return .homebrew(brew: brew) }
        }
        return .direct
    }

    /// The script Terminal runs for a Homebrew update. The person already
    /// chose to update, so brew does not ask again. Griasa quits before it
    /// starts, so the app is not replaced under itself, and is opened again
    /// afterwards whether or not the update went through.
    static func homebrewScript(brew: String, bundleID: String) -> String {
        """
        #!/bin/zsh
        echo "Updating Griasa with Homebrew…"
        echo
        HOMEBREW_NO_ASK=1 '\(brew)' upgrade --cask \(caskName)
        result=$?
        echo
        if [ $result -eq 0 ]; then
          echo "Done. Griasa is opening again; this window can be closed."
        else
          echo "Homebrew could not update Griasa (see above). The installed version is opening again."
        fi
        open -b '\(bundleID)'
        """
    }
}

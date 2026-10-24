cask "griasa" do
  version "@VERSION@"
  sha256 "@DMG_SHA256@"

  url "https://github.com/Stari-am/griasa/releases/download/v#{version}/Griasa-#{version}.dmg"
  name "Griasa"
  desc "Local-first meeting memory: who promised what, briefs and dictation"
  homepage "https://stari-am.github.io/griasa/"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :sonoma"

  app "Griasa.app"

  zap trash: [
    "~/Library/Application Support/Griasa",
    "~/Library/Preferences/am.stari.griasa.plist",
  ]
end

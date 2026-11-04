cask "griasa" do
  version "@VERSION@"
  sha256 "@DMG_SHA256@"

  url "https://github.com/Stari-am/griasa/releases/download/v#{version}/Griasa-#{version}.dmg"
  name "Griasa"
  desc "Remembers what was promised in your meetings, on your Mac"
  homepage "https://stari-am.github.io/griasa/"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :sonoma"
  # The speech and AI engines Griasa would otherwise install with brew on first launch.
  depends_on formula: ["whisper.cpp", "llama.cpp"]

  app "Griasa.app"

  zap trash: [
    "~/Library/Application Support/Griasa",
    "~/Library/Preferences/am.stari.griasa.plist",
  ]
end

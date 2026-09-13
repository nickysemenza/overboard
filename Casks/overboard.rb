cask "overboard" do
  version "0.4.0"
  # `version` and `sha256` are maintained by .github/workflows/release.yml,
  # which commits the bump to main after each release's zip is uploaded, so a
  # tap pointed at this repo upgrades on its own. `:no_check` is only the
  # pre-first-release placeholder; the workflow replaces it with a real hash.
  sha256 :no_check

  url "https://github.com/nickysemenza/overboard/releases/download/v#{version}/Overboard-#{version}.zip"
  name "Overboard"
  desc "Menu-bar launcher and clipboard manager"
  homepage "https://github.com/nickysemenza/overboard"

  livecheck do
    url :url
    strategy :github_latest
  end

  # :tahoe is macOS 26, the oldest release Overboard builds against.
  depends_on macos: ">= :tahoe"

  app "Overboard.app"

  zap trash: [
    "~/Library/Application Support/Overboard",
    "~/Library/Preferences/com.nickysemenza.overboard.plist",
    "~/Library/Saved Application State/com.nickysemenza.overboard.savedState",
    "~/Library/HTTPStorages/com.nickysemenza.overboard",
    "~/Library/Caches/com.nickysemenza.overboard",
  ]
end

cask "overboard" do
  version "0.4.0"
  # The Release workflow prints the released zip's `sha256 "…"` line into its
  # job summary; paste it here when bumping `version`. `:no_check` is a
  # placeholder so the cask is installable from a local checkout, not a claim
  # that the download is unverified upstream.
  sha256 :no_check

  url "https://github.com/nickysemenza/overboard/releases/download/v#{version}/Overboard-#{version}.zip"
  name "Overboard"
  desc "Menu-bar launcher and clipboard manager"
  homepage "https://github.com/nickysemenza/overboard"

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

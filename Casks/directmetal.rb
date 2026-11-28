cask "directmetal" do
  version "1.2.0"
  sha256 "278354945984006f0512502d11f2a250d5759afa25587150bda0df3b01f65719"

  url "https://github.com/amoham42/DirectMetal/releases/download/v#{version}/DirectMetal-Lite-macOS-arm64.dmg"
  name "DirectMetal"
  desc "Apple Silicon direct-to-Metal 3/4 runtime for Windows DirectX 9/10/11/12 games"
  homepage "https://github.com/amoham42/DirectMetal"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on arch: :arm64
  depends_on macos: ">= :sequoia"

  app "DirectMetal-Lite.app"
  binary "#{appdir}/DirectMetal-Lite.app/Contents/MacOS/DirectMetal", target: "directmetal"

  postflight do
    # Remove Gatekeeper quarantine on ad-hoc signed community builds; no-op once notarized.
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/DirectMetal-Lite.app"],
                   must_succeed: false
  end

  caveats <<~EOS
    Verify your Apple Silicon setup anytime with:
      directmetal doctor

    Enable native zsh or bash tab completions:
      eval "$(directmetal completions zsh)"
  EOS

  zap trash: [
    "~/Library/Application Support/DirectMetal",
    "~/Library/Caches/DirectMetal",
    "~/Library/Preferences/dev.directmetal.DirectMetal.plist",
  ]
end

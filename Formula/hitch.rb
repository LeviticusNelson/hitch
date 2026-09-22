class Hitch < Formula
  desc "Cursor models on the APIs your harness already speaks"
  homepage "https://github.com/LeviticusNelson/hitch"
  version "0.2.0"
  license "MIT"

  on_macos do
    on_arm do
      url "https://github.com/LeviticusNelson/hitch/releases/download/v0.2.0/hitch-aarch64-macos"
      sha256 "0000000000000000000000000000000000000000000000000000000000000000"
    end
    on_intel do
      url "https://github.com/LeviticusNelson/hitch/releases/download/v0.2.0/hitch-x86_64-macos"
      sha256 "0000000000000000000000000000000000000000000000000000000000000000"
    end
  end

  on_linux do
    on_arm do
      url "https://github.com/LeviticusNelson/hitch/releases/download/v0.2.0/hitch-aarch64-linux"
      sha256 "0000000000000000000000000000000000000000000000000000000000000000"
    end
    on_intel do
      url "https://github.com/LeviticusNelson/hitch/releases/download/v0.2.0/hitch-x86_64-linux"
      sha256 "0000000000000000000000000000000000000000000000000000000000000000"
    end
  end

  def install
    if OS.mac?
      bin.install Dir["hitch-*"].first => "hitch"
    else
      bin.install Dir["hitch-*"].first => "hitch"
    end
  end

  def caveats
    <<~EOS
      The downloaded binary contains the Grok plugin. No git clone.

        hitch install-plugin
        ~/.hitch/fetch-bridge.sh
        # set CURSOR_API_KEY in ~/.hitch/env
        ~/.hitch/start.sh

      Checksums in this formula are placeholders until the v0.2.0
      release assets exist. Replace them with `shasum -a 256` of each asset.
    EOS
  end

  test do
    assert_match "hitch #{version}", shell_output("#{bin}/hitch version")
  end
end

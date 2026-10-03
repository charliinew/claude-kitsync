class ClaudeKitsync < Formula
  desc "Sync Claude Code configuration across machines via git"
  homepage "https://github.com/charliinew/claude-kitsync"
  url "https://github.com/charliinew/claude-kitsync/releases/download/v1.2.1/claude-kitsync-v1.2.1.tar.gz"
  sha256 "eab8a8ca8e1263485c040c179fa37ef2cab2a31d10f7d64c46319ac7aed2ddf4"
  license "MIT"
  head "https://github.com/charliinew/claude-kitsync.git", branch: "main"

  livecheck do
    url :stable
    strategy :github_latest
  end

  def install
    # Completions first: Pathname#install moves files, so they must leave the
    # build dir before the rest of the tree is moved into libexec
    zsh_completion.install "completions/_claude-kitsync"
    bash_completion.install "completions/claude-kitsync.bash"
    libexec.install "bin", "lib", "kit", "templates", "VERSION"
    bin.install_symlink libexec/"bin/claude-kitsync"
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/claude-kitsync --version 2>&1")
  end
end

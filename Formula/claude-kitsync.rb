class ClaudeKitsync < Formula
  desc "Sync Claude Code configuration across machines via git"
  homepage "https://github.com/charliinew/claude-kitsync"
  url "https://github.com/charliinew/claude-kitsync/releases/download/v1.2.10/claude-kitsync-v1.2.10.tar.gz"
  sha256 "d0daa59a5445ce9e05577b55f3adb97c15c6da16684a4d4cb7fe71b9abd7da55"
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

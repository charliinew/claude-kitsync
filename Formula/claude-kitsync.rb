class ClaudeKitsync < Formula
  desc "Sync Claude Code configuration across machines via git"
  homepage "https://github.com/charliinew/claude-kitsync"
  url "https://github.com/charliinew/claude-kitsync/archive/refs/tags/v1.1.6.tar.gz"
  sha256 "0b8298e8fd88cf192ebab472bf5029336c6554b6fe3c2c7defa8bfd0795d189e"
  license "MIT"
  head "https://github.com/charliinew/claude-kitsync.git", branch: "main"

  def install
    libexec.install "bin", "lib", "kit", "templates", "completions", "VERSION"
    bin.install_symlink libexec/"bin/claude-kitsync"
    zsh_completion.install "completions/_claude-kitsync"
    bash_completion.install "completions/claude-kitsync.bash"
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/claude-kitsync --version 2>&1")
  end
end

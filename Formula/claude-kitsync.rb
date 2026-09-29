class ClaudeKitsync < Formula
  desc "Sync Claude Code configuration across machines via git"
  homepage "https://github.com/charliinew/claude-kitsync"
  url "https://github.com/charliinew/claude-kitsync/archive/refs/tags/v1.1.3.tar.gz"
  sha256 "8e77cddd30ca41f8fd978a808e10ce12d437e6d6f33c387417fae5af7c495788"
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

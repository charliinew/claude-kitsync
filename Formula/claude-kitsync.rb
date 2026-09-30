class ClaudeKitsync < Formula
  desc "Sync Claude Code configuration across machines via git"
  homepage "https://github.com/charliinew/claude-kitsync"
  url "https://github.com/charliinew/claude-kitsync/archive/refs/tags/v1.1.7.tar.gz"
  sha256 "919e8850419154b54afe555d5d646951e7b0f42a934614d8f0b3b7b88fe31453"
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

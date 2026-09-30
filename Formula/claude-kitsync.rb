class ClaudeKitsync < Formula
  desc "Sync Claude Code configuration across machines via git"
  homepage "https://github.com/charliinew/claude-kitsync"
  url "https://github.com/charliinew/claude-kitsync/archive/refs/tags/v1.1.5.tar.gz"
  sha256 "b46edc3100509f95cdebe1f87f6dad697ecb038a851490f96e40a6ad0913a7a1"
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

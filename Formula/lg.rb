# Homebrew Formula for lg
class Lg < Formula
  desc "Modern ls replacement with git status integration and full Unicode support"
  homepage "https://github.com/mariusei/lg"
  url "https://github.com/mariusei/lg/archive/refs/tags/v1.0.0.tar.gz"
  # sha256 will be set after first release - run:
  # curl -sL https://github.com/mariusei/lg/archive/refs/tags/v1.0.0.tar.gz | shasum -a 256
  sha256 "PLACEHOLDER_UPDATE_AFTER_RELEASE"
  license "MIT"
  head "https://github.com/mariusei/lg.git", branch: "main"

  depends_on "zig" => :build
  depends_on "utf8proc"

  def install
    # Build with Zig
    system "zig", "build", "-Doptimize=ReleaseFast", "--prefix", prefix

    # The binary is installed to prefix/bin/lg
    # Homebrew automatically adds this to PATH via symlinks
  end

  test do
    # Test that lg can run
    assert_match "Usage:", shell_output("#{bin}/lg --help")

    # Test basic functionality
    system bin/"lg"
  end
end

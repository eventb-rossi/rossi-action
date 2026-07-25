#!/usr/bin/env bash
#
# Install a released rossi binary onto the runner's PATH.
#
# The checksum manifest is fetched *before* the archive, and nothing the
# manifest does not vouch for is installed.
#
# Inputs (environment):
#   ROSSI_VERSION  optional, without the leading `v`; empty means latest
#   ROSSI_REPO     optional, defaults to eventb-rossi/rossi
#   RUNNER_OS / RUNNER_ARCH / RUNNER_TEMP / GITHUB_PATH   from the runner
set -euo pipefail

repo="${ROSSI_REPO:-eventb-rossi/rossi}"
version="${ROSSI_VERSION:-}"
version="${version#v}"

# The six targets rossi's release workflow builds.
case "${RUNNER_OS:-}-${RUNNER_ARCH:-}" in
  Linux-X64)     triple="x86_64-unknown-linux-gnu" ;;
  Linux-ARM64)   triple="aarch64-unknown-linux-gnu" ;;
  macOS-X64)     triple="x86_64-apple-darwin" ;;
  macOS-ARM64)   triple="aarch64-apple-darwin" ;;
  Windows-X64)   triple="x86_64-pc-windows-msvc" ;;
  Windows-ARM64) triple="aarch64-pc-windows-msvc" ;;
  *)
    echo "::error::no prebuilt rossi for ${RUNNER_OS:-?}/${RUNNER_ARCH:-?}" >&2
    exit 1
    ;;
esac

if [ "${RUNNER_OS}" = "Windows" ]; then
  ext="zip"
else
  ext="tar.gz"
fi
asset="rossi-${triple}.${ext}"
if [ -n "$version" ]; then
  base="https://github.com/${repo}/releases/download/v${version}"
else
  base="https://github.com/${repo}/releases/latest/download"
fi
dest="${RUNNER_TEMP:-/tmp}/rossi-${version:-latest}-${triple}"
mkdir -p "$dest"

# Read from stdin so the tool prints no filename: given a path holding a
# backslash — every path on Windows — GNU coreutils escapes the name and marks
# the line with a leading `\`, which ends up in the digest and never matches.
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum < "$1" | cut -d' ' -f1
  else
    shasum -a 256 < "$1" | cut -d' ' -f1
  fi
}

# The manifest first: a release without one is not a release we can verify, and
# a missing manifest is also the clearest signal that the release does not exist.
if ! curl -fsSL --retry 3 -o "$dest/SHA256SUMS" "$base/SHA256SUMS"; then
  echo "::error::no rossi release ${version:-latest} at https://github.com/${repo}/releases" >&2
  exit 1
fi

# Lines are `<sha256>  <asset>`; the binary-mode marker `*` may precede the name.
expected="$(awk -v want="$asset" '$NF == want || $NF == "*" want { print $1; exit }' "$dest/SHA256SUMS")"
if [ -z "$expected" ]; then
  echo "::error::${asset} is not listed in SHA256SUMS" >&2
  exit 1
fi

curl -fsSL --retry 3 -o "$dest/$asset" "$base/$asset"

actual="$(sha256_of "$dest/$asset")"
if [ "$(echo "$actual" | tr 'A-F' 'a-f')" != "$(echo "$expected" | tr 'A-F' 'a-f')" ]; then
  echo "::error::checksum mismatch for ${asset}: expected ${expected}, got ${actual}" >&2
  exit 1
fi

# Release archives are flat.
#
# Extract from inside $dest rather than passing it: a Windows path starts
# `D:\`, and tar reads an argument containing a colon as a remote host:path
# spec — "Cannot connect to D: resolve failed". Inside the directory the
# archive is a bare filename, so there is no colon left to misread.
#
# zip is not handled by tar here: inside Git Bash `tar` resolves to MSYS2's
# GNU tar, which cannot read zip at all ("This does not look like a tar
# archive"). Windows' own bsdtar could, but it is not the one on PATH.
# Expand-Archive ships with every Windows runner and needs no path
# translation, because the argument is a bare filename by this point.
case "$ext" in
  tar.gz) (cd "$dest" && tar -xzf "$asset") ;;
  zip)
    (cd "$dest" && powershell -NoProfile -NonInteractive -Command \
      "Expand-Archive -LiteralPath '${asset}' -DestinationPath (Get-Location) -Force")
    ;;
esac

binary="rossi"
[ "${RUNNER_OS}" = "Windows" ] && binary="rossi.exe"
if [ ! -f "$dest/$binary" ]; then
  echo "::error::${asset} did not contain ${binary}" >&2
  exit 1
fi

if [ "${RUNNER_OS}" != "Windows" ]; then
  chmod +x "$dest/rossi" "$dest/eventb-language-server" 2>/dev/null || true
fi

echo "$dest" >> "${GITHUB_PATH:?GITHUB_PATH is required}"
echo "installed rossi ${version:-latest} (${triple}) into ${dest}"

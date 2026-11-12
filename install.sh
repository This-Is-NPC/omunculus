#!/usr/bin/env bash
# install.sh - install omunculus from a GitHub release, through pacman.
#
#   curl -fsSL https://raw.githubusercontent.com/This-Is-NPC/omunculus/master/install.sh | bash
#
# It downloads the two Arch packages a release carries (the core and the
# apps), checks them against the release's SHA256SUMS, and hands them to
# `pacman -U`, so `sudo pacman -R omunculus omunculus-apps` takes every
# file of them off again.
#
# Environment:
#   VERSION   release to install, e.g. 0.1.0 or v0.1.0 (default: the latest)
#   REPO      GitHub repository (default: This-Is-NPC/omunculus)
#   BASE_URL  where the release files are, instead of GitHub's download URL
#   APPS=0    install the core package only, without the apps
#   DRY_RUN=1 download and verify, then print the pacman command instead
set -euo pipefail

REPO="${REPO:-This-Is-NPC/omunculus}"
VERSION="${VERSION:-}"
BASE_URL="${BASE_URL:-}"
APPS="${APPS:-1}"
DRY_RUN="${DRY_RUN:-0}"

say() { printf 'omunculus: %s\n' "$*" >&2; }
die() { say "$*"; exit 1; }

command -v pacman >/dev/null 2>&1 ||
  die "this installs an Arch package, and there is no pacman here."
[[ "$(uname -m)" == x86_64 ]] ||
  die "there is only an x86_64 package, and this machine is $(uname -m)."
command -v curl >/dev/null 2>&1 || die "curl is needed to download the release."

# The whole answer is read before it is searched: grep closing the pipe early
# would make curl fail under pipefail.
latest_tag() {
  local answer
  answer="$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest")" || return 1
  sed -nE '/"tag_name"/{s/.*"tag_name" *: *"([^"]+)".*/\1/p;q;}' <<<"$answer"
}

if [[ -z "$BASE_URL" ]]; then
  if [[ -z "$VERSION" ]]; then
    tag="$(latest_tag)" || die "found no published release of ${REPO}."
    [[ -n "$tag" ]] || die "${REPO} has no release yet."
  else
    tag="v${VERSION#v}"
  fi
  BASE_URL="https://github.com/${REPO}/releases/download/${tag}"
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

curl -fsSL "${BASE_URL}/SHA256SUMS" -o "$tmp/SHA256SUMS" ||
  die "could not download ${BASE_URL}/SHA256SUMS."

# The first column of the checksum file names each package: the core is
# omunculus-<version>, the apps omunculus-apps-<version>.
names=(omunculus)
[[ "$APPS" == 0 ]] || names+=(omunculus-apps)

files=()
for name in "${names[@]}"; do
  package="$(awk -v n="$name" '$2 ~ "^" n "-[0-9].*\\.pkg\\.tar\\.zst$" { print $2; exit }' "$tmp/SHA256SUMS")"
  [[ -n "$package" ]] || die "the release's SHA256SUMS names no ${name} package."

  say "downloading ${package}"
  curl -fsSL "${BASE_URL}/${package}" -o "$tmp/${package}" ||
    die "could not download ${BASE_URL}/${package}."
  (cd "$tmp" && grep -F " ${package}" SHA256SUMS | sha256sum -c --quiet -) ||
    die "${package} does not match the release's SHA256SUMS; nothing was installed."
  files+=("$tmp/${package}")
done

# `curl | bash` gives the script's own text as stdin, so pacman asks on the
# terminal instead, and is answered yes when there is none.
install=(sudo pacman -U "${files[@]}")
if [[ "$DRY_RUN" == 1 ]]; then
  printf '%s\n' "${install[*]}"
  exit 0
fi
if [[ -r /dev/tty ]] && (: </dev/tty) 2>/dev/null; then
  "${install[@]}" </dev/tty
else
  "${install[@]}" --noconfirm
fi

say "installed. Next: omunculus setup"
say "take it off again with: sudo pacman -R omunculus omunculus-apps"

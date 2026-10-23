#!/usr/bin/env nix
#! nix shell nixpkgs#bash nixpkgs#coreutils nixpkgs#curl nixpkgs#gnupg nixpkgs#gnused nixpkgs#gawk --command bash
# shellcheck shell=bash
#
# Bump package.nix to the newest claude-desktop in Anthropic's apt repo.
#
# Trust chain: key.asc (fingerprint pinned below, as published in
# https://code.claude.com/docs/en/desktop-linux) -> signed InRelease ->
# SHA256 of each Packages index -> SHA256 of each .deb, which must match
# what nix-prefetch-url computes on its own download.
#
#   ./update.sh            update package.nix if a newer version exists
#   ./update.sh --check    exit 1 if an update is available, change nothing
#   ./update.sh --force    re-prefetch and rewrite even if up to date
set -euo pipefail

REPO=https://downloads.claude.ai/claude-desktop/apt/stable
KEY_URL=https://downloads.claude.ai/claude-desktop/key.asc
FINGERPRINT=31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE
# nix system -> Debian arch
declare -A ARCHES=([x86_64-linux]=amd64 [aarch64-linux]=arm64)

mode=${1:-}
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
pkg=$here/package.nix
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export GNUPGHOME=$work/gnupg
mkdir -m 700 "$GNUPGHOME"

die() { echo "update.sh: $*" >&2; exit 1; }

curl -fsSL -o "$work/key.asc" "$KEY_URL"
gpg --quiet --import "$work/key.asc" 2>/dev/null
gpg --with-colons --fingerprint | grep -q "^fpr:::::::::$FINGERPRINT:$" \
  || die "signing key fingerprint is not $FINGERPRINT"

curl -fsSL -o "$work/InRelease" "$REPO/dists/stable/InRelease"
gpg --quiet --status-fd 1 --output "$work/Release" --decrypt "$work/InRelease" 2>/dev/null \
  | grep -q "^\[GNUPG:\] VALIDSIG $FINGERPRINT " \
  || die "InRelease signature does not verify against $FINGERPRINT"

# Newest version that exists for every architecture
for system in "${!ARCHES[@]}"; do
  arch=${ARCHES[$system]}
  index=main/binary-$arch/Packages
  want=$(awk -v f="$index" '/^SHA256:/{s=1;next} /^[^ ]/{s=0} s && $3==f {print $1}' "$work/Release")
  [[ -n $want ]] || die "$index not listed in InRelease"
  curl -fsSL -o "$work/Packages-$arch" "$REPO/dists/stable/$index"
  echo "$want  $work/Packages-$arch" | sha256sum --quiet -c - || die "$index hash mismatch"
  awk '/^Package: /{p=$2} /^Version: /&&p=="claude-desktop"{print $2}' "$work/Packages-$arch" \
    | sort -uV > "$work/versions-$arch"
done
version=$(cat "$work"/versions-* | sort -V | uniq -c \
  | awk -v n="${#ARCHES[@]}" '$1==n {print $2}' | sort -V | tail -n1)
[[ -n $version ]] || die "no version available for all architectures"

current=$(sed -n 's/^  version = "\(.*\)";$/\1/p' "$pkg")
echo "current: ${current:-?}  latest: $version"
if [[ $current == "$version" && $mode != --force ]]; then
  echo "up to date"
  exit 0
fi
[[ $mode == --check ]] && exit 1

block="  # BEGIN update.sh — this block is rewritten by ./update.sh, do not edit by hand
  version = \"$version\";
  srcs = {"
for system in x86_64-linux aarch64-linux; do
  arch=${ARCHES[$system]}
  stanza=$(awk -v RS= -v v="$version" '$0 ~ "\nVersion: " v "\n" && /^Package: claude-desktop\n/' "$work/Packages-$arch")
  file=$(sed -n 's/^Filename: //p' <<<"$stanza")
  sha=$(sed -n 's/^SHA256: //p' <<<"$stanza")
  [[ -n $file && -n $sha ]] || die "no $arch stanza for $version"
  echo "prefetching $REPO/$file"
  got=$(nix-prefetch-url --type sha256 "$REPO/$file" 2>/dev/null)
  got=$(nix hash convert --hash-algo sha256 --to base16 "$got")
  [[ $got == "$sha" ]] || die "$file: prefetched sha256 $got != signed index $sha"
  sri=$(nix hash convert --hash-algo sha256 --to sri "$got")
  block+="
    $system = {
      arch = \"$arch\";
      hash = \"$sri\";
    };"
done
block+="
  };
  # END update.sh"

awk -v block="$block" '
  /# BEGIN update.sh/ { print block; skip = 1; next }
  /# END update.sh/   { skip = 0; next }
  !skip
' "$pkg" > "$work/package.nix"
grep -q "version = \"$version\";" "$work/package.nix" || die "failed to rewrite package.nix"
cp "$work/package.nix" "$pkg"
echo "package.nix: ${current:-?} -> $version"

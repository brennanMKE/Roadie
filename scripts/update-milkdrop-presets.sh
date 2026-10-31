#!/bin/bash
# Copies MilkDropMetalKit's MIT presets (Presets/*.milk, gallery.json, README.md) at a tag into
# App/Visualization/Presets/, with a VERSION file naming the tag and commit (#0258).
# Host only, read-only on the package: `git archive` of the tag; never checks out, fetches or builds there.
# Usage: scripts/update-milkdrop-presets.sh [TAG] [REPO]   (defaults: 1.0.0, ../MilkDropMetalKit beside the repo)
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
tag="${1:-1.0.0}"
repo="${2:-$root/../MilkDropMetalKit}"
if ! commit="$(git -C "$repo" rev-parse --verify --quiet "$tag^{commit}")"; then
    echo "error: no tag $tag in $repo" >&2
    exit 1
fi
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
git -C "$repo" archive "$tag" Presets | tar -x -C "$tmp"
dest="$root/App/Visualization/Presets"
rm -rf "$dest"
mkdir -p "$dest"
cp "$tmp"/Presets/*.milk "$dest"/
for file in gallery.json README.md; do
    if [ -f "$tmp/Presets/$file" ]; then cp "$tmp/Presets/$file" "$dest"/; fi
done
printf 'MilkDropMetalKit %s\n%s\n' "$tag" "$commit" > "$dest/VERSION"
echo "Copied $(ls "$dest"/*.milk | wc -l | tr -d ' ') presets from MilkDropMetalKit $tag ($commit) to $dest"

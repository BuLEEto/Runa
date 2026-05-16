#!/usr/bin/env bash
# Fetch the version-pinned test fonts the CI matrix runs against.
# This is the CI equivalent of the symlinks a developer maintains
# in tests/fonts/ for local work. Outputs land in tests/fonts/.

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DEST="$ROOT/tests/fonts"
mkdir -p "$DEST"

fetch() {
  local url="$1" out="$2"
  echo "fetching $out"
  curl -fsSL --max-time 60 "$url" -o "$DEST/$out"
}

# Roboto (OFL-1.1) — Latin baseline.
fetch \
  "https://github.com/googlefonts/roboto-3-classic/raw/main/src/hinted/Roboto-Regular.ttf" \
  "Roboto-Regular.ttf" || \
fetch \
  "https://raw.githubusercontent.com/googlefonts/roboto/main/src/hinted/Roboto-Regular.ttf" \
  "Roboto-Regular.ttf"

# Inter Variable (OFL-1.1) — variable font load test.
fetch \
  "https://github.com/rsms/inter/raw/master/docs/font-files/InterVariable.ttf" \
  "InterVariable.ttf"

# Fira Code (OFL-1.1) — programming-font ligature test. Ships as a
# release zip; unpack the Regular variant.
echo "fetching FiraCode-Regular.ttf"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
curl -fsSL --max-time 60 \
  "https://github.com/tonsky/FiraCode/releases/download/6.2/Fira_Code_v6.2.zip" \
  -o "$tmp_dir/firacode.zip"
unzip -p "$tmp_dir/firacode.zip" 'ttf/FiraCode-Regular.ttf' > "$DEST/FiraCode-Regular.ttf"

# Twemoji-Mozilla (Apache-2.0 tools, CC-BY-4.0 artwork) — COLRv0 test.
fetch \
  "https://github.com/mozilla/twemoji-colr/releases/download/v0.7.0/Twemoji.Mozilla.ttf" \
  "Twemoji-Mozilla.ttf"

echo "fetched:"
ls -lh "$DEST"

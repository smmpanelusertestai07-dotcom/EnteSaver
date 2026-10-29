#!/usr/bin/env bash
# Downloads the UI fonts (static TTF instances) from the fontsource CDN on jsDelivr
# and writes a combined SIL OFL 1.1 license file.
# Usage: bash fetch_fonts.sh [out_dir]
set -euo pipefail
OUT="${1:-$(cd "$(dirname "$0")/../.." && pwd)/assets/fonts}"
mkdir -p "$OUT"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fetch() { # family-slug weight out-name
  local url="https://cdn.jsdelivr.net/fontsource/fonts/$1@latest/latin-$2-normal.ttf"
  if curl -fsS -o "$TMP/$3.ttf" "$url"; then
    mv "$TMP/$3.ttf" "$OUT/$3.ttf"; echo "ok  $3.ttf  <- $url"
  else # fall back to the npm package's WOFF2
    url="https://cdn.jsdelivr.net/npm/@fontsource/$1@5/files/$1-latin-$2-normal.woff2"
    curl -fsS -o "$OUT/$3.woff2" "$url"; echo "ok  $3.woff2 <- $url"
  fi
}
# Saved under the names scripts/ui.gd loads.
fetch rajdhani   600 ui_semibold
fetch rajdhani   700 ui_bold
fetch teko       600 number
fetch bebas-neue 400 title

for p in rajdhani teko bebas-neue; do
  curl -fsS -o "$TMP/LICENSE-$p" "https://cdn.jsdelivr.net/npm/@fontsource/$p@5/LICENSE"
done

{
  echo "Fonts in this folder are licensed under the SIL Open Font License, Version 1.1."
  echo "Fonts by their respective authors; downloaded from the Fontsource CDN (cdn.jsdelivr.net)."
  echo "Files are unmodified 'latin' subset static instances, saved under the names the game loads."
  echo
  echo "ui_semibold.ttf (Rajdhani SemiBold), ui_bold.ttf (Rajdhani Bold)"
  echo "  Copyright (c) 2014 Indian Type Foundry (info@indiantypefoundry.com)"
  echo "  https://fonts.google.com/specimen/Rajdhani"
  echo "number.ttf (Teko SemiBold)"
  echo "  Copyright 2023 The Teko Project Authors (https://www.github.com/googlefonts/teko)"
  echo "  (original design by Indian Type Foundry)"
  echo "title.ttf (Bebas Neue Regular)"
  echo "  Copyright 2019 The Bebas Neue Project Authors (https://github.com/dharmatype/Bebas-Neue)"
  echo "  (Bebas Neue by Ryoichi Tsunekawa, Dharma Type)"
  echo
  echo "No Reserved Font Names are claimed in the copyright notices above."
  echo
  echo "This Font Software is licensed under the SIL Open Font License, Version 1.1."
  echo "This license is copied below, and is also available with a FAQ at:"
  echo "https://openfontlicense.org"
  echo
  echo
  # OFL body (identical in all three packages) starts at the dashed header line.
  sed -n '8,$p' "$TMP/LICENSE-rajdhani"
} > "$OUT/LICENSE.txt"
echo "wrote $OUT/LICENSE.txt"

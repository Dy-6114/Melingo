#!/usr/bin/env bash
# Fails if Domain sources import infrastructure frameworks (TZ §14).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DOMAIN_SRC="$ROOT/Packages/Domain/Sources"

FORBIDDEN=(
  SwiftUI
  SwiftData
  Vision
  PDFKit
  Readium
  FoundationModels
  MLX
  AVFoundation
  AppKit
  UIKit
)

violations=0
while IFS= read -r -d '' file; do
  for mod in "${FORBIDDEN[@]}"; do
    if grep -E "^[[:space:]]*import[[:space:]]+${mod}([[:space:]]|$)" "$file" >/dev/null 2>&1; then
      echo "FORBIDDEN import $mod in $file"
      violations=$((violations + 1))
    fi
  done
done < <(find "$DOMAIN_SRC" -name '*.swift' -print0)

if [[ "$violations" -gt 0 ]]; then
  echo "Domain isolation check failed ($violations violation(s))."
  exit 1
fi

echo "Domain isolation check passed."

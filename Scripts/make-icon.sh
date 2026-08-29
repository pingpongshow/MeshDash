#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ICONSET="$ROOT/build/MeshDash.iconset"
mkdir -p "$ROOT/build" "$ROOT/Resources"
swift "$ROOT/Scripts/make-icon.swift" "$ICONSET"
iconutil --convert icns "$ICONSET" --output "$ROOT/Resources/AppIcon.icns"
echo "Wrote $ROOT/Resources/AppIcon.icns"

#!/bin/bash
# Regenerates Sources/MeshtasticProtobufs from the upstream protobuf definitions.
# Run this when the Meshtastic firmware adds fields you want to expose.
#
# Requires: protoc and protoc-gen-swift  (brew install protobuf swift-protobuf)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

REF="${1:-master}"
SRC="$ROOT/.proto-src"
OUT="$ROOT/Sources/MeshtasticProtobufs"

for tool in protoc protoc-gen-swift; do
    command -v "$tool" >/dev/null || { echo "error: $tool not found. brew install protobuf swift-protobuf"; exit 1; }
done

if [ -d "$SRC/.git" ]; then
    echo "Updating protobuf definitions…"
    git -C "$SRC" fetch --depth 1 origin "$REF"
    git -C "$SRC" checkout -q FETCH_HEAD
else
    echo "Cloning protobuf definitions…"
    rm -rf "$SRC"
    git clone --depth 1 --branch "$REF" https://github.com/meshtastic/protobufs.git "$SRC"
fi

echo "Generating Swift at $REF ($(git -C "$SRC" rev-parse --short HEAD))…"
rm -f "$OUT"/*.pb.swift
protoc \
    --plugin="$(command -v protoc-gen-swift)" \
    --swift_opt=Visibility=Public \
    --swift_out="$OUT" \
    -I "$SRC" \
    "$SRC"/meshtastic/*.proto

# protoc mirrors the proto package as a directory; flatten it into the target.
if [ -d "$OUT/meshtastic" ]; then
    mv "$OUT"/meshtastic/*.swift "$OUT"/
    rmdir "$OUT/meshtastic"
fi

echo "Generated $(ls "$OUT"/*.pb.swift | wc -l | tr -d ' ') files."
swift build 2>&1 | tail -3

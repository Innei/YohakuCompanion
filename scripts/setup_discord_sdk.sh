#!/usr/bin/env bash
set -euo pipefail

# Install Discord Social SDK for Yohaku Companion from the official C++ archive.
# Discord distributes this archive only through an enabled application's
# Developer Portal Downloads page, so the repository cannot provide a public
# default URL.
#
# Usage:
#   bash scripts/setup_discord_sdk.sh /path/to/DiscordSocialSdk-1.9.17379.zip
#   bash scripts/setup_discord_sdk.sh /path/to/a-newer-sdk.zip SHA256
#
# The same values may be supplied through:
#   DISCORD_SOCIAL_SDK_ARCHIVE
#   DISCORD_SOCIAL_SDK_SHA256

PINNED_VERSION="1.9.17379"
PINNED_SHA256="b94694bf839a509fa72c3f20b1881b8ebf19c5344065d85d2a19041554759863"
SDK_ARCHIVE="${1:-${DISCORD_SOCIAL_SDK_ARCHIVE:-}}"
SDK_SHA256="${2:-${DISCORD_SOCIAL_SDK_SHA256:-$PINNED_SHA256}}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VENDOR_DIR="$ROOT_DIR/Vendor/Discord"
INCLUDE_DIR="$VENDOR_DIR/include"
LIB_DIR="$VENDOR_DIR/lib"

if [[ -z "$SDK_ARCHIVE" ]]; then
  echo "Usage: $0 /path/to/DiscordSocialSdk-$PINNED_VERSION.zip [SHA256]" >&2
  echo "Download the C++ SDK from Discord Developer Portal > Social SDK > Downloads." >&2
  exit 64
fi
if [[ ! -f "$SDK_ARCHIVE" ]]; then
  echo "[setup] ERROR: Social SDK archive does not exist: $SDK_ARCHIVE" >&2
  exit 1
fi
if [[ ! "$SDK_SHA256" =~ ^[0-9a-fA-F]{64}$ ]]; then
  echo "[setup] ERROR: SHA-256 must contain exactly 64 hexadecimal characters." >&2
  exit 1
fi

TMP_DIR="$(mktemp -d 2>/dev/null || mktemp -d -t discord_social_sdk)"
EXTRACT_DIR="$TMP_DIR/extract"
STAGED_INCLUDE_DIR="$TMP_DIR/include"
STAGED_LIB_DIR="$TMP_DIR/lib"
mkdir -p "$EXTRACT_DIR" "$STAGED_INCLUDE_DIR" "$STAGED_LIB_DIR"

cleanup() { rm -rf "$TMP_DIR" || true; }
trap cleanup EXIT

echo "[setup] Verifying Social SDK archive checksum ..."
ACTUAL_SHA256="$(shasum -a 256 "$SDK_ARCHIVE" | awk '{print $1}')"
NORMALIZED_EXPECTED_SHA256="$(printf '%s' "$SDK_SHA256" | tr '[:upper:]' '[:lower:]')"
if [[ "$ACTUAL_SHA256" != "$NORMALIZED_EXPECTED_SHA256" ]]; then
  echo "[setup] ERROR: Discord Social SDK checksum mismatch." >&2
  echo "[setup] Expected: $NORMALIZED_EXPECTED_SHA256" >&2
  echo "[setup] Actual:   $ACTUAL_SHA256" >&2
  exit 1
fi

echo "[setup] Extracting Social SDK ..."
unzip -q "$SDK_ARCHIVE" -d "$EXTRACT_DIR"

DISCORDPP_HEADER="$(find "$EXTRACT_DIR" -type f -name discordpp.h -print -quit)"
SOCIAL_DYLIB="$(find "$EXTRACT_DIR" -type f -name libdiscord_partner_sdk.dylib -print -quit)"
if [[ -z "$DISCORDPP_HEADER" ]]; then
  echo "[setup] ERROR: The archive does not contain discordpp.h." >&2
  exit 1
fi
if [[ -z "$SOCIAL_DYLIB" ]]; then
  echo "[setup] ERROR: The archive does not contain libdiscord_partner_sdk.dylib." >&2
  exit 1
fi
if ! command -v lipo >/dev/null 2>&1; then
  echo "[setup] ERROR: lipo is required to prepare the Apple Silicon SDK input." >&2
  exit 1
fi
if ! command -v install_name_tool >/dev/null 2>&1; then
  echo "[setup] ERROR: install_name_tool is required to prepare the SDK dylib." >&2
  exit 1
fi

HEADER_DIR="$(dirname "$DISCORDPP_HEADER")"
while IFS= read -r -d '' header; do
  cp -f "$header" "$STAGED_INCLUDE_DIR/"
done < <(find "$HEADER_DIR" -maxdepth 1 -type f -name '*.h' -print0)

ARCHITECTURES="$(lipo -archs "$SOCIAL_DYLIB")"
case " $ARCHITECTURES " in
  *" arm64 "*)
    if [[ "$ARCHITECTURES" == "arm64" ]]; then
      cp -f "$SOCIAL_DYLIB" "$STAGED_LIB_DIR/libdiscord_partner_sdk.dylib"
    else
      lipo "$SOCIAL_DYLIB" -thin arm64 \
        -output "$STAGED_LIB_DIR/libdiscord_partner_sdk.dylib"
    fi
    ;;
  *)
    echo "[setup] ERROR: Social SDK dylib has no arm64 slice: $ARCHITECTURES" >&2
    exit 1
    ;;
esac

install_name_tool -id '@rpath/libdiscord_partner_sdk.dylib' \
  "$STAGED_LIB_DIR/libdiscord_partner_sdk.dylib"

STAGED_ARCHITECTURES="$(lipo -archs "$STAGED_LIB_DIR/libdiscord_partner_sdk.dylib")"
if [[ "$STAGED_ARCHITECTURES" != "arm64" ]]; then
  echo "[setup] ERROR: Staged Social SDK dylib is not arm64-only: $STAGED_ARCHITECTURES" >&2
  exit 1
fi

# Replace the ignored proprietary input as one validated unit so legacy SDK
# headers or binaries cannot remain alongside the Social SDK.
rm -rf "$INCLUDE_DIR" "$LIB_DIR"
mkdir -p "$INCLUDE_DIR" "$LIB_DIR"
cp -f "$STAGED_INCLUDE_DIR"/*.h "$INCLUDE_DIR/"
cp -f "$STAGED_LIB_DIR/libdiscord_partner_sdk.dylib" "$LIB_DIR/"

echo "[setup] Installed Discord Social SDK input (arm64)."
echo "[setup] Header: $INCLUDE_DIR/discordpp.h"
echo "[setup] Library: $LIB_DIR/libdiscord_partner_sdk.dylib"

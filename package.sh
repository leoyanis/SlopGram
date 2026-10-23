#!/usr/bin/env bash
# Builds SlopGram.ipa from a decrypted Instagram IPA, signs it with your development profile
# and, with --install, puts it on your connected iPhone.
#
#   ./package.sh            build + sign -> packages/SlopGram.ipa
#   ./package.sh --install  ...and install on the paired iPhone
#
# Settings come from the environment or from signing.env next to this script (not committed):
#   IPA_IN    decrypted Instagram .ipa
#   TEAM      your Apple team ID, e.g. ABCDE12345
#   IDENTITY  SHA-1 of your "Apple Development" certificate (security find-identity -v -p codesigning)
#   PROFILE   a development .mobileprovision for that team, wildcard or matching BUNDLE
#   BUNDLE    bundle id to install under (default com.slopgram.instagram)
#   DEVICE    device id for --install (xcrun devicectl list devices)
set -euo pipefail
cd "$(dirname "$0")"
[ -f signing.env ] && source signing.env

: "${IPA_IN:?set IPA_IN to a decrypted Instagram .ipa}"
: "${TEAM:?set TEAM to your Apple team ID}"
: "${IDENTITY:?set IDENTITY to your signing certificate SHA-1}"
: "${PROFILE:?set PROFILE to your .mobileprovision}"
BUNDLE="${BUNDLE:-com.slopgram.instagram}"

WORK=packages/work
mkdir -p packages
rm -rf "$WORK" packages/SlopGram-unsigned.ipa packages/SlopGram.ipa

echo "==> Building the tweak"
make clean >/dev/null
make FINALPACKAGE=1 >/dev/null
DYLIB=.theos/obj/SlopGram.dylib

echo "==> Injecting into Instagram"
cyan -i "$IPA_IN" -o packages/SlopGram-unsigned.ipa -f "$DYLIB" \
    -n SlopGram -b "$BUNDLE" -m 15.0 -u -d -w -c 0 --overwrite
ipapatch --input packages/SlopGram-unsigned.ipa --inplace --noconfirm

echo "==> Signing for team $TEAM"
mkdir -p "$WORK"
unzip -q packages/SlopGram-unsigned.ipa -d "$WORK"
APP=$(find "$WORK/Payload" -maxdepth 1 -name "*.app" | head -1)
python3 -I sign.py "$APP" "$PROFILE" "$IDENTITY" "$TEAM"

(cd "$WORK" && zip -qry ../SlopGram.ipa Payload)
echo "==> packages/SlopGram.ipa"

if [ "${1:-}" == "--install" ]; then
    : "${DEVICE:?set DEVICE to the id of your iPhone}"
    echo "==> Installing on the iPhone"
    xcrun devicectl device install app --device "$DEVICE" "$APP"
fi

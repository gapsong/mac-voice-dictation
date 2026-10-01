#!/usr/bin/env bash
#
# Builds the VoiceDictation menu-bar app into a runnable .app bundle.
#
# We use an SPM executable plus this bundling step (rather than an Xcode
# project) so the whole build is reproducible headlessly - it needs only the
# Swift toolchain / Command Line Tools, not a full Xcode install.
#
# Output: build/VoiceDictation.app
#
# Usage:
#   Scripts/build-app.sh            # release build + bundle + stable self-signed sign
#   CONFIG=debug Scripts/build-app.sh
set -euo pipefail

CONFIG="${CONFIG:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_NAME="VoiceDictation"
BUNDLE_ID="com.firstmate.VoiceDictation"
# Common Name of the stable, persistent self-signed code-signing identity we
# create once (see ensure_signing_identity) and reuse on every build.
SIGN_IDENTITY_CN="VoiceDictation Self-Signed"
# The identity lives in its OWN keychain (not login) with a known, local-only
# passphrase - see ensure_signing_identity for why. Persistent across rebuilds.
SIGN_KEYCHAIN="$HOME/Library/Keychains/voicedictation-signing.keychain-db"
SIGN_KC_PASS="voicedictation-signing"
BUILD_DIR="$ROOT/build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RESOURCES_DIR="$CONTENTS/Resources"

# Ensures a STABLE self-signed code-signing identity exists and prints its SHA-1
# hash on stdout (all progress goes to stderr). Prints "-" to request an ad-hoc
# fallback if a real identity cannot be created.
#
# Why this matters: macOS TCC (Microphone / Accessibility) keys its grants off
# the app's code-signing identity - specifically the designated requirement,
# which for a signed app pins the leaf certificate. Pure ad-hoc signing
# (`--sign -`) has NO stable certificate: every rebuild produces a fresh cdhash
# and thus a different identity, so macOS treats each reinstall as a brand-new
# app and forgets the grants. Signing with one persistent self-signed cert keeps
# the designated requirement constant, so the grants survive rebuilds.
#
# Why a DEDICATED keychain, not the login keychain: codesign reads the signing
# private key, and on modern macOS that read is gated by the key's *partition
# list*. Updating a partition list (`security set-key-partition-list`) requires
# the keychain's password. We do not know the user's login-keychain password, so
# on the login keychain codesign fails non-interactively with
# `errSecInternalComponent` (only a one-time GUI "Always Allow" click unblocks
# it). By keeping the identity in a small keychain WE own with a known local
# passphrase, we can set the partition list ourselves - so builds are fully
# non-interactive, headless-safe, and idempotent. This is the standard CI
# codesigning pattern (fastlane, GitHub Actions). The keychain is added to the
# search list so codesign finds the identity by hash.
#
# Idempotent: the keychain + cert are created only if absent; subsequent builds
# find and reuse them. We reference the identity by SHA-1 hash (not name) so
# codesign is never ambiguous even if several like-named certs exist, and we do
# NOT pass `-v` to find-identity: an untrusted self-signed cert reports
# CSSMERR_TP_NOT_TRUSTED and is filtered by `-v`, yet codesign signs with it
# fine (trust only matters at verification time, which is Gatekeeper's job).
existing_identity_hash() {
    security find-identity -p codesigning "$SIGN_KEYCHAIN" 2>/dev/null \
        | grep -F "$SIGN_IDENTITY_CN" | head -1 | awk '{print $2}' || true
}

# Appends the signing keychain to the user's search list if not already present
# (idempotent). Never replaces the list - that would drop the login keychain.
add_signing_keychain_to_search_list() {
    if security list-keychains -d user 2>/dev/null | sed 's/"//g' | grep -qF "$SIGN_KEYCHAIN"; then
        return 0
    fi
    local existing
    existing="$(security list-keychains -d user 2>/dev/null | sed -e 's/^[[:space:]]*//' -e 's/"//g')"
    # shellcheck disable=SC2086
    security list-keychains -d user -s $existing "$SIGN_KEYCHAIN" >/dev/null 2>&1 || true
}

ensure_signing_identity() {
    local hash
    hash="$(existing_identity_hash)"
    if [[ -n "$hash" ]]; then
        add_signing_keychain_to_search_list
        security unlock-keychain -p "$SIGN_KC_PASS" "$SIGN_KEYCHAIN" >/dev/null 2>&1 || true
        echo "==> Reusing stable signing identity '$SIGN_IDENTITY_CN' ($hash)" >&2
        echo "$hash"
        return 0
    fi

    echo "==> Creating stable self-signed signing identity '$SIGN_IDENTITY_CN' (one-time)" >&2

    # Create (or reuse) the dedicated keychain, keep it unlocked with no auto-
    # lock timeout, and put it on the search list so codesign can find the key.
    if [[ ! -f "$SIGN_KEYCHAIN" ]]; then
        if ! security create-keychain -p "$SIGN_KC_PASS" "$SIGN_KEYCHAIN" >/dev/null 2>&1; then
            echo "warning: could not create the signing keychain" >&2
            echo "-"
            return 0
        fi
    fi
    security set-keychain-settings "$SIGN_KEYCHAIN" >/dev/null 2>&1 || true
    security unlock-keychain -p "$SIGN_KC_PASS" "$SIGN_KEYCHAIN" >/dev/null 2>&1 || true
    add_signing_keychain_to_search_list

    local tmp cfg
    tmp="$(mktemp -d)"
    cfg="$tmp/openssl.cnf"
    # A code-signing leaf: CA:false, digitalSignature, EKU codeSigning. Config
    # file (not -addext) so it works on the LibreSSL that ships with macOS.
    cat > "$cfg" <<CNF
[ req ]
distinguished_name = dn
x509_extensions = codesign_ext
prompt = no

[ dn ]
CN = $SIGN_IDENTITY_CN

[ codesign_ext ]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CNF

    if ! openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
            -keyout "$tmp/key.pem" -out "$tmp/cert.pem" -config "$cfg" >/dev/null 2>&1; then
        echo "warning: openssl failed to create a self-signed certificate" >&2
        rm -rf "$tmp"
        echo "-"
        return 0
    fi

    # Package as PKCS#12 with a throwaway transport password. Two portability
    # notes for `security import`:
    #  - a non-empty password avoids the empty-password MAC quirk that makes
    #    `security` reject the file ("MAC verification failed").
    #  - OpenSSL 3 (e.g. Homebrew) defaults to algorithms macOS's older Security
    #    framework cannot read, so we try `-legacy` first; LibreSSL (the CLT-only
    #    default) has no `-legacy` flag but already writes compatible output, so
    #    we fall back to the plain form.
    local p12_pass="voicedictation-transport"
    if ! openssl pkcs12 -export -legacy -inkey "$tmp/key.pem" -in "$tmp/cert.pem" \
            -out "$tmp/identity.p12" -passout "pass:$p12_pass" -name "$SIGN_IDENTITY_CN" >/dev/null 2>&1; then
        if ! openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" \
                -out "$tmp/identity.p12" -passout "pass:$p12_pass" -name "$SIGN_IDENTITY_CN" >/dev/null 2>&1; then
            echo "warning: openssl failed to package the identity" >&2
            rm -rf "$tmp"
            echo "-"
            return 0
        fi
    fi

    # Import key+cert into the dedicated keychain. -A lets codesign use the key.
    if ! security import "$tmp/identity.p12" -k "$SIGN_KEYCHAIN" -P "$p12_pass" -A \
            -T /usr/bin/codesign >/dev/null 2>&1; then
        echo "warning: failed to import the signing identity" >&2
        rm -rf "$tmp"
        echo "-"
        return 0
    fi
    rm -rf "$tmp"

    # The crucial step the login keychain can't do headlessly: authorise
    # codesign (and Apple's tools) to use the private key without a GUI prompt.
    security set-key-partition-list -S apple-tool:,apple:,codesign: \
        -s -k "$SIGN_KC_PASS" "$SIGN_KEYCHAIN" >/dev/null 2>&1 || true

    hash="$(existing_identity_hash)"
    if [[ -n "$hash" ]]; then
        echo "$hash"
        return 0
    fi

    echo "warning: signing identity not usable after import" >&2
    echo "-"
    return 0
}

echo "==> Building $APP_NAME ($CONFIG)"
swift build -c "$CONFIG" --product "$APP_NAME"

BIN_PATH="$(swift build -c "$CONFIG" --product "$APP_NAME" --show-bin-path)/$APP_NAME"
if [[ ! -x "$BIN_PATH" ]]; then
    echo "error: built binary not found at $BIN_PATH" >&2
    exit 1
fi

echo "==> Assembling bundle at $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$BIN_PATH" "$MACOS_DIR/$APP_NAME"
cp "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"
# App icon. Generated from Resources/AppIcon.svg by Scripts/make-icon.sh.
cp "$ROOT/Resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
printf 'APPL????' > "$CONTENTS/PkgInfo"

# Code signature. We sign with a STABLE self-signed identity (created once) so
# the designated requirement stays constant and macOS TCC remembers granted
# Microphone / Accessibility permissions across rebuilds. If no such identity
# can be created we fall back to ad-hoc, which still runs but WILL make TCC
# re-prompt on each reinstall.
SIGN_ID="$(ensure_signing_identity)"
if [[ "$SIGN_ID" == "-" ]]; then
    echo "==> Ad-hoc code signing (fallback - TCC grants will NOT persist across rebuilds)" >&2
else
    echo "==> Code signing with '$SIGN_ID'"
fi
codesign --force --sign "$SIGN_ID" --identifier "$BUNDLE_ID" \
    --timestamp=none "$APP_BUNDLE" >/dev/null 2>&1 || {
        echo "warning: codesign failed; the app will still run but TCC may re-prompt" >&2
    }

echo "==> Done: $APP_BUNDLE"
echo "    Run with: open \"$APP_BUNDLE\""
echo "    Or:       \"$MACOS_DIR/$APP_NAME\"   (foreground, for logs)"

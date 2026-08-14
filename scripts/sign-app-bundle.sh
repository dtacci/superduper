#!/usr/bin/env bash
set -euo pipefail

# Re-sign a built app bundle with explicit nested ordering so macOS TCC can
# consistently track bundle identity across launches.
#
# Usage:
#   ./scripts/sign-app-bundle.sh /path/to/Pindrop.app [identity]
#
# identity defaults to "-" (ad-hoc). Pass "local" to use the persistent
# Superduper Dictation signing certificate from the user's login keychain.

APP_BUNDLE="${1:-}"
SIGN_IDENTITY="${2:--}"
SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(dirname "${SCRIPT_DIRECTORY}")"
APP_ENTITLEMENTS="${REPOSITORY_ROOT}/Pindrop/Pindrop.entitlements"

if [ "${SIGN_IDENTITY}" = "local" ]; then
    LOCAL_CERTIFICATE_NAME="Superduper Dictation Local Signing"
    LOGIN_KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"
    SIGN_IDENTITY="$({
        security find-certificate -c "${LOCAL_CERTIFICATE_NAME}" -Z "${LOGIN_KEYCHAIN}" 2>/dev/null || true
    } | awk -F': ' '/SHA-1 hash:/{print $2; exit}')"

    if [ -z "${SIGN_IDENTITY}" ]; then
        echo "⚠️  Persistent local signing certificate not found; falling back to ad-hoc signing."
        echo "⚠️  Accessibility permission may need to be granted again after every rebuild."
        SIGN_IDENTITY="-"
    else
        echo "🔐 Using persistent local signing certificate: ${LOCAL_CERTIFICATE_NAME}"
    fi
fi

if [ -z "${APP_BUNDLE}" ]; then
    echo "❌ Missing app bundle path."
    echo "Usage: $0 /path/to/Pindrop.app [identity]"
    exit 1
fi

if [ ! -d "${APP_BUNDLE}" ]; then
    echo "❌ App bundle not found: ${APP_BUNDLE}"
    exit 1
fi

SPARKLE_FRAMEWORK="${APP_BUNDLE}/Contents/Frameworks/Sparkle.framework"

echo "🔏 Signing app bundle with identity: ${SIGN_IDENTITY}"

if [ -d "${SPARKLE_FRAMEWORK}" ]; then
    echo "🔏 Signing nested Sparkle executables..."
    while IFS= read -r executable; do
        [ -n "${executable}" ] || continue
        codesign --force --options runtime --sign "${SIGN_IDENTITY}" "${executable}"
    done < <(find "${SPARKLE_FRAMEWORK}" -type f -perm -111 | sort)

    echo "🔏 Signing nested Sparkle bundles..."
    while IFS= read -r nested_bundle; do
        [ -n "${nested_bundle}" ] || continue
        codesign --force --options runtime --sign "${SIGN_IDENTITY}" "${nested_bundle}"
    done < <(find "${SPARKLE_FRAMEWORK}" -type d \( -name "*.xpc" -o -name "*.app" -o -name "*.framework" \) | sort -r)

    echo "🔏 Signing Sparkle.framework..."
    codesign --force --options runtime --sign "${SIGN_IDENTITY}" "${SPARKLE_FRAMEWORK}"
else
    echo "⚠️  Sparkle.framework not found at ${SPARKLE_FRAMEWORK}; skipping Sparkle-specific signing."
fi

echo "🔏 Signing main app bundle..."
MAIN_SIGN_ARGUMENTS=(--force --options runtime --sign "${SIGN_IDENTITY}")
if [ -f "${APP_ENTITLEMENTS}" ]; then
    MAIN_SIGN_ARGUMENTS+=(--entitlements "${APP_ENTITLEMENTS}")
fi
codesign "${MAIN_SIGN_ARGUMENTS[@]}" "${APP_BUNDLE}"

echo "🔍 Verifying strict deep signature..."
codesign --verify --deep --strict --verbose=2 "${APP_BUNDLE}"
echo "✅ Strict deep signature verification passed"

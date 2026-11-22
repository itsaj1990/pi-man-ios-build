#!/usr/bin/env bash
# Google OAuth client IDs are public configuration, not passwords or API keys.
# Verified in Google Cloud project 855328258763 on 2026-11-21.
# Run after checkout and before XcodeGen/build. Env vars override the verified
# public defaults without committing any secret.
set -euo pipefail
cd "$(dirname "$0")/../.."
PLIST=ios/PIMan/Info.plist
IOS_ID="${PI_MAN_GOOGLE_IOS_CLIENT_ID:-855328258763-9me6rrr09h5a4k7ias2bak4v78n9ih55.apps.googleusercontent.com}"
WEB_ID="${PI_MAN_GOOGLE_WEB_CLIENT_ID:-855328258763-i5nfgb4ugc4vvf79t5gt7177bbblafso.apps.googleusercontent.com}"

# The verified existing PI Man Web OAuth client is public configuration.
# An iOS OAuth client is a DIFFERENT credential, tied to com.piman.app.
# Do not mistakenly reuse the Web ID as GIDClientID. Until supplied, leave
# the Google button hidden and preserve the working Apple/email login.
if [[ -z "$IOS_ID" ]]; then
  echo "Google iOS OAuth client is not configured; native Google sign-in stays hidden."
  exit 0
fi
if [[ ! "$IOS_ID" =~ ^[0-9]+-[A-Za-z0-9_-]+\.apps\.googleusercontent\.com$ ]] ||
   [[ ! "$WEB_ID" =~ ^[0-9]+-[A-Za-z0-9_-]+\.apps\.googleusercontent\.com$ ]]; then
  echo "Both Google client IDs must be valid iOS and Web OAuth client IDs." >&2
  exit 1
fi

# Fail closed if the Web ID is mistakenly supplied as the native iOS client.
if [[ "$IOS_ID" == "$WEB_ID" ]]; then
  echo "Google iOS and Web OAuth client IDs must be different." >&2
  exit 1
fi

PREFIX="${IOS_ID%.apps.googleusercontent.com}"
URL_SCHEME="com.googleusercontent.apps.${PREFIX}"
/usr/libexec/PlistBuddy -c "Add :GIDClientID string $IOS_ID" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :GIDServerClientID string $WEB_ID" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes array" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:0 dict" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes array" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes:0 string $URL_SCHEME" "$PLIST"
echo "Google iOS OAuth client and redirect scheme configured for this build."

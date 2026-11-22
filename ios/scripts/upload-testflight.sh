#!/usr/bin/env bash
# Run only on macOS 26+ with a protected GitHub environment and main branch.
set -euo pipefail
umask 077
cd "$(dirname "$0")/../.."
: "$RUNNER_TEMP" "$GITHUB_RUN_NUMBER" "$IOS_DISTRIBUTION_CERT_P12_BASE64"
: "$IOS_DISTRIBUTION_CERT_PASSWORD" "$IOS_APPSTORE_PROVISIONING_PROFILE_BASE64"
: "$ASC_API_KEY_ID" "$ASC_ISSUER_ID" "$ASC_API_KEY_P8_BASE64"
TEAM_ID=R6G37PYF87
BUNDLE_ID=com.piman.app
KEYCHAIN="$RUNNER_TEMP/pi-man-signing.keychain-db"
KEYCHAIN_PASSWORD="$(openssl rand -hex 24)"
CERT="$RUNNER_TEMP/pi-man-distribution.p12"
CERT_PEM="$RUNNER_TEMP/pi-man-distribution-certificates.pem"
KEYCHAIN_CERT="$RUNNER_TEMP/pi-man-keychain-distribution.p12"
OPENSSL="$(brew --prefix openssl@3)/bin/openssl"
PROFILE="$RUNNER_TEMP/pi-man-appstore.mobileprovision"
PLIST="$RUNNER_TEMP/pi-man-appstore.plist"
API_KEY_DIR="$HOME/.appstoreconnect/private_keys"
API_KEY_PATH="$API_KEY_DIR/AuthKey_$ASC_API_KEY_ID.p8"
EXPORT_PLIST="$RUNNER_TEMP/PIManExportOptions.plist"
ARCHIVE_PATH="$RUNNER_TEMP/PIMan.xcarchive"
EXPORT_PATH="$RUNNER_TEMP/PIManExport"

cleanup() {
  security delete-keychain "$KEYCHAIN" >/dev/null 2>&1 || true
  rm -f "$CERT" "$CERT_PEM" "$KEYCHAIN_CERT" "$PROFILE" "$PLIST" "$EXPORT_PLIST" "$API_KEY_PATH"
}
trap cleanup EXIT

printf '%s' "$IOS_DISTRIBUTION_CERT_P12_BASE64" | base64 -D > "$CERT"
printf '%s' "$IOS_APPSTORE_PROVISIONING_PROFILE_BASE64" | base64 -D > "$PROFILE"
mkdir -p "$API_KEY_DIR"
chmod 700 "$API_KEY_DIR"
printf '%s' "$ASC_API_KEY_P8_BASE64" | base64 -D > "$API_KEY_PATH"
chmod 600 "$API_KEY_PATH"

# macOS Keychain requires a compatible PKCS#12 envelope. Keep the private key
# in a pipe while repackaging the original identity for the ephemeral keychain.
"$OPENSSL" pkcs12 -in "$CERT" -nokeys -passin env:IOS_DISTRIBUTION_CERT_PASSWORD -out "$CERT_PEM"
"$OPENSSL" pkcs12 -in "$CERT" -nocerts -noenc -passin env:IOS_DISTRIBUTION_CERT_PASSWORD |
  "$OPENSSL" pkcs12 -export -inkey /dev/stdin -in "$CERT_PEM" -out "$KEYCHAIN_CERT" \
    -passout env:IOS_DISTRIBUTION_CERT_PASSWORD \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1

security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security list-keychains -d user -s "$KEYCHAIN"
security import "$KEYCHAIN_CERT" -k "$KEYCHAIN" -P "$IOS_DISTRIBUTION_CERT_PASSWORD" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security find-identity -v -p codesigning "$KEYCHAIN"

security cms -D -i "$PROFILE" > "$PLIST"
PROFILE_UUID="$(/usr/libexec/PlistBuddy -c 'Print :UUID' "$PLIST")"
PROFILE_NAME="$(/usr/libexec/PlistBuddy -c 'Print :Name' "$PLIST")"
PROFILE_TEAM="$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' "$PLIST")"
PROFILE_APP="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:application-identifier' "$PLIST")"
if [[ "$PROFILE_TEAM" != "$TEAM_ID" || "$PROFILE_APP" != "$TEAM_ID.$BUNDLE_ID" ]]; then
  echo "Provisioning profile must match the PI Man Team ID and Bundle ID." >&2
  exit 1
fi
# Signing succeeds only if the updated profile permits native Sign in with Apple.
# Fail before archiving if GitHub still has the previous profile secret.
APPLE_SIGNIN_ENTITLEMENT="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.developer.applesignin:0' "$PLIST" 2>/dev/null || true)"
if [[ "$APPLE_SIGNIN_ENTITLEMENT" != "Default" ]]; then
  echo "App Store provisioning profile in GitHub lacks Sign in with Apple. Replace IOS_APPSTORE_PROVISIONING_PROFILE_BASE64 in the ios-testflight environment." >&2
  exit 1
fi
mkdir -p "$HOME/Library/MobileDevice/Provisioning Profiles"
cp "$PROFILE" "$HOME/Library/MobileDevice/Provisioning Profiles/$PROFILE_UUID.mobileprovision"
# A temporary build repository starts its run counter at 1 even though the
# existing PI Man TestFlight builds have already reached higher numbers.
# Set PI_MAN_BUILD_NUMBER to a new build number from App Store Connect.
BUILD_NUMBER="${PI_MAN_BUILD_NUMBER:-$GITHUB_RUN_NUMBER}"
if [[ ! "$BUILD_NUMBER" =~ ^[1-9][0-9]{0,3}$ ]]; then
  echo "Invalid PI Man build number (expected integer 1-9999)." >&2
  exit 1
fi
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" ios/PIMan/Info.plist

# Signing settings live on the PIMan application target in ios/project.yml.
# Do not pass PROVISIONING_PROFILE_SPECIFIER via the xcodebuild CLI: that
# applies it to transitive Swift Package targets, which reject profiles.
if [[ "$PROFILE_NAME" != "PIMan AppStore" ]]; then
  echo "Expected PIMan AppStore signing profile; update ios/project.yml if the profile was renamed." >&2
  exit 1
fi
xcodebuild -project ios/PIMan.xcodeproj -scheme PIMan \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE_PATH" DEVELOPMENT_TEAM="$TEAM_ID" -quiet archive

cat > "$EXPORT_PLIST" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>export</string>
  <key>signingStyle</key><string>manual</string>
  <key>teamID</key><string>R6G37PYF87</string>
  <key>provisioningProfiles</key><dict>
    <key>com.piman.app</key><string>PIMan AppStore</string>
  </dict>
</dict></plist>
PLIST
/usr/libexec/PlistBuddy -c "Set :provisioningProfiles:$BUNDLE_ID $PROFILE_NAME" "$EXPORT_PLIST"

xcodebuild -exportArchive -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" -exportOptionsPlist "$EXPORT_PLIST" -quiet

IPA="$EXPORT_PATH/PIMan.ipa"
[[ -f "$IPA" ]] || { echo "Signed PIMan.ipa was not produced." >&2; exit 1; }
xcrun altool --upload-app --type ios --file "$IPA" \
  --apiKey "$ASC_API_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
echo "PI Man IPA delivered to App Store Connect for TestFlight processing."

#!/bin/sh
# RSLabs fork (rsaulo/buzz, branch ipad/main): archive the iPad build and
# upload it to TestFlight as "Buzz iPad" (br.com.rslabs.buzz-ipad).
#
# Signing follows the RSLabs Apple team's automatic-signing flow (same as Pi
# Code): team 8AA6CY9332, cloud-managed distribution certificate, App Store
# Connect API key for headless provisioning. No push gateway is configured, so
# the artifact deliberately has no push (see require-push-gateway-origin.sh).
#
# Usage: mobile/scripts/rslabs-ipad-testflight.sh [--no-upload]
set -eu

TEAM_ID=${RSLABS_APPLE_TEAM_ID:-8AA6CY9332}
BUNDLE_ID=${RSLABS_BUZZ_BUNDLE_ID:-br.com.rslabs.buzz-ipad}
DISPLAY_NAME=${RSLABS_BUZZ_DISPLAY_NAME:-Buzz iPad}
ASC_KEY_ID=${ASC_KEY_ID:-96GC667MNM}
ASC_ISSUER_ID=${ASC_ISSUER_ID:-5fe101e7-eaf7-48fc-9084-fd6dcc9501e8}
ASC_KEY_PATH=${ASC_KEY_PATH:-$HOME/git/metagastos/backend/keys/AuthKey_$ASC_KEY_ID.p8}

upload=true
[ "${1:-}" = "--no-upload" ] && upload=false

mobile_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
repo_dir=$(CDPATH= cd -- "$mobile_dir/.." && pwd)
cd "$mobile_dir"

if [ ! -r "$ASC_KEY_PATH" ]; then
  echo "error: App Store Connect API key not found at $ASC_KEY_PATH" >&2
  exit 1
fi

# Marketing version comes from the upstream mobile release this branch is
# based on (mobile-vX.Y.Z-rc.N -> X.Y.Z). Xcode assigns the build number.
base_tag=$(git -C "$repo_dir" describe --tags --match 'mobile-v*' --abbrev=0)
version=$(printf '%s' "$base_tag" | sed -E 's/^mobile-v([0-9]+\.[0-9]+\.[0-9]+).*/\1/')
commit=$(git -C "$repo_dir" rev-parse --short HEAD)

# CocoaPods fails on non-UTF-8 locales.
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

# Gitignored by upstream; included last by Debug/Release.xcconfig.
cat > ios/Flutter/AppOverrides.xcconfig <<EOF
// Written by scripts/rslabs-ipad-testflight.sh (RSLabs fork).
BUNDLE_IDENTIFIER = $BUNDLE_ID
APP_DISPLAY_NAME = $DISPLAY_NAME
BUZZ_DEVELOPMENT_TEAM = $TEAM_ID
EOF

# The App Store Connect API key provisions bundle IDs, push and profiles, but
# not App Attest, Communication Notifications, Declared Age Range or App Group
# registration (developer-portal only). Those serve push enrollment (no
# gateway here) and the age gate, which production builds keep disabled and
# fail-open. Sign this build with only push + keychain sharing; the tracked
# entitlements are restored on exit, so the fork carries no diff for this.
runner_entitlements=ios/Runner/Runner.entitlements
extension_entitlements=ios/NotificationService/NotificationService.entitlements
restore_entitlements() {
  # pod install also rewrites the CocoaPods version line in Podfile.lock.
  git -C "$mobile_dir" checkout -- "$runner_entitlements" \
    "$extension_entitlements" ios/Podfile.lock
}
trap restore_entitlements EXIT
plist_head='<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>'
keychain_group='	<key>keychain-access-groups</key>
	<array>
		<string>$(AppIdentifierPrefix)$(BUZZ_KEYCHAIN_ACCESS_GROUP)</string>
	</array>'
printf '%s\n\t<key>aps-environment</key>\n\t<string>$(BUZZ_IOS_PUSH_ENVIRONMENT)</string>\n%s\n</dict>\n</plist>\n' \
  "$plist_head" "$keychain_group" > "$runner_entitlements"
printf '%s\n%s\n</dict>\n</plist>\n' \
  "$plist_head" "$keychain_group" > "$extension_entitlements"

../bin/flutter build ios --release --config-only \
  --build-name "$version" --build-number 1

work=${RSLABS_BUZZ_BUILD_DIR:-/tmp/buzz-ipad-build}
archive="$work/BuzzIPad-$version-$commit.xcarchive"
export_dir="$work/export-$version-$commit"
rm -rf "$archive" "$export_dir"
mkdir -p "$work"

set -- -allowProvisioningUpdates \
  -authenticationKeyPath "$ASC_KEY_PATH" \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID"

xcodebuild -workspace ios/Runner.xcworkspace -scheme Runner \
  -configuration Release -destination generic/platform=iOS \
  -archivePath "$archive" "$@" archive

if [ "$upload" = false ]; then
  echo "archive: $archive"
  exit 0
fi

cat > "$work/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>upload</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>automatic</string>
  <key>manageAppVersionAndBuildNumber</key><true/>
  <key>uploadSymbols</key><true/>
</dict>
</plist>
EOF

xcodebuild -exportArchive -archivePath "$archive" \
  -exportOptionsPlist "$work/ExportOptions.plist" \
  -exportPath "$export_dir" "$@"

echo "uploaded $version ($commit) from $archive"

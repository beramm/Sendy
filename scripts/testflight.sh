#!/usr/bin/env bash
#
# Archive, export and upload the app to TestFlight.
#
#   ./scripts/testflight.sh            archive + export + upload
#   ./scripts/testflight.sh --no-upload  archive + export only
#
# Authentication for the upload step, in order of preference:
#
#   1. App Store Connect API key, via environment:
#        ASC_KEY_ID, ASC_ISSUER_ID, and a .p8 in ~/.appstoreconnect/private_keys/
#      Create one at App Store Connect > Users and Access > Integrations > App
#      Store Connect API. Role "App Manager" is enough.
#
#   2. An app-specific password, via environment:
#        ASC_APPLE_ID (the Apple ID email) and ASC_APP_PASSWORD
#      Create the password at appleid.apple.com > Sign-In and Security.
#
# The build number is a UTC timestamp, so it always increases. The marketing
# version is whatever MARKETING_VERSION is set to in the project.

set -euo pipefail

cd "$(dirname "$0")/.."

SCHEME="SendSociety"
PROJECT="SendSociety.xcodeproj"
BUILD_DIR=".build/testflight"
ARCHIVE="$BUILD_DIR/$SCHEME.xcarchive"
BUILD_NUMBER="$(date -u +%y%m%d%H%M)"

UPLOAD=1
[[ "${1:-}" == "--no-upload" ]] && UPLOAD=0

echo "==> Build number $BUILD_NUMBER"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "==> Archiving"
xcodebuild archive \
	-project "$PROJECT" \
	-scheme "$SCHEME" \
	-configuration Release \
	-destination 'generic/platform=iOS' \
	-archivePath "$ARCHIVE" \
	-allowProvisioningUpdates \
	CURRENT_PROJECT_VERSION="$BUILD_NUMBER"

echo "==> Exporting .ipa"
xcodebuild -exportArchive \
	-archivePath "$ARCHIVE" \
	-exportPath "$BUILD_DIR" \
	-exportOptionsPlist scripts/ExportOptions.plist \
	-allowProvisioningUpdates

IPA="$(find "$BUILD_DIR" -maxdepth 1 -name '*.ipa' | head -1)"
echo "==> Exported $IPA"

if [[ "$UPLOAD" -eq 0 ]]; then
	echo "==> Skipping upload (--no-upload)"
	exit 0
fi

echo "==> Uploading to App Store Connect"
if [[ -n "${ASC_KEY_ID:-}" && -n "${ASC_ISSUER_ID:-}" ]]; then
	xcrun altool --upload-app \
		--type ios \
		--file "$IPA" \
		--apiKey "$ASC_KEY_ID" \
		--apiIssuer "$ASC_ISSUER_ID"
elif [[ -n "${ASC_APPLE_ID:-}" && -n "${ASC_APP_PASSWORD:-}" ]]; then
	xcrun altool --upload-app \
		--type ios \
		--file "$IPA" \
		--username "$ASC_APPLE_ID" \
		--password "$ASC_APP_PASSWORD"
else
	echo "No App Store Connect credentials in the environment." >&2
	echo "Set ASC_KEY_ID + ASC_ISSUER_ID, or ASC_APPLE_ID + ASC_APP_PASSWORD." >&2
	echo "The .ipa is at $IPA and can be uploaded from Xcode's Organizer." >&2
	exit 1
fi

echo "==> Uploaded build $BUILD_NUMBER. Processing takes a few minutes."

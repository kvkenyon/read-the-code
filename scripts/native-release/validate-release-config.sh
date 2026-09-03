#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
cd "$repo_root"

for plist in native/App/ReadTheCodeApp.entitlements native/CLI/rtc.entitlements native/Services/GitWorker.entitlements native/Services/ModelWorker.entitlements native/App/Resources/Info.plist; do
  /usr/bin/plutil -lint "$plist" >/dev/null
done

for entitlement in native/App/ReadTheCodeApp.entitlements native/CLI/rtc.entitlements native/Services/GitWorker.entitlements native/Services/ModelWorker.entitlements; do
  contents=$(/usr/bin/plutil -convert json -o - "$entitlement")
  test "$contents" = '{}'
done

test "$(/usr/bin/plutil -extract LSMinimumSystemVersion raw -o - native/App/Resources/Info.plist)" = "14.0"
test "$(/usr/bin/plutil -extract SUFeedURL raw -o - native/App/Resources/Info.plist)" = "https://updates.invalid/read-the-code/appcast.xml"
test "$(/usr/bin/plutil -extract SUPublicEDKey raw -o - native/App/Resources/Info.plist)" = "RTC_SPARKLE_PUBLIC_KEY_REQUIRED_AT_RELEASE"
grep -Fqx 'MACOSX_DEPLOYMENT_TARGET = 14.0' native/Configs/Release.xcconfig
grep -Fqx 'RTC_DISTRIBUTION = developer-id-notarized' native/Configs/Release.xcconfig
grep -Fqx 'ENABLE_HARDENED_RUNTIME = YES' native/Configs/Release.xcconfig
grep -Fqx 'OTHER_CODE_SIGN_FLAGS = --timestamp --options runtime' native/Configs/Release.xcconfig
grep -Fqx 'RTC_SPARKLE_FEED_URL = https://updates.invalid/read-the-code/appcast.xml' native/Configs/Release.xcconfig
test ! -e native/Packaging/Sparkle/appcast.xml
! grep -q '<enclosure' native/Packaging/Sparkle/appcast.xml.template
node scripts/native-release/generate-sbom.mjs --validate-only
printf '%s\n' 'Native release configuration is safe for unsigned validation.'

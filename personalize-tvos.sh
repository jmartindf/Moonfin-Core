#!/bin/bash
set -euo pipefail

DEVELOPER_ID=F6J3WTU2J9

sed -i '.orig' \
  -e "s#PRODUCT_BUNDLE_IDENTIFIER = org.moonfin.app;#PRODUCT_BUNDLE_IDENTIFIER = org.$DEVELOPER_ID.moonfin.app;#" \
  -e "s#PRODUCT_BUNDLE_IDENTIFIER = org.moonfin.app.topshelf;#PRODUCT_BUNDLE_IDENTIFIER = org.$DEVELOPER_ID.moonfin.app.topshelf;#" \
  -e "s#DEVELOPMENT_TEAM = CCBYLPUSVH;#DEVELOPMENT_TEAM = $DEVELOPER_ID;#" \
  -e "s#CODE_SIGN_ENTITLEMENTS = MoonfinTopShelf/MoonfinTopShelf.entitlements;#CODE_SIGN_ENTITLEMENTS = MoonfinTopShelf/MoonfinTopShelfSideload.entitlements;#" \
  -e "s#CODE_SIGN_ENTITLEMENTS = Runner/Runner.entitlements;#CODE_SIGN_ENTITLEMENTS = Runner/RunnerSideload.entitlements;#" \
  tvos/Runner.xcodeproj/project.pbxproj

cp tvos/Runner/Runner.entitlements tvos/Runner/RunnerSideload.entitlements
cp tvos/MoonfinTopShelf/MoonfinTopShelf.entitlements tvos/MoonfinTopShelf/MoonfinTopShelfSideload.entitlements
sed -i '' \
  "s#group.org.moonfin.app#group.org.$DEVELOPER_ID.moonfin.app#" \
  tvos/Runner/RunnerSideload.entitlements \
  tvos/MoonfinTopShelf/MoonfinTopShelfSideload.entitlements \
  tvos/Runner/TopShelfChannel.swift \
  tvos/MoonfinTopShelf/ServiceProvider.swift

sed -i '.orig' \
  "s#<string>Moonfin</string>#<string>Sidefin</string>#" \
  tvos/Runner/Info.plist

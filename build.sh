#!/bin/sh
# Builds SwitzachWidgetProbe and packages it as a .deb in build/.
#
#   SDK=/path/to/iPhoneOS16.5.sdk ./build.sh
#
# Needs clang and lld (LLVM), an iOS SDK with the private Preferences framework
# (e.g. theos/sdks iPhoneOS16.5.sdk) and dpkg-deb.
set -eu
cd "$(dirname "$0")"

SDK=${SDK:-$HOME/theos/sdks/iPhoneOS16.5.sdk}
[ -d "$SDK" ] || { echo "SDK not found: $SDK (set SDK=...)" >&2; exit 1; }

VERSION=$(sed -n 's/^Version: //p' layout/DEBIAN/control)
STAGE=build/stage
WARN="-Wall -Wextra -Wno-unused-parameter -Wno-missing-field-initializers"
CC="clang -target arm64-apple-ios15.0 -isysroot $SDK -fobjc-arc -fmodules -O2 $WARN -fuse-ld=lld -Wl,-adhoc_codesign -DWG_VERSION=\"$VERSION\""
UI="-framework Foundation -framework UIKit -framework QuartzCore -framework CoreGraphics"
DYLIBS=$STAGE/Library/MobileSubstrate/DynamicLibraries
PREFS=$STAGE/Library/PreferenceBundles/SwitzachWidgetProbePrefs.bundle
HOST=$STAGE/Library/SwitzachWidgetProbe/SwitzachWidgetHost.app

rm -rf build
mkdir -p build
cp -R layout "$STAGE"
mkdir -p "$PREFS" "$HOST"

# SpringBoard: finds the widgets, starts their hosts, shows what they draw. No app code here.
$CC -dynamiclib $UI -install_name /Library/MobileSubstrate/DynamicLibraries/SwitzachWidgetProbe.dylib \
    -o "$DYLIBS/SwitzachWidgetProbe.dylib" src/springboard/*.m src/common/WGShared.m

# The widget host: one app's widget extension, in a process of its own.
$CC $UI -o "$HOST/SwitzachWidgetHost" src/host/*.m src/host/WGAsync.s src/common/WGShared.m
sed "s/@VERSION@/$VERSION/g" host/Info.plist > "$HOST/Info.plist"

# Loaded into apps: hands a widget link's URL to the app it opens.
$CC -dynamiclib -framework Foundation -framework UIKit \
    -install_name /Library/MobileSubstrate/DynamicLibraries/SwitzachWidgetLinks.dylib \
    -o "$DYLIBS/SwitzachWidgetLinks.dylib" src/links/WGLinks.m

# The settings page (PreferenceLoader bundle).
$CC -bundle -F"$SDK/System/Library/PrivateFrameworks" -framework Preferences -framework Foundation -framework UIKit \
    -o "$PREFS/SwitzachWidgetProbePrefs" prefs/SWPRootListController.m
cp prefs/Resources/* "$PREFS/"
sed -i.bak "s/@VERSION@/$VERSION/g" "$PREFS/Info.plist" "$PREFS/Root.plist" && rm -f "$PREFS"/*.bak

printf 'Installed-Size: %s\n' "$(du -sk "$STAGE/Library" | cut -f1)" >> "$STAGE/DEBIAN/control"
find "$STAGE" -name .DS_Store -delete
dpkg-deb --root-owner-group -Zgzip -b "$STAGE" "build/com.rinapple.switzachwidgetprobe_${VERSION}_iphoneos-arm64e.deb"

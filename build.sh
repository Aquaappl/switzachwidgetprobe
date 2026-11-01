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
CC="clang -target arm64-apple-ios15.0 -isysroot $SDK -fobjc-arc -fmodules -O2 -fuse-ld=lld -Wl,-adhoc_codesign"
DYLIBS=$STAGE/Library/MobileSubstrate/DynamicLibraries
PREFS=$STAGE/Library/PreferenceBundles/SwitzachWidgetProbePrefs.bundle

rm -rf build
mkdir -p build
cp -R layout "$STAGE"
mkdir -p "$PREFS"

# SpringBoard tweak: the widgets on the home screen.
$CC -dynamiclib -framework Foundation -framework UIKit -framework QuartzCore -framework CoreGraphics \
    -install_name /Library/MobileSubstrate/DynamicLibraries/SwitzachWidgetProbe.dylib \
    -o "$DYLIBS/SwitzachWidgetProbe.dylib" \
    src/Tweak.m src/WPHome.m src/WPProbe.m src/WPSettings.m src/WPAsync.s

# Loaded into apps: hands a widget link's URL to the app it opens.
$CC -dynamiclib -framework Foundation -framework UIKit \
    -install_name /Library/MobileSubstrate/DynamicLibraries/SwitzachWidgetLinks.dylib \
    -o "$DYLIBS/SwitzachWidgetLinks.dylib" \
    src/WPLinks.m

# Settings page (PreferenceLoader bundle).
$CC -bundle -F"$SDK/System/Library/PrivateFrameworks" -framework Preferences -framework Foundation -framework UIKit \
    -o "$PREFS/SwitzachWidgetProbePrefs" \
    prefs/SWPRootListController.m
cp prefs/Resources/* "$PREFS/"
sed -i.bak "s/@VERSION@/$VERSION/g" "$PREFS/Info.plist" "$PREFS/Root.plist" && rm -f "$PREFS"/*.bak

SIZE=$(du -sk "$STAGE/Library" | cut -f1)
printf 'Installed-Size: %s\n' "$SIZE" >> "$STAGE/DEBIAN/control"
find "$STAGE" -name .DS_Store -delete
dpkg-deb --root-owner-group -Zgzip -b "$STAGE" "build/com.rinapple.switzachwidgetprobe_${VERSION}_iphoneos-arm64e.deb"

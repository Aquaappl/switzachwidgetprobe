// SwitzachWidgetProbe: home screen widgets for the apps installed in the Switzach ROM.
//
// Loaded into SpringBoard. Only the ROM's home screen (NXHomeScreenViewController) is touched;
// in any other process with SpringBoard's bundle id nothing is done.

#import "WGSpringBoard.h"

__attribute__((constructor)) static void WGInit(void) {
    @autoreleasepool {
        if (!objc_getClass("NXHomeScreenViewController") || !objc_getClass("SBHIconManager")) return;
        WGLogRotate();
        WGLogSetTag(@"");
        WGSettingsInstall();
        WGHomeInstall();
        WGWidgetViewsInstall();
        NSLog(@"[SwitzachWidgetProbe] %s loaded", WG_VERSION);
    }
}

#import "../common/WGShared.h"

// The app's shared data for its widget (WGSharedData.m).

// Finds the extension's App Groups (cached in workDir until the build changes). Any thread.
FOUNDATION_EXPORT void WGSharedDataFindGroups(WGExtension *ext, NSString *workDir);
// Redirects the groups to the app's data container and watches them. Main thread, once.
FOUNDATION_EXPORT void WGSharedDataSetUp(WGExtension *ext, NSString *workDir);
// Before the widget's code fetches data: what it writes itself in the next seconds is ignored.
FOUNDATION_EXPORT void WGSharedDataWillRender(void);

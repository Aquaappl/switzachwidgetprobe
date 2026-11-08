// The SwitzachWidgetProbe page in TweakSettings / Settings (loaded by PreferenceLoader).
// The switch is written by PSListController itself (defaults / key / PostNotification in
// Root.plist); the buttons record the time of their request, which SpringBoard acts on
// (WGSettings.m).

#import <UIKit/UIKit.h>

@interface PSSpecifier : NSObject
@end

@interface PSListController : UIViewController {
    NSArray *_specifiers;
}
- (NSMutableArray *)loadSpecifiersFromPlistName:(NSString *)name target:(id)target;
@end

@interface SWPRootListController : PSListController
- (void)request:(NSString *)key;
@end

static NSString *const kSWPDomain = @"com.rinapple.switzachwidgetprobe";
static NSString *const kSWPChanged = @"com.rinapple.switzachwidgetprobe/settings";

@implementation SWPRootListController

- (NSArray *)specifiers {
    if (!_specifiers) _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    return _specifiers;
}

// A button's request: its time, which SpringBoard acts on (WGSettings.m).
- (void)request:(NSString *)key {
    CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFNumberRef)@(CFAbsoluteTimeGetCurrent()), (__bridge CFStringRef)kSWPDomain);
    CFPreferencesAppSynchronize((__bridge CFStringRef)kSWPDomain);
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), (__bridge CFStringRef)kSWPChanged, NULL, NULL, YES);
}

- (void)restartWidgets:(PSSpecifier *)specifier {
    [self request:@"RestartRequest"];
    UIAlertController *done = [UIAlertController alertControllerWithTitle:@"Restarting Widgets"
                                                                  message:@"The widgets on the home screen are drawn anew within a few seconds."
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [done addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:done animated:YES completion:nil];
}

- (void)resetSafetyGuards:(PSSpecifier *)specifier {
    UIAlertController *ask = [UIAlertController
        alertControllerWithTitle:@"Reset Widget Safety Guards"
                         message:@"Widgets and the parts of them that were stopped after a crash will be tried again."
                  preferredStyle:UIAlertControllerStyleAlert];
    [ask addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [ask addAction:[UIAlertAction actionWithTitle:@"Reset" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        [weakSelf request:@"ResetRequest"];
        UIAlertController *done = [UIAlertController alertControllerWithTitle:@"Reset Requested"
                                                                      message:@"The home screen tries the stopped parts again within a few seconds."
                                                               preferredStyle:UIAlertControllerStyleAlert];
        [done addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
        [weakSelf presentViewController:done animated:YES completion:nil];
    }]];
    [self presentViewController:ask animated:YES completion:nil];
}

@end

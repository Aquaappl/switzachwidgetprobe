// The SwitzachWidgetProbe page in TweakSettings / Settings (loaded by PreferenceLoader).
// The switch is written by PSListController itself (defaults / key / PostNotification in
// Root.plist); the reset button records the time of the request, which SpringBoard acts on
// (WPSettings.m).

#import <UIKit/UIKit.h>

@interface PSSpecifier : NSObject
@end

@interface PSListController : UIViewController {
    NSArray *_specifiers;
}
- (NSMutableArray *)loadSpecifiersFromPlistName:(NSString *)name target:(id)target;
@end

@interface SWPRootListController : PSListController
@end

static NSString *const kSWPDomain = @"com.rinapple.switzachwidgetprobe";
static NSString *const kSWPChanged = @"com.rinapple.switzachwidgetprobe/settings";

@implementation SWPRootListController

- (NSArray *)specifiers {
    if (!_specifiers) _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    return _specifiers;
}

- (void)resetSafetyGuards:(PSSpecifier *)specifier {
    UIAlertController *ask = [UIAlertController
        alertControllerWithTitle:@"Reset Widget Safety Guards"
                         message:@"Buttons, settings and data loading that were stopped after a crash will be tried again."
                  preferredStyle:UIAlertControllerStyleAlert];
    [ask addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [ask addAction:[UIAlertAction actionWithTitle:@"Reset" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        CFPreferencesSetAppValue(CFSTR("ResetRequest"), (__bridge CFNumberRef)@(CFAbsoluteTimeGetCurrent()), (__bridge CFStringRef)kSWPDomain);
        CFPreferencesAppSynchronize((__bridge CFStringRef)kSWPDomain);
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), (__bridge CFStringRef)kSWPChanged, NULL, NULL, YES);
        UIAlertController *done = [UIAlertController alertControllerWithTitle:@"Reset Requested"
                                                                      message:@"The home screen tries the stopped parts again within a few seconds."
                                                               preferredStyle:UIAlertControllerStyleAlert];
        [done addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
        [weakSelf presentViewController:done animated:YES completion:nil];
    }]];
    [self presentViewController:ask animated:YES completion:nil];
}

@end

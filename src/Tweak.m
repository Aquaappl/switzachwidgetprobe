// SwitzachWidgetProbe
// Puts the widgets of ROM-installed (sideloaded) apps on the Switzach home screen.
// "+" menu > Add Widget opens the add sheet. The settings (TweakSettings / Settings >
// SwitzachWidgetProbe) hold the rest: the diagnostic log and resetting the safety guards.

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "WPProbe.h"

void WPHomeInstall(void);
void WPHomeOpenAddSheet(UIViewController *home);
void WPSettingsInstall(void);

@interface NXHomeScreenViewController : UIViewController
- (UIMenu *)addButtonMenu;
@end

#pragma mark - Hook

static IMP orig_addButtonMenu;

static UIMenu *hook_addButtonMenu(UIViewController *self, SEL _cmd) {
    UIMenu *menu = ((UIMenu *(*)(id, SEL))orig_addButtonMenu)(self, _cmd);
    if (![menu isKindOfClass:[UIMenu class]]) return menu;
    __weak UIViewController *weakSelf = self;
    UIAction *add = [UIAction actionWithTitle:@"Add Widget"
                                        image:[UIImage systemImageNamed:@"square.grid.2x2"]
                                   identifier:nil
                                      handler:^(UIAction *a) { WPHomeOpenAddSheet(weakSelf); }];
    NSMutableArray *children = [menu.children mutableCopy] ?: [NSMutableArray array];
    [children addObject:add];
    return [menu menuByReplacingChildren:children];
}

__attribute__((constructor)) static void WPInit(void) {
    Class cls = objc_getClass("NXHomeScreenViewController");
    if (!cls) return;
    SEL sel = @selector(addButtonMenu);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    WPSettingsInstall();
    class_addMethod(cls, sel, method_getImplementation(m), method_getTypeEncoding(m));
    m = class_getInstanceMethod(cls, sel);
    orig_addButtonMenu = method_setImplementation(m, (IMP)hook_addButtonMenu);
    WPHomeInstall();
    NSLog(@"[WidgetProbe] loaded");
}

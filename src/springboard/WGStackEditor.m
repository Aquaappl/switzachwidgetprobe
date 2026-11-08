// Edit Stack (long-press menu of a stack): a sheet of our own with the widgets of the stack, to
// reorder or remove. SpringBoardHome's own card does not show on this ROM (it opened with
// nothing on screen), so it is not used.

#import "WGSpringBoard.h"

#pragma mark - Our sheet

@interface WGStackEditorViewController : UITableViewController
- (instancetype)initWithIcon:(id)icon;
@end

@implementation WGStackEditorViewController {
    __weak id _icon;
    NSMutableArray *_widgets;
}

- (instancetype)initWithIcon:(id)icon {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _icon = icon;
        _widgets = [WGIconWidgets(icon) mutableCopy];
        self.title = @"Edit Stack";
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel target:self
                                                                                          action:@selector(cancel)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self
                                                                                           action:@selector(done)];
    self.tableView.editing = YES;
    self.tableView.allowsSelectionDuringEditing = NO;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return _widgets.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return @"Drag to change the order. The widget at the top shows first.";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"w"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                                                                                         reuseIdentifier:@"w"];
    id widget = _widgets[indexPath.row];
    WGExtension *ext = [WGExtensions extensionWithID:WGCall(widget, @"extensionBundleIdentifier")];
    id name = WGCall(widget, @"displayName");
    cell.textLabel.text = ext.appName ?: @"Widget";
    cell.detailTextLabel.text = [name isKindOfClass:[NSString class]] ? name : WGCall(widget, @"kind");
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    return cell;
}

- (BOOL)tableView:(UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)indexPath {
    return YES;
}

- (void)tableView:(UITableView *)tableView moveRowAtIndexPath:(NSIndexPath *)from toIndexPath:(NSIndexPath *)to {
    id w = _widgets[from.row];
    [_widgets removeObjectAtIndex:from.row];
    [_widgets insertObject:w atIndex:to.row];
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath {
    return UITableViewCellEditingStyleDelete;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)style forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (style != UITableViewCellEditingStyleDelete) return;
    [_widgets removeObjectAtIndex:indexPath.row];
    [tableView deleteRowsAtIndexPaths:@[ indexPath ] withRowAnimation:UITableViewRowAnimationAutomatic];
    self.navigationItem.rightBarButtonItem.enabled = _widgets.count > 0;
}

- (void)cancel {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)done {
    id icon = _icon;
    NSArray *widgets = [_widgets copy];
    [self dismissViewControllerAnimated:YES completion:^{
        if (icon) WGApplyStackOrder(icon, widgets);
    }];
}

@end

void WGApplyStackOrder(id icon, NSArray *widgets) {
    NSArray *before = WGIconWidgets(icon);
    if (!widgets.count || [before isEqualToArray:widgets]) return;
    id active = WGCall(icon, @"activeWidget");
    void (^update)(void) = ^{
        for (id w in before) {
            if (![widgets containsObject:w]) WGSend1(icon, @"removeIconDataSource:", w);
        }
        // In the new order: each one taken out and put back at the end.
        for (id w in widgets) {
            WGSend1(icon, @"removeIconDataSource:", w);
            WGSend1(icon, @"addIconDataSource:", w);
        }
    };
    SEL coalesced = NSSelectorFromString(@"performCoalescedDataSourceUpdate:");
    @try {
        if ([icon respondsToSelector:coalesced]) ((void (*)(id, SEL, id))objc_msgSend)(icon, coalesced, update);
        else update();
        if (active && [widgets containsObject:active]) WGSend1(icon, @"setActiveWidget:", active);
        else WGSend1(icon, @"setActiveWidget:", widgets.firstObject);
    } @catch (NSException *e) {
        WGLogImportant(@"Edit Stack: could not apply (%@)", e.reason);
    }
    WGLog(@"Edit Stack: %lu → %lu widget(s)%@", (unsigned long)before.count, (unsigned long)WGIconWidgets(icon).count,
          [WGIconWidgets(icon) isEqualToArray:widgets] ? @"" : @" (not as asked)");
    WGSaveIconState();
}

static void WGPresentStackSheet(UIView *iconView, id icon) {
    UIViewController *top = iconView.window.rootViewController;
    while (top.presentedViewController) top = top.presentedViewController;
    if (!top) return;
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:[[WGStackEditorViewController alloc] initWithIcon:icon]];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    UISheetPresentationController *sheet = nav.sheetPresentationController;
    sheet.detents = @[ UISheetPresentationControllerDetent.mediumDetent, UISheetPresentationControllerDetent.largeDetent ];
    sheet.prefersGrabberVisible = YES;
    [top presentViewController:nav animated:YES completion:nil];
}

void WGEditStack(UIView *iconView, id icon) {
    WGLog(@"Edit Stack: %lu widget(s)", (unsigned long)WGIconWidgets(icon).count);
    WGPresentStackSheet(iconView, icon);
}

// Edit Widget (long-press menu): the settings of a widget configured with a SiriKit intent, as
// the app defines them (its .intentdefinition), with the choices its Intents extension gives.
// Each widget keeps its own (under its unique identifier); its host reads and saves them.

#import "WGSpringBoard.h"

NSString *WGWidgetConfigKey(id widget) {
    id u = WGCall(widget, @"uniqueIdentifier");
    return [u isKindOfClass:[NSString class]] && [u length] ? u : nil;
}

static WGExtension *WGWidgetExtension(id widget) {
    id extID = WGCall(widget, @"extensionBundleIdentifier");
    return [extID isKindOfClass:[NSString class]] ? [WGExtensions extensionWithID:extID] : nil;
}

BOOL WGWidgetIsEditable(id widget) {
    WGExtension *ext = WGWidgetExtension(widget);
    NSString *kind = WGCall(widget, @"kind");
    if (!ext || ![kind isKindOfClass:[NSString class]] || !WGWidgetConfigKey(widget)) return NO;
    for (NSDictionary *w in [WGHost hostForExtension:ext].widgets) {
        if ([w[@"kind"] isEqual:kind]) return [w[@"editable"] boolValue];
    }
    return NO;
}

#pragma mark - Choices

@interface WGWidgetChoicesViewController : UITableViewController
@property (nonatomic, copy) void (^chosen)(NSDictionary *value); // {index} or {indexes}
@end

@implementation WGWidgetChoicesViewController {
    NSArray<NSDictionary *> *_options; // {title, subtitle?}
    NSString *_message;
    BOOL _multiple;
    NSMutableSet<NSNumber *> *_picked;
    NSString *_current;
}

- (instancetype)initWithTitle:(NSString *)title current:(NSString *)current multiple:(BOOL)multiple {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        self.title = title;
        _current = current;
        _multiple = multiple;
        _picked = [NSMutableSet set];
        _message = @"Loading…";
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    if (_multiple) {
        self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self
                                                                                               action:@selector(done)];
    }
}

- (void)showOptions:(NSArray<NSDictionary *> *)options message:(NSString *)message {
    _options = options;
    _message = options.count ? nil : (message ?: @"No choices.");
    if (_multiple && _current.length) { // what is chosen now, by title
        NSArray *now = [_current componentsSeparatedByString:@", "];
        for (NSUInteger i = 0; i < options.count; i++) if ([now containsObject:options[i][@"title"]]) [_picked addObject:@(i)];
    }
    [self.tableView reloadData];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return _options.count ?: 1;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    if (!_options.count) {
        cell.textLabel.text = _message;
        cell.textLabel.textColor = UIColor.secondaryLabelColor;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }
    NSDictionary *o = _options[indexPath.row];
    cell.textLabel.text = o[@"title"];
    cell.detailTextLabel.text = o[@"subtitle"];
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    BOOL on = _multiple ? [_picked containsObject:@(indexPath.row)] : [o[@"title"] isEqual:_current];
    cell.accessoryType = on ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (!_options.count) return;
    if (_multiple) {
        NSNumber *n = @(indexPath.row);
        if ([_picked containsObject:n]) [_picked removeObject:n];
        else [_picked addObject:n];
        [tableView reloadRowsAtIndexPaths:@[ indexPath ] withRowAnimation:UITableViewRowAnimationNone];
        return;
    }
    if (self.chosen) self.chosen(@{ @"index" : @(indexPath.row) });
    [self.navigationController popViewControllerAnimated:YES];
}

- (void)done {
    NSArray *indexes = [_picked.allObjects sortedArrayUsingSelector:@selector(compare:)];
    if (self.chosen) self.chosen(@{ @"indexes" : indexes });
    [self.navigationController popViewControllerAnimated:YES];
}

@end

#pragma mark - Settings

@interface WGWidgetSettingsViewController : UITableViewController
- (instancetype)initWithWidget:(id)widget;
@end

@implementation WGWidgetSettingsViewController {
    WGExtension *_ext;
    NSString *_kind, *_config;
    NSArray<NSDictionary *> *_params;
    NSString *_message;
}

- (instancetype)initWithWidget:(id)widget {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _ext = WGWidgetExtension(widget);
        _kind = [WGCall(widget, @"kind") copy];
        _config = WGWidgetConfigKey(widget);
        id name = WGCall(widget, @"displayName");
        self.title = [name isKindOfClass:[NSString class]] ? name : (_ext.appName ?: @"Widget");
        _message = @"Loading…";
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self
                                                                                           action:@selector(close)];
    [self reload];
}

- (void)close {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (NSDictionary *)base {
    return @{ @"kind" : _kind ?: @"", @"config" : _config ?: @"" };
}

- (void)reload {
    if (!_ext) return;
    NSMutableDictionary *m = [[self base] mutableCopy];
    m[WGOp] = @"config-params";
    __weak typeof(self) weakSelf = self;
    [[WGHost hostForExtension:_ext] request:m timeout:10 reply:^(NSDictionary *r) {
        typeof(self) s = weakSelf;
        if (!s) return;
        NSArray *params = [r[@"params"] isKindOfClass:[NSArray class]] ? r[@"params"] : nil;
        s->_params = params;
        s->_message = params.count ? nil : ([r[@"error"] description] ?: (r ? @"This widget has no settings." : @"The widget did not answer."));
        WGLog(@"Edit Widget: %@ %lu setting(s)%@", s->_kind, (unsigned long)params.count, s->_message ? [@": " stringByAppendingString:s->_message] : @"");
        [s.tableView reloadData];
    }];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return _params.count ?: 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return _params.count ? _ext.appName : nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    if (!_params.count) {
        cell.textLabel.text = _message;
        cell.textLabel.textColor = UIColor.secondaryLabelColor;
        cell.textLabel.numberOfLines = 0;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }
    NSDictionary *p = _params[indexPath.row];
    NSString *kind = p[@"kind"];
    cell.textLabel.text = p[@"title"];
    if ([kind isEqual:@"bool"]) {
        UISwitch *sw = [UISwitch new];
        sw.on = [p[@"value"] isEqual:@"1"];
        sw.tag = indexPath.row;
        [sw addTarget:self action:@selector(switched:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else {
        cell.detailTextLabel.text = [p[@"value"] length] ? p[@"value"] : @"Choose";
        BOOL editable = [@[ @"enum", @"object", @"objects", @"string" ] containsObject:kind];
        cell.accessoryType = editable && ![kind isEqual:@"string"] ? UITableViewCellAccessoryDisclosureIndicator : UITableViewCellAccessoryNone;
        if (!editable) {
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            cell.textLabel.textColor = UIColor.secondaryLabelColor;
        }
    }
    return cell;
}

- (void)set:(NSString *)name value:(NSDictionary *)value {
    NSMutableDictionary *m = [[self base] mutableCopy];
    m[WGOp] = @"config-set";
    m[@"param"] = name;
    m[@"value"] = value;
    __weak typeof(self) weakSelf = self;
    [[WGHost hostForExtension:_ext] request:m timeout:10 reply:^(NSDictionary *r) {
        typeof(self) s = weakSelf;
        if (!r[@"ok"]) {
            UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Could Not Change"
                                                                        message:[r[@"error"] description] ?: @"The widget did not answer."
                                                                 preferredStyle:UIAlertControllerStyleAlert];
            [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
            [s presentViewController:a animated:YES completion:nil];
        }
        [s reload];
    }];
}

- (void)switched:(UISwitch *)sw {
    if ((NSUInteger)sw.tag < _params.count) [self set:_params[sw.tag][@"name"] value:@{ @"bool" : @(sw.on) }];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.row >= (NSInteger)_params.count) return;
    NSDictionary *p = _params[indexPath.row];
    NSString *kind = p[@"kind"], *name = p[@"name"];
    __weak typeof(self) weakSelf = self;
    if ([kind isEqual:@"string"]) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:p[@"title"] message:nil preferredStyle:UIAlertControllerStyleAlert];
        [a addTextFieldWithConfigurationHandler:^(UITextField *f) { f.text = p[@"value"]; }];
        [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
        __weak UIAlertController *weakAlert = a;
        [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
            [weakSelf set:name value:@{ @"string" : weakAlert.textFields.firstObject.text ?: @"" }];
        }]];
        [self presentViewController:a animated:YES completion:nil];
        return;
    }
    if (![@[ @"enum", @"object", @"objects" ] containsObject:kind]) return;
    WGWidgetChoicesViewController *choices = [[WGWidgetChoicesViewController alloc] initWithTitle:p[@"title"] current:p[@"value"]
                                                                                         multiple:[kind isEqual:@"objects"]];
    choices.chosen = ^(NSDictionary *value) { [weakSelf set:name value:value]; };
    [self.navigationController pushViewController:choices animated:YES];
    if ([kind isEqual:@"enum"]) {
        NSMutableArray *options = [NSMutableArray array];
        for (NSString *t in p[@"values"]) [options addObject:@{ @"title" : t }];
        [choices showOptions:options message:nil];
        return;
    }
    NSMutableDictionary *m = [[self base] mutableCopy];
    m[WGOp] = @"config-options";
    m[@"param"] = name;
    __weak WGWidgetChoicesViewController *weakChoices = choices;
    [[WGHost hostForExtension:_ext] request:m timeout:20 reply:^(NSDictionary *r) {
        NSArray *options = [r[@"options"] isKindOfClass:[NSArray class]] ? r[@"options"] : @[];
        [weakChoices showOptions:options message:[r[@"error"] description] ?: (r ? nil : @"The app did not answer.")];
    }];
}

@end

void WGEditWidget(UIView *iconView, id widget) {
    UIViewController *top = iconView.window.rootViewController;
    while (top.presentedViewController) top = top.presentedViewController;
    if (!top || !widget) return;
    WGLog(@"Edit Widget: %@", WGCall(widget, @"kind"));
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:[[WGWidgetSettingsViewController alloc] initWithWidget:widget]];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    UISheetPresentationController *sheet = nav.sheetPresentationController;
    sheet.detents = @[ UISheetPresentationControllerDetent.mediumDetent, UISheetPresentationControllerDetent.largeDetent ];
    sheet.prefersGrabberVisible = YES;
    [top presentViewController:nav animated:YES completion:nil];
}

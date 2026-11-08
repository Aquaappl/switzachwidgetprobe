// The widget gallery ("+" › Add Widget), as on iOS: suggested widgets at the top, the apps with
// widgets below, search; an app's page shows each of its widgets in each of its sizes. Previews
// are the widgets themselves, drawn by their hosts in the home screen's current style. Opening
// the gallery starts no host: suggestions come from hosts that already listed their widgets.

#import "WGSpringBoard.h"

#pragma mark - Helpers

static BOOL WGIsPad(void) {
    return UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad;
}

// The home screen sizes a widget offers: what it declares, else what its kind suggests
// ("….small"), else small, medium and large.
static NSArray<NSString *> *WGFamiliesOf(NSDictionary *w) {
    NSArray *declared = w[@"families"];
    if ([declared isKindOfClass:[NSArray class]]) {
        return [declared filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSString *f, NSDictionary *b) {
            return ![f isEqual:@"extraLarge"] || WGIsPad();
        }]];
    }
    NSString *kind = [w[@"kind"] lowercaseString];
    NSMutableArray *guess = [NSMutableArray array];
    for (NSString *size in @[ @"small", @"medium", @"large" ]) if ([kind containsString:size]) [guess addObject:size];
    return guess.count ? guess : @[ @"small", @"medium", @"large" ];
}

static NSArray<NSDictionary *> *WGHomeWidgets(NSArray<NSDictionary *> *widgets) {
    return [widgets filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *w, NSDictionary *b) {
        return WGFamiliesOf(w).count > 0;
    }]];
}

// A readable name when the widget has none: the meaningful end of its kind.
static NSString *WGWidgetTitle(NSDictionary *w, WGExtension *ext) {
    NSString *name = w[@"name"];
    if ([name isKindOfClass:[NSString class]] && name.length) return name;
    NSMutableArray *parts = [[[w[@"kind"] ?: @"" componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"._-"]]
                              filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]] mutableCopy];
    NSSet *noise = [NSSet setWithArray:@[ @"widget", @"widgets", @"small", @"medium", @"large", @"com", @"jp", @"app", @"extension" ]];
    while (parts.count && [noise containsObject:[parts.lastObject lowercaseString]]) [parts removeLastObject];
    NSString *last = parts.lastObject;
    if (last.length) {
        NSString *spaced = [last stringByReplacingOccurrencesOfString:@"([a-z])([A-Z])" withString:@"$1 $2" options:NSRegularExpressionSearch
                                                                range:NSMakeRange(0, last.length)];
        spaced = [[spaced stringByReplacingOccurrencesOfString:@"Widget" withString:@""] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (spaced.length) return [[spaced substringToIndex:1].uppercaseString stringByAppendingString:[spaced substringFromIndex:1]];
    }
    return ext.appName;
}

UIImage *WGAppIcon(WGExtension *ext) {
    static NSCache *cache;
    if (!cache) cache = [NSCache new];
    UIImage *img = [cache objectForKey:ext.appID];
    if (img) return img;
    @try {
        id leaf = WGCall1(WGCall(WGIconManager(), @"iconModel"), @"leafIconForIdentifier:", ext.appID);
        id dataSource = WGCall(leaf, @"activeDataSource");
        Class leafClass = NSClassFromString(@"SBLeafIcon");
        SEL imageSel = NSSelectorFromString(@"iconImageForDataSource:ofIcon:info:");
        if (leaf && dataSource && [leafClass respondsToSelector:imageSel]) {
            WGIconImageInfo info = { CGSizeMake(60, 60), UIScreen.mainScreen.scale, 13.5 };
            img = ((id (*)(id, SEL, id, id, WGIconImageInfo))objc_msgSend)(leafClass, imageSel, dataSource, leaf, info);
        }
    } @catch (NSException *e) {
        img = nil;
    }
    if (![img isKindOfClass:[UIImage class]]) img = nil;
    if (!img) {
        NSBundle *bundle = [NSBundle bundleWithPath:ext.appPath];
        NSDictionary *icons = [bundle objectForInfoDictionaryKey:@"CFBundleIcons"][@"CFBundlePrimaryIcon"];
        NSMutableArray *names = [NSMutableArray array];
        if ([icons[@"CFBundleIconFiles"] isKindOfClass:[NSArray class]]) [names addObjectsFromArray:[icons[@"CFBundleIconFiles"] reverseObjectEnumerator].allObjects];
        if ([icons[@"CFBundleIconName"] isKindOfClass:[NSString class]]) [names addObject:icons[@"CFBundleIconName"]];
        for (NSString *n in names) if ((img = [UIImage imageNamed:n inBundle:bundle compatibleWithTraitCollection:nil])) break;
    }
    if (!img) img = [UIImage systemImageNamed:@"app.fill"];
    [cache setObject:img forKey:ext.appID];
    return img;
}

static UIViewController *WGPreview(WGExtension *ext, NSString *kind, WGFamily family) {
    WGWidgetViewController *vc = [[WGWidgetViewController alloc] initWithExtension:ext kind:kind family:family];
    vc.preview = YES;
    [vc setImageInfo:WGImageInfoForFamily(family)];
    return vc;
}

static void WGAlert(UIViewController *on, NSString *title, NSString *message) {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [on presentViewController:alert animated:YES completion:nil];
}

#pragma mark - An app's widgets

@interface WGGalleryDetailViewController : UIViewController <UIScrollViewDelegate>
@property (nonatomic, strong) WGExtension *extension;
@property (nonatomic, copy) NSArray<NSDictionary *> *widgets;
@property (nonatomic, copy) NSString *startKind;
@end

@implementation WGGalleryDetailViewController {
    NSArray<NSDictionary *> *_pages; // {widget, family}
    UIScrollView *_scroll;
    UIPageControl *_dots;
    NSMutableDictionary<NSNumber *, UIView *> *_pageViews;
    NSInteger _current;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    NSMutableArray *pages = [NSMutableArray array];
    NSInteger start = -1;
    for (NSDictionary *w in self.widgets) {
        if (start < 0 && [w[@"kind"] isEqual:self.startKind]) start = (NSInteger)pages.count;
        for (NSString *f in WGFamiliesOf(w)) [pages addObject:@{ @"widget" : w, @"family" : @(WGFamilyFromName(f)) }];
    }
    _pages = pages;
    _pageViews = [NSMutableDictionary dictionary];
    _current = MAX(0, start);

    UIImageView *icon = [[UIImageView alloc] initWithImage:WGAppIcon(self.extension)];
    icon.layer.cornerRadius = 6;
    icon.layer.cornerCurve = kCACornerCurveContinuous;
    icon.clipsToBounds = YES;
    UILabel *appName = [UILabel new];
    appName.text = self.extension.appName;
    appName.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    UIButton *close = [UIButton buttonWithType:UIButtonTypeClose];
    [close addTarget:self action:@selector(close) forControlEvents:UIControlEventTouchUpInside];

    _scroll = [UIScrollView new];
    _scroll.pagingEnabled = YES;
    _scroll.showsHorizontalScrollIndicator = NO;
    _scroll.delegate = self;
    _dots = [UIPageControl new];
    _dots.numberOfPages = (NSInteger)pages.count;
    _dots.currentPage = _current;
    _dots.hidesForSinglePage = YES;
    _dots.currentPageIndicatorTintColor = UIColor.labelColor;
    _dots.pageIndicatorTintColor = UIColor.tertiaryLabelColor;
    [_dots addTarget:self action:@selector(dotsChanged) forControlEvents:UIControlEventValueChanged];

    UIButtonConfiguration *config = [UIButtonConfiguration filledButtonConfiguration];
    config.title = @"Add Widget";
    config.image = [UIImage systemImageNamed:@"plus.circle.fill"];
    config.imagePadding = 6;
    config.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    UIButton *add = [UIButton buttonWithConfiguration:config primaryAction:nil];
    add.enabled = pages.count > 0;
    [add addTarget:self action:@selector(addCurrent) forControlEvents:UIControlEventTouchUpInside];

    for (UIView *v in @[ icon, appName, close, _scroll, _dots, add ]) {
        v.translatesAutoresizingMaskIntoConstraints = NO;
        [self.view addSubview:v];
    }
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [icon.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:20],
        [icon.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:22],
        [icon.widthAnchor constraintEqualToConstant:26], [icon.heightAnchor constraintEqualToConstant:26],
        [appName.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor constant:10],
        [appName.centerYAnchor constraintEqualToAnchor:icon.centerYAnchor],
        [appName.trailingAnchor constraintLessThanOrEqualToAnchor:close.leadingAnchor constant:-10],
        [close.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-18],
        [close.centerYAnchor constraintEqualToAnchor:icon.centerYAnchor],
        [_scroll.topAnchor constraintEqualToAnchor:icon.bottomAnchor constant:18],
        [_scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_scroll.bottomAnchor constraintEqualToAnchor:_dots.topAnchor constant:-6],
        [_dots.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [_dots.bottomAnchor constraintEqualToAnchor:add.topAnchor constant:-14],
        [add.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:20],
        [add.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-20],
        [add.heightAnchor constraintEqualToConstant:50],
        [add.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-12],
    ]];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGSize s = _scroll.bounds.size;
    if (s.width < 10) return;
    _scroll.contentSize = CGSizeMake(s.width * _pages.count, s.height);
    for (NSNumber *key in _pageViews) [self layoutPage:_pageViews[key] index:key.integerValue];
    if (!_scroll.isDragging && !_scroll.isDecelerating) _scroll.contentOffset = CGPointMake(_current * s.width, 0);
    [self loadPagesAround:_current];
}

// Pages are made when they come near (each one draws its widget).
- (void)loadPagesAround:(NSInteger)index {
    for (NSInteger i = index - 1; i <= index + 1; i++) {
        if (i < 0 || i >= (NSInteger)_pages.count || _pageViews[@(i)]) continue;
        UIView *page = [self makePage:i];
        _pageViews[@(i)] = page;
        [_scroll addSubview:page];
        [self layoutPage:page index:i];
    }
}

- (UIView *)makePage:(NSInteger)index {
    NSDictionary *w = _pages[index][@"widget"];
    WGFamily family = (WGFamily)[_pages[index][@"family"] intValue];
    UIView *page = [UIView new];
    UILabel *title = [UILabel new];
    title.text = WGWidgetTitle(w, self.extension);
    title.font = [UIFont systemFontOfSize:28 weight:UIFontWeightBold];
    title.textAlignment = NSTextAlignmentCenter;
    title.adjustsFontSizeToFitWidth = YES;
    title.minimumScaleFactor = 0.6;
    title.tag = 1;
    UILabel *desc = [UILabel new];
    desc.text = [w[@"description"] isKindOfClass:[NSString class]] ? w[@"description"] : @"";
    desc.font = [UIFont systemFontOfSize:15];
    desc.textColor = UIColor.secondaryLabelColor;
    desc.textAlignment = NSTextAlignmentCenter;
    desc.numberOfLines = 3;
    desc.tag = 2;
    [page addSubview:title];
    [page addSubview:desc];
    UIViewController *preview = WGPreview(self.extension, w[@"kind"], family);
    [self addChildViewController:preview];
    WGIconImageInfo info = WGImageInfoForFamily(family);
    preview.view.bounds = CGRectMake(0, 0, info.size.width, info.size.height);
    preview.view.tag = 3;
    UIView *shadow = [UIView new]; // a soft shadow under the widget, as in the gallery
    shadow.tag = 4;
    shadow.layer.shadowColor = UIColor.blackColor.CGColor;
    shadow.layer.shadowOpacity = 0.18;
    shadow.layer.shadowRadius = 14;
    shadow.layer.shadowOffset = CGSizeMake(0, 6);
    [shadow addSubview:preview.view];
    [page addSubview:shadow];
    [preview didMoveToParentViewController:self];
    return page;
}

- (void)layoutPage:(UIView *)page index:(NSInteger)index {
    CGSize s = _scroll.bounds.size;
    page.frame = CGRectMake(index * s.width, 0, s.width, s.height);
    UIView *title = [page viewWithTag:1], *shadow = [page viewWithTag:4], *preview = [page viewWithTag:3];
    UILabel *desc = (UILabel *)[page viewWithTag:2];
    CGFloat inset = 28;
    title.frame = CGRectMake(inset, 4, s.width - inset * 2, 36);
    CGSize d = [desc sizeThatFits:CGSizeMake(s.width - inset * 2, 80)];
    desc.frame = CGRectMake(inset, 46, s.width - inset * 2, MIN(d.height, 60));
    CGFloat top = CGRectGetMaxY(desc.frame) + 16, room = MAX(40, s.height - top - 8);
    CGSize real = preview.bounds.size;
    CGFloat scale = MIN(1, MIN((s.width - 32) / MAX(real.width, 1), room / MAX(real.height, 1)));
    shadow.bounds = CGRectMake(0, 0, real.width, real.height);
    shadow.center = CGPointMake(s.width / 2, top + room / 2);
    shadow.transform = CGAffineTransformMakeScale(scale, scale);
    preview.frame = shadow.bounds;
    shadow.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:shadow.bounds cornerRadius:preview.layer.cornerRadius].CGPath;
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    CGFloat w = scrollView.bounds.size.width;
    if (w < 1) return;
    NSInteger page = MAX(0, MIN((NSInteger)_pages.count - 1, (NSInteger)lround(scrollView.contentOffset.x / w)));
    if (page == _current) return;
    _current = page;
    _dots.currentPage = page;
    [self loadPagesAround:page];
}

- (void)dotsChanged {
    _current = _dots.currentPage;
    [_scroll setContentOffset:CGPointMake(_current * _scroll.bounds.size.width, 0) animated:YES];
    [self loadPagesAround:_current];
}

- (void)close {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)addCurrent {
    if (_current < 0 || _current >= (NSInteger)_pages.count) return;
    NSDictionary *p = _pages[_current];
    NSString *error = WGInsertWidget(self.extension, p[@"widget"][@"kind"], (WGFamily)[p[@"family"] intValue]);
    if (error) {
        WGAlert(self, @"Could Not Add Widget", error);
        return;
    }
    // Close the whole gallery, as iOS does.
    UIViewController *gallery = self.presentingViewController;
    [(gallery.presentingViewController ?: gallery) dismissViewControllerAnimated:YES completion:nil];
}

@end

#pragma mark - The gallery

@interface WGGalleryViewController : UIViewController <UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate>
@end

@implementation WGGalleryViewController {
    UISearchBar *_search;
    UITableView *_table;
    NSArray<WGExtension *> *_apps, *_shown;
    NSArray<NSDictionary *> *_suggestions; // {ext, widget, family}
    CGFloat _builtWidth;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    _search = [UISearchBar new];
    _search.searchBarStyle = UISearchBarStyleMinimal;
    _search.placeholder = @"Search Widgets";
    _search.delegate = self;
    _table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    _table.dataSource = self;
    _table.delegate = self;
    _table.backgroundColor = UIColor.clearColor;
    _table.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    _table.rowHeight = 52;
    for (UIView *v in @[ _search, _table ]) {
        v.translatesAutoresizingMaskIntoConstraints = NO;
        [self.view addSubview:v];
    }
    [NSLayoutConstraint activateConstraints:@[
        [_search.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:18],
        [_search.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:10],
        [_search.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-10],
        [_table.topAnchor constraintEqualToAnchor:_search.bottomAnchor constant:4],
        [_table.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_table.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_table.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];
    [self reloadApps];
    // Apps installed since the last look show up a moment later.
    __weak typeof(self) weakSelf = self;
    [WGExtensions refresh:^{ [weakSelf reloadApps]; }];
}

- (void)reloadApps {
    _apps = [[[WGExtensions all].allValues filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(WGExtension *e, NSDictionary *b) {
        NSArray *listed = [WGHost hostForExtension:e].widgets;
        return !listed || WGHomeWidgets(listed).count > 0; // apps whose widgets are all for elsewhere are left out
    }]] sortedArrayUsingComparator:^NSComparisonResult(WGExtension *a, WGExtension *b) { return [a.appName localizedStandardCompare:b.appName]; }];
    [self filter];
}

- (BOOL)matches:(WGExtension *)e query:(NSString *)q {
    if (!q.length || [e.appName rangeOfString:q options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    for (NSDictionary *w in [WGHost hostForExtension:e].widgets ?: @[]) {
        if ([WGWidgetTitle(w, e) rangeOfString:q options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    }
    return NO;
}

- (void)filter {
    NSString *q = _search.text;
    _shown = [_apps filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(WGExtension *e, NSDictionary *b) { return [self matches:e query:q]; }]];
    [self buildSuggestions];
    [_table reloadData];
}

// One suggestion per app (its first home screen widget), at the widget's real size (smaller only
// when it does not fit), in centered rows that wrap: two small ones beside a larger one on an
// iPhone, more on an iPad.
- (void)buildSuggestions {
    NSMutableArray *items = [NSMutableArray array];
    for (WGExtension *ext in _shown) {
        for (NSDictionary *w in WGHomeWidgets([WGHost hostForExtension:ext].widgets ?: @[])) {
            [items addObject:@{ @"ext" : ext, @"widget" : w, @"family" : @(WGFamilyFromName(WGFamiliesOf(w).firstObject)) }];
            break;
        }
        if (items.count >= 8) break;
    }
    _suggestions = items;
    for (UIViewController *c in self.childViewControllers.copy) {
        [c willMoveToParentViewController:nil];
        [c.view removeFromSuperview];
        [c removeFromParentViewController];
    }
    CGFloat width = self.view.bounds.size.width > 10 ? self.view.bounds.size.width : UIScreen.mainScreen.bounds.size.width;
    _builtWidth = width;
    if (!items.count) {
        _table.tableHeaderView = nil;
        return;
    }
    UIView *container = [UIView new];
    CGFloat inset = 20, gap = 14, available = width - inset * 2;
    __block CGFloat y = 8, rowWidth = 0, rowHeight = 0;
    NSMutableArray<UIView *> *row = [NSMutableArray array];
    void (^finishRow)(void) = ^{
        CGFloat x = inset + (available - rowWidth) / 2;
        for (UIView *tile in row) {
            tile.frame = CGRectMake(x, y, tile.bounds.size.width, tile.bounds.size.height);
            x += tile.bounds.size.width + gap;
        }
        if (row.count) y += rowHeight + 6;
        [row removeAllObjects];
        rowWidth = rowHeight = 0;
    };
    for (NSUInteger i = 0; i < items.count; i++) {
        NSDictionary *it = items[i];
        WGFamily family = (WGFamily)[it[@"family"] intValue];
        WGIconImageInfo info = WGImageInfoForFamily(family);
        CGFloat scale = MIN(1, available / MAX(info.size.width, 1));
        CGFloat w = info.size.width * scale, h = info.size.height * scale;
        UIButton *tile = [UIButton buttonWithType:UIButtonTypeCustom];
        tile.bounds = CGRectMake(0, 0, w, h + 40);
        tile.tag = (NSInteger)i;
        [tile addTarget:self action:@selector(openSuggestion:) forControlEvents:UIControlEventTouchUpInside];
        UIViewController *preview = WGPreview(it[@"ext"], it[@"widget"][@"kind"], family);
        [self addChildViewController:preview];
        preview.view.bounds = CGRectMake(0, 0, info.size.width, info.size.height);
        preview.view.transform = CGAffineTransformMakeScale(scale, scale);
        preview.view.center = CGPointMake(w / 2, h / 2);
        preview.view.userInteractionEnabled = NO;
        [tile addSubview:preview.view];
        [preview didMoveToParentViewController:self];
        UILabel *app = [UILabel new];
        app.text = ((WGExtension *)it[@"ext"]).appName;
        app.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
        app.textAlignment = NSTextAlignmentCenter;
        app.frame = CGRectMake(0, h + 6, w, 17);
        UILabel *sub = [UILabel new];
        sub.text = WGWidgetTitle(it[@"widget"], it[@"ext"]);
        sub.font = [UIFont systemFontOfSize:12];
        sub.textColor = UIColor.secondaryLabelColor;
        sub.textAlignment = NSTextAlignmentCenter;
        sub.frame = CGRectMake(0, h + 22, w, 16);
        [tile addSubview:app];
        [tile addSubview:sub];
        [container addSubview:tile];
        if (row.count && rowWidth + gap + w > available) finishRow();
        rowWidth += (row.count ? gap : 0) + w;
        rowHeight = MAX(rowHeight, h + 40);
        [row addObject:tile];
    }
    finishRow();
    container.frame = CGRectMake(0, 0, width, y);
    _table.tableHeaderView = container;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    if (_suggestions.count && fabs(_builtWidth - self.view.bounds.size.width) > 1) [self buildSuggestions];
}

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)text {
    [self filter];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    [searchBar resignFirstResponder];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return MAX(1, (NSInteger)_shown.count);
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return WGHomeDrawingStopped() ? @"Widgets are not drawn during this launch: SpringBoard ended repeatedly just before." : nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
    UIListContentConfiguration *c = [UIListContentConfiguration cellConfiguration];
    if (!_shown.count) {
        c.text = _search.text.length ? @"No Results" : [@"No apps with widgets\n\n" stringByAppendingString:WGFilesystemSandboxHint];
        c.textProperties.color = UIColor.secondaryLabelColor;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else {
        WGExtension *e = _shown[indexPath.row];
        c.text = e.appName;
        c.image = WGAppIcon(e);
        c.imageProperties.maximumSize = CGSizeMake(32, 32);
        c.imageProperties.cornerRadius = 7.5;
        c.imageToTextPadding = 14;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    cell.contentConfiguration = c;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (!_shown.count) return;
    WGExtension *e = _shown[indexPath.row];
    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
    UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    cell.accessoryView = spinner;
    [spinner startAnimating];
    tableView.userInteractionEnabled = NO;
    __weak typeof(self) weakSelf = self;
    [[WGHost hostForExtension:e] loadWidgets:^{
        tableView.userInteractionEnabled = YES;
        cell.accessoryView = nil;
        [weakSelf openApp:e startKind:nil];
        [weakSelf buildSuggestions];
    }];
}

- (void)openSuggestion:(UIButton *)tile {
    if (tile.tag < 0 || tile.tag >= (NSInteger)_suggestions.count) return;
    NSDictionary *it = _suggestions[tile.tag];
    [self openApp:it[@"ext"] startKind:it[@"widget"][@"kind"]];
}

- (void)openApp:(WGExtension *)ext startKind:(NSString *)kind {
    if (!self.view.window) return;
    WGHost *host = [WGHost hostForExtension:ext];
    NSArray *all = host.widgets ?: @[], *widgets = WGHomeWidgets(all);
    if (!widgets.count) {
        NSString *message = host.blocked ? WGFilesystemSandboxMessage
                            : host.disabled ? @"This app's widgets keep crashing. They are tried again after a respring."
                            : all.count ? @"This app's widgets are for the Lock Screen and cannot be placed on the Home Screen."
                                        : @"No widgets were found.";
        WGAlert(self, ext.appName, message);
        return;
    }
    WGGalleryDetailViewController *detail = [WGGalleryDetailViewController new];
    detail.extension = ext;
    detail.widgets = widgets;
    detail.startKind = kind;
    detail.modalPresentationStyle = UIModalPresentationPageSheet;
    detail.sheetPresentationController.detents = @[ UISheetPresentationControllerDetent.largeDetent ];
    [self presentViewController:detail animated:YES completion:nil];
}

@end

void WGGalleryOpen(UIViewController *home) {
    UIViewController *top = home;
    while (top.presentedViewController) top = top.presentedViewController;
    WGGalleryViewController *gallery = [WGGalleryViewController new];
    gallery.modalPresentationStyle = UIModalPresentationPageSheet;
    UISheetPresentationController *sheet = gallery.sheetPresentationController;
    sheet.detents = @[ UISheetPresentationControllerDetent.largeDetent ];
    sheet.prefersGrabberVisible = YES;
    [top presentViewController:gallery animated:YES completion:nil];
}

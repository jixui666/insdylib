// ProfileButtons.m
//
// 在 Instagram 个人主页「编辑主页 / 分析」按钮行下面，插入 N 个自定义按钮，
// 点击用「应用内浏览器」打开网页（默认 SFSafariViewController，可切换成自绘 WKWebView）。
//
// 目标 App：com.burbn.instagram 451.0.0（本 IPA 内已核实存在
//          accessibilityIdentifier = "edit_profile_button"，Swift 类是
//          IGProfile.IGProfileViewController）。
//
// 构建：Theos（见 README.md，可全程用 GitHub Actions 出 dylib，不需要 Mac）。
// 注入：Sideloadly「Tweak Injection」/ ESign「注入 dylib」/ TrollFools。

#import <UIKit/UIKit.h>
#import <SafariServices/SafariServices.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>

#define PB_LOG(fmt, ...) NSLog(@"[ProfileButtons] " fmt, ##__VA_ARGS__)

// ---------------------------------------------------------------------------
// MARK: - 常量 / 配置
// ---------------------------------------------------------------------------

static NSString *const PBRowIdentifier = @"pb_profile_buttons_row";
static NSString *const PBConfigName   = @"PBConfig";       // App 包内 PBConfig.plist
static const NSInteger PBRowTag       = 0x5042;            // 'PB'

// 找不到 accessibilityIdentifier 时的兜底文字匹配（多语言）
static NSArray<NSString *> *PBEditTitles(void) {
    return @[
        @"编辑主页", @"編輯主頁", @"编辑个人主页", @"編輯個人主頁",
        @"Edit profile", @"Edit Profile", @"Modifier le profil",
        @"Editar perfil", @"プロフィールを編集", @"프로필 편집",
        @"Profil bearbeiten", @"Modifica profilo",
    ];
}

// PBConfig.plist 缺省值（用户不提供配置文件时用这三条）
static NSArray<NSDictionary *> *PBDefaultButtons(void) {
    return @[
        @{ @"Title": @"官网", @"URL": @"https://example.com",        @"Icon": @"globe" },
        @{ @"Title": @"客服", @"URL": @"https://example.com/support", @"Icon": @"bubble.left" },
        @{ @"Title": @"社群", @"URL": @"https://example.com/group",   @"Icon": @"person.2.fill" },
    ];
}

static NSDictionary *PBConfig(void) {
    static NSDictionary *cfg;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *path = [[NSBundle mainBundle] pathForResource:PBConfigName ofType:@"plist"];
        NSDictionary *d = path ? [NSDictionary dictionaryWithContentsOfFile:path] : nil;
        cfg = [d isKindOfClass:[NSDictionary class]] ? d : @{};
        PB_LOG(@"config %@ (%@)", cfg.count ? @"loaded" : @"not found, using defaults", path ?: @"-");
    });
    return cfg;
}

static NSArray<NSDictionary *> *PBButtonConfigs(void) {
    NSArray *arr = PBConfig()[@"Buttons"];
    if ([arr isKindOfClass:[NSArray class]] && arr.count > 0) return arr;
    return PBDefaultButtons();
}

static BOOL PBDebug(void) {
    id v = PBConfig()[@"Debug"];
    return v ? [v boolValue] : NO;
}

static BOOL PBUseSafariViewController(void) {
    id v = PBConfig()[@"UseSafariViewController"];
    return v ? [v boolValue] : YES;
}

// ---------------------------------------------------------------------------
// MARK: - 通用：找 VC / 找视图 / 打印层级
// ---------------------------------------------------------------------------

static UIViewController *PBTopViewController(void) {
    UIWindow *keyWindow = nil;
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) {
            if (w.isKeyWindow) { keyWindow = w; break; }
        }
        if (keyWindow) break;
    }
    if (!keyWindow) keyWindow = [UIApplication sharedApplication].keyWindow;

    UIViewController *vc = keyWindow.rootViewController;
    while (YES) {
        UIViewController *next = nil;
        if (vc.presentedViewController) next = vc.presentedViewController;
        else if ([vc isKindOfClass:[UITabBarController class]]) next = ((UITabBarController *)vc).selectedViewController;
        else if ([vc isKindOfClass:[UINavigationController class]]) next = ((UINavigationController *)vc).topViewController;
        else if ([vc isKindOfClass:[UISplitViewController class]]) {
            UISplitViewController *s = (UISplitViewController *)vc;
            next = s.viewControllers.lastObject;
        }
        if (!next || next == vc) break;
        vc = next;
    }
    return vc;
}

static BOOL PBIsProfileViewController(UIViewController *vc) {
    if (!vc) return NO;
    NSString *name = NSStringFromClass([vc class]);
    // Swift 运行时类名形如 "IGProfile.IGProfileViewController"
    return [name containsString:@"IGProfileViewController"];
}

static NSString *PBViewOwnText(UIView *v) {
    if ([v isKindOfClass:[UIButton class]]) {
        UIButton *b = (UIButton *)v;
        NSString *t = [b titleForState:b.state];
        if (t.length == 0) t = b.currentTitle;
        if (t.length == 0) t = b.titleLabel.text;
        if (t.length) return t;
    }
    if ([v isKindOfClass:[UILabel class]]) {
        return ((UILabel *)v).text;
    }
    return nil;
}

static BOOL PBTextMatchesEditProfile(NSString *text) {
    if (text.length == 0) return NO;
    NSString *t = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    for (NSString *candidate in PBEditTitles()) {
        if ([t caseInsensitiveCompare:candidate] == NSOrderedSame) return YES;
    }
    for (NSString *candidate in PBEditTitles()) {
        if ([t localizedCaseInsensitiveContainsString:candidate]) return YES;
    }
    return NO;
}

// 从任意视图向上找最近的 UIControl（IG 的按钮常是自绘控件 + 内部 UILabel）
static UIControl *PBEnclosingControl(UIView *v) {
    UIView *cur = v;
    for (int i = 0; i < 8 && cur; i++, cur = cur.superview) {
        if ([cur isKindOfClass:[UIControl class]]) return (UIControl *)cur;
    }
    return nil;
}

static UIView *PBFindEditProfileAnchor(UIView *root) {
    if (!root) return nil;

    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:root];
    NSInteger visited = 0;
    while (queue.count > 0 && visited < 12000) {
        UIView *v = queue.firstObject;
        [queue removeObjectAtIndex:0];
        visited++;

        // 1) IG 自己给这个按钮挂了无障碍标识，最可靠
        NSString *ident = v.accessibilityIdentifier;
        if (ident.length &&
            ([ident isEqualToString:@"edit_profile_button"] ||
             [ident localizedCaseInsensitiveContainsString:@"edit_profile"])) {
            return v;
        }

        // 2) 文字兜底（按钮本身、按钮内部 label、accessibilityLabel）
        NSString *text = PBViewOwnText(v);
        if (PBTextMatchesEditProfile(text)) {
            UIControl *control = PBEnclosingControl(v);
            if (control) return control;
            if (v.userInteractionEnabled) return v;
        }
        NSString *a11y = v.accessibilityLabel;
        if (a11y.length && PBTextMatchesEditProfile(a11y)) {
            UIControl *control = PBEnclosingControl(v);
            if (control) return control;
        }

        [queue addObjectsFromArray:v.subviews];
    }
    return nil;
}

static void PBDumpAncestors(UIView *v, const char *why) {
    NSMutableString *chain = [NSMutableString string];
    UIView *cur = v;
    for (int i = 0; i < 12 && cur; i++, cur = cur.superview) {
        [chain appendFormat:@"\n    %@ frame=%@ id=%@ constraints=%lu",
                            NSStringFromClass([cur class]),
                            NSStringFromCGRect(cur.frame),
                            cur.accessibilityIdentifier ?: @"-",
                            (unsigned long)cur.constraints.count];
    }
    PB_LOG(@"[dump:%s] ancestors of %@:%@", why, NSStringFromClass([v class]), chain);
}

static void PBDumpTree(UIView *v, NSInteger depth, NSInteger maxDepth) {
    if (!v || depth > maxDepth) return;
    PB_LOG(@"%*s%@ frame=%@ id=%@", (int)(depth * 2), "",
           NSStringFromClass([v class]), NSStringFromCGRect(v.frame),
           v.accessibilityIdentifier ?: @"-");
    for (UIView *s in v.subviews) PBDumpTree(s, depth + 1, maxDepth);
}

// ---------------------------------------------------------------------------
// MARK: - 应用内浏览器
// ---------------------------------------------------------------------------

@interface PBWebViewController : UIViewController <WKNavigationDelegate>
@property (nonatomic, strong) NSURL *url;
@property (nonatomic, strong) WKWebView *webView;
@end

@implementation PBWebViewController

- (instancetype)initWithURL:(NSURL *)url {
    if (self = [super initWithNibName:nil bundle:nil]) {
        _url = url;
        self.title = url.host ?: @"网页";
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    WKWebViewConfiguration *cfg = [WKWebViewConfiguration new];
    cfg.allowsInlineMediaPlayback = YES;
    _webView = [[WKWebView alloc] initWithFrame:CGRectZero configuration:cfg];
    _webView.navigationDelegate = self;
    _webView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_webView];
    [NSLayoutConstraint activateConstraints:@[
        [_webView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [_webView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_webView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_webView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];

    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"关闭" style:UIBarButtonItemStylePlain
                                        target:self action:@selector(close:)];
    self.navigationItem.rightBarButtonItems = @[
        [[UIBarButtonItem alloc] initWithTitle:@"刷新" style:UIBarButtonItemStylePlain
                                        target:self action:@selector(reload:)],
        [[UIBarButtonItem alloc] initWithTitle:@"后退" style:UIBarButtonItemStylePlain
                                        target:self action:@selector(goBack:)],
    ];

    [_webView loadRequest:[NSURLRequest requestWithURL:_url]];
}

- (void)close:(id)sender { [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)reload:(id)sender { [_webView reload]; }
- (void)goBack:(id)sender { if (_webView.canGoBack) [_webView goBack]; }

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    NSString *title = webView.title;
    if (title.length) self.title = title;
}

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation
       withError:(NSError *)error {
    PB_LOG(@"webview failed: %@", error.localizedDescription);
}

@end

// ---------------------------------------------------------------------------
// MARK: - 按钮点击处理
// ---------------------------------------------------------------------------

static const char kPBURLKey;

@interface PBButtonActionHandler : NSObject
+ (instancetype)shared;
- (void)tapButton:(UIButton *)sender;
@end

@implementation PBButtonActionHandler

+ (instancetype)shared {
    static PBButtonActionHandler *handler;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ handler = [PBButtonActionHandler new]; });
    return handler;
}

- (void)tapButton:(UIButton *)sender {
    NSURL *url = objc_getAssociatedObject(sender, &kPBURLKey);
    if (!url) { PB_LOG(@"button has no url"); return; }

    UIViewController *top = PBTopViewController();
    if (!top) return;

    BOOL http = [[url.scheme lowercaseString] isEqualToString:@"http"] ||
                [[url.scheme lowercaseString] isEqualToString:@"https"];

    if (!http) {
        // 非 http(s)，交给系统（可写 tg:// instagram:// mailto: 之类）
        [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
        return;
    }

    PB_LOG(@"opening %@ from %@", url.absoluteString, NSStringFromClass([top class]));

    if (PBUseSafariViewController()) {
        SFSafariViewControllerConfiguration *cfg = [SFSafariViewControllerConfiguration new];
        cfg.barCollapsingEnabled = NO;
        SFSafariViewController *svc = [[SFSafariViewController alloc] initWithURL:url configuration:cfg];
        svc.dismissButtonStyle = SFSafariViewControllerDismissButtonStyleClose;
        svc.preferredControlTintColor = [UIColor labelColor];
        svc.modalPresentationStyle = UIModalPresentationPageSheet;
        [top presentViewController:svc animated:YES completion:nil];
    } else {
        PBWebViewController *wvc = [[PBWebViewController alloc] initWithURL:url];
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:wvc];
        nav.modalPresentationStyle = UIModalPresentationPageSheet;
        [top presentViewController:nav animated:YES completion:nil];
    }
}

@end

// ---------------------------------------------------------------------------
// MARK: - 造按钮 / 造按钮行 / 插入
// ---------------------------------------------------------------------------

static UIButton *PBMakeButton(NSDictionary *cfg) {
    NSString *title = cfg[@"Title"];
    if (![title isKindOfClass:[NSString class]] || title.length == 0) title = @"链接";
    NSString *urlString = cfg[@"URL"];
    NSString *iconName = cfg[@"Icon"];

    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];

    UIButtonConfiguration *conf = [UIButtonConfiguration tintedButtonConfiguration];
    UIFont *font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    conf.attributedTitle = [[NSAttributedString alloc] initWithString:title
                                                          attributes:@{ NSFontAttributeName: font }];
    if ([iconName isKindOfClass:[NSString class]] && iconName.length) {
        UIImage *icon = [UIImage systemImageNamed:iconName];
        if (icon) {
            conf.image = icon;
            conf.imagePadding = 4.0;
            conf.imagePlacement = NSDirectionalRectEdgeLeading;
        }
    }
    conf.baseForegroundColor = [UIColor labelColor];
    conf.background.backgroundColor = [UIColor tertiarySystemFillColor];
    conf.cornerStyle = UIButtonConfigurationCornerStyleMedium;
    conf.contentInsets = NSDirectionalEdgeInsetsMake(6, 8, 6, 8);
    button.configuration = conf;
    button.configurationUpdateHandler = ^(UIButton *b) {
        b.alpha = b.isHighlighted ? 0.55 : 1.0;
    };
    button.accessibilityLabel = title;

    NSURL *url = [urlString isKindOfClass:[NSString class]] ? [NSURL URLWithString:urlString] : nil;
    if (url) objc_setAssociatedObject(button, &kPBURLKey, url, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    [button addTarget:[PBButtonActionHandler shared]
               action:@selector(tapButton:)
     forControlEvents:UIControlEventTouchUpInside];
    return button;
}

static UIView *PBMakeRow(void) {
    UIStackView *row = [[UIStackView alloc] init];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.spacing = 8.0;
    row.distribution = UIStackViewDistributionFillEqually;
    row.alignment = UIStackViewAlignmentFill;
    row.tag = PBRowTag;
    row.accessibilityIdentifier = PBRowIdentifier;
    row.translatesAutoresizingMaskIntoConstraints = NO;

    for (NSDictionary *cfg in PBButtonConfigs()) {
        if (![cfg isKindOfClass:[NSDictionary class]]) continue;
        [row addArrangedSubview:PBMakeButton(cfg)];
    }
    [row.heightAnchor constraintEqualToConstant:36.0].active = YES;
    return row;
}

// 在 stack 的 arrangedSubviews 里找「包含 target 的那一项」的下标
static NSInteger PBArrangedIndexForView(UIStackView *stack, UIView *target) {
    NSArray<UIView *> *arranged = stack.arrangedSubviews;
    for (NSUInteger i = 0; i < arranged.count; i++) {
        UIView *item = arranged[i];
        if (item == target) return (NSInteger)i;
        UIView *p = target;
        while ((p = p.superview)) {
            if (p == item) return (NSInteger)i;
            if (p == stack) break;
        }
    }
    return NSNotFound;
}

// 方案 A：插进「竖直 UIStackView」里，紧跟按钮行之后 —— 最干净，IG 自己会把下面的内容推开
static BOOL PBInsertIntoVerticalStack(UIView *anchor, UIView *row) {
    UIView *cur = anchor;
    for (int depth = 0; depth < 10 && cur; depth++, cur = cur.superview) {
        if (![cur isKindOfClass:[UIStackView class]]) continue;
        UIStackView *stack = (UIStackView *)cur;
        if (stack.axis != UILayoutConstraintAxisVertical) continue;
        NSInteger idx = PBArrangedIndexForView(stack, anchor);
        if (idx != NSNotFound) {
            [stack insertArrangedSubview:row atIndex:(NSUInteger)(idx + 1)];
            PB_LOG(@"inserted into vertical stack %@ at index %ld",
                   NSStringFromClass([stack class]), (long)(idx + 1));
            return YES;
        }
    }
    return NO;
}

// 方案 B：用 Auto Layout 挂到按钮行容器的下方，并尝试把容器高度约束撑大
static BOOL PBInsertBelowContainer(UIView *anchor, UIView *row) {
    UIView *rowContainer = anchor.superview;          // 装按钮的那一层
    UIView *parent = rowContainer.superview;          // header 内容视图
    if (!rowContainer || !parent) return NO;

    const CGFloat spacing = 8.0;
    const CGFloat height  = 36.0;

    [parent addSubview:row];
    [NSLayoutConstraint activateConstraints:@[
        [row.leadingAnchor constraintEqualToAnchor:rowContainer.leadingAnchor],
        [row.trailingAnchor constraintEqualToAnchor:rowContainer.trailingAnchor],
        [row.topAnchor constraintEqualToAnchor:rowContainer.bottomAnchor constant:spacing],
    ]];

    BOOL grew = NO;
    for (NSLayoutConstraint *c in parent.constraints) {
        if (c.firstItem == parent &&
            c.firstAttribute == NSLayoutAttributeHeight &&
            c.relation == NSLayoutRelationEqual) {
            c.constant += (height + spacing);
            grew = YES;
            break;
        }
    }
    [parent setNeedsLayout];
    PB_LOG(@"attached below %@ in %@ (grewHeight=%d)",
           NSStringFromClass([rowContainer class]), NSStringFromClass([parent class]), grew);

    if (!grew && PBDebug()) {
        PBDumpAncestors(anchor, "below-container");
    }
    return YES;
}

// 方案 C（兜底）：主页底部悬浮一条，保证一定能看到
static void PBDockToViewController(UIViewController *vc, UIView *row) {
    [vc.view addSubview:row];
    [NSLayoutConstraint activateConstraints:@[
        [row.leadingAnchor constraintEqualToAnchor:vc.view.leadingAnchor constant:16.0],
        [row.trailingAnchor constraintEqualToAnchor:vc.view.trailingAnchor constant:-16.0],
        [row.bottomAnchor constraintEqualToAnchor:vc.view.safeAreaLayoutGuide.bottomAnchor constant:-10.0],
    ]];
    PB_LOG(@"docked fallback row to %@", NSStringFromClass([vc class]));
}

// ---------------------------------------------------------------------------
// MARK: - 安装
// ---------------------------------------------------------------------------

static const char kPBInstalledRowKey;
static const char kPBLastAttemptKey;
static const char kPBFailCountKey;

static void PBInstallForViewController(UIViewController *vc) {
    if (!vc.view || vc.view.window == nil) return;

    // 已经装过且还在视图树上 → 直接返回
    UIView *existing = objc_getAssociatedObject(vc, &kPBInstalledRowKey);
    if (existing && existing.window != nil) return;

    // 别人的主页没有「编辑主页」按钮，试几次就别再扫了，省性能
    NSNumber *fails = objc_getAssociatedObject(vc, &kPBFailCountKey);
    if (fails.integerValue >= 8) return;

    // 同一个页面 4 秒内只尝试一次，避免看门狗刷日志
    NSTimeInterval now = CACurrentMediaTime();
    NSNumber *last = objc_getAssociatedObject(vc, &kPBLastAttemptKey);
    if (last && now - last.doubleValue < 4.0) return;
    objc_setAssociatedObject(vc, &kPBLastAttemptKey, @(now), OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    UIView *anchor = PBFindEditProfileAnchor(vc.view);
    if (!anchor) {
        NSUInteger count = fails.unsignedIntegerValue + 1;
        objc_setAssociatedObject(vc, &kPBFailCountKey, @(count), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (count <= 2) {
            PB_LOG(@"edit-profile button not found in %@ (attempt %lu/8)",
                   NSStringFromClass([vc class]), (unsigned long)count);
            if (PBDebug()) PBDumpTree(vc.view, 0, 6);
        }
        return;
    }

    PBDumpAncestors(anchor, "anchor");

    UIView *row = PBMakeRow();
    BOOL ok = PBInsertIntoVerticalStack(anchor, row);
    if (!ok) ok = PBInsertBelowContainer(anchor, row);
    if (!ok) PBDockToViewController(vc, row);

    objc_setAssociatedObject(vc, &kPBInstalledRowKey, row, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    PB_LOG(@"installed %lu button(s) (%@)",
           (unsigned long)PBButtonConfigs().count, ok ? @"in header" : @"docked");
}

// ---------------------------------------------------------------------------
// MARK: - Hook：所有 VC 的 viewDidAppear（profile 页出现时安装）
// ---------------------------------------------------------------------------

typedef void (*PBViewDidAppearIMP)(id, SEL, BOOL);
static PBViewDidAppearIMP PBOrigViewDidAppear;

static void PBViewDidAppear(id self, SEL _cmd, BOOL animated) {
    if (PBOrigViewDidAppear) PBOrigViewDidAppear(self, _cmd, animated);
    UIViewController *vc = (UIViewController *)self;
    if (PBIsProfileViewController(vc)) {
        dispatch_async(dispatch_get_main_queue(), ^{
            PBInstallForViewController(vc);
        });
    }
}

// 看门狗：兜底 profile 页不会走 viewDidAppear 的情况（如页面复用 / 热重载）
static void PBStartWatchdog(void) {
    NSTimer *timer = [NSTimer scheduledTimerWithTimeInterval:1.5 repeats:YES block:^(NSTimer *t) {
        UIViewController *vc = PBTopViewController();
        if (PBIsProfileViewController(vc)) PBInstallForViewController(vc);
    }];
    timer.tolerance = 0.5;
}

__attribute__((constructor)) static void PBInit(void) {
    @autoreleasepool {
        Class cls = [UIViewController class];
        Method m = class_getInstanceMethod(cls, @selector(viewDidAppear:));
        if (m) {
            PBOrigViewDidAppear = (PBViewDidAppearIMP)method_getImplementation(m);
            method_setImplementation(m, (IMP)PBViewDidAppear);
        }
        PB_LOG(@"loaded (buttons=%lu, safari=%d, debug=%d)",
               (unsigned long)PBButtonConfigs().count, PBUseSafariViewController(), PBDebug());
        PBStartWatchdog();
    }
}

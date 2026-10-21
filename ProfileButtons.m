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
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

#define PB_LOG(fmt, ...) NSLog(@"[ProfileButtons] " fmt, ##__VA_ARGS__)

// ---------------------------------------------------------------------------
// MARK: - 常量 / 配置
// ---------------------------------------------------------------------------

static NSString *const PBRowIdentifier = @"pb_profile_buttons_row";
static NSString *const PBConfigName   = @"PBConfig";       // App 包内 PBConfig.plist
static const NSInteger PBRowTag       = 0x5042;            // 'PB'

static const char kPBTrackerKey;

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

// 按钮行放在「编辑主页」行的上方（默认）还是下方。
// 下放在某些账号上会被 IG 自己的按钮（专业账户 / 推广 / 分享等）盖住，所以默认 above。
static BOOL PBPositionAbove(void) {
    NSString *pos = PBConfig()[@"Position"];
    if ([pos isKindOfClass:[NSString class]]) {
        return !([pos caseInsensitiveCompare:@"below"] == NSOrderedSame);
    }
    return YES;
}

// 强制悬浮：不做头部插入，直接贴在安全区顶部（排障用，保证一定能看到）
static BOOL PBForceDock(void) {
    id v = PBConfig()[@"ForceDock"];
    return v ? [v boolValue] : NO;
}

static BOOL PBShouldShowLaunchToast(void) {
    id v = PBConfig()[@"ShowLaunchToast"];
    if (v) return [v boolValue];
    return PBDebug();
}

static CGFloat PBRowHeight(void) {
    id v = PBConfig()[@"RowHeight"];
    return v ? [v doubleValue] : 36.0;
}

static CGFloat PBOverlayHeight(void) {
    id v = PBConfig()[@"OverlayHeight"];
    return v ? [v doubleValue] : 28.0;
}

static CGFloat PBOverlayGap(void) {
    id v = PBConfig()[@"OverlayGap"];
    return v ? [v doubleValue] : 4.0;
}

// ---------------------------------------------------------------------------
// MARK: - 通用：找 VC / 找视图 / 打印层级
// ---------------------------------------------------------------------------

static UIWindow *PBKeyWindow(void) {
    // iOS 13+ 多场景：只从 UIWindowScene 取，避免用已弃用的 UIApplication.keyWindow
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) {
            if (w.isKeyWindow) return w;
        }
    }
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        NSArray<UIWindow *> *windows = ((UIWindowScene *)scene).windows;
        if (windows.count) return windows.firstObject;
    }
    return nil;
}

static UIViewController *PBTopViewController(void) {
    UIWindow *keyWindow = PBKeyWindow();

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
    // Swift 运行时类名形如 "IGProfile.IGProfileViewController"。
    // 放宽到「名字里有 Profile 且不是编辑资料页」，避免 IG 升级换类名后完全失配。
    if ([name containsString:@"Profile"] == NO) return NO;
    if ([name containsString:@"EditProfile"]) return NO;
    if ([name containsString:@"BusinessProfile"]) return NO;
    return YES;
}

// IG 的「按钮」不一定是 UIControl：也可能是带点击手势的自绘视图
static UIView *PBTappableAncestor(UIView *v) {
    UIView *cur = v;
    for (int i = 0; i < 10 && cur; i++, cur = cur.superview) {
        if ([cur isKindOfClass:[UIControl class]]) return cur;
        for (UIGestureRecognizer *g in cur.gestureRecognizers) {
            if ([g isKindOfClass:[UITapGestureRecognizer class]]) return cur;
        }
        NSString *cls = NSStringFromClass([cur class]);
        if ([cls containsString:@"Button"] || [cls containsString:@"ActionRow"]) return cur;
    }
    return nil;
}

static NSString *PBViewOwnText(UIView *v) {
    if ([v isKindOfClass:[UIButton class]]) {
        UIButton *b = (UIButton *)v;
        NSString *t = [b titleForState:b.state];
        if (t.length == 0) t = b.currentTitle;
        if (t.length == 0) t = b.titleLabel.text;
        if (t.length == 0) t = [b attributedTitleForState:b.state].string;
        if (t.length == 0 && b.configuration) t = b.configuration.title;
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

static UIView *PBFindEditProfileAnchor(UIView *root) {
    if (!root) return nil;

    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:root];
    NSInteger visited = 0;
    while (queue.count > 0 && visited < 12000) {
        UIView *v = queue.firstObject;
        [queue removeObjectAtIndex:0];
        visited++;

        BOOL matched = NO;

        // 1) IG 自己给这个按钮挂了无障碍标识，最可靠
        NSString *ident = v.accessibilityIdentifier;
        if (ident.length &&
            ([ident isEqualToString:@"edit_profile_button"] ||
             [ident localizedCaseInsensitiveContainsString:@"edit_profile"])) {
            matched = YES;
        }

        // 2) 文字兜底（按钮本身、按钮内部 label、accessibilityLabel、attributed title）
        if (!matched && PBTextMatchesEditProfile(PBViewOwnText(v))) matched = YES;
        if (!matched && PBTextMatchesEditProfile(v.accessibilityLabel)) matched = YES;

        if (matched) {
            UIView *tappable = PBTappableAncestor(v);
            if (tappable) return tappable;
            if (v.userInteractionEnabled && v.bounds.size.width > 60) return v;
            // 文字命中但暂时找不到可点的祖先：返回最上层那个有尺寸的祖先
            UIView *up = v.superview;
            for (int i = 0; i < 6 && up; i++, up = up.superview) {
                if (up.bounds.size.width > 60 && up.bounds.size.height > 20) return up;
            }
        }

        [queue addObjectsFromArray:v.subviews];
    }
    return nil;
}

// 在 root 里找「所有可能是按钮」的可点视图，仅用于 debug 日志
static NSArray<NSString *> *PBSampleTappableViews(UIView *root) {
    NSMutableArray<NSString *> *result = [NSMutableArray array];
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:root];
    NSInteger visited = 0;
    while (queue.count > 0 && visited < 12000 && result.count < 40) {
        UIView *v = queue.firstObject;
        [queue removeObjectAtIndex:0];
        visited++;
        BOOL tappable = [v isKindOfClass:[UIControl class]] || v.gestureRecognizers.count > 0;
        NSString *text = PBViewOwnText(v) ?: v.accessibilityLabel;
        if (tappable && (text.length || v.accessibilityIdentifier.length)) {
            [result addObject:[NSString stringWithFormat:@"%@(%@) id=%@ text=%@",
                               NSStringFromClass([v class]),
                               NSStringFromCGRect(v.frame),
                               v.accessibilityIdentifier ?: @"-",
                               text ?: @"-"]];
        }
        [queue addObjectsFromArray:v.subviews];
    }
    return result;
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

// 方案 A：插进「竖直 UIStackView」里，紧贴按钮行上方（或下方）
// —— 最干净，IG 自己会把其他内容推开
static BOOL PBInsertIntoVerticalStack(UIView *anchor, UIView *row) {
    BOOL above = PBPositionAbove();
    UIView *cur = anchor;
    for (int depth = 0; depth < 10 && cur; depth++, cur = cur.superview) {
        if (![cur isKindOfClass:[UIStackView class]]) continue;
        UIStackView *stack = (UIStackView *)cur;
        if (stack.axis != UILayoutConstraintAxisVertical) continue;
        NSInteger idx = PBArrangedIndexForView(stack, anchor);
        if (idx != NSNotFound) {
            NSUInteger insertAt = above ? (NSUInteger)idx : (NSUInteger)(idx + 1);
            [row.heightAnchor constraintEqualToConstant:PBRowHeight()].active = YES;
            [stack insertArrangedSubview:row atIndex:insertAt];
            PB_LOG(@"inserted into vertical stack %@ at index %lu (%@)",
                   NSStringFromClass([stack class]), (unsigned long)insertAt,
                   above ? @"above" : @"below");
            return YES;
        }
    }
    return NO;
}

// 在所有祖先前置约束里调整 view 的某个属性（用来给上方腾出空间）
static BOOL PBAdjustConstraint(UIView *view, NSLayoutAttribute attr, CGFloat delta) {
    NSMutableArray<UIView *> *candidates = [NSMutableArray arrayWithObject:view];
    UIView *a = view.superview;
    for (int depth = 0; depth < 8 && a; depth++, a = a.superview) {
        [candidates addObject:a];
    }
    for (UIView *owner in candidates) {
        for (NSLayoutConstraint *c in owner.constraints) {
            if (c.relation != NSLayoutRelationEqual) continue;
            if (c.firstAttribute != attr) continue;
            if (c.firstItem != view) continue;
            c.constant += delta;
            return YES;
        }
    }
    return NO;
}

// 方案 B：用 Auto Layout 挂到按钮行容器的上方（或下方）。
// above 模式下还会把按钮行整体下移 44pt、并把父视图高度撑大，避免压住上面的简介/统计。
static BOOL PBInsertRelativeToContainer(UIView *anchor, UIView *row) {
    UIView *rowContainer = anchor.superview;          // 装按钮的那一层
    UIView *parent = rowContainer.superview;          // header 内容视图
    if (!rowContainer || !parent) return NO;

    const CGFloat spacing = 8.0;
    const CGFloat height  = PBRowHeight();
    const CGFloat delta   = height + spacing;
    BOOL above = PBPositionAbove();

    [row.heightAnchor constraintEqualToConstant:height].active = YES;
    [parent addSubview:row];
    if (above) {
        [NSLayoutConstraint activateConstraints:@[
            [row.leadingAnchor constraintEqualToAnchor:rowContainer.leadingAnchor],
            [row.trailingAnchor constraintEqualToAnchor:rowContainer.trailingAnchor],
            [row.bottomAnchor constraintEqualToAnchor:rowContainer.topAnchor constant:-spacing],
        ]];
    } else {
        [NSLayoutConstraint activateConstraints:@[
            [row.leadingAnchor constraintEqualToAnchor:rowContainer.leadingAnchor],
            [row.trailingAnchor constraintEqualToAnchor:rowContainer.trailingAnchor],
            [row.topAnchor constraintEqualToAnchor:rowContainer.bottomAnchor constant:spacing],
        ]];
    }

    BOOL shifted = NO, grew = NO;
    if (above) {
        // 把按钮行以及它下面的内容整体推下去，腾出 44pt。
        // 推不动说明父视图是手写 frame / 顶部被裁，硬放在这里会完全看不见，
        // 直接放弃 header 方案，交给 dock 兜底。
        shifted = PBAdjustConstraint(rowContainer, NSLayoutAttributeTop, delta);
        if (!shifted) {
            [row removeFromSuperview];
            PB_LOG(@"above-mode: no shiftable top constraint on %@ — fallback to dock",
                   NSStringFromClass([rowContainer class]));
            return NO;
        }
    }
    // 撑大父视图，否则新加的空间会被裁掉
    for (NSLayoutConstraint *c in parent.constraints) {
        if (c.firstItem == parent &&
            c.firstAttribute == NSLayoutAttributeHeight &&
            c.relation == NSLayoutRelationEqual) {
            c.constant += delta;
            grew = YES;
            break;
        }
    }
    [parent setNeedsLayout];

    PB_LOG(@"attached %@ %@ in %@ (shifted=%d grewHeight=%d)",
           above ? @"above" : @"below", NSStringFromClass([rowContainer class]),
           NSStringFromClass([parent class]), shifted, grew);

    if (PBDebug() && !grew) {
        PBDumpAncestors(anchor, "relative-container");
    }
    return YES;
}

// ---------------------------------------------------------------------------
// 方案 D：跟随按钮行位置的重叠层
// 不依赖 StackView / 约束，直接贴在「编辑主页 / 分享主页」这一行的上方一点点；
// 每次布局后重新贴位置，所以手写 frame 布局的 header 也能用。
// ---------------------------------------------------------------------------

@interface PBRowTracker : NSObject
@property (nonatomic, weak) UIView *row;
@property (nonatomic, weak) UIView *alignView;
@property (nonatomic, weak) UIViewController *vc;
@property (nonatomic, strong) CADisplayLink *link;
- (instancetype)initWithRow:(UIView *)row alignView:(UIView *)alignView vc:(UIViewController *)vc;
- (void)start;
- (void)stop;
@end

@implementation PBRowTracker

- (instancetype)initWithRow:(UIView *)row alignView:(UIView *)alignView vc:(UIViewController *)vc {
    if (self = [super init]) {
        _row = row;
        _alignView = alignView;
        _vc = vc;
    }
    return self;
}

- (void)start {
    if (self.link) return;
    self.link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
    self.link.preferredFramesPerSecond = 30;
    [self.link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

- (void)stop {
    [self.link invalidate];
    self.link = nil;
}

- (void)tick:(CADisplayLink *)link {
    UIView *row = self.row;
    UIView *align = self.alignView;
    UIViewController *vc = self.vc;
    UIView *host = row.superview;

    if (!row || !align || !host || !vc) { [self stop]; return; }
    if (vc.view.window == nil || align.window == nil) {
        row.hidden = YES;
        [self stop];          // 页面不可见就停，等下次 viewDidAppear 再重启
        return;
    }
    if (row.hidden) row.hidden = NO;

    CGRect a = [align convertRect:align.bounds toView:host];
    CGFloat h = row.bounds.size.height > 0 ? row.bounds.size.height : PBOverlayHeight();
    CGFloat gap = PBOverlayGap();
    CGRect f = CGRectMake(a.origin.x, a.origin.y - gap - h, a.size.width, h);

    CGFloat maxY = MAX(0.0, host.bounds.size.height - h);
    if (f.origin.y > maxY) f.origin.y = maxY;
    if (f.origin.y < 0.0) f.origin.y = 0.0;
    if (!CGRectEqualToRect(row.frame, f)) row.frame = f;
}

@end

// 去掉行上已有/冲突的高度约束（切到手动 frame 模式前必须清掉）
static void PBRemoveRowHeightConstraints(UIView *row) {
    NSMutableArray<NSLayoutConstraint *> *toRemove = [NSMutableArray array];
    for (NSLayoutConstraint *c in row.constraints) {
        if (c.firstItem == row && c.firstAttribute == NSLayoutAttributeHeight) {
            [toRemove addObject:c];
        }
    }
    for (NSLayoutConstraint *c in toRemove) [row removeConstraint:c];
}

static BOOL PBInsertOverlayAbove(UIView *anchor, UIView *row, UIViewController *vc) {
    UIView *align = anchor.superview ?: anchor;
    UIView *host = align;
    while (host && [host isKindOfClass:[UIStackView class]]) host = host.superview;
    if (!host || host == row) return NO;

    PBRemoveRowHeightConstraints(row);
    row.translatesAutoresizingMaskIntoConstraints = YES;
    [host addSubview:row];

    CGRect a = [align convertRect:align.bounds toView:host];
    CGFloat h = PBOverlayHeight();
    CGFloat gap = PBOverlayGap();
    row.frame = CGRectMake(a.origin.x, a.origin.y - gap - h, a.size.width, h);

    PBRowTracker *tracker = [[PBRowTracker alloc] initWithRow:row alignView:align vc:vc];
    objc_setAssociatedObject(vc, &kPBTrackerKey, tracker, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [tracker start];

    PB_LOG(@"overlay above %@ in %@ frame=%@",
           NSStringFromClass([align class]), NSStringFromClass([host class]),
           NSStringFromCGRect(row.frame));
    return YES;
}

// 方案 C（兜底）：贴在主页顶部（安全区下方）或底部，保证一定能看到
static void PBDockToViewController(UIViewController *vc, UIView *row) {
    BOOL above = PBPositionAbove();
    PBRemoveRowHeightConstraints(row);
    [row.heightAnchor constraintEqualToConstant:PBRowHeight()].active = YES;
    [vc.view addSubview:row];
    if (above) {
        [NSLayoutConstraint activateConstraints:@[
            [row.leadingAnchor constraintEqualToAnchor:vc.view.leadingAnchor constant:16.0],
            [row.trailingAnchor constraintEqualToAnchor:vc.view.trailingAnchor constant:-16.0],
            [row.topAnchor constraintEqualToAnchor:vc.view.safeAreaLayoutGuide.topAnchor constant:8.0],
        ]];
    } else {
        [NSLayoutConstraint activateConstraints:@[
            [row.leadingAnchor constraintEqualToAnchor:vc.view.leadingAnchor constant:16.0],
            [row.trailingAnchor constraintEqualToAnchor:vc.view.trailingAnchor constant:-16.0],
            [row.bottomAnchor constraintEqualToAnchor:vc.view.safeAreaLayoutGuide.bottomAnchor constant:-10.0],
        ]];
    }
    PB_LOG(@"docked fallback row (%@) to %@", above ? @"top" : @"bottom",
           NSStringFromClass([vc class]));
}

// 判断插入后的按钮行到底有没有真的显示出来（被裁剪 / 尺寸为 0 都算失败）
static BOOL PBRowIsVisible(UIView *row, UIViewController *vc) {
    if (!row || !row.window || row.hidden || row.alpha < 0.01) return NO;
    if (row.bounds.size.width < 20 || row.bounds.size.height < 10) return NO;

    UIView *superview = row.superview;
    if (superview) {
        CGRect inSuper = [row convertRect:row.bounds toView:superview];
        if (superview.clipsToBounds && !CGRectIntersectsRect(inSuper, superview.bounds)) return NO;
    }
    if (vc.view) {
        CGRect inVC = [row convertRect:row.bounds toView:vc.view];
        if (!CGRectIntersectsRect(inVC, vc.view.bounds)) return NO;
    }
    return YES;
}

static void PBShowLaunchToast(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIWindow *w = PBKeyWindow();
        if (!w) return;
        UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, MIN(300.0, w.bounds.size.width - 60.0), 34.0)];
        label.text = @"ProfileButtons 已加载";
        label.textAlignment = NSTextAlignmentCenter;
        label.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
        label.textColor = [UIColor whiteColor];
        label.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.78];
        label.layer.cornerRadius = 17.0;
        label.layer.masksToBounds = YES;
        label.center = CGPointMake(w.bounds.size.width / 2.0, w.bounds.size.height - 140.0);
        label.alpha = 0.0;
        label.userInteractionEnabled = NO;
        [w addSubview:label];
        [UIView animateWithDuration:0.25 animations:^{
            label.alpha = 1.0;
        } completion:^(BOOL finished) {
            [UIView animateWithDuration:0.4 delay:2.5 options:0 animations:^{
                label.alpha = 0.0;
            } completion:^(BOOL finished2) {
                [label removeFromSuperview];
            }];
        }];
    });
}

// 启动时列出运行时里所有名字含 ProfileViewController 的类，确认实际类名
static void PBLogProfileClasses(void) {
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    if (!classes) return;
    NSInteger found = 0;
    for (unsigned int i = 0; i < count && found < 12; i++) {
        NSString *name = NSStringFromClass(classes[i]);
        if ([name containsString:@"ProfileViewController"]) {
            PB_LOG(@"runtime class: %@", name);
            found++;
        }
    }
    free(classes);
}

// ---------------------------------------------------------------------------
// MARK: - 安装
// ---------------------------------------------------------------------------

static const char kPBInstalledRowKey;
static const char kPBLastAttemptKey;
static const char kPBFailCountKey;

static void PBInstallForViewController(UIViewController *vc) {
    if (!vc.view || vc.view.window == nil) return;

    // 已经装过且还在视图树上 → 恢复跟随（重叠层可能被隐藏过）
    UIView *existing = objc_getAssociatedObject(vc, &kPBInstalledRowKey);
    if (existing && existing.window != nil) {
        PBRowTracker *tracker = objc_getAssociatedObject(vc, &kPBTrackerKey);
        if (tracker) {
            existing.hidden = NO;
            [tracker start];
        }
        return;
    }

    // ForceDock：跳过头部插入，直接悬浮，保证可见
    if (PBForceDock()) {
        UIView *row = PBMakeRow();
        PBDockToViewController(vc, row);
        objc_setAssociatedObject(vc, &kPBInstalledRowKey, row, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        PB_LOG(@"ForceDock: docked %lu button(s) on %@",
               (unsigned long)PBButtonConfigs().count, NSStringFromClass([vc class]));
        return;
    }

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
        if (count <= 3) {
            PB_LOG(@"edit-profile button not found in %@ (attempt %lu/8, view=%dx%d)",
                   NSStringFromClass([vc class]), (unsigned long)count,
                   (int)vc.view.bounds.size.width, (int)vc.view.bounds.size.height);
            if (PBDebug()) {
                for (NSString *s in PBSampleTappableViews(vc.view)) PB_LOG(@"  tappable: %@", s);
                PBDumpTree(vc.view, 0, 4);
            }
        }
        return;
    }

    PBDumpAncestors(anchor, "anchor");

    UIView *row = PBMakeRow();
    NSString *mode = @"docked";
    if (PBInsertIntoVerticalStack(anchor, row)) {
        mode = @"in header (stack)";
    } else if (PBInsertRelativeToContainer(anchor, row)) {
        mode = @"in header (constraints)";
    } else if (PBInsertOverlayAbove(anchor, row, vc)) {
        mode = @"overlay above buttons";
    } else {
        PBDockToViewController(vc, row);
    }
    BOOL inHeader = ![mode isEqualToString:@"docked"];

    objc_setAssociatedObject(vc, &kPBInstalledRowKey, row, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    PB_LOG(@"installed %lu button(s) %@ edit-profile row (%@)",
           (unsigned long)PBButtonConfigs().count,
           PBPositionAbove() ? @"above" : @"below", mode);

    // 关键：插进 header 后确认真的看得见，看不见就退回悬浮
    if (inHeader) {
        __weak UIView *weakRow = row;
        __weak UIViewController *weakVC = vc;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIView *strongRow = weakRow;
            UIViewController *strongVC = weakVC;
            if (!strongRow || !strongVC) return;
            if (PBRowIsVisible(strongRow, strongVC)) return;

            CGRect inVC = strongRow.window ? [strongRow convertRect:strongRow.bounds toView:strongVC.view] : CGRectZero;
            PB_LOG(@"row not visible after install (frame in VC: %@, superview %@) — docking instead",
                   NSStringFromCGRect(inVC), NSStringFromClass([strongRow.superview class]));
            if (PBDebug()) PBDumpAncestors(strongRow, "invisible-row");
            PBRowTracker *tracker = objc_getAssociatedObject(strongVC, &kPBTrackerKey);
            [tracker stop];
            objc_setAssociatedObject(strongVC, &kPBTrackerKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [strongRow removeFromSuperview];
            PBDockToViewController(strongVC, strongRow);
            objc_setAssociatedObject(strongVC, &kPBInstalledRowKey, strongRow, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        });
    }
}

// ---------------------------------------------------------------------------
// MARK: - Hook：所有 VC 的 viewDidAppear（profile 页出现时安装）
// ---------------------------------------------------------------------------

typedef void (*PBViewDidAppearIMP)(id, SEL, BOOL);
static PBViewDidAppearIMP PBOrigViewDidAppear;

static void PBViewDidAppear(id self, SEL _cmd, BOOL animated) {
    if (PBOrigViewDidAppear) PBOrigViewDidAppear(self, _cmd, animated);
    UIViewController *vc = (UIViewController *)self;
    if (PBDebug()) PB_LOG(@"appeared: %@", NSStringFromClass([vc class]));
    if (PBIsProfileViewController(vc)) {
        dispatch_async(dispatch_get_main_queue(), ^{
            PBInstallForViewController(vc);
        });
    }
}

// 看门狗：兜底 profile 页不会走 viewDidAppear / 数据延迟加载的情况
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

        PB_LOG(@"loaded build=%@ (buttons=%lu, safari=%d, debug=%d, position=%@, forceDock=%d)",
               @"2025-10-21-r4",
               (unsigned long)PBButtonConfigs().count,
               PBUseSafariViewController(), PBDebug(),
               PBPositionAbove() ? @"above" : @"below", PBForceDock());
        PB_LOG(@"bundle=%@", [[NSBundle mainBundle] bundlePath]);
        PB_LOG(@"UIViewController.viewDidAppear hooked=%d", PBOrigViewDidAppear != NULL);

        Class profileClass = objc_getClass("IGProfile.IGProfileViewController");
        PB_LOG(@"objc_getClass(\"IGProfile.IGProfileViewController\") = %@",
               profileClass ? NSStringFromClass(profileClass) : @"(nil)");
        if (PBDebug()) PBLogProfileClasses();

        PBStartWatchdog();
        if (PBShouldShowLaunchToast()) PBShowLaunchToast();
    }
}

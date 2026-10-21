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

// ---------------------------------------------------------------------------
// MARK: - 日志：同时写 NSLog 和 app 沙盒 Documents/ProfileButtons.log
// ---------------------------------------------------------------------------

static NSString *PBLogFilePath(void) {
    static NSString *path;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        if (docs.length == 0) docs = NSTemporaryDirectory();
        path = [docs stringByAppendingPathComponent:@"ProfileButtons.log"];
    });
    return path;
}

static void PBLogWrite(NSString *message) {
    static NSDateFormatter *formatter;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        formatter = [[NSDateFormatter alloc] init];
        formatter.dateFormat = @"MM-dd HH:mm:ss.SSS";
    });

    NSString *line = [NSString stringWithFormat:@"%@ %@\n",
                      [formatter stringFromDate:[NSDate date]], message];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    if (data.length == 0) return;

    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *path = PBLogFilePath();
    if (![fm fileExistsAtPath:path]) {
        [fm createFileAtPath:path contents:[NSData data] attributes:nil];
    }
    // 超过 1MB 清空，避免长期使用把沙盒写满
    NSDictionary *attrs = [fm attributesOfItemAtPath:path error:NULL];
    if (attrs && [attrs[NSFileSize] unsignedLongLongValue] > (1024ULL * 1024ULL)) {
        [fm removeItemAtPath:path error:NULL];
        [fm createFileAtPath:path contents:[NSData data] attributes:nil];
    }

    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!handle) return;
    @try {
        [handle seekToEndOfFile];
        [handle writeData:data];
        [handle synchronizeFile];
        [handle closeFile];
    } @catch (NSException *exception) {
        NSLog(@"[ProfileButtons] log write failed: %@", exception);
    }
}

static void PBLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSLog(@"[ProfileButtons] %@", message);
    PBLogWrite(message);
}

#define PB_LOG(fmt, ...) PBLog(fmt, ##__VA_ARGS__)


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
    if (v) return [v boolValue];
    // 没有 PBConfig.plist 时默认开详细日志，省得为了排障再拆包放配置；
    // 一旦放了配置，就以配置里的 Debug 为准。
    return PBConfig().count == 0;
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
    return v ? [v boolValue] : NO;
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

// 是否优先尝试「插进 header 布局」（默认关：IG 的 header 多半是手写 frame，
// 插进去容易被裁掉/压住；跟随重叠层更可控）
static BOOL PBTryHeaderInsert(void) {
    id v = PBConfig()[@"TryHeaderInsert"];
    return v ? [v boolValue] : NO;
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

// 只在 root 的「内容区」里找，导航栏里的同名元素不算
static BOOL PBViewInsideChrome(UIView *v, UIView *root) {
    UIView *cur = v;
    for (int i = 0; i < 20 && cur; i++, cur = cur.superview) {
        if ([cur isKindOfClass:[UINavigationBar class]] ||
            [cur isKindOfClass:[UITabBar class]] ||
            [cur isKindOfClass:[UIToolbar class]]) {
            return YES;
        }
        if (cur == root) break;
    }
    return NO;
}

// 收集所有候选，挑「最靠下、可点、尺寸正常」的那个：
// 个人主页里的「编辑主页」在简介下面，不会被导航栏里的同名元素或隐藏的旧 header 抢走。
static UIView *PBFindEditProfileAnchor(UIView *root) {
    if (!root) return nil;

    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:root];
    NSInteger visited = 0;
    UIView *best = nil;
    CGFloat bestScore = -CGFLOAT_MAX;

    while (queue.count > 0 && visited < 12000) {
        UIView *v = queue.firstObject;
        [queue removeObjectAtIndex:0];
        visited++;

        BOOL matched = NO;
        BOOL byIdentifier = NO;

        NSString *ident = v.accessibilityIdentifier;
        if (ident.length &&
            ([ident isEqualToString:@"edit_profile_button"] ||
             [ident localizedCaseInsensitiveContainsString:@"edit_profile"])) {
            matched = YES;
            byIdentifier = YES;
        }
        if (!matched && PBTextMatchesEditProfile(PBViewOwnText(v))) matched = YES;
        if (!matched && PBTextMatchesEditProfile(v.accessibilityLabel)) matched = YES;

        if (matched && !PBViewInsideChrome(v, root)) {
            UIView *anchor = PBTappableAncestor(v) ?: v;
            CGRect r = [anchor convertRect:anchor.bounds toView:root];
            BOOL usable = r.size.width > 30.0 && r.size.height > 14.0 && r.size.height < 90.0 &&
                          !CGRectIsEmpty(r) && anchor.alpha > 0.05 && !anchor.hidden &&
                          r.origin.y > root.safeAreaInsets.top + 30.0 &&
                          CGRectIntersectsRect(r, root.bounds);
            if (usable) {
                // 位置越靠下越优先（主页里「编辑主页」在简介下面），再叠加可点/标识加成
                CGFloat score = r.origin.y * 5.0;
                if ([anchor isKindOfClass:[UIControl class]]) score += 600.0;
                if (anchor.gestureRecognizers.count > 0) score += 150.0;
                if (byIdentifier) score += 300.0;
                if (PBDebug()) {
                    PB_LOG(@"[anchor] candidate %@ id=%@ rect=%@ score=%.0f",
                           NSStringFromClass([anchor class]), anchor.accessibilityIdentifier ?: @"-",
                           NSStringFromCGRect(r), score);
                }
                if (score > bestScore) {
                    bestScore = score;
                    best = anchor;
                }
            } else if (PBDebug()) {
                PB_LOG(@"[anchor] rejected %@ id=%@ rect=%@ (size/visibility)",
                       NSStringFromClass([anchor class]), anchor.accessibilityIdentifier ?: @"-",
                       NSStringFromCGRect(r));
            }
        }

        [queue addObjectsFromArray:v.subviews];
    }

    if (PBDebug() && best) {
        CGRect r = [best convertRect:best.bounds toView:root];
        PB_LOG(@"anchor chosen: %@ id=%@ rect=%@",
               NSStringFromClass([best class]), best.accessibilityIdentifier ?: @"-",
               NSStringFromCGRect(r));
    }
    return best;
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

// 日志查看器：长按任意自绘按钮打开，可全选复制（不方便取沙盒文件时用）
@interface PBLogViewController : UIViewController
@end

@implementation PBLogViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"ProfileButtons 日志";
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    UITextView *textView = [[UITextView alloc] initWithFrame:CGRectZero];
    textView.editable = NO;
    textView.selectable = YES;
    textView.alwaysBounceVertical = YES;
    textView.font = [UIFont monospacedSystemFontOfSize:11.0 weight:UIFontWeightRegular];
    textView.text = [NSString stringWithContentsOfFile:PBLogFilePath()
                                             encoding:NSUTF8StringEncoding
                                                error:NULL] ?: @"(日志为空)";
    textView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:textView];
    [NSLayoutConstraint activateConstraints:@[
        [textView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [textView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [textView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [textView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];

    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"关闭" style:UIBarButtonItemStylePlain
                                        target:self action:@selector(closeTapped:)];
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"复制" style:UIBarButtonItemStylePlain
                                        target:self action:@selector(copyTapped:)];
}

- (void)closeTapped:(id)sender {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)copyTapped:(id)sender {
    NSString *text = [NSString stringWithContentsOfFile:PBLogFilePath()
                                               encoding:NSUTF8StringEncoding
                                                  error:NULL];
    if (text.length) {
        [UIPasteboard generalPasteboard].string = text;
        PB_LOG(@"log copied to pasteboard (%lu chars)", (unsigned long)text.length);
    }
}

@end

@interface PBButtonActionHandler : NSObject
+ (instancetype)shared;
- (void)tapButton:(UIButton *)sender;
- (void)longPressButton:(UILongPressGestureRecognizer *)recognizer;
@end

@implementation PBButtonActionHandler

+ (instancetype)shared {
    static PBButtonActionHandler *handler;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ handler = [PBButtonActionHandler new]; });
    return handler;
}

- (void)longPressButton:(UILongPressGestureRecognizer *)recognizer {
    if (recognizer.state != UIGestureRecognizerStateBegan) return;
    if (!PBDebug()) return;

    UIViewController *top = PBTopViewController();
    if (!top) return;
    PB_LOG(@"opening log viewer");
    PBLogViewController *logVC = [[PBLogViewController alloc] initWithNibName:nil bundle:nil];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:logVC];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    [top presentViewController:nav animated:YES completion:nil];
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

    // 长按打开日志查看器（Debug 时可用），不方便取沙盒文件时可以直接复制
    UILongPressGestureRecognizer *longPress =
        [[UILongPressGestureRecognizer alloc] initWithTarget:[PBButtonActionHandler shared]
                                                      action:@selector(longPressButton:)];
    longPress.minimumPressDuration = 0.6;
    [button addGestureRecognizer:longPress];
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
// 直接挂在 vc.view 上（不碰 IG 的容器，避免被 clipsToBounds 裁掉），
// 用坐标换算把行贴在「编辑主页 / 分享主页」这一行的上沿，滚动时每帧跟随。
// ---------------------------------------------------------------------------

// 按钮行在 host 坐标系里的矩形：anchor 自身 + 同一行里「尺寸相近」的兄弟按钮。
// 注意：不能把带手势的大容器并进来，否则矩形上沿会跑到屏幕顶部（那正是之前「贴到最顶部」的原因）。
static CGRect PBRowRectForAnchor(UIView *anchor, UIView *host) {
    if (!anchor || !host) return CGRectZero;
    CGRect r = [anchor convertRect:anchor.bounds toView:host];
    UIView *parent = anchor.superview;
    if (!parent || r.size.height < 10.0) return r;

    const CGFloat anchorH = r.size.height;
    const CGFloat maxHeight = anchorH * 1.6;

    for (UIView *sib in parent.subviews) {
        if (sib == anchor) continue;
        BOOL looksButton = [sib isKindOfClass:[UIControl class]] ||
                           sib.gestureRecognizers.count > 0 ||
                           [NSStringFromClass([sib class]) containsString:@"Button"];
        if (!looksButton) continue;

        CGRect sr = [sib convertRect:sib.bounds toView:host];
        if (sr.size.width < 20.0 || sr.size.height < 10.0) continue;
        // 只合并同一行、尺寸接近的按钮；大容器（整个 header）直接跳过
        if (fabs(sr.size.height - anchorH) > 12.0) continue;
        if (sr.size.width > 320.0 || sr.size.width > r.size.width * 2.5) continue;
        if (CGRectContainsRect(sr, r)) continue;

        CGFloat overlap = MIN(CGRectGetMaxY(sr), CGRectGetMaxY(r)) - MAX(sr.origin.y, r.origin.y);
        CGFloat minHeight = MIN(sr.size.height, r.size.height);
        if (overlap <= minHeight * 0.6) continue;

        CGRect merged = CGRectUnion(r, sr);
        if (merged.size.height > maxHeight) continue;
        r = merged;
    }
    return r;
}

// 把按钮行矩形换算成「行放哪」：安全区下方、按钮行上方 gap 处，并夹在屏幕内
static CGRect PBRowFrameAboveRect(CGRect rect, CGRect bounds, CGFloat safeTop, CGFloat h, CGFloat gap) {
    CGFloat y = rect.origin.y - gap - h;
    CGFloat minY = safeTop + 4.0;
    CGFloat maxY = bounds.size.height - h - 6.0;
    if (maxY < minY) maxY = minY;
    if (y < minY) y = minY;
    if (y > maxY) y = maxY;

    CGFloat x = MAX(8.0, rect.origin.x);
    CGFloat w = MIN(rect.size.width, bounds.size.width - x - 8.0);
    if (w < 120.0) {
        x = 8.0;
        w = MAX(120.0, bounds.size.width - 16.0);
    }
    return CGRectMake(x, y, w, h);
}

@interface PBRowTracker : NSObject
@property (nonatomic, weak) UIView *row;
@property (nonatomic, weak) UIView *anchor;
@property (nonatomic, weak) UIViewController *vc;
@property (nonatomic, strong) CADisplayLink *link;
@property (nonatomic, copy) UIView *(^resolver)(void);   // 锚点失效时重新找
@property (nonatomic, assign) NSTimeInterval lastResolve;
- (instancetype)initWithRow:(UIView *)row anchor:(UIView *)anchor vc:(UIViewController *)vc;
- (void)start;
- (void)stop;
- (BOOL)reacquireAnchorIfNeeded;
@end

@implementation PBRowTracker

- (instancetype)initWithRow:(UIView *)row anchor:(UIView *)anchor vc:(UIViewController *)vc {
    if (self = [super init]) {
        _row = row;
        _anchor = anchor;
        _vc = vc;
        __weak UIViewController *weakVC = vc;
        _resolver = ^UIView *{
            UIViewController *strongVC = weakVC;
            if (!strongVC || !strongVC.view) return nil;
            return PBFindEditProfileAnchor(strongVC.view);
        };
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

// 下拉刷新 / 换账号后 IG 会重建 header 里的按钮，旧 anchor 会被释放，
// 这里重新扫一遍把 anchor 接上，避免行被「冻」在原地。
- (BOOL)reacquireAnchorIfNeeded {
    UIView *anchor = self.anchor;
    if (anchor && anchor.window != nil) return YES;
    if (!self.resolver) return NO;

    NSTimeInterval now = CACurrentMediaTime();
    if (now - self.lastResolve < 0.4) return NO;
    self.lastResolve = now;

    UIView *found = self.resolver();
    if (found) {
        self.anchor = found;
        PB_LOG(@"anchor re-acquired: %@", NSStringFromClass([found class]));
        return YES;
    }
    return NO;
}

- (void)tick:(CADisplayLink *)link {
    UIView *row = self.row;
    UIViewController *vc = self.vc;
    UIView *host = row.superview;

    if (!row || !host || !vc) { [self stop]; return; }
    if (vc.view.window == nil) {
        row.hidden = YES;
        [self stop];          // 页面不可见就停，等下次 viewDidAppear 再重启
        return;
    }
    if (![self reacquireAnchorIfNeeded]) {
        row.hidden = YES;     // 暂时没锚点：先藏起来，等重新找到再显示，别定格在原地
        return;
    }
    UIView *anchor = self.anchor;
    CGFloat h = row.bounds.size.height > 0 ? row.bounds.size.height : PBOverlayHeight();
    CGRect rect = PBRowRectForAnchor(anchor, host);
    CGFloat rawY = rect.origin.y - PBOverlayGap() - h;

    // 按钮行滚到导航栏下面时，行也跟着“滚出去”，而不是钉在顶部 —— 看起来才像真的在页面里
    if (rawY < host.safeAreaInsets.top + 2.0) {
        row.hidden = YES;
        return;
    }
    if (row.hidden) row.hidden = NO;

    CGRect f = PBRowFrameAboveRect(rect, host.bounds, host.safeAreaInsets.top, h, PBOverlayGap());
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
    if (!anchor || !vc.view) return NO;

    PBRemoveRowHeightConstraints(row);
    row.translatesAutoresizingMaskIntoConstraints = YES;
    [vc.view addSubview:row];

    CGFloat h = PBOverlayHeight();
    CGFloat gap = PBOverlayGap();
    CGRect rect = PBRowRectForAnchor(anchor, vc.view);
    CGFloat rawY = rect.origin.y - gap - h;
    CGRect frame = PBRowFrameAboveRect(rect, vc.view.bounds, vc.view.safeAreaInsets.top, h, gap);
    row.frame = frame;
    row.hidden = (rawY < vc.view.safeAreaInsets.top + 2.0);
    BOOL clamped = fabs(frame.origin.y - rawY) > 0.5;

    PBRowTracker *tracker = [[PBRowTracker alloc] initWithRow:row anchor:anchor vc:vc];
    objc_setAssociatedObject(vc, &kPBTrackerKey, tracker, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [tracker start];

    PB_LOG(@"overlay: vc=%@ view=%@ safeTop=%.0f anchor=%@ anchorRect=%@ rawY=%.0f clamped=%d frame=%@",
           NSStringFromClass([vc class]), NSStringFromCGRect(vc.view.bounds),
           vc.view.safeAreaInsets.top, NSStringFromClass([anchor class]),
           NSStringFromCGRect(rect), rawY, clamped, NSStringFromCGRect(frame));

    if (clamped) {
        // 位置被夹住 = 锚点太靠上，把候选清单写进日志，方便按真实层级调整
        PB_LOG(@"overlay clamped: dumping tappable candidates");
        for (NSString *s in PBSampleTappableViews(vc.view)) PB_LOG(@"  tappable: %@", s);
    }
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

    // 已经装过且还在视图树上 → 恢复跟随（重叠层可能被隐藏过，锚点也可能被 IG 换掉）
    UIView *existing = objc_getAssociatedObject(vc, &kPBInstalledRowKey);
    if (existing && existing.window != nil) {
        PBRowTracker *tracker = objc_getAssociatedObject(vc, &kPBTrackerKey);
        if (tracker) {
            existing.hidden = NO;
            [tracker reacquireAnchorIfNeeded];
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
    BOOL usedHeader = NO;
    if (PBTryHeaderInsert()) {
        if (PBInsertIntoVerticalStack(anchor, row)) {
            mode = @"in header (stack)";
            usedHeader = YES;
        } else if (PBInsertRelativeToContainer(anchor, row)) {
            mode = @"in header (constraints)";
            usedHeader = YES;
        }
    }
    if (!usedHeader) {
        if (PBInsertOverlayAbove(anchor, row, vc)) {
            mode = @"overlay above buttons";
        } else {
            PBDockToViewController(vc, row);
        }
    }
    objc_setAssociatedObject(vc, &kPBInstalledRowKey, row, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    PB_LOG(@"installed %lu button(s) %@ edit-profile row (%@)",
           (unsigned long)PBButtonConfigs().count,
           PBPositionAbove() ? @"above" : @"below", mode);

    // 插进 header 布局才需要复核可见性；重叠层自己会跟随，不需要复核
    if (usedHeader) {
        __weak UIView *weakRow = row;
        __weak UIViewController *weakVC = vc;
        __weak UIView *weakAnchor = anchor;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIView *strongRow = weakRow;
            UIViewController *strongVC = weakVC;
            UIView *strongAnchor = weakAnchor;
            if (!strongRow || !strongVC) return;
            if (PBRowIsVisible(strongRow, strongVC)) return;

            CGRect inVC = strongRow.window ? [strongRow convertRect:strongRow.bounds toView:strongVC.view] : CGRectZero;
            PB_LOG(@"header row not visible (frame in VC: %@, superview %@) — falling back to overlay",
                   NSStringFromCGRect(inVC), NSStringFromClass([strongRow.superview class]));
            if (PBDebug()) PBDumpAncestors(strongRow, "invisible-row");
            PBRowTracker *tracker = objc_getAssociatedObject(strongVC, &kPBTrackerKey);
            [tracker stop];
            objc_setAssociatedObject(strongVC, &kPBTrackerKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [strongRow removeFromSuperview];
            if (!strongAnchor || !PBInsertOverlayAbove(strongAnchor, strongRow, strongVC)) {
                PBDockToViewController(strongVC, strongRow);
            }
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

        PB_LOG(@"loaded build=%@ (buttons=%lu, safari=%d, debug=%d, position=%@, forceDock=%d, tryHeader=%d)",
               @"2025-10-21-r8",
               (unsigned long)PBButtonConfigs().count,
               PBUseSafariViewController(), PBDebug(),
               PBPositionAbove() ? @"above" : @"below", PBForceDock(), PBTryHeaderInsert());
        PB_LOG(@"env: ios=%@ screen=%@ app=%@ (%@) log=%@",
               [[UIDevice currentDevice] systemVersion],
               NSStringFromCGRect([UIScreen mainScreen].bounds),
               [[NSBundle mainBundle] infoDictionary][@"CFBundleShortVersionString"] ?: @"?",
               [[NSBundle mainBundle] infoDictionary][@"CFBundleVersion"] ?: @"?",
               PBLogFilePath());
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

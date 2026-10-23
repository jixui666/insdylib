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
static const char kPBInstalledRowKey;
static const char kPBLastAttemptKey;
static const char kPBFailCountKey;
static const char kPBFirstAttemptKey;
static const char kPBNativeInstalledKey;

// 当前登录账号（从「自己的主页」VC 上 KVC 拿到的 user 对象里缓存）
static NSDictionary *gPBAccountInfo;

// 前置声明（这几个函数互相引用）
static NSDictionary *PBConfig(void);
static NSArray<NSDictionary *> *PBRemoteButtons(void);
static NSArray<NSDictionary *> *PBDefaultButtonsResolved(void);
static NSArray<NSDictionary *> *PBButtonConfigs(void);

// 找不到 accessibilityIdentifier 时的兜底文字匹配（覆盖 IG 支持的常见语言）
// 每项是 @[语言码, 「编辑主页」在该语言下的文字]，用于两件事：
//   1) 找到个人主页上的编辑按钮；
//   2) 反过来从按钮文字推断 IG 当前界面语言（IG 用内建语言设置，不改 NSLocale）。
static NSArray<NSArray<NSString *> *> *PBEditTitleTable(void) {
    return @[
        @[@"zh-Hans", @"编辑主页"], @[@"zh-Hant", @"編輯主頁"],
        @[@"zh-Hans", @"编辑个人主页"], @[@"zh-Hant", @"編輯個人主頁"],
        @[@"en", @"Edit profile"], @[@"en", @"Edit Profile"],
        @[@"fr", @"Modifier le profil"], @[@"es", @"Editar perfil"],
        @[@"ja", @"プロフィールを編集"], @[@"ko", @"프로필 편집"],
        @[@"de", @"Profil bearbeiten"], @[@"it", @"Modifica profilo"],
        @[@"ru", @"Редактировать профиль"], @[@"ar", @"تعديل الملف الشخصي"],
        @[@"tr", @"Profili düzenle"], @[@"id", @"Edit Profil"],
        @[@"th", @"แก้ไขโปรไฟล์"], @[@"vi", @"Chỉnh sửa trang cá nhân"],
        @[@"hi", @"प्रोफ़ाइल संपादित करें"], @[@"uk", @"Редагувати профіль"],
        @[@"pl", @"Edytuj profil"], @[@"nl", @"Profiel bewerken"],
        @[@"ro", @"Editează profilul"], @[@"hu", @"Profil szerkesztése"],
        @[@"cs", @"Upravit profil"], @[@"el", @"Επεξεργασία προφίλ"],
        @[@"sv", @"Redigera profil"], @[@"da", @"Rediger profil"],
        @[@"fi", @"Muokkaa profiilia"], @[@"no", @"Rediger profil"],
        @[@"bn", @"প্রোফাইল সম্পাদনা করুন"], @[@"ta", @"ப்ரொஃபைலைத் திருத்து"],
        @[@"te", @"ప్రొఫైల్ను సవరించండి"], @[@"mr", @"पार्श्वचित्र संपादित करा"],
        @[@"gu", @"સંપાદિત પ્રોફાઇલ"], @[@"kn", @"ಪ್ರೊಫೈಲ್ ಸಂಪಾದಿಸಿ"],
        @[@"ml", @"പ്രൊഫൈൽ എഡിറ്റ് ചെയ്യുക"], @[@"pa", @"ਪ੍ਰੋਫ਼ਾਈਲ ਸੋਧੋ"],
        @[@"ur", @"پروفائل میں ترمیم کریں"], @[@"fa", @"ویرایش پروفایل"],
        @[@"he", @"עריכת הפרופיל"], @[@"az", @"Profili redaktə et"],
        @[@"kk", @"Профильді өңдеу"], @[@"uz", @"Profilni tahrirlash"],
        @[@"ka", @"პროფილის რედაქტირება"], @[@"hy", @"Խմբագրել պրոֆիլը"],
        @[@"sr", @"Уреди профил"], @[@"hr", @"Uredi profil"],
        @[@"sl", @"Uredi profil"], @[@"sk", @"Upraviť profil"],
        @[@"bg", @"Редактиране на профила"], @[@"lt", @"Redaguoti profilį"],
        @[@"lv", @"Rediģēt profilu"], @[@"et", @"Muuda profiili"],
        @[@"km", @"កែសម្រួលប្រវត្តិរូប"], @[@"lo", @"ແກ້ໄຂໂປຣໄຟລ໌"],
        @[@"my", @"ပရိုဖိုင်ကို တည်းဖြတ်ရန်"], @[@"si", @"පැතිකඩ සංස්කරණය කරන්න"],
        @[@"ne", @"प्रोफाइल सम्पादन गर्नुहोस्"], @[@"sw", @"Hariri wasifu"],
        @[@"fil", @"I-edit ang profile"],
    ];
}

static NSArray<NSString *> *PBEditTitles(void) {
    NSMutableArray<NSString *> *titles = [NSMutableArray array];
    for (NSArray<NSString *> *pair in PBEditTitleTable()) {
        [titles addObject:pair.lastObject];
    }
    return titles;
}

// 内置默认按钮：店铺中心 / 商品橱窗 / 订单详情（多语言标题）
// 远程控制端（ControlURL）返回配置时，标题/链接/图标都以远程为准。
static NSArray<NSDictionary *> *PBDefaultButtons(void) {
    return @[
        @{ @"id": @"store",
           @"Icon": @"storefront",
           @"URL": @"https://example.com/store",
           @"Titles": @{
               @"zh-Hans": @"店铺中心", @"zh-Hant": @"店鋪中心", @"en": @"Store Center",
               @"ja": @"ストアセンター", @"ko": @"스토어 센터", @"es": @"Centro de la tienda",
               @"fr": @"Centre boutique", @"de": @"Store-Center", @"pt": @"Central da loja",
               @"ru": @"Центр магазина", @"ar": @"مركز المتجر", @"th": @"ศูนย์ร้านค้า",
               @"vi": @"Trung tâm cửa hàng", @"id": @"Pusat toko", @"tr": @"Mağaza merkezi",
               @"it": @"Centro del negozio",
               @"pl": @"Centrum sklepu", @"nl": @"Winkelcentrum", @"uk": @"Центр магазину",
               @"ro": @"Centrul magazinului", @"hu": @"Áruház", @"cs": @"Centrum obchodu",
               @"el": @"Κέντρο καταστήματος", @"sv": @"Butikscenter", @"da": @"Butikscenter",
               @"fi": @"Kaupan keskus", @"no": @"Butikksenter", @"ms": @"Pusat kedai",
               @"hi": @"स्टोर केंद्र", @"bn": @"স্টোর সেন্টার", @"ta": @"ஸ்டோர் மையம்",
               @"te": @"స్టోర్ సెంటర్", @"ur": @"اسٹور سینٹر", @"fa": @"مرکز فروشگاه",
               @"he": @"מרכז החנות", @"bg": @"Център на магазина", @"sk": @"Centrum obchodu",
               @"sr": @"Центар продавнице", @"hr": @"Centar trgovine", @"lt": @"Parduotuvės centras",
               @"lv": @"Veikala centrs", @"et": @"Poe keskus", @"kk": @"Дүкен орталығы",
               @"az": @"Mağaza mərkəzi", @"hy": @"Խանութի կենտրոն", @"ka": @"მაღაზიის ცენტრი",
               @"sw": @"Kituo cha duka", @"fil": @"Sentro ng tindahan",
           } },
        @{ @"id": @"showcase",
           @"Icon": @"bag",
           @"URL": @"https://example.com/showcase",
           @"Titles": @{
               @"zh-Hans": @"商品橱窗", @"zh-Hant": @"商品櫥窗", @"en": @"Showcase",
               @"ja": @"ショーケース", @"ko": @"쇼케이스", @"es": @"Escaparate",
               @"fr": @"Vitrine", @"de": @"Schaufenster", @"pt": @"Vitrine",
               @"ru": @"Витрина", @"ar": @"واجهة المنتجات", @"th": @"โชว์เคส",
               @"vi": @"Trưng bày", @"id": @"Etalase", @"tr": @"Vitrin",
               @"it": @"Vetrina",
               @"pl": @"Witryna produktów", @"nl": @"Etalage", @"uk": @"Вітрина",
               @"ro": @"Vitrină", @"hu": @"Kirakat", @"cs": @"Výloha",
               @"el": @"Βιτρίνα", @"sv": @"Skyltfönster", @"da": @"Udstillingsvindue",
               @"fi": @"Näyteikkuna", @"no": @"Utstillingsvindu", @"ms": @"Pameran",
               @"hi": @"उत्पाद शोकेस", @"bn": @"পণ্য শোকেস", @"ta": @"தயாரிப்பு காட்சி",
               @"te": @"ఉత్పత్తి షోకేస్", @"ur": @"پروڈکٹ شوکیس", @"fa": @"ویترین محصولات",
               @"he": @"חלון ראווה", @"bg": @"Витрина", @"sk": @"Vitrína",
               @"sr": @"Излог", @"hr": @"Izlog", @"lt": @"Vitrina", @"lv": @"Skatlogs",
               @"et": @"Vaateaken", @"kk": @"Өнім витринасы", @"az": @"Məhsul vitrini",
               @"hy": @"Ապրանքների ցուցափեղկ", @"ka": @"პროდუქტის ვიტრინა",
               @"sw": @"Maonyesho ya bidhaa", @"fil": @"Showcase ng produkto",
           } },
        @{ @"id": @"orders",
           @"Icon": @"doc.text",
           @"URL": @"https://example.com/orders",
           @"Titles": @{
               @"zh-Hans": @"订单详情", @"zh-Hant": @"訂單詳情", @"en": @"Order Details",
               @"ja": @"注文詳細", @"ko": @"주문 상세", @"es": @"Detalles del pedido",
               @"fr": @"Détails de la commande", @"de": @"Bestelldetails", @"pt": @"Detalhes do pedido",
               @"ru": @"Детали заказа", @"ar": @"تفاصيل الطلب", @"th": @"รายละเอียดคำสั่งซื้อ",
               @"vi": @"Chi tiết đơn hàng", @"id": @"Detail pesanan", @"tr": @"Sipariş detayları",
               @"it": @"Dettagli ordine",
               @"pl": @"Szczegóły zamówienia", @"nl": @"Bestelgegevens", @"uk": @"Деталі замовлення",
               @"ro": @"Detalii comandă", @"hu": @"Rendelés részletei", @"cs": @"Podrobnosti objednávky",
               @"el": @"Λεπτομέρειες παραγγελίας", @"sv": @"Orderdetaljer", @"da": @"Ordredetaljer",
               @"fi": @"Tilauksen tiedot", @"no": @"Ordredetaljer", @"ms": @"Butiran pesanan",
               @"hi": @"ऑर्डर विवरण", @"bn": @"অর্ডার বিবরণ", @"ta": @"ஆர்டர் விவரங்கள்",
               @"te": @"ఆర్డర్ వివరాలు", @"ur": @"آرڈر کی تفصیلات", @"fa": @"جزئیات سفارش",
               @"he": @"פרטי הזמנה", @"bg": @"Детайли на поръчка", @"sk": @"Podrobnosti objednávky",
               @"sr": @"Детаљи поруџбине", @"hr": @"Detalji narudžbe", @"lt": @"Užsakymo informacija",
               @"lv": @"Pasūtījuma informācija", @"et": @"Tellimuse üksikasjad",
               @"kk": @"Тапсырыс мәліметтері", @"az": @"Sifariş detalları",
               @"hy": @"Պատվերի մանրամասներ", @"ka": @"შეკვეთის დეტალები",
               @"sw": @"Maelezo ya agizo", @"fil": @"Detalye ng order",
           } },
    ];
}

// 把系统语言规范成我们用的短码：zh-Hans / zh-Hant / en / ja …
static NSString *PBNormalizeLanguage(NSString *raw) {    if (![raw isKindOfClass:[NSString class]] || raw.length == 0) return @"en";
    NSString *s = [raw stringByReplacingOccurrencesOfString:@"_" withString:@"-"];
    NSArray<NSString *> *parts = [s componentsSeparatedByString:@"-"];
    NSString *base = [parts.firstObject lowercaseString] ?: @"en";
    if ([base isEqualToString:@"zh"]) {
        BOOL hant = NO;
        for (NSString *p in parts) {
            NSString *u = [p uppercaseString];
            if ([u hasPrefix:@"HANT"] || [u isEqualToString:@"TW"] ||
                [u isEqualToString:@"HK"] || [u isEqualToString:@"MO"]) {
                hant = YES;
            }
        }
        return hant ? @"zh-Hant" : @"zh-Hans";
    }
    return base;
}

static NSString *gPBUILanguage;           // 从 IG 界面文字推断出来的语言
static NSString *gPBIGDefaultsLanguage;   // 从 IG 自己的 defaults 读出来的语言
static NSString *PBNormalizeLanguage(NSString *raw);
static void PBRebuildVisibleRows(void);

// 读 IG 自己的语言设置：IG 的「语言」选项不会改 NSLocale，
// 只会写它自己的 defaults，所以必须优先读这里。
static NSString *PBReadIGLanguageFromDefaults(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    for (NSString *key in @[@"current_language", @"current_locale", @"primary_locale",
                            @"ig_language", @"app_language"]) {
        id v = [defaults objectForKey:key];
        if ([v isKindOfClass:[NSString class]] && [v length] > 0) {
            PB_LOG(@"i18n: defaults[%@] = %@", key, v);
            return PBNormalizeLanguage(v);
        }
    }
    return nil;
}

// 从「编辑主页」实际显示的文字反推语言
static NSString *PBEditTitleLanguage(NSString *text) {
    if (![text isKindOfClass:[NSString class]] || text.length == 0) return nil;
    NSString *trimmed = [text stringByTrimmingCharactersInSet:
                         [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *lower = [trimmed lowercaseString];
    if (lower.length < 3) return nil;

    for (NSArray<NSString *> *pair in PBEditTitleTable()) {
        if ([[pair.lastObject lowercaseString] isEqualToString:lower]) return pair.firstObject;
    }
    // 按钮文字可能带括号/后缀，退一步做包含匹配
    for (NSArray<NSString *> *pair in PBEditTitleTable()) {
        NSString *t = [pair.lastObject lowercaseString];
        if (t.length >= 5 && [lower containsString:t]) return pair.firstObject;
    }
    return nil;
}

static void PBDetectLanguageFromText(NSString *text) {
    NSString *lang = PBEditTitleLanguage(text);
    if (lang.length == 0) return;
    if ([lang isEqualToString:gPBUILanguage ?: @""]) return;

    NSString *old = gPBUILanguage;
    gPBUILanguage = [lang copy];
    PB_LOG(@"i18n: UI language = %@ (was=%@, system=%@, defaults=%@)",
           lang, old ?: @"-",
           PBNormalizeLanguage([NSLocale preferredLanguages].firstObject),
           gPBIGDefaultsLanguage ?: @"-");

    if (old.length > 0) {
        // 运行时切语言：把已装的按钮重建，让标题跟着变
        dispatch_async(dispatch_get_main_queue(), ^{
            PBRebuildVisibleRows();
        });
    }
}

static NSString *PBCurrentLanguage(void) {
    if (gPBUILanguage.length) return gPBUILanguage;
    if (gPBIGDefaultsLanguage.length) return gPBIGDefaultsLanguage;
    NSArray<NSString *> *langs = [NSLocale preferredLanguages];
    return PBNormalizeLanguage(langs.firstObject);
}

// titles 里按「当前语言 → 语言基码 → 另一套中文 → en → 任意非空」取标题
static NSString *PBTitleForTitles(NSDictionary *titles) {
    if (![titles isKindOfClass:[NSDictionary class]] || titles.count == 0) return nil;
    NSString *cur = PBCurrentLanguage();
    NSString *base = [[cur componentsSeparatedByString:@"-"] firstObject];
    NSMutableArray<NSString *> *keys = [NSMutableArray arrayWithObject:cur];
    if (base.length && ![keys containsObject:base]) [keys addObject:base];
    if ([cur hasPrefix:@"zh"]) {
        [keys addObject:[cur isEqualToString:@"zh-Hans"] ? @"zh-Hant" : @"zh-Hans"];
    }
    [keys addObject:@"en"];

    for (NSString *k in keys) {
        id v = titles[k];
        if ([v isKindOfClass:[NSString class]] && [v length] > 0) return v;
    }
    for (NSString *k in titles) {
        if (![k isKindOfClass:[NSString class]]) continue;
        if (base.length && [k.lowercaseString hasPrefix:base]) {
            id v = titles[k];
            if ([v isKindOfClass:[NSString class]] && [v length] > 0) return v;
        }
    }
    for (NSString *k in titles) {
        id v = titles[k];
        if ([v isKindOfClass:[NSString class]] && [v length] > 0) return v;
    }
    return nil;
}

static NSString *PBRemoteCachePath(void) {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (docs.length == 0) docs = NSTemporaryDirectory();
    return [docs stringByAppendingPathComponent:@"ProfileButtons.remote.json"];
}

// ---- 远程控制端 ----
static NSString *const PBRemoteDidChangeNotification = @"PBRemoteDidChange";
static NSDictionary *gPBRemoteConfig;          // 最近一次成功的远程 JSON
static NSTimeInterval gPBRemoteLastFetch;      // 上次拉取时间（CACurrentMediaTime）

static void PBLoadRemoteCache(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSData *data = [NSData dataWithContentsOfFile:PBRemoteCachePath()];
        if (data.length == 0) return;
        id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
        if ([obj isKindOfClass:[NSDictionary class]]) {
            gPBRemoteConfig = obj;
            PB_LOG(@"remote: cache loaded (%lu button(s))",
                   (unsigned long)[obj[@"buttons"] count]);
        }
    });
}

static void PBFetchRemoteConfig(BOOL force) {
    NSString *urlString = PBConfig()[@"ControlURL"];
    if (![urlString isKindOfClass:[NSString class]] || urlString.length == 0) return;

    NSTimeInterval now = CACurrentMediaTime();
    if (!force && gPBRemoteLastFetch > 0 && now - gPBRemoteLastFetch < 600.0) return;
    gPBRemoteLastFetch = now;

    NSURLComponents *comps = [NSURLComponents componentsWithString:urlString];
    if (!comps) { PB_LOG(@"remote: bad ControlURL"); return; }

    NSMutableArray<NSURLQueryItem *> *items = [NSMutableArray array];
    if (comps.queryItems) [items addObjectsFromArray:comps.queryItems];
    [items addObject:[NSURLQueryItem queryItemWithName:@"lang" value:PBCurrentLanguage()]];
    NSString *appVersion = [[NSBundle mainBundle] infoDictionary][@"CFBundleShortVersionString"];
    if (appVersion.length) [items addObject:[NSURLQueryItem queryItemWithName:@"v" value:appVersion]];
    [items addObject:[NSURLQueryItem queryItemWithName:@"t"
                                                 value:[NSString stringWithFormat:@"%.0f", [[NSDate date] timeIntervalSince1970]]]];
    comps.queryItems = items;

    NSURL *url = comps.URL;
    if (!url) { PB_LOG(@"remote: bad url %@", urlString); return; }

    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    cfg.timeoutIntervalForRequest = 5.0;
    cfg.timeoutIntervalForResource = 8.0;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    req.HTTPShouldHandleCookies = NO;

    PB_LOG(@"remote: fetching %@", url.absoluteString);
    [[session dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        if (error || data.length == 0) {
            PB_LOG(@"remote: fetch failed (%@)", error.localizedDescription ?: @"no data");
            return;
        }
        id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
        if (![obj isKindOfClass:[NSDictionary class]]) {
            PB_LOG(@"remote: invalid json");
            return;
        }
        NSArray *buttons = ((NSDictionary *)obj)[@"buttons"];
        if (![buttons isKindOfClass:[NSArray class]] || buttons.count == 0) {
            PB_LOG(@"remote: no buttons in response");
            return;
        }
        NSMutableArray *valid = [NSMutableArray array];
        for (NSDictionary *b in buttons) {
            if (![b isKindOfClass:[NSDictionary class]]) continue;
            NSString *u = b[@"url"];
            if (![u isKindOfClass:[NSString class]] || u.length == 0) continue;
            [valid addObject:b];
        }
        if (valid.count == 0) { PB_LOG(@"remote: no valid buttons"); return; }

        NSDictionary *merged = @{ @"buttons": valid, @"fetchedAt": @([[NSDate date] timeIntervalSince1970]) };
        gPBRemoteConfig = merged;
        BOOL saved = [data writeToFile:PBRemoteCachePath() atomically:YES];
        PB_LOG(@"remote: ok (%lu button(s), cached=%d)", (unsigned long)valid.count, saved);

        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:PBRemoteDidChangeNotification object:nil];
        });
    }] resume];
}

// 把内置的三条（带多语言标题）解析成 {Title, URL, Icon}
static NSArray<NSDictionary *> *PBDefaultButtonsResolved(void) {
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *d in PBDefaultButtons()) {
        [out addObject:@{ @"id": d[@"id"] ?: @"",
                          @"Title": PBTitleForTitles(d[@"Titles"]) ?: @"Link",
                          @"URL": d[@"URL"] ?: @"",
                          @"Icon": d[@"Icon"] ?: @"" }];
    }
    return out;
}

// 远程配置（没有远程返回 nil，交给本地/内置兜底）
static NSArray<NSDictionary *> *PBRemoteButtons(void) {
    PBLoadRemoteCache();

    NSArray *defaults = PBDefaultButtons();
    NSArray *remote = [gPBRemoteConfig[@"buttons"] isKindOfClass:[NSArray class]]
                        ? gPBRemoteConfig[@"buttons"] : nil;
    if (remote.count == 0) return nil;

    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *b in remote) {
        if (![b isKindOfClass:[NSDictionary class]]) continue;
        NSString *bid = [b[@"id"] isKindOfClass:[NSString class]] ? b[@"id"] : nil;

        NSDictionary *def = nil;
        if (bid.length) {
            for (NSDictionary *d in defaults) {
                if ([d[@"id"] isEqual:bid]) { def = d; break; }
            }
        }

        id titleValue = b[@"title"] ?: b[@"titles"];
        NSString *title = nil;
        if ([titleValue isKindOfClass:[NSDictionary class]]) {
            title = PBTitleForTitles(titleValue);
        } else if ([titleValue isKindOfClass:[NSString class]] && [titleValue length]) {
            title = titleValue;
        }
        if (title.length == 0 && def) title = PBTitleForTitles(def[@"Titles"]);
        if (title.length == 0) title = @"Link";

        NSString *url = [b[@"url"] isKindOfClass:[NSString class]] ? b[@"url"] : nil;
        if (url.length == 0 && def) url = def[@"URL"];

        NSString *icon = [b[@"icon"] isKindOfClass:[NSString class]] ? b[@"icon"] : nil;
        if (icon.length == 0 && def) icon = def[@"Icon"];

        [out addObject:@{ @"id": bid ?: @"",
                          @"Title": title,
                          @"URL": url ?: @"",
                          @"Icon": icon ?: @"" }];
    }
    return out.count ? out : nil;
}

// 优先级：远程控制端 > 本地 PBConfig.plist 的 Buttons > 内置（多语言）
static NSArray<NSDictionary *> *PBButtonConfigs(void) {
    NSArray *remote = PBRemoteButtons();
    if (remote.count) return remote;

    NSArray *local = PBConfig()[@"Buttons"];
    if ([local isKindOfClass:[NSArray class]] && local.count > 0) return local;

    return PBDefaultButtonsResolved();
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
// 1 = 自己的主页，0 = 别人的主页，-1 = 判断不出来
static int PBSelfProfileState(UIViewController *vc) {
    if (!vc) return -1;
    @try {
        id user = nil;
        if ([vc respondsToSelector:@selector(valueForKey:)]) {
            user = [vc valueForKey:@"user"];
        }
        if (user && user != [NSNull null]) {
            for (NSString *key in @[@"isSelfProfile", @"isSelf", @"isCurrentUser", @"isLoggedInUser"]) {
                SEL sel = NSSelectorFromString(key);
                if (![user respondsToSelector:sel]) continue;
                id v = [user valueForKey:key];
                if ([v isKindOfClass:[NSNumber class]]) return [v boolValue] ? 1 : 0;
            }
        }
        for (NSString *key in @[@"isSelfProfile", @"isViewingSelf"]) {
            SEL sel = NSSelectorFromString(key);
            if (![vc respondsToSelector:sel]) continue;
            id v = [vc valueForKey:key];
            if ([v isKindOfClass:[NSNumber class]]) return [v boolValue] ? 1 : 0;
        }
    } @catch (NSException *e) {
        PB_LOG(@"self detect caught: %@", e.reason);
    }
    return -1;
}

// ---------------------------------------------------------------------------
// MARK: - 账号信息（只在自己主页上抓一次，之后点按钮时拼到 URL）
// ---------------------------------------------------------------------------

static NSString *PBAccountStringValue(id v) {
    if ([v isKindOfClass:[NSString class]]) return v;
    if ([v isKindOfClass:[NSNumber class]]) return [(NSNumber *)v stringValue];
    return nil;
}

static NSString *PBAccountValue(id obj, NSArray<NSString *> *keys) {
    for (NSString *key in keys) {
        @try {
            id v = [obj valueForKey:key];
            NSString *s = PBAccountStringValue(v);
            if (s.length) return s;
        } @catch (NSException *e) {
        }
    }
    return nil;
}

static void PBCaptureAccountFromViewController(UIViewController *vc) {
    @try {
        id user = nil;
        @try {
            if ([vc respondsToSelector:@selector(valueForKey:)]) user = [vc valueForKey:@"user"];
        } @catch (NSException *e) {
            user = nil;
        }
        if (!user || user == [NSNull null]) return;

        NSString *pk = PBAccountValue(user, @[@"pk", @"userID", @"userId"]);
        NSString *username = PBAccountValue(user, @[@"username", @"userName"]);
        NSString *nickname = PBAccountValue(user, @[@"fullName", @"full_name", @"displayName"]);
        if (pk.length == 0 && username.length == 0) return;

        gPBAccountInfo = @{
            @"pk": pk ?: @"",
            @"username": username ?: @"",
            @"nickname": nickname ?: @"",
        };
        PB_LOG(@"account: pk=%@ username=%@ nickname=%@", pk, username, nickname);
    } @catch (NSException *e) {
        PB_LOG(@"account capture failed: %@", e.reason);
    }
}

static NSString *PBAccountLanguageCode(void) {
    NSString *ig = PBReadIGLanguageFromDefaults();
    if (ig.length) {
        NSRange dash = [ig rangeOfString:@"-"];
        return dash.location == NSNotFound ? ig : [ig substringToIndex:dash.location];
    }
    NSString *code = [NSLocale currentLocale].languageCode;
    return code.length ? code : @"en";
}

// 把 source / pk / customID / username / nickname / lang / timezone / v 拼到 http(s) URL 上；
// 已经存在的同名参数不重复添加，非 http(s) 链接原样返回。
static NSURL *PBURLWithAccountParams(NSURL *url) {
    if (!url) return nil;
    NSString *scheme = url.scheme.lowercaseString;
    if (![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"]) return url;

    NSURLComponents *comps = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    if (!comps) return url;

    NSMutableArray<NSURLQueryItem *> *items = [NSMutableArray arrayWithArray:comps.queryItems ?: @[]];
    NSMutableSet<NSString *> *existing = [NSMutableSet set];
    for (NSURLQueryItem *item in items) {
        if (item.name.length) [existing addObject:item.name];
    }

    void (^add)(NSString *, NSString *) = ^(NSString *key, NSString *value) {
        if (key.length == 0 || value.length == 0) return;
        if ([existing containsObject:key]) return;
        [items addObject:[NSURLQueryItem queryItemWithName:key value:value]];
        [existing addObject:key];
    };

    NSDictionary *acc = gPBAccountInfo ?: @{};
    NSString *pk = acc[@"pk"];
    NSString *user = acc[@"username"];
    NSString *nick = acc[@"nickname"];
    // 抓不到时的兜底：写在 PBConfig.plist 里的固定值
    NSDictionary *cfg = PBConfig();
    if (pk.length == 0) pk = cfg[@"AccountID"];
    if (user.length == 0) user = cfg[@"Username"];
    if (nick.length == 0) nick = cfg[@"Nickname"];
    if (nick.length == 0) nick = user;

    add(@"source", @"Instagram");
    add(@"pk", pk);
    add(@"customID", pk);
    add(@"username", user);
    add(@"nickname", nick);
    add(@"lang", PBAccountLanguageCode());
    add(@"timezone", [NSTimeZone localTimeZone].name);
    add(@"v", [[NSBundle mainBundle] infoDictionary][@"CFBundleShortVersionString"]);

    comps.queryItems = items;
    return comps.URL ?: url;
}

static UIView *PBFindEditProfileAnchor(UIView *root, BOOL allowActionBarFallback) {
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
        NSString *ownText = PBViewOwnText(v);
        if (!matched && PBTextMatchesEditProfile(ownText)) matched = YES;
        if (!matched && PBTextMatchesEditProfile(v.accessibilityLabel)) matched = YES;
        // 用按钮上真实显示的文字推断 IG 当前界面语言（IG 内建语言不改 NSLocale）
        if (matched) PBDetectLanguageFromText(ownText ?: v.accessibilityLabel);

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

    // 文字/标识都没匹配到（例如系统语言不在我们的列表里），
    // 但对「自己的主页」有兜底：直接拿 action bar 容器当锚点，与语言无关。
    if (!best && allowActionBarFallback) {
        UIView *bar = nil;
        NSMutableArray<UIView *> *q2 = [NSMutableArray arrayWithObject:root];
        NSInteger v2 = 0;
        while (q2.count > 0 && v2 < 12000) {
            UIView *v = q2.firstObject;
            [q2 removeObjectAtIndex:0];
            v2++;
            NSString *cls = NSStringFromClass([v class]);
            if ([cls containsString:@"IGProfileActionBarView"] &&
                ![cls containsString:@"Cell"] &&
                v.bounds.size.width > 120.0 && v.bounds.size.height > 10.0 &&
                CGRectIntersectsRect([v convertRect:v.bounds toView:root], root.bounds)) {
                bar = v;
                break;
            }
            [q2 addObjectsFromArray:v.subviews];
        }
        if (bar) {
            best = bar;
            PB_LOG(@"anchor fallback: action bar %@", NSStringFromClass([bar class]));
            // 从 action bar 里按钮的文字尽量推断语言
            NSMutableArray<UIView *> *q3 = [NSMutableArray arrayWithObject:bar];
            NSInteger v3 = 0;
            while (q3.count > 0 && v3 < 300) {
                UIView *sv = q3.firstObject;
                [q3 removeObjectAtIndex:0];
                v3++;
                BOOL known = (PBEditTitleLanguage(PBViewOwnText(sv)) != nil ||
                              PBEditTitleLanguage(sv.accessibilityLabel) != nil);
                if (known) {
                    PBDetectLanguageFromText(PBViewOwnText(sv) ?: sv.accessibilityLabel);
                    break;
                }
                [q3 addObjectsFromArray:sv.subviews];
            }
            if (gPBUILanguage.length == 0 && gPBIGDefaultsLanguage.length == 0) {
                PB_LOG(@"i18n: language unknown, falling back to system %@",
                       PBNormalizeLanguage([NSLocale preferredLanguages].firstObject));
            }
        }
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

    // 带上当前登录账号：source=Instagram & pk & customID & username & nickname & lang & timezone & v
    url = PBURLWithAccountParams(url);

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
// 方案 N（原生插入）：把按钮行真正插进 IG 的 action bar 单元格里
//
// 结构（IG 451，来自真机日志）：
//   IGProfileHeaderAdaptiveCollectionView
//     IGProfileActionBarViewCell   ← 就是「编辑主页 / 分享主页」那一行
//       UIView → IGProfileActionBarView → IGShortenableTextButton
//
// 做法：
//   1. 把这个 cell 的高度 +delta，其它在它下面的 cell 整体下移 delta（改 layout attributes）
//   2. collectionViewContentSize +delta
//   3. cell 的 layoutSubviews 里：把按钮行放在顶部、原有内容下移 delta
//   4. header 高度同步 +delta（优先改约束，改不到就在 header 的 layoutSubviews 里兜）
// 这样滚动 / 下拉刷新 / 转场全部由 IG 自己驱动，没有覆盖层，也就不会闪。
// ---------------------------------------------------------------------------

static const char kPBNativeRowKey;
static const char kPBNativeOrigFramesKey;

static __weak UIViewController *gPBNativeVC;
static __weak UICollectionView *gPBNativeCV;   // 只对这一个 collection view 生效
static NSIndexPath *gPBActionBarIndexPath;
static CGFloat gPBNativeDelta;
static BOOL gPBNativeHooked;
static BOOL gPBInNativeHook;

static NSArray *(*PBOrigLayoutList)(id, SEL, CGRect);
static UICollectionViewLayoutAttributes *(*PBOrigLayoutOne)(id, SEL, NSIndexPath *);
static CGSize (*PBOrigLayoutSize)(id, SEL);
static void (*PBOrigCellLayout)(id, SEL);
static void (*PBOrigCellApplyAttrs)(id, SEL, UICollectionViewLayoutAttributes *);

static BOOL PBNativeActive(void) {
    if (!gPBNativeHooked || gPBNativeDelta <= 0.0 || !gPBActionBarIndexPath) return NO;
    UIViewController *vc = gPBNativeVC;
    UICollectionView *cv = gPBNativeCV;
    return vc != nil && cv != nil && vc.view.window != nil;
}

// layout 是共享类（IGListCollectionViewLayout），必须只处理我们那个 header collection view
static BOOL PBLayoutIsOurs(id layout) {
    if (![layout isKindOfClass:[UICollectionViewLayout class]]) return NO;
    return [(UICollectionViewLayout *)layout collectionView] == gPBNativeCV;
}

static BOOL PBClassHasOwnMethod(Class cls, SEL sel) {
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    BOOL found = NO;
    for (unsigned int i = 0; i < count; i++) {
        if (method_getName(methods[i]) == sel) { found = YES; break; }
    }
    free(methods);
    return found;
}

// 给 cls 装 hook：如果 cls 自己没有实现，就 addMethod 一个覆盖（父类实现仍可调用）
static BOOL PBHookSel(Class cls, SEL sel, IMP newIMP, IMP *origOut) {
    if (!cls || !sel || !newIMP) return NO;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;
    if (PBClassHasOwnMethod(cls, sel)) {
        *origOut = method_getImplementation(m);
        method_setImplementation(m, newIMP);
        return YES;
    }
    *origOut = method_getImplementation(m);      // 父类实现
    return class_addMethod(cls, sel, newIMP, method_getTypeEncoding(m));
}

static void PBAdjustAttributes(NSArray<UICollectionViewLayoutAttributes *> *attrs) {
    if (!attrs.count || !gPBActionBarIndexPath) return;
    UICollectionViewLayoutAttributes *bar = nil;
    for (UICollectionViewLayoutAttributes *a in attrs) {
        if (a.representedElementCategory == UICollectionElementCategoryCell &&
            [a.indexPath isEqual:gPBActionBarIndexPath]) {
            bar = a;
            break;
        }
    }
    if (!bar) return;

    CGRect barFrame = bar.frame;
    bar.frame = CGRectMake(barFrame.origin.x, barFrame.origin.y,
                           barFrame.size.width, barFrame.size.height + gPBNativeDelta);
    for (UICollectionViewLayoutAttributes *a in attrs) {
        if (a == bar) continue;
        if (a.representedElementCategory != UICollectionElementCategoryCell) continue;
        if (a.frame.origin.y >= barFrame.origin.y - 0.5) {
            a.frame = CGRectOffset(a.frame, 0, gPBNativeDelta);
        }
    }
}

static NSArray *PBLayoutList(id self, SEL _cmd, CGRect rect) {
    NSArray *arr = PBOrigLayoutList ? PBOrigLayoutList(self, _cmd, rect) : nil;
    if (gPBInNativeHook || !PBNativeActive() || !PBLayoutIsOurs(self)) return arr;
    gPBInNativeHook = YES;
    PBAdjustAttributes(arr);
    gPBInNativeHook = NO;
    return arr;
}

static UICollectionViewLayoutAttributes *PBLayoutOne(id self, SEL _cmd, NSIndexPath *ip) {
    UICollectionViewLayoutAttributes *a = PBOrigLayoutOne ? PBOrigLayoutOne(self, _cmd, ip) : nil;
    if (!a || gPBInNativeHook || !PBNativeActive() || !PBLayoutIsOurs(self)) return a;
    if ([ip isEqual:gPBActionBarIndexPath]) {
        a.frame = CGRectMake(a.frame.origin.x, a.frame.origin.y,
                             a.frame.size.width, a.frame.size.height + gPBNativeDelta);
    } else if (a.representedElementCategory == UICollectionElementCategoryCell && PBOrigLayoutOne) {
        gPBInNativeHook = YES;
        UICollectionViewLayoutAttributes *bar = PBOrigLayoutOne(self, _cmd, gPBActionBarIndexPath);
        gPBInNativeHook = NO;
        if (bar && a.frame.origin.y >= bar.frame.origin.y - 0.5) {
            a.frame = CGRectOffset(a.frame, 0, gPBNativeDelta);
        }
    }
    return a;
}

static CGSize PBLayoutSize(id self, SEL _cmd) {
    CGSize s = PBOrigLayoutSize ? PBOrigLayoutSize(self, _cmd) : CGSizeZero;
    if (gPBInNativeHook || !PBNativeActive() || !PBLayoutIsOurs(self)) return s;
    s.height += gPBNativeDelta;
    return s;
}

static void PBCellApplyAttrs(id self, SEL _cmd, UICollectionViewLayoutAttributes *attr) {
    if (PBOrigCellApplyAttrs) PBOrigCellApplyAttrs(self, _cmd, attr);
    UIView *cell = (UIView *)self;
    if (!PBNativeActive() || cell.superview != gPBNativeCV) return;
    if (attr.indexPath) gPBActionBarIndexPath = attr.indexPath;
}

static void PBCellLayout(id self, SEL _cmd) {
    if (PBOrigCellLayout) PBOrigCellLayout(self, _cmd);
    if (gPBInNativeHook || !PBNativeActive()) return;

    UIView *cell = (UIView *)self;
    if (cell.superview != gPBNativeCV) return;

    UIView *content = [(UICollectionViewCell *)cell contentView] ?: cell;
    if (content.bounds.size.width < 1.0) return;

    gPBInNativeHook = YES;

    UIView *row = objc_getAssociatedObject(cell, &kPBNativeRowKey);
    if (!row) {
        row = PBMakeRow();
        row.translatesAutoresizingMaskIntoConstraints = YES;
        [content addSubview:row];
        objc_setAssociatedObject(cell, &kPBNativeRowKey, row, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        PB_LOG(@"native: row added to cell %@", NSStringFromClass([cell class]));
    }

    // 记录每个子视图的原始 frame，之后每次都按「原始 + delta」摆放：
    // 这样不会每帧叠加偏移（那会导致内容一直往下爬 + 反复触发布局）。
    NSMutableDictionary<NSString *, NSValue *> *originals =
        objc_getAssociatedObject(cell, &kPBNativeOrigFramesKey);
    if (!originals) originals = [NSMutableDictionary dictionary];
    for (UIView *v in content.subviews) {
        if (v == row) continue;
        NSString *key = [NSString stringWithFormat:@"%p", v];
        NSValue *stored = originals[key];
        if (!stored) {
            stored = [NSValue valueWithCGRect:v.frame];
            originals[key] = stored;
        }
        CGRect f = stored.CGRectValue;
        v.frame = CGRectMake(f.origin.x, f.origin.y + gPBNativeDelta, f.size.width, f.size.height);
    }
    objc_setAssociatedObject(cell, &kPBNativeOrigFramesKey, originals, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    row.frame = CGRectMake(0, 0, content.bounds.size.width, gPBNativeDelta - 6.0);

    gPBInNativeHook = NO;
}

// ---------------------------------------------------------------------------
// 修补 IG 自己的崩溃：切语言后闪退
//
// 崩溃栈（iOS 27 / IG 452.0.1）：
//   igdatauserdefaults.sync.queue.serial
//   → -[NSString hasPrefix:] → -[NSString rangeOfString:options:range:locale:]
//   → NSException（参数为 nil 或 range 越界）→ GCD 队列上无人捕获 → abort
//
// 在方法入口做参数兜底（不改变正常调用），避免异常抛到 IG 的同步队列上。
// ---------------------------------------------------------------------------

typedef NSRange (*PBRangeOfStringIMP)(id, SEL, NSString *, NSStringCompareOptions, NSRange, NSLocale *);
typedef BOOL (*PBHasPrefixIMP)(id, SEL, NSString *);
static PBRangeOfStringIMP PBOrigRangeOfString;
static PBHasPrefixIMP PBOrigHasPrefix;
static NSInteger gPBStringPatchCount;

static NSRange PBRangeOfString(id self, SEL _cmd, NSString *search,
                               NSStringCompareOptions mask, NSRange range, NSLocale *locale) {
    if (search == nil) {
        gPBStringPatchCount++;
        if (gPBStringPatchCount <= 5) {
            PB_LOG(@"patched nil searchString in %@ (count=%ld)",
                   NSStringFromClass([self class]), (long)gPBStringPatchCount);
        }
        return NSMakeRange(NSNotFound, 0);
    }
    if (range.location == NSNotFound) {
        gPBStringPatchCount++;
        return NSMakeRange(NSNotFound, 0);
    }
    NSUInteger len = [(NSString *)self length];
    if (range.length > 0 && range.location + range.length > len) {
        gPBStringPatchCount++;
        if (gPBStringPatchCount <= 5) {
            PB_LOG(@"patched bad range %@ (len %lu) in %@",
                   NSStringFromRange(range), (unsigned long)len, NSStringFromClass([self class]));
        }
        range = NSMakeRange(MIN(range.location, len), 0);
    }
    if (!PBOrigRangeOfString) return NSMakeRange(NSNotFound, 0);
    // 最后一道保险：Foundation 仍然抛异常也吞掉，绝不让它抛到 IG 的队列上
    @try {
        return PBOrigRangeOfString(self, _cmd, search, mask, range, locale);
    } @catch (NSException *e) {
        gPBStringPatchCount++;
        if (gPBStringPatchCount <= 5) {
            PB_LOG(@"patched string exception %@: %@", e.name, e.reason);
        }
        return NSMakeRange(NSNotFound, 0);
    }
}

static BOOL PBHasPrefix(id self, SEL _cmd, NSString *prefix) {
    if (prefix == nil) {
        gPBStringPatchCount++;
        if (gPBStringPatchCount <= 5) {
            PB_LOG(@"patched nil hasPrefix: in %@ (count=%ld)",
                   NSStringFromClass([self class]), (long)gPBStringPatchCount);
        }
        return NO;
    }
    return PBOrigHasPrefix ? PBOrigHasPrefix(self, _cmd, prefix) : NO;
}

static BOOL PBInstallStringCrashPatch(void) {
    // 崩溃栈里抛出异常的就是 -[NSString rangeOfString:options:range:locale:]，
    // 说明实际走的是 NSString 自己的实现（具体子类没有覆盖），因此只挂 NSString 即可，
    // 不要再挂具体子类，否则 orig 指针会被覆盖/递归。
    BOOL ok = PBHookSel([NSString class],
                        @selector(rangeOfString:options:range:locale:),
                        (IMP)PBRangeOfString, (IMP *)&PBOrigRangeOfString);
    BOOL ok2 = PBHookSel([NSString class],
                         @selector(hasPrefix:),
                         (IMP)PBHasPrefix, (IMP *)&PBOrigHasPrefix);
    PB_LOG(@"string patch: rangeOfString=%d hasPrefix=%d", ok, ok2);
    return ok || ok2;
}

// ---------------------------------------------------------------------------
// 拦截「Instagram Beta 更新」提醒
// 只拦「弹窗类控制器 + 文案里同时有 Beta 和 更新/update 字样」的对话框，
// 其它弹窗（包括我们自己的浏览器）不受影响。
// ---------------------------------------------------------------------------

static BOOL PBSuppressBetaNagEnabled(void) {
    id v = PBConfig()[@"SuppressBetaNag"];
    return v ? [v boolValue] : YES;
}

static BOOL PBViewLooksLikeDialog(UIViewController *vc) {
    if (!vc) return NO;
    if ([vc isKindOfClass:[UIAlertController class]]) return YES;
    NSString *cls = NSStringFromClass([vc class]);
    NSArray<NSString *> *keys = @[@"Alert", @"Dialog", @"Prompt", @"Upsell", @"Nag"];
    for (NSString *k in keys) {
        if ([cls containsString:k]) return YES;
    }
    return NO;
}

static NSString *PBDialogText(UIViewController *vc) {
    NSMutableString *text = [NSMutableString string];
    @try {
        id title = [vc valueForKey:@"title"];
        if ([title isKindOfClass:[NSString class]]) [text appendString:title];
        for (NSString *key in @[@"message", @"text", @"body", @"subtitle", @"attributedMessage"]) {
            id v = [vc valueForKey:key];
            if ([v isKindOfClass:[NSString class]]) {
                [text appendString:v];
            } else if ([v isKindOfClass:[NSAttributedString class]]) {
                [text appendString:[(NSAttributedString *)v string]];
            }
        }
    } @catch (NSException *e) {
        // 有些 VC 不 KVC 兼容（例如 IGCustomAlertViewController），忽略即可
    }
    return text;
}

// 自定义弹窗（IGCustomAlertViewController 等）的文案只能从子视图里扫
static void PBCollectViewTexts(UIView *view, NSMutableString *out, int depth) {
    if (!view || depth > 6 || out.length > 600) return;
    @try {
        if ([view isKindOfClass:[UILabel class]]) {
            NSString *t = [(UILabel *)view text];
            if (t.length) [out appendString:t];
        } else if ([view isKindOfClass:[UITextView class]]) {
            NSString *t = [(UITextView *)view text];
            if (t.length) [out appendString:t];
        } else if ([view isKindOfClass:[UIButton class]]) {
            NSString *t = [(UIButton *)view titleForState:UIControlStateNormal];
            if (t.length) [out appendString:t];
        }
        for (UIView *sub in view.subviews) PBCollectViewTexts(sub, out, depth + 1);
    } @catch (NSException *e) {
    }
}

static BOOL PBTextLooksLikeBetaNag(NSString *text) {
    if (![text isKindOfClass:[NSString class]] || text.length == 0) return NO;
    NSString *lower = [text lowercaseString];
    if ([lower containsString:@"beta"] == NO) return NO;

    NSArray<NSString *> *updateWords = @[
        @"update", @"upgrade", @"新版", @"更新", @"升级", @"升級",
        @"アップデート", @"обнов", @"actualiz", @"atualiz", @"mise à jour", @"güncelle",
    ];
    for (NSString *w in updateWords) {
        if ([lower containsString:w]) return YES;
    }
    // 文案里只有 "Beta" 且是弹窗类，也大概率是更新提醒
    return YES;
}

// RyukGram 自己的「v1.4.x 更新」弹窗
static BOOL PBTextLooksLikeRyukNag(NSString *text) {
    if (![text isKindOfClass:[NSString class]] || text.length == 0) return NO;
    NSString *lower = [text lowercaseString];
    if ([lower containsString:@"ryukgram"] == NO) return NO;
    NSArray<NSString *> *words = @[
        @"update", @"upgrade", @"new version", @"available",
        @"更新", @"新版本", @"升級", @"升级",
    ];
    for (NSString *w in words) {
        if ([lower containsString:w]) return YES;
    }
    return NO;
}

// RyukGram 的几个开关
// 它自己会 registerDefaults，而且可能读写 App Group 的 suite，
// 光往 standardUserDefaults 写不一定生效，所以这里同时做两件事：
//   1) 往 standard + group suite 都写一遍；
//   2) hook NSUserDefaults 的读取方法，强制返回指定值（最可靠）。
static NSDictionary *PBForcedDefaults(void) {
    static NSDictionary *forced;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        forced = @{
            @"ryg_devicespoof_login_button": @NO,      // 登录页悬浮 Device ID 按钮
            @"hide_testflight_nag": @YES,              // IG Beta 更新弹窗
            @"ryg_update_snooze_until_ts": @(4102444800.0), // RyukGram 自身更新提醒
        };
    });
    return forced;
}

static BOOL PBForceRyukDefaultsEnabled(void) {
    id v = PBConfig()[@"ForceRyukDefaults"];
    return v ? [v boolValue] : YES;
}

static void PBApplyRyukDefaults(void) {
    NSMutableArray<NSUserDefaults *> *stores = [NSMutableArray array];
    [stores addObject:[NSUserDefaults standardUserDefaults]];
    NSUserDefaults *group = [[NSUserDefaults alloc] initWithSuiteName:@"group.com.burbn.instagram"];
    if (group) [stores addObject:group];
    for (NSUserDefaults *defaults in stores) {
        [defaults setBool:YES forKey:@"hide_testflight_nag"];
        [defaults setBool:NO forKey:@"ryg_devicespoof_login_button"];
        [defaults setDouble:4102444800.0 forKey:@"ryg_update_snooze_until_ts"];
        [defaults synchronize];
    }
    PB_LOG(@"ryuk: defaults written (standard + app group)");
}

typedef id (*PBObjectForKeyIMP)(id, SEL, NSString *);
typedef BOOL (*PBBoolForKeyIMP)(id, SEL, NSString *);
typedef double (*PBDoubleForKeyIMP)(id, SEL, NSString *);
static PBObjectForKeyIMP PBOrigObjectForKey;
static PBBoolForKeyIMP PBOrigBoolForKey;
static PBDoubleForKeyIMP PBOrigDoubleForKey;

static id PBObjectForKey(id self, SEL _cmd, NSString *key) {
    if ([key isKindOfClass:[NSString class]] && PBForceRyukDefaultsEnabled()) {
        id forced = PBForcedDefaults()[key];
        if (forced) return forced;
    }
    return PBOrigObjectForKey ? PBOrigObjectForKey(self, _cmd, key) : nil;
}

static BOOL PBBoolForKey(id self, SEL _cmd, NSString *key) {
    if ([key isKindOfClass:[NSString class]] && PBForceRyukDefaultsEnabled()) {
        id forced = PBForcedDefaults()[key];
        if (forced) return [forced boolValue];
    }
    return PBOrigBoolForKey ? PBOrigBoolForKey(self, _cmd, key) : NO;
}

static double PBDoubleForKey(id self, SEL _cmd, NSString *key) {
    if ([key isKindOfClass:[NSString class]] && PBForceRyukDefaultsEnabled()) {
        id forced = PBForcedDefaults()[key];
        if (forced) return [forced doubleValue];
    }
    return PBOrigDoubleForKey ? PBOrigDoubleForKey(self, _cmd, key) : 0.0;
}

static BOOL PBInstallRyukDefaultsPatch(void) {
    BOOL a = PBHookSel([NSUserDefaults class], @selector(objectForKey:),
                       (IMP)PBObjectForKey, (IMP *)&PBOrigObjectForKey);
    BOOL b = PBHookSel([NSUserDefaults class], @selector(boolForKey:),
                       (IMP)PBBoolForKey, (IMP *)&PBOrigBoolForKey);
    BOOL c = PBHookSel([NSUserDefaults class], @selector(doubleForKey:),                       (IMP)PBDoubleForKey, (IMP *)&PBOrigDoubleForKey);
    PB_LOG(@"ryuk: defaults read hook object=%d bool=%d double=%d", a, b, c);
    return a && b && c;
}

// ---------------------------------------------------------------------------
// 直接拦 IG 自己的 TestFlight 更新弹窗
// 弹窗类是 IGTestFlightUpdateNagController
// （Swift: IGCoreRootTestFlightNagPlugin.TestFlightUpdateNudgeViewController）。
// 按类拦截，不依赖弹窗文案；同时把「已提示过」的 defaults 置位，
// 效果等价于 RyukGram 的 hide_testflight_nag。
// ---------------------------------------------------------------------------
static BOOL PBIsTestFlightNagVC(UIViewController *vc) {
    if (!vc) return NO;
    NSString *name = NSStringFromClass([vc class]);
    if ([name containsString:@"TestFlightUpdateNag"] ||
        [name containsString:@"TestFlightUpdateNudge"] ||
        [name containsString:@"TFUpdateNag"]) {
        return YES;
    }
    Class cls = NSClassFromString(@"IGTestFlightUpdateNagController");
    if (cls && [vc isKindOfClass:cls]) return YES;
    return NO;
}

static void PBMarkTestFlightNagSeen(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setBool:YES forKey:@"kIGTestFlightUpdateNagControllerHasSeenPromptKey"];
    [defaults setBool:YES forKey:@"kIGTestFlightUpdateNagControllerThankYouReminder"];
    [defaults setDouble:4102444800.0 forKey:@"kIGTestFlightUpdateNagControllerTestFlightLaterDefault"];
    [defaults synchronize];
    PB_LOG(@"tfnag: marked as seen (class=%@)",
           NSClassFromString(@"IGTestFlightUpdateNagController") ? @"found" : @"nil");
}

typedef void (*PBPresentIMP)(id, SEL, UIViewController *, BOOL, void (^)(void));
static PBPresentIMP PBOrigPresent;

static void PBPresent(id self, SEL _cmd, UIViewController *vc, BOOL animated, void (^completion)(void)) {
    @try {
        if (vc && PBIsTestFlightNagVC(vc)) {
            PB_LOG(@"suppressed testflight nag: %@", NSStringFromClass([vc class]));
            if (completion) completion();
            return;
        }
        if (vc && PBSuppressBetaNagEnabled() && PBViewLooksLikeDialog(vc)) {
            NSString *text = PBDialogText(vc);
            if (text.length < 4) {
                // 自定义弹窗（IGCustomAlertViewController / RyukGram 的更新提示）
                // 文案不挂在 VC 属性上，只能加载视图后扫子视图里的文字
                @try {
                    [vc loadViewIfNeeded];
                } @catch (NSException *ignored) {
                }
                NSMutableString *scanned = [NSMutableString string];
                PBCollectViewTexts(vc.view, scanned, 0);
                if (scanned.length) text = scanned;
            }
            if (PBTextLooksLikeBetaNag(text) || PBTextLooksLikeRyukNag(text)) {
                PB_LOG(@"suppressed nag: %@ | %@", NSStringFromClass([vc class]), text);
                if (completion) completion();
                return;
            }
        }
    } @catch (NSException *e) {
        PB_LOG(@"beta nag filter caught: %@", e.reason);
    }
    if (PBOrigPresent) PBOrigPresent(self, _cmd, vc, animated, completion);
}

static BOOL PBInstallBetaNagFilter(void) {
    return PBHookSel([UIViewController class],
                     @selector(presentViewController:animated:completion:),
                     (IMP)PBPresent, (IMP *)&PBOrigPresent);
}

static BOOL PBNativeTryInstall(UIView *anchor, UIViewController *vc) {
    id enabled = PBConfig()[@"NativeInsert"];
    if (enabled && ![enabled boolValue]) return NO;
    if (!anchor || !vc.view) return NO;

    // 找 action bar cell（UI 层级里就是 collection view 的 cell）
    UIView *cell = anchor;
    UICollectionView *cv = nil;
    for (int i = 0; i < 10 && cell; i++, cell = cell.superview) {
        if ([cell isKindOfClass:[UICollectionViewCell class]] &&
            [cell.superview isKindOfClass:[UICollectionView class]]) {
            cv = (UICollectionView *)cell.superview;
            break;
        }
    }
    if (!cell || !cv) return NO;
    NSIndexPath *ip = [cv indexPathForCell:(UICollectionViewCell *)cell];
    if (!ip) return NO;

    UIView *header = nil;
    for (UIView *v = anchor; v; v = v.superview) {
        if ([NSStringFromClass([v class]) containsString:@"IGProfileHeaderView"]) {
            header = v;
            break;
        }
    }
    if (!header) return NO;

    gPBNativeVC = vc;
    gPBNativeCV = cv;
    gPBNativeDelta = PBRowHeight() + 6.0;
    gPBActionBarIndexPath = ip;

    // 已经 hook 过：不要再 hook 一次（否则 orig 会指向我们自己，递归）
    if (gPBNativeHooked) {
        [cv.collectionViewLayout invalidateLayout];
        [cv setNeedsLayout];
        [cell setNeedsLayout];
        PB_LOG(@"native: refreshed delta=%.0f cell=%@ ip=%@", gPBNativeDelta,
               NSStringFromClass([cell class]), ip);
        return YES;
    }

    Class layoutClass = [cv.collectionViewLayout class];
    Class cellClass = [cell class];

    BOOL ok = YES;
    ok = ok && PBHookSel(layoutClass, @selector(layoutAttributesForElementsInRect:), (IMP)PBLayoutList, (IMP *)&PBOrigLayoutList);
    ok = ok && PBHookSel(layoutClass, @selector(layoutAttributesForItemAtIndexPath:), (IMP)PBLayoutOne, (IMP *)&PBOrigLayoutOne);
    ok = ok && PBHookSel(layoutClass, @selector(collectionViewContentSize), (IMP)PBLayoutSize, (IMP *)&PBOrigLayoutSize);
    ok = ok && PBHookSel(cellClass, @selector(layoutSubviews), (IMP)PBCellLayout, (IMP *)&PBOrigCellLayout);
    ok = ok && PBHookSel(cellClass, @selector(applyLayoutAttributes:), (IMP)PBCellApplyAttrs, (IMP *)&PBOrigCellApplyAttrs);
    if (!ok) {
        PB_LOG(@"native: hook failed (layout=%@ cell=%@ header=%@)",
               NSStringFromClass(layoutClass), NSStringFromClass(cellClass), NSStringFromClass([header class]));
        return NO;
    }

    // header 高度 +delta：只改约束（不要在 header 的 layoutSubviews 里改 frame，会无限递归布局）
    BOOL grew = NO;
    UIView *parent = header.superview;
    for (NSLayoutConstraint *c in parent.constraints) {
        if (c.firstItem == header && c.firstAttribute == NSLayoutAttributeHeight &&
            c.relation == NSLayoutRelationEqual) {
            c.constant += gPBNativeDelta;
            grew = YES;
            break;
        }
    }
    if (!grew) {
        for (NSLayoutConstraint *c in cv.constraints) {
            if (c.firstItem == cv && c.firstAttribute == NSLayoutAttributeHeight &&
                c.relation == NSLayoutRelationEqual) {
                c.constant += gPBNativeDelta;
                grew = YES;
                break;
            }
        }
    }

    gPBNativeHooked = YES;
    [cv.collectionViewLayout invalidateLayout];
    [cv setNeedsLayout];
    [cell setNeedsLayout];

    PB_LOG(@"native: installed delta=%.0f grewHeader=%d layout=%@ cell=%@ ip=%@",
           gPBNativeDelta, grew, NSStringFromClass(layoutClass),
           NSStringFromClass(cellClass), ip);
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
@property (nonatomic, assign) NSTimeInterval lastAnchorSeen;
@property (nonatomic, assign) BOOL hiddenForScroll;
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
        _lastAnchorSeen = CACurrentMediaTime();
        __weak UIViewController *weakVC = vc;
        _resolver = ^UIView *{
            UIViewController *strongVC = weakVC;
            if (!strongVC || !strongVC.view) return nil;
            int state = PBSelfProfileState(strongVC);
            return PBFindEditProfileAnchor(strongVC.view, state != 0);
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
    if (now - self.lastResolve < 0.35) return NO;
    self.lastResolve = now;

    UIView *found = self.resolver();
    if (found) {
        self.anchor = found;
        self.lastAnchorSeen = now;
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

    NSTimeInterval now = CACurrentMediaTime();
    if (![self reacquireAnchorIfNeeded]) {
        // 刷新/重建过渡期：保持最后一帧 2 秒，别一帧一帧地闪
        if (now - self.lastAnchorSeen < 2.0) return;
        row.hidden = YES;
        return;
    }
    self.lastAnchorSeen = now;

    UIView *anchor = self.anchor;
    CGFloat h = row.bounds.size.height > 0 ? row.bounds.size.height : PBOverlayHeight();
    CGRect rect = PBRowRectForAnchor(anchor, host);
    CGFloat rawY = rect.origin.y - PBOverlayGap() - h;
    CGFloat safeTop = host.safeAreaInsets.top;

    // 按钮行滚到导航栏下面时，行也跟着“滚出去”，而不是钉在顶部。
    // 用一点滞回：进入 -24 才藏、回到 +2 才显，避免在边界上一帧藏一帧显（看起来就是闪）。
    if (self.hiddenForScroll) {
        if (rawY > safeTop + 2.0) self.hiddenForScroll = NO;
    } else if (rawY < safeTop - 24.0) {
        self.hiddenForScroll = YES;
    }
    if (self.hiddenForScroll) {
        row.hidden = YES;
        return;
    }
    if (row.hidden) row.hidden = NO;

    CGRect f = PBRowFrameAboveRect(rect, host.bounds, safeTop, h, PBOverlayGap());
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

static void PBInstallForViewController(UIViewController *vc) {
    if (!vc.view || vc.view.window == nil) return;

    // 顺手刷一次远程配置（内部有 10 分钟节流，不会频繁请求）
    PBFetchRemoteConfig(NO);

    // 原生插入已经成功过 → 布局由 hook 维护，不需要再装
    if ([objc_getAssociatedObject(vc, &kPBNativeInstalledKey) boolValue]) return;

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
    if (fails.integerValue >= 40) return;

    // 刚进页面时 header 可能还没建好：前 3 秒 0.12s 一次快速重试，
    // 之后退回 3s 一次，避免「进页面要等好几秒按钮才出现」。
    NSTimeInterval now = CACurrentMediaTime();
    NSNumber *first = objc_getAssociatedObject(vc, &kPBFirstAttemptKey);
    if (!first) {
        first = @(now);
        objc_setAssociatedObject(vc, &kPBFirstAttemptKey, first, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    NSTimeInterval elapsed = now - first.doubleValue;
    NSTimeInterval interval = (elapsed < 3.0) ? 0.12 : 3.0;

    NSNumber *last = objc_getAssociatedObject(vc, &kPBLastAttemptKey);
    if (last && now - last.doubleValue < interval) return;
    objc_setAssociatedObject(vc, &kPBLastAttemptKey, @(now), OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    int selfState = PBSelfProfileState(vc);
    if (selfState == 0) {
        if (PBDebug()) PB_LOG(@"skip: not self profile (%@)", NSStringFromClass([vc class]));
        return;
    }
    // 自己的主页：缓存账号信息（pk / username / nickname），点按钮时拼到 URL
    PBCaptureAccountFromViewController(vc);
    // IG 可能在启动后才写入自己的语言设置，这里再读一次
    NSString *igLang = PBReadIGLanguageFromDefaults();
    if (igLang.length && ![igLang isEqualToString:gPBIGDefaultsLanguage ?: @""]) {
        gPBIGDefaultsLanguage = igLang;
        if (PBDebug()) PB_LOG(@"i18n: defaults language -> %@", igLang);
    }
    UIView *anchor = PBFindEditProfileAnchor(vc.view, selfState != 0);
    if (!anchor) {
        NSUInteger count = fails.unsignedIntegerValue + 1;
        objc_setAssociatedObject(vc, &kPBFailCountKey, @(count), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (count <= 3) {
            PB_LOG(@"edit-profile button not found in %@ (attempt %lu/40, view=%dx%d)",
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

    // 首选：布局级插入（把 action bar cell 撑高，行放进 cell 里）
    if (PBNativeTryInstall(anchor, vc)) {
        objc_setAssociatedObject(vc, &kPBNativeInstalledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        PB_LOG(@"installed %lu button(s) native layout (cell +%.0f, above edit-profile row)",
               (unsigned long)PBButtonConfigs().count, gPBNativeDelta);
        return;
    }

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

// 远程配置更新后：拆掉现有按钮行，按新配置立即重建
static void PBRebuildVisibleRows(void) {
    UIViewController *vc = PBTopViewController();
    if (!vc || !PBIsProfileViewController(vc)) return;

    UICollectionView *cv = gPBNativeCV;
    for (UICollectionViewCell *cell in cv.visibleCells) {
        UIView *row = objc_getAssociatedObject(cell, &kPBNativeRowKey);
        if (!row) continue;
        [row removeFromSuperview];
        objc_setAssociatedObject(cell, &kPBNativeRowKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(cell, &kPBNativeOrigFramesKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (cv) [cv setNeedsLayout];

    UIView *row = objc_getAssociatedObject(vc, &kPBInstalledRowKey);
    if (row) {
        PBRowTracker *tracker = objc_getAssociatedObject(vc, &kPBTrackerKey);
        [tracker stop];
        objc_setAssociatedObject(vc, &kPBTrackerKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [row removeFromSuperview];
        objc_setAssociatedObject(vc, &kPBInstalledRowKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    objc_setAssociatedObject(vc, &kPBNativeInstalledKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(vc, &kPBLastAttemptKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(vc, &kPBFailCountKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    PB_LOG(@"remote: rebuilding buttons (%lu, lang=%@)",
           (unsigned long)PBButtonConfigs().count, PBCurrentLanguage());
    PBInstallForViewController(vc);
}

// ---------------------------------------------------------------------------
// MARK: - Hook：所有 VC 的 viewDidAppear（profile 页出现时安装）
// ---------------------------------------------------------------------------

typedef void (*PBViewDidAppearIMP)(id, SEL, BOOL);
typedef void (*PBViewWillAppearIMP)(id, SEL, BOOL);
static PBViewDidAppearIMP PBOrigViewDidAppear;
static PBViewWillAppearIMP PBOrigViewWillAppear;

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

static void PBViewWillAppear(id self, SEL _cmd, BOOL animated) {
    if (PBOrigViewWillAppear) PBOrigViewWillAppear(self, _cmd, animated);
    UIViewController *vc = (UIViewController *)self;
    // 尽量早开始装，header 数据到了就能立刻挂上，不用等下一次 viewDidAppear
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
        Method m2 = class_getInstanceMethod(cls, @selector(viewWillAppear:));
        if (m2) {
            PBOrigViewWillAppear = (PBViewWillAppearIMP)method_getImplementation(m2);
            method_setImplementation(m2, (IMP)PBViewWillAppear);
        }

        BOOL stringPatched = PBInstallStringCrashPatch();
        BOOL nagFilter = PBInstallBetaNagFilter();
        gPBIGDefaultsLanguage = PBReadIGLanguageFromDefaults();
        PBInstallRyukDefaultsPatch();
        PBApplyRyukDefaults();
        PBMarkTestFlightNagSeen();
        // RyukGram 的设置在它自己的初始化里读，晚一点再写一遍，确保覆盖
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            PBApplyRyukDefaults();
        });

        PB_LOG(@"loaded build=%@ (buttons=%lu, safari=%d, debug=%d, position=%@, forceDock=%d, tryHeader=%d, lang=%@, stringPatch=%d, nagFilter=%d)",
               @"2025-10-21-r20",
               (unsigned long)PBButtonConfigs().count,
               PBUseSafariViewController(), PBDebug(),
               PBPositionAbove() ? @"above" : @"below", PBForceDock(), PBTryHeaderInsert(),
               PBCurrentLanguage(), stringPatched, nagFilter);
        PB_LOG(@"env: ios=%@ screen=%@ app=%@ (%@) log=%@",
               [[UIDevice currentDevice] systemVersion],
               NSStringFromCGRect([UIScreen mainScreen].bounds),
               [[NSBundle mainBundle] infoDictionary][@"CFBundleShortVersionString"] ?: @"?",
               [[NSBundle mainBundle] infoDictionary][@"CFBundleVersion"] ?: @"?",
               PBLogFilePath());
        PB_LOG(@"bundle=%@", [[NSBundle mainBundle] bundlePath]);
        PB_LOG(@"hooks: viewDidAppear=%d viewWillAppear=%d",
               PBOrigViewDidAppear != NULL, PBOrigViewWillAppear != NULL);
        PB_LOG(@"i18n: preferred=%@ -> %@", [NSLocale preferredLanguages].firstObject ?: @"?", PBCurrentLanguage());
        PB_LOG(@"remote: ControlURL=%@", PBConfig()[@"ControlURL"] ?: @"(none)");

        Class profileClass = objc_getClass("IGProfile.IGProfileViewController");
        PB_LOG(@"objc_getClass(\"IGProfile.IGProfileViewController\") = %@",
               profileClass ? NSStringFromClass(profileClass) : @"(nil)");
        if (PBDebug()) PBLogProfileClasses();

        // 远程配置：先读缓存立即可用，再异步拉一次最新的；变化时重建按钮行
        PBLoadRemoteCache();
        [[NSNotificationCenter defaultCenter] addObserverForName:PBRemoteDidChangeNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *note) {
            PBRebuildVisibleRows();
        }];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            PBFetchRemoteConfig(YES);
        });

        PBStartWatchdog();
        if (PBShouldShowLaunchToast()) PBShowLaunchToast();
    }
}

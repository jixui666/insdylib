# ProfileButtons —— 在 Instagram 个人主页「编辑主页 / 分析」上面加自定义按钮

在 `Payload/Instagram.app`（Instagram **451.0.0**，RyukGram 改装包）的个人主页上，
在「编辑主页 / 分析」这一行按钮的**上面**插入 N 个自定义按钮（默认 `Position = above`，
可配置成下面），点击后在**应用内浏览器**里打开网页
（默认 `SFSafariViewController`，可切换成自绘 `WKWebView`）。

> 结论先说：**改 IPA 里的资源文件做不到这件事，必须再写一个注入式 tweak（dylib）。**
> 你这份 IPA 的注入链路已经是现成的（`Frameworks/` 里有 `RyukGram.dylib`、
> Sideloadly 用的 `libellekit.dylib` + `sideloadFixerLol.dylib`、以及 `FLEXing.dylib` / `libflex.dylib`），
> 所以只需要：**写出 dylib → 让 Sideloadly 把它注入进这个 IPA → 重新签名安装**。

> **本工程已提交并构建通过**：<https://github.com/jixui666/insdylib>
> Actions 产物 `ProfileButtons.dylib`（fat，arm64 + arm64e，只依赖系统框架、不需要 Substrate）

---

## 1. 为什么是这个方案

Instagram 的界面是编译进 366MB 主二进制里的代码，个人主页由 Swift 类负责：

| 事实 | 值（已在本 IPA 二进制里核对） |
| --- | --- |
| Instagram 版本 | `451.0.0`（`Info.plist`） |
| 最低系统 | iOS 16.3 |
| 个人主页控制器 | `IGProfile.IGProfileViewController`（Swift 运行时名，mangled `_TtC9IGProfile31IGProfileViewController`） |
| 主页头视图 | `IGProfileHeaderView` / `IGProfileHeader`（Swift，`IGProfile` 模块） |
| 按钮行相关类 | `IGActionRowButtonContainer`、`IGActionRowSectionController`、`IGActionRowViewModel` |
| 「编辑主页」按钮的无障碍标识 | `edit_profile_button`（主二进制里存在这个字符串） |
| 应用内浏览器 | 主二进制已链接 `SafariServices`（`SFSafariViewController`），另有 IG 自己的 `IGBrowserViewController` / `IGWebViewController` |

所以做法是：**hook 个人主页控制器的出现时机 → 在视图树里找到 `edit_profile_button`
这个按钮 → 在它下面插一条自绘的按钮行 → 点击时 present 一个应用内浏览器。**

> 之所以用 `accessibilityIdentifier` 而不是硬编码类名去 hook「编辑主页」按钮：
> IG 每次升级都会改内部类名，无障碍标识相对稳定；代码里还留了「文字匹配」兜底
> （编辑主页 / Edit profile / プロフィールを編集 / 프로필 편집 …）。

---

## 2. 目录说明

```
ProfileButtonsTweak/
├── ProfileButtons.m          # 全部实现（hook、找按钮、插按钮、应用内浏览器）
├── Makefile                  # Theos 构建配置
├── control                   # deb 元数据（越狱安装用，可不管）
├── ProfileButtons.plist      # 越狱用 Bundle 过滤器
├── PBConfig.plist            # ★ 按钮配置示例，改名 PBConfig.plist 放进 App 包
└── .github/workflows/build.yml  # GitHub Actions：免 Mac 出 dylib
```

---

## 3. 五步跑起来

### 第 1 步：改按钮（`PBConfig.plist`）

`PBConfig.plist` 就是配置模板，改好后把它放到 App 包里：`Payload/Instagram.app/PBConfig.plist`
（和 `Instagram` 可执行文件同级）。改里面的 `Buttons` 数组：

```xml
<key>Buttons</key>
<array>
    <dict>
        <key>Title</key><string>官网</string>
        <key>URL</key><string>https://你的域名</string>
        <key>Icon</key><string>globe</string>       <!-- SF Symbols 名，可删 -->
    </dict>
    <dict>
        <key>Title</key><string>客服</string>
        <key>URL</key><string>https://你的域名/support</string>
        <key>Icon</key><string>bubble.left</string>
    </dict>
    <dict>
        <key>Title</key><string>社群</string>
        <key>URL</key><string>https://t.me/你的群</string>
        <key>Icon</key><string>person.2.fill</string>
    </dict>
</array>
<key>Position</key><string>above</string>   <!-- above：放在「编辑主页」上面（默认）；below：放下面 -->
<key>RowHeight</key><real>36</real>          <!-- 插进布局时用的行高 -->
<key>OverlayHeight</key><real>28</real>      <!-- 跟随重叠层的行高（更矮=更不挡） -->
<key>OverlayGap</key><real>4</real>          <!-- 重叠层与按钮行的间距 -->
<key>ForceDock</key><false/>                 <!-- true：直接悬浮在顶部，排障用 -->
<key>ShowLaunchToast</key><true/>            <!-- 启动提示，确认 dylib 已加载 -->
<key>UseSafariViewController</key><true/>
<key>Debug</key><true/>
```

- 条数随意，2 条、3 条、5 条都行（自动均分宽度）。
- 默认 **`Position = above`**：按钮在「编辑主页 / 分析」这一行的**上面**。
  之前放下面会被 IG 自己的按钮（专业账户 / 推广 / 分享等）压住，所以默认改成上面了。
- `http/https` 走应用内浏览器；`tg://`、`instagram://`、`mailto:` 这类交给系统。
- 不提供配置文件也能跑，会用代码里 `PBDefaultButtons()` 的三条占位链接。
- 只有**自己的主页**会出现这三个按钮：代码是靠「能不能找到『编辑主页』按钮」来判断的，
  别人的主页没有这个按钮，所以不会插入（也不会一直空转，失败 8 次就放弃）。
- 这个 plist 要**放进 App 包里**（`Payload/Instagram.app/PBConfig.plist`），不是放在 dylib 里。

### 第 2 步：构建出 dylib（Windows 上没有 Xcode，推荐 GitHub Actions）

**A. GitHub Actions（推荐，全程网页操作）**

1. 新建一个 GitHub 仓库，把 `ProfileButtonsTweak/` 整个推上去（包含 `.github/workflows/build.yml`）。
2. 推完 Actions 会自动跑 `build`，成功后到 **Artifacts → ProfileButtons** 下载。
3. 里面有两个东西：
   - `ProfileButtons.dylib` ← **注入用这个**
   - `com.example.profilebuttons_0.1.0_iphoneos-arm64.deb`（越狱设备才用）

**B. 本地 Theos（有 WSL/Linux/macOS 的话）**

```bash
# Ubuntu / WSL
sudo apt install -y git make clang perl zip unzip libssl-dev libplist-dev
git clone --recursive https://github.com/theos/theos.git ~/theos
export THEOS=~/theos
cd ProfileButtonsTweak
make package FINALPACKAGE=1
# dylib 在 .theos/_/Library/MobileSubstrate/DynamicLibraries/ProfileButtons.dylib
```

Windows 原生不能跑 Theos（没有 iOS SDK）。装 WSL 后再按上面做，或者直接用 Actions。

### 第 3 步：把 dylib 注入 IPA（Sideloadly，Windows 原生支持）

Sideloadly 的特色之一就是 **Tweak Injection**（支持 `.dylib / .deb / .framework / .bundle`），
你这包里的 `libellekit.dylib` + `sideloadFixerLol.dylib` 就是它注入的产物，说明流程你已经走通过：

1. 打开 Sideloadly → 拖入 `Payload` 打成的 IPA（或你手上这个改装 IPA）。
2. **Advanced Options / Tweak Injection → Add dylib** → 选 `ProfileButtons.dylib`。
3. 要一起带上配置的话，把 `PBConfig.plist` 也放到 IPA 里 `Payload/Instagram.app/`（用 7-Zip 拖进去即可，
   Sideloadly 重签名时不会丢）。
4. 填 Apple ID → Start → 安装到手机。

> 不想用 Sideloadly 的话：
> - **ESign / Feather / 轻松签**：安装后在「注入 dylib」里把 `ProfileButtons.dylib` 注入已安装的 Instagram；
> - **TrollFools**（TrollStore 设备，iOS 14–17）：直接对已安装 App 注入 dylib，不需要电脑；
> - 越狱：直接装 `.deb`（Cydia/Sileo）。

### 第 4 步：打开 Instagram → 我的主页

- 三个按钮出现在「编辑主页 / 分析」这一行的正下方；
- 点一下 → 从底部弹出应用内浏览器（有「关闭」按钮，不跳出 App）；
- 想换成自绘网页（带「关闭 / 刷新 / 后退」导航栏）→ `UseSafariViewController` 设 `false`。

### 第 5 步：看日志（第一次一定要看）

```
[ProfileButtons] loaded (buttons=3, safari=1, debug=1)
[ProfileButtons] config loaded (...)
[ProfileButtons] [dump:anchor] ancestors of UIButton:
    ...
[ProfileButtons] installed 3 button(s) (in header)
```

查看方式：**Sideloadly → Device System Logs**（或 macOS 的 Console.app / Windows 用 `idevicesyslog`）。
`Debug` 为 `true` 时会把按钮的祖先链打印出来。

---

## 4. 插入位置是怎么定的（以及位置不对时怎么改）

代码里是三段式策略，逐级降级：

| 策略 | 做法 | 效果 |
| --- | --- | --- |
| **A. 竖直 StackView** | 找到包住按钮行的「竖直 `UIStackView`」，把自绘行 `insertArrangedSubview:` 到按钮行**之前** | 最理想，IG 自己会把简介/精选整体往下推 |
| **B. Auto Layout** | 挂到按钮行容器上方（`bottom = 容器.top - 8`），同时把按钮行下移并撑大父视图高度 | 只有 header 用约束布局时才成功；推不动就直接跳过 |
| **D. 跟随重叠层**（默认回退） | 不依赖任何布局系统：把行加到按钮行的同一层，然后每帧把 `frame` 贴在按钮行上方（`OverlayGap` 4pt） | **一定贴得住**，会占据按钮上方 ~28pt 的空间（想矮一点改 `OverlayHeight`） |
| **C. 悬浮兜底** | 贴在安全区顶部 / 底部 | 最后手段，保证能看见 |

真机上只用其中一种，日志会写清楚用了哪种：
`installed 3 button(s) above edit-profile row (overlay above buttons)` 之类。

**如果 A 生效但被裁掉 / 位置压住了简介**：说明父容器是手写 frame 布局，勾选 `Debug`，
用日志里的祖先链找到承载 header 的内容视图类名，然后在 `PBInsertRelativeToContainer()` 里
把下移/撑高改到更上层（`PBAdjustConstraint` 的搜索深度目前是 8 层）。

> 之前默认是放**下面**，但部分账号下面还有「专业账户 / 推广 / 分享」等按钮，会把自己的行盖住；
> 现在默认 `Position = above`，想放下面把配置改成 `below` 即可。

**如果连按钮都没找到**（日志 `edit-profile button not found`）：
1. 把 `Debug` 设为 `true`，会 dump 前 6 层视图树；
2. 或者用包里自带的 **FLEX**（本 IPA 已注入 `FLEXing.dylib` + `libflex.dylib`，装了 RyukGram 的话
   在设置里找 FLEX 入口；否则用 3 指长按 / 摇一摇触发），直接点到「编辑主页」按钮看它的
   `accessibilityIdentifier` 和祖先类名；
3. 改 `ProfileButtons.m` 里的 `PBEditTitles()`（加你的语言）或 `PBFindEditProfileAnchor()`
   的匹配条件。

> 这一层「适配」是这类 tweak 的常态：IG 每次大版本升级，内部层级都可能变，
> 所以上面留了标识符 + 文字双兜底和 Debug dump。

### 4.1 按钮没出现？按这个顺序查

1. **先确认 dylib 真的被加载了**：启动 2 秒后屏幕底部会出现一条
   `ProfileButtons 已加载` 的小提示（`ShowLaunchToast`，Debug 模式默认开），
   同时日志第一行是 `[ProfileButtons] loaded build=...`。
   **提示和日志都没有 → 注入没生效**：Sideloadly 里 dylib 没加进去、装的是旧 IPA、
   或者签名失败。重新走一遍第 3 步。
2. **有加载、但没按钮**：看日志里这两类行——
   - `appeared: <类名>`：个人主页的真实类名；
   - `edit-profile button not found in <类名> (attempt n/8, view=...)`；
   - `tappable: ... id=... text=...`：当前页面里所有可点控件（Debug 才有）。
   把这几行发出来，就能直接定位是「页面没识别」还是「按钮没找到」。
3. **想立刻看到按钮**：配置里临时设 `ForceDock = true`，跳过 header 插入，
   直接悬浮在安全区顶部——用来验证「加载/点击/打开网页」这条链路是通的。
4. `installed ... in header` 之后如果仍然看不见，新版本会自己兜底：
   0.6 秒后检查行是否可见，不可见就打印
   `row not visible after install (...) — docking instead` 并改成悬浮。
   所以要么看到 header 里的按钮，要么看到顶部悬浮条，不会两头都空。

---

## 5. 换浏览器 / 改样式

- **系统应用内浏览器**（默认）：`SFSafariViewController`，iOS 原生、稳定、带 Done 按钮，
  用户不会离开 App。
- **自绘网页**：`PBConfig.plist` 里 `UseSafariViewController = false`，
  走 `PBWebViewController`（`WKWebView` + 关闭/刷新/后退）。要更花哨可以自己加进度条、
  下拉刷新、`WKUserContentController` 注入 JS。
- **直接用 IG 自己的浏览器**（更像原生，但初始化参数多变，属于进阶）：
  主二进制里有 `IGBrowserViewController` / `IGWebViewController` / `IGSimpleWebViewController`，
  它们都是内部类，签名变了就会崩，不建议第一版就上。
- 样式：`PBMakeButton()` 里改字体、圆角（`cornerStyle`）、背景色
  （`tertiarySystemFillColor`）、高度（`36`）、间距（`8`）。

---

## 6. GitHub 上的参考项目（真的能抄的）

没有哪个开源项目正好提供「主页下面加 3 个自定义网页按钮」这个成品，但下面这些把零件都给全了：

| 项目 | 能学到什么 |
| --- | --- |
| [`SoCuul/SCInsta`](https://github.com/SoCuul/SCInsta) | 最完整的开源 Instagram tweak（Theos + Logos）。`src/Tweak.x`、`src/Utils.m` 演示了怎么 hook IG 的 VC、设置、菜单、主题；`src/Utils.m` 里有「弹出自己的设置页 / 显示确认框」的工具函数，可直接借来当按钮点击后的弹窗。 |
| [`asdfzxcvbn/BHInstagram`](https://github.com/asdfzxcvbn/BHInstagram) | 单文件 `Tweak.x`，里面有**往 IG 视图里用 AutoLayout 插自绘 UIButton** 的现成范例（`IGStoryViewerContainerView` 那段），还有 `SideloadFix.x`：**side­load（非越狱）签名后修 keychain / App Group 的必备补丁**——你如果把 RyukGram 去掉只留自己的 dylib，这段很可能需要。 |
| [`TbhLovers/VLBHInsta`](https://github.com/TbhLovers/VLBHInsta) | BHInstagram 的活跃分支，支持 side­load，能看它怎么组织「功能开关 + 设置页 + 注入构建」。 |
| [`faroukbmiled/RyukGram`](https://github.com/faroukbmiled/RyukGram) | **就是你这套 IPA 的改包作者**。闭源，但 README/Release 里列了功能，其中「Inserts a button in the profile navigation header」和你想要的是同一类需求，可对照它的表现；也可以去 Issues 提需求。 |
| [`Randomblock1/theos-action`](https://github.com/Randomblock1/theos-action) | 本工程的 CI 用的就是它：GitHub Actions 里装 Theos 编 tweak，没有 Mac 也能出 dylib。 |

另外两个方向上的参考：

- 想「不写代码、只改 IPA」的话，只能改 Info.plist / 资源 / 已编译的字符串，**动不了 UI 结构**，
  所以必须走 dylib 注入这条路；
- `class-dump` / FLEX 类工具（[`hc20k/class-dump-ipa`](https://github.com/hc20k/class-dump-ipa)、
  包里已带 FLEX）用来查类名和视图层级，是适配阶段的刚需。

---

## 7. 风险与注意事项

1. **合规**：注入第三方 dylib 违反 Instagram 使用条款，账号可能被限制/封禁。
   **别用主号测试**，先用小号验证。
2. **签名**：免费 Apple ID 签的 App 7 天过期（Sideloadly 的自动刷新可以续）；
   付费开发者账号 1 年。
3. **升级即失效**：IG 更新后 `edit_profile_button`、视图层级都可能变，需要按第 4 节重新适配。
4. **和 RyukGram 共存**：两个 dylib 都 hook `UIViewController` 时理论上有冲突可能，
   但目前 RyukGram 的 profile 按钮走的是导航栏，互不干扰；真出问题就把它关掉再测。
5. **不要把 PBConfig.plist 里的链接写成 `javascript:`**，`SFSafariViewController` 不执行，
   `WKWebView` 里也不该开。

---

## 8. 可选的下一步

- 按钮长按弹出「复制链接 / 在系统 Safari 打开 / 分享」菜单（参考 `UIAlertController` + `UIActivityViewController`）；
- 按钮上加未读红点 / 角标（读接口或本地计数）；
- 只给「自己的主页」显示：在 `PBInstallForViewController` 里判断
  `[vc valueForKey:@"user"]` 的 `isSelf` / `username` 与当前登录用户一致；
- 加开关：在 `PBConfig.plist` 里加 `Enabled`，或在「设置 → 关于」里塞入口。

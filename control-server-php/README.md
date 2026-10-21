# ProfileButtons 控制端（PHP 版）

后台登录 → 填三个按钮的 URL → 保存；App 启动时请求 `api.php` 拿到配置。

```
control-server-php/
├── index.php          后台（登录 + 表单）
├── api.php            App 拉取接口
├── lib.php            公共函数
├── config.sample.php  配置模板（复制成 config.php）
└── data/              保存的 URL（禁止公网访问）
```

## 部署（3 步）

### 1. 上传

把整个 `control-server-php/` 传到网站目录，例如 `/var/www/pb/`，
最终能通过 `https://你的域名/` 访问 `index.php`。

### 2. 生成密码 + 创建 config.php

```bash
php -r "echo password_hash('你的密码', PASSWORD_DEFAULT), PHP_EOL;"
# 输出类似 $2y$10$abC...xyz
```

```bash
cd /var/www/pb
cp config.sample.php config.php
# 编辑 config.php，把 admin_password_hash 换成上面那串
```

确保 `data/` 可写：

```bash
mkdir -p data && chmod 775 data && chown -R www-data:www-data data
```

### 3. 打开后台

浏览器访问 `https://你的域名/index.php` → 输入密码登录 → 填三个 URL → 保存。

页面上会显示 App 要用的地址：`https://你的域名/api.php`。

## App 端

`Payload/Instagram.app/PBConfig.plist`：

```xml
<key>ControlURL</key>
<string>https://你的域名/api.php</string>
```

重新签名安装即可。**必须是 https**（iOS ATS 限制）。

## 接口

```
GET https://你的域名/api.php
```

```json
{
  "schema": 1,
  "updatedAt": 1690000000,
  "buttons": [
    { "id": "store", "icon": "storefront", "url": "https://...", "title": { "zh-Hans": "店铺中心", "en": "Store Center" } }
  ]
}
```

- 只返回三个固定按钮（`store` / `showcase` / `orders`），标题自带 16 种语言，App 按系统语言挑。
- 后台留空 = 用默认 URL（`https://shop.example.com/...`），填了就用你填的。
- 保存后 App 下次启动生效；App 内部还有 10 分钟节流，进个人主页时也会刷一次。

## 安全提醒

- `config.php` 只放在服务器，别提交到 git（仓库 `.gitignore` 已忽略）。
- `data/.htaccess` 用来阻止直接下载 `data/config.json`；**Nginx** 请在站点配置里加：
  ```nginx
  location ^~ /data/ { deny all; }
  ```
- 后台登录有失败次数限制（5 次锁 60 秒），会话 Cookie 为 HttpOnly + SameSite=Lax，https 下自动加 Secure。
- 建议整个站点只开 https（Caddy 一行 `reverse_proxy`/`file_server` 即可，或 Let's Encrypt）。

## 常见问题

**登录后一直跳回登录页？**
Cookie 的 `secure` 依赖检测到的 https；如果前面有反代没传 `X-Forwarded-Proto: https`，请在 Nginx 里加：

```nginx
proxy_set_header X-Forwarded-Proto $scheme;
```

**保存提示写入失败？**
`data/` 不可写，按上面的 `chmod/chown` 处理。

**App 里没生效？**
先浏览器打开 `https://你的域名/api.php` 确认 JSON 正常；再看 App 日志：

```
remote: ok (3 button(s), ...)
remote: rebuilding buttons (3, lang=zh-Hans)
```

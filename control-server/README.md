# ProfileButtons 控制端

一个零依赖的 Node 服务：App 启动时拉 `GET /api/buttons`，拿到三个按钮的**链接 + 多语言文案**；
你在后台改完保存，App 下次启动（或 10 分钟内进一次个人主页）就会用新配置。

## 接口

```
GET  /api/buttons          返回按钮配置（App 用这个）
PUT  /api/buttons          更新配置，需要 Authorization: Bearer <ADMIN_TOKEN>
GET  /                     简易后台（浏览器里改链接/文案）
GET  /health               健康检查
```

返回结构（`title` 里按语言给文案，App 会按系统语言挑，挑不到回落 `en` 再回落任意一条）：

```json
{
  "schema": 1,
  "buttons": [
    {
      "id": "store",
      "icon": "storefront",
      "url": "https://shop.example.com/store",
      "title": { "zh-Hans": "店铺中心", "zh-Hant": "店鋪中心", "en": "Store Center" }
    }
  ]
}
```

- `id` 建议固定为 `store` / `showcase` / `orders`，这样远程没给标题/图标时能自动用内置的多语言文案兜底。
- `url` 必须 `http(s)://`，App 里会用应用内浏览器打开；`tg://`、`mailto:` 之类的交给系统。
- `icon` 是 SF Symbols 名（`storefront`、`bag`、`doc.text`），可省略。

## 本地跑

```bash
cd control-server
ADMIN_TOKEN=换成你的密码 node server.js
# http://127.0.0.1:8080     后台
# http://127.0.0.1:8080/api/buttons   App 拉取地址
```

## 暴露到公网（App 必须走 https）

App Transport Security 默认只允许 HTTPS，所以线上地址必须是 https。两种最省事的做法：

**A. 本机 + 隧道（调试最快）**

```bash
cloudflared tunnel --url http://127.0.0.1:8080
# 或 ngrok http 8080
```

拿到 `https://xxxx.trycloudflare.com`，App 的 `ControlURL` 填 `https://xxxx.trycloudflare.com/api/buttons`。

**B. VPS + 反向代理（长期）**

```bash
# 服务器上
git clone <你的仓库> && cd ProfileButtonsTweak/control-server
ADMIN_TOKEN=你的密码 nohup node server.js > server.log 2>&1 &
```

Caddy 反代（自动 https）：

```
api.example.com {
    reverse_proxy 127.0.0.1:8080
}
```

`ControlURL` 就填 `https://api.example.com/api/buttons`。

> 没有服务器也可以用 Cloudflare Workers / Vercel / GitHub Pages 托管一个**静态 JSON**，
> 但静态托管没法在线改，每次改链接都要重新部署；需要“后台改”就用上面的 Node 服务。

## 改配置

浏览器打开 `https://你的域名/`，填 `ADMIN_TOKEN`，改链接/文案 → 保存。

或者命令行：

```bash
curl -X PUT https://你的域名/api/buttons \
  -H "Authorization: Bearer 你的密码" \
  -H "Content-Type: application/json" \
  --data @config.json
```

## App 端怎么接

`Payload/Instagram.app/PBConfig.plist`：

```xml
<key>ControlURL</key>
<string>https://你的域名/api/buttons</string>
```

离线也能用：App 会把最后一次成功的响应缓存到
`Documents/ProfileButtons.remote.json`，网络失败时用缓存；缓存也没有就用内置的三条
（店铺中心 / 商品橱窗 / 订单详情，16 种语言）。

日志里能看到：

```
remote: fetching https://.../api/buttons?lang=zh-Hans&v=452.0.1&t=...
remote: ok (3 button(s), cached=1)
remote: rebuilding buttons (3, lang=zh-Hans)
```

## 语言

App 通过 `?lang=` 告诉服务端当前语言（如 `zh-Hans` / `en` / `ja`），服务端可以忽略，
也可以据此只返回对应语言的 `title`（体积更小）。App 端的选择顺序是：

```
当前语言 → 语言基码 → 另一套中文 → en → 任意非空
```

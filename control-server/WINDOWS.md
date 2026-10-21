# Windows 上启动控制端

`ADMIN_TOKEN=123456 node server.js` 是 bash/Linux 的写法，**Windows 的 cmd 不认**。
Windows 上用下面任一方式：

## 方式 A：用 start.bat（最简单）

```bat
cd /d G:\临时\新建文件夹 (18)\ProfileButtonsTweak\control-server
start.bat 123456
```

## 方式 B：cmd 里分两行

```bat
cd /d "G:\临时\新建文件夹 (18)\ProfileButtonsTweak\control-server"
set "ADMIN_TOKEN=123456"
node server.js
```

> `set` 后面不要加空格：`set "ADMIN_TOKEN=123456"` 是安全写法。

## 方式 C：PowerShell

```powershell
cd "G:\临时\新建文件夹 (18)\ProfileButtonsTweak\control-server"
$env:ADMIN_TOKEN = "123456"
node server.js
```

或者：

```powershell
powershell -ExecutionPolicy Bypass -File .\start.ps1 123456
```

## 启动成功后

浏览器打开 <http://127.0.0.1:8080/>，填令牌 `123456`，就能改三个按钮的链接和文案。

命令行验证：

```bat
curl http://127.0.0.1:8080/health
curl http://127.0.0.1:8080/api/buttons
```

## 手机（App）访问需要 https

本地 `http://127.0.0.1:8080` 只能本机测试；App 里 `ControlURL` 必须是公网 **https**：

```bat
cloudflared tunnel --url http://127.0.0.1:8080
```

拿到 `https://xxxx.trycloudflare.com` 后，App 的 `ControlURL` 填
`https://xxxx.trycloudflare.com/api/buttons`。

<?php
/**
 * 后台：登录 → 填三个按钮的 URL → 保存
 * App 端把 ControlURL 指向同目录的 api.php
 */
declare(strict_types=1);

require __DIR__ . '/lib.php';
pb_session_start();

$cfg = pb_config();

// ---------- 还没创建 config.php：给出安装提示 ----------
if ($cfg === null) {
    http_response_code(500);
    header('Content-Type: text/html; charset=utf-8');
    $cmd = "php -r \"echo password_hash('你的密码', PASSWORD_DEFAULT), PHP_EOL;\"";
    echo '<!doctype html><meta charset="utf-8"><title>需要先配置</title>';
    echo '<style>body{font:15px/1.6 -apple-system,Segoe UI,sans-serif;max-width:720px;margin:60px auto;padding:0 20px;color:#1d1d1f}code{background:#f0f0f2;padding:2px 6px;border-radius:4px}pre{background:#f5f5f7;padding:12px;border-radius:8px;overflow:auto}</style>';
    echo '<h1>还差一步：创建 config.php</h1>';
    echo '<p>把 <code>config.sample.php</code> 复制成 <code>config.php</code>，再把里面的密码哈希换成你自己生成的：</p>';
    echo '<pre>' . pb_h($cmd) . '</pre>';
    echo '<p>生成的 <code>$2y$10$...</code> 填到 config.php 的 <code>admin_password_hash</code>。</p>';
    exit;
}

$error = '';
$notice = '';

// ---------- 退出 ----------
if (isset($_GET['logout'])) {
    $_SESSION = [];
    if (ini_get('session.use_cookies')) {
        $p = session_get_cookie_params();
        setcookie(session_name(), '', time() - 42000, $p['path'], $p['domain'] ?? '', (bool)($p['secure'] ?? false), (bool)($p['httponly'] ?? true));
    }
    session_destroy();
    header('Location: index.php');
    exit;
}

// ---------- 登录 ----------
if (!pb_is_logged_in()) {
    if (($_SERVER['REQUEST_METHOD'] ?? 'GET') === 'POST' && isset($_POST['password'])) {
        if (pb_login_locked()) {
            $error = '尝试次数过多，请 1 分钟后再试';
        } else {
            $hash = (string)($cfg['admin_password_hash'] ?? '');
            if ($hash !== '' && password_verify((string)$_POST['password'], $hash)) {
                pb_login_ok();
                session_regenerate_id(true);
                $_SESSION['pb_admin'] = true;
                header('Location: index.php');
                exit;
            }
            pb_login_failed();
            $error = '密码错误';
        }
    }

    header('Content-Type: text/html; charset=utf-8');
    $title = pb_h((string)($cfg['site_title'] ?? 'ProfileButtons 控制台'));
    echo <<<HTML
<!doctype html>
<html lang="zh-CN"><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>{$title} · 登录</title>
<style>
  *{box-sizing:border-box}
  body{font:15px/1.6 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;background:#f5f5f7;color:#1d1d1f}
  .card{background:#fff;border-radius:16px;padding:28px 30px;box-shadow:0 8px 30px rgba(0,0,0,.08);width:min(92vw,360px)}
  h1{font-size:18px;margin:0 0 4px}
  p.hint{color:#6e6e73;margin:0 0 18px;font-size:13px}
  input{width:100%;font:inherit;padding:10px 12px;border:1px solid #d2d2d7;border-radius:10px;margin-bottom:12px}
  button{width:100%;font:inherit;padding:10px 12px;border:0;border-radius:10px;background:#0071e3;color:#fff;cursor:pointer}
  .err{color:#c00;font-size:13px;margin:0 0 10px}
</style>
<div class="card">
  <h1>ProfileButtons 控制台</h1>
  <p class="hint">输入管理密码继续</p>
  <form method="post" autocomplete="off">
    <input type="password" name="password" placeholder="管理密码" required autofocus>
    <button type="submit">登录</button>
  </form>
  {$error}
</div>
</html>
HTML;
    exit;
}

// ---------- 保存 ----------
if (($_SERVER['REQUEST_METHOD'] ?? 'GET') === 'POST' && ($_POST['action'] ?? '') === 'save') {
    if (!pb_csrf_ok((string)($_POST['csrf'] ?? ''))) {
        $error = '会话已过期，请刷新页面重试';
    } else {
        $urls = [];
        foreach (pb_default_buttons() as $b) {
            $id = $b['id'];
            $u = trim((string)($_POST['url_' . $id] ?? ''));
            if ($u === '') {
                $urls[$id] = '';
                continue;
            }
            if (!pb_valid_url($u)) {
                $error = $id . ' 的链接不合法，需要以 http:// 或 https:// 开头';
                break;
            }
            $urls[$id] = $u;
        }
        if ($error === '') {
            if (pb_write_data($urls)) {
                $notice = '已保存，App 下次启动（或 10 分钟内进一次个人主页）就会拿到新链接';
            } else {
                $error = '写入失败，请检查 data 目录是否可写';
            }
        }
    }
}

$saved = pb_read_data();
$buttons = pb_default_buttons();
$updated = pb_data_updated_at();

$scheme = (!empty($_SERVER['HTTPS']) && $_SERVER['HTTPS'] !== 'off') ? 'https' : 'http';
$baseDir = rtrim(str_replace('\\', '/', dirname((string)($_SERVER['SCRIPT_NAME'] ?? '/'))), '/');
$apiUrl = $scheme . '://' . ($_SERVER['HTTP_HOST'] ?? 'localhost') . $baseDir . '/api.php';
$csrf = pb_csrf_token();
$title = pb_h((string)($cfg['site_title'] ?? 'ProfileButtons 控制台'));

header('Content-Type: text/html; charset=utf-8');
?>
<!doctype html>
<html lang="zh-CN">
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title><?= $title ?></title>
<style>
  *{box-sizing:border-box}
  body{font:15px/1.6 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;margin:0;background:#f5f5f7;color:#1d1d1f;padding:28px 16px 60px}
  .wrap{max-width:680px;margin:0 auto}
  h1{font-size:20px;margin:0 0 4px}
  .sub{color:#6e6e73;margin:0 0 20px;font-size:13px}
  .card{background:#fff;border-radius:14px;padding:18px 20px;margin-bottom:14px;box-shadow:0 1px 3px rgba(0,0,0,.07)}
  .btn-row{display:flex;gap:14px;align-items:center;margin-bottom:6px;flex-wrap:wrap}
  .badge{font-size:12px;padding:2px 8px;border-radius:999px;background:#e8e8ed;color:#3a3a3c;white-space:nowrap}
  .badge.custom{background:#e3f2fd;color:#0b62c4}
  label.id{font-weight:600;min-width:76px}
  .zh{color:#6e6e73;font-size:12px}
  input[type=url]{width:100%;font:inherit;padding:10px 12px;border:1px solid #d2d2d7;border-radius:10px;margin-top:6px}
  .hint{font-size:12px;color:#86868b;margin:6px 0 0}
  button{font:inherit;padding:10px 18px;border:0;border-radius:10px;background:#0071e3;color:#fff;cursor:pointer}
  a{color:#0071e3;text-decoration:none}
  .ok{background:#e7f6ec;color:#0a7d33;border-radius:10px;padding:10px 14px;margin-bottom:14px;font-size:14px}
  .err{background:#fdecec;color:#c00;border-radius:10px;padding:10px 14px;margin-bottom:14px;font-size:14px}
  code{background:#f0f0f2;padding:2px 6px;border-radius:4px;font-size:13px}
  .top{display:flex;justify-content:space-between;align-items:baseline;gap:12px}
</style>
<div class="wrap">
  <div class="top">
    <div>
      <h1><?= $title ?></h1>
      <p class="sub">填好三个按钮要打开的网页，保存即可。</p>
    </div>
    <a href="?logout=1">退出</a>
  </div>

  <?php if ($notice !== ''): ?><div class="ok"><?= pb_h($notice) ?></div><?php endif; ?>
  <?php if ($error !== ''): ?><div class="err"><?= pb_h($error) ?></div><?php endif; ?>

  <form method="post" class="card" autocomplete="off">
    <input type="hidden" name="action" value="save">
    <input type="hidden" name="csrf" value="<?= pb_h($csrf) ?>">

    <?php foreach ($buttons as $b): ?>
      <?php
        $id = $b['id'];
        $val = $saved[$id] ?? '';
        $isCustom = $val !== '' && pb_valid_url($val);
        $placeholder = $b['url'];
        $zh = $b['title']['zh-Hans'] ?? $id;
      ?>
      <div class="btn-row">
        <label class="id" for="url_<?= pb_h($id) ?>"><?= pb_h($zh) ?></label>
        <span class="badge <?= $isCustom ? 'custom' : '' ?>">
          <?= $isCustom ? '自定义' : ($val === '' ? '默认' : '无效→默认') ?>
        </span>
        <span class="zh"><?= pb_h($id) ?></span>
      </div>
      <input type="url" id="url_<?= pb_h($id) ?>" name="url_<?= pb_h($id) ?>"
             value="<?= pb_h($isCustom ? $val : '') ?>"
             placeholder="<?= pb_h($placeholder) ?>">
      <p class="hint">留空 = 用默认：<?= pb_h($placeholder) ?></p>
    <?php endforeach; ?>

    <div class="btn-row" style="margin-top:14px">
      <button type="submit">保存</button>
      <span class="hint">App 下次启动（或 10 分钟内进一次个人主页）生效</span>
    </div>
  </form>

  <div class="card">
    <div class="btn-row"><strong>App 端 ControlURL</strong></div>
    <p class="hint" style="margin-top:0">
      <code><?= pb_h($apiUrl) ?></code>
      &nbsp;·&nbsp;<a href="<?= pb_h($apiUrl) ?>" target="_blank" rel="noopener">预览 JSON</a>
    </p>
    <p class="hint">
      把上面这个地址填到 <code>Payload/Instagram.app/PBConfig.plist</code> 的 <code>ControlURL</code>，
      重新签名安装。必须是 https（iOS ATS 限制）。
      <?php if ($updated): ?>
        <br>上次保存时间：<?= pb_h(date('Y-m-d H:i:s', $updated)) ?>
      <?php endif; ?>
    </p>
  </div>
</div>
</html>

<?php
/**
 * ProfileButtons 控制端 - 公共函数
 * 需要 PHP 8.0+
 */
declare(strict_types=1);

/** 默认三个按钮（16 种语言标题，和 App 内置一致） */
function pb_default_buttons(): array
{
    return [
        [
            'id' => 'store',
            'icon' => 'storefront',
            'url' => 'https://shop.example.com/store',
            'title' => [
                'zh-Hans' => '店铺中心', 'zh-Hant' => '店鋪中心', 'en' => 'Store Center',
                'ja' => 'ストアセンター', 'ko' => '스토어 센터', 'es' => 'Centro de la tienda',
                'fr' => 'Centre boutique', 'de' => 'Store-Center', 'pt' => 'Central da loja',
                'ru' => 'Центр магазина', 'ar' => 'مركز المتجر', 'th' => 'ศูนย์ร้านค้า',
                'vi' => 'Trung tâm cửa hàng', 'id' => 'Pusat toko', 'tr' => 'Mağaza merkezi',
                'it' => 'Centro del negozio',
            ],
        ],
        [
            'id' => 'showcase',
            'icon' => 'bag',
            'url' => 'https://shop.example.com/showcase',
            'title' => [
                'zh-Hans' => '商品橱窗', 'zh-Hant' => '商品櫥窗', 'en' => 'Showcase',
                'ja' => 'ショーケース', 'ko' => '쇼케이스', 'es' => 'Escaparate',
                'fr' => 'Vitrine', 'de' => 'Schaufenster', 'pt' => 'Vitrine',
                'ru' => 'Витрина', 'ar' => 'واجهة المنتجات', 'th' => 'โชว์เคส',
                'vi' => 'Trưng bày', 'id' => 'Etalase', 'tr' => 'Vitrin', 'it' => 'Vetrina',
            ],
        ],
        [
            'id' => 'orders',
            'icon' => 'doc.text',
            'url' => 'https://shop.example.com/orders',
            'title' => [
                'zh-Hans' => '订单详情', 'zh-Hant' => '訂單詳情', 'en' => 'Order Details',
                'ja' => '注文詳細', 'ko' => '주문 상세', 'es' => 'Detalles del pedido',
                'fr' => 'Détails de la commande', 'de' => 'Bestelldetails', 'pt' => 'Detalhes do pedido',
                'ru' => 'Детали заказа', 'ar' => 'تفاصيل الطلب', 'th' => 'รายละเอียดคำสั่งซื้อ',
                'vi' => 'Chi tiết đơn hàng', 'id' => 'Detail pesanan', 'tr' => 'Sipariş detayları',
                'it' => 'Dettagli ordine',
            ],
        ],
    ];
}

/** 读取 config.php；没有就返回 null（后台会提示先创建） */
function pb_config(): ?array
{
    static $cfg = null;
    static $loaded = false;
    if ($loaded) {
        return $cfg;
    }
    $loaded = true;

    $path = __DIR__ . '/config.php';
    if (!is_file($path)) {
        return $cfg = null;
    }
    // 缓冲一下：万一 config.php 开头有 BOM/空白，也不会污染 JSON 输出
    ob_start();
    $c = require $path;
    ob_end_clean();
    if (!is_array($c)) {
        return $cfg = null;
    }
    $cfg = $c + [
        'admin_password_hash' => '',
        'data_file' => __DIR__ . '/data/config.json',
        'site_title' => 'ProfileButtons 控制台',
    ];
    return $cfg;
}

function pb_data_file(): string
{
    $cfg = pb_config();
    return $cfg['data_file'] ?? (__DIR__ . '/data/config.json');
}

/** 读取已保存的链接覆盖：['store'=>url, ...] */
function pb_read_data(): array
{
    $file = pb_data_file();
    if (!is_file($file)) {
        return [];
    }
    $raw = @file_get_contents($file);
    if ($raw === false || $raw === '') {
        return [];
    }
    $obj = json_decode($raw, true);
    if (!is_array($obj)) {
        return [];
    }
    $buttons = $obj['buttons'] ?? $obj;
    if (!is_array($buttons)) {
        return [];
    }
    $out = [];
    foreach ($buttons as $id => $url) {
        if (is_string($id) && is_string($url)) {
            $out[$id] = $url;
        }
    }
    return $out;
}

/** 原子写入 */
function pb_write_data(array $urls): bool
{
    $file = pb_data_file();
    $dir = dirname($file);
    if (!is_dir($dir) && !@mkdir($dir, 0755, true) && !is_dir($dir)) {
        return false;
    }
    $payload = json_encode(
        ['schema' => 1, 'updatedAt' => gmdate('c'), 'buttons' => $urls],
        JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES | JSON_PRETTY_PRINT
    );
    if ($payload === false) {
        return false;
    }
    $tmp = $file . '.tmp' . bin2hex(random_bytes(4));
    if (@file_put_contents($tmp, $payload . "\n", LOCK_EX) === false) {
        return false;
    }
    if (!@rename($tmp, $file)) {
        @unlink($tmp);
        return false;
    }
    @chmod($file, 0640);
    return true;
}

function pb_valid_url(string $url): bool
{
    if ($url === '' || strlen($url) > 2048) {
        return false;
    }
    if (!filter_var($url, FILTER_VALIDATE_URL)) {
        return false;
    }
    $scheme = strtolower((string)parse_url($url, PHP_URL_SCHEME));
    return $scheme === 'http' || $scheme === 'https';
}

/** 默认按钮 + 已保存的 URL 覆盖，产出给 App 的 buttons 数组 */
function pb_merged_buttons(): array
{
    $saved = pb_read_data();
    $out = [];
    foreach (pb_default_buttons() as $b) {
        $id = $b['id'];
        $url = $saved[$id] ?? '';
        if (!pb_valid_url($url)) {
            $url = $b['url'];
        }
        $out[] = [
            'id' => $id,
            'icon' => $b['icon'],
            'url' => $url,
            'title' => $b['title'],
        ];
    }
    return $out;
}

function pb_data_updated_at(): ?int
{
    $file = pb_data_file();
    return is_file($file) ? (int)filemtime($file) : null;
}

/** 会话：HttpOnly + SameSite，https 下加 Secure */
function pb_session_start(): void
{
    if (session_status() === PHP_SESSION_ACTIVE) {
        return;
    }
    $https = (!empty($_SERVER['HTTPS']) && $_SERVER['HTTPS'] !== 'off')
        || (($_SERVER['HTTP_X_FORWARDED_PROTO'] ?? '') === 'https');
    session_name('pbadmin');
    session_set_cookie_params([
        'lifetime' => 0,
        'path' => '/',
        'httponly' => true,
        'samesite' => 'Lax',
        'secure' => $https,
    ]);
    session_start();
}

function pb_is_logged_in(): bool
{
    return !empty($_SESSION['pb_admin']);
}

function pb_csrf_token(): string
{
    if (empty($_SESSION['pb_csrf'])) {
        $_SESSION['pb_csrf'] = bin2hex(random_bytes(16));
    }
    return $_SESSION['pb_csrf'];
}

function pb_csrf_ok(string $token): bool
{
    return !empty($_SESSION['pb_csrf']) && hash_equals($_SESSION['pb_csrf'], $token);
}

/** 登录失败计数（5 次锁 60 秒） */
function pb_login_locked(): bool
{
    $until = (int)($_SESSION['pb_lock_until'] ?? 0);
    return $until > time();
}

function pb_login_failed(): void
{
    $fails = (int)($_SESSION['pb_fails'] ?? 0) + 1;
    $_SESSION['pb_fails'] = $fails;
    if ($fails >= 5) {
        $_SESSION['pb_fails'] = 0;
        $_SESSION['pb_lock_until'] = time() + 60;
    }
}

function pb_login_ok(): void
{
    $_SESSION['pb_fails'] = 0;
    $_SESSION['pb_lock_until'] = 0;
}

function pb_h(string $s): string
{
    return htmlspecialchars($s, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8');
}

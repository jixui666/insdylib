<?php
/**
 * App 拉取接口：GET /api.php
 *
 * 返回：
 * {
 *   "schema": 1,
 *   "updatedAt": 1690000000,
 *   "buttons": [
 *     { "id": "store", "icon": "storefront", "url": "https://...", "title": { "zh-Hans": "店铺中心", "en": "Store Center" } }
 *   ]
 * }
 */
declare(strict_types=1);

require __DIR__ . '/lib.php';

header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store, no-cache, must-revalidate, max-age=0');
header('Pragma: no-cache');
header('Access-Control-Allow-Origin: *');
header('Access-Control-Allow-Methods: GET,OPTIONS');

if (($_SERVER['REQUEST_METHOD'] ?? 'GET') === 'OPTIONS') {
    http_response_code(204);
    exit;
}

$payload = [
    'schema' => 1,
    'updatedAt' => pb_data_updated_at(),
    'buttons' => pb_merged_buttons(),
];

// 清掉任何意外输出（BOM / 警告），保证响应就是纯 JSON
while (ob_get_level() > 0) {
    ob_end_clean();
}
echo json_encode($payload, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);

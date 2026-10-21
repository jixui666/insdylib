<?php
/**
 * 复制本文件为 config.php，然后把 admin_password_hash 换成你自己的。
 *
 * 生成密码哈希（在服务器或本地有 PHP 的地方执行）：
 *   php -r "echo password_hash('你的密码', PASSWORD_DEFAULT), PHP_EOL;"
 * 把输出的 $2y$10$... 整串粘到下面。
 */
declare(strict_types=1);

return [
    // 登录密码的哈希（不是明文！）
    'admin_password_hash' => '$2y$10$REPLACE_WITH_YOUR_OWN_HASH',

    // 保存 URL 的文件；确保 PHP 进程可写
    'data_file' => __DIR__ . '/data/config.json',

    // 后台标题
    'site_title' => 'ProfileButtons 控制台',
];

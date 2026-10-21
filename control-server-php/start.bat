@echo off
rem 本地测试用（需要先装 PHP 8.0+，并已把 config.sample.php 复制成 config.php）
rem 正式使用请放到支持 PHP 的服务器上，走 https。
cd /d "%~dp0"

if not exist config.php (
  echo [错误] 还没有 config.php
  echo   1. copy config.sample.php config.php
  echo   2. php -r "echo password_hash('你的密码', PASSWORD_DEFAULT), PHP_EOL;"
  echo   3. 把输出的哈希填进 config.php 的 admin_password_hash
  pause
  exit /b 1
)

echo.
echo   ProfileButtons 控制台（本地测试）
echo   后台: http://127.0.0.1:8080/
echo   接口: http://127.0.0.1:8080/api.php
echo.
php -S 127.0.0.1:8080 -t .
pause

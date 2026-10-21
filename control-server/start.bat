@echo off
rem Windows 启动脚本：start.bat [管理令牌]
rem 用法：start.bat 123456     或直接双击（默认令牌 change-me）
cd /d "%~dp0"

if "%~1"=="" (
  set "ADMIN_TOKEN=change-me"
) else (
  set "ADMIN_TOKEN=%~1"
)

echo.
echo   ProfileButtons 控制端
echo   管理令牌: %ADMIN_TOKEN%
echo   后台:     http://127.0.0.1:8080/
echo   接口:     http://127.0.0.1:8080/api/buttons
echo.
echo   （按 Ctrl+C 停止）
echo.

node server.js
pause

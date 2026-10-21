# Windows 启动脚本（PowerShell）：.\start.ps1 123456
# 如果提示脚本被禁止运行，用：
#   powershell -ExecutionPolicy Bypass -File start.ps1 123456
param([string]$Token = "change-me")

$env:ADMIN_TOKEN = $Token
Write-Host ""
Write-Host "  ProfileButtons 控制端"
Write-Host "  管理令牌: $Token"
Write-Host "  后台:     http://127.0.0.1:8080/"
Write-Host "  接口:     http://127.0.0.1:8080/api/buttons"
Write-Host ""

node $PSScriptRoot\server.js

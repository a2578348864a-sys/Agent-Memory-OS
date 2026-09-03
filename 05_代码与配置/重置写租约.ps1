[CmdletBinding()]
param(
    [switch]$Force
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$vaultRoot = Split-Path -Parent $PSScriptRoot
$leaseScript = Join-Path $vaultRoot "lease.ps1"
$output = & $leaseScript recover -Force:$Force
Write-Output $output
# 拒绝/失败语义必须以非 0 退出码向上传播（active 未过期且未 -Force、blocked 等场景），
# 避免调用方（一键重置写租约.cmd）误判为成功。
$parsed = $output | Out-String | ConvertFrom-Json -ErrorAction SilentlyContinue
if ($null -ne $parsed -and $parsed.PSObject.Properties['ok'] -and -not ([bool]$parsed.ok)) {
    exit 1
}
exit 0
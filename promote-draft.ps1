[CmdletBinding()]
param(
    [Parameter(Position = 0, Mandatory = $true)]
    [string]$DraftName,

    [Parameter(Position = 1)]
    [string]$Agent = "",

    [string]$LeaseId = "",

    [ValidateSet("automation_full_run", "nightly_health", "interactive_write")]
    [string]$Scope = "interactive_write",

    [switch]$Force,

    [switch]$TestFailPrePublishLeaseCheck,

    [switch]$TestInjectFailureAfterTargetWrite
)

$script = Join-Path (Join-Path $PSScriptRoot "05_代码与配置") "草稿卡提升器.ps1"
& $script -DraftName $DraftName -Agent $Agent -LeaseId $LeaseId -Scope $Scope -Force:$Force -TestFailPrePublishLeaseCheck:$TestFailPrePublishLeaseCheck -TestInjectFailureAfterTargetWrite:$TestInjectFailureAfterTargetWrite
[CmdletBinding()]
param(
    [int]$RetentionCount = 15,
    [string]$TargetDir = ""
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.IO.Compression.FileSystem

$vaultRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($TargetDir)) {
    $workspaceRoot = Split-Path -Parent (Split-Path -Parent $vaultRoot)
    $TargetDir = Join-Path $workspaceRoot "_rollback_backups\obsidian-vault-snapshots"
}

if (-not (Test-Path -LiteralPath $TargetDir -PathType Container)) {
    [void][System.IO.Directory]::CreateDirectory($TargetDir)
}

$nowUtc = [System.DateTime]::UtcNow
$timestamp = $nowUtc.ToString("yyyyMMdd-HHmmss")
$zipFileName = "vault-snapshot-$timestamp.zip"
$zipFilePath = Join-Path $TargetDir $zipFileName

$stagingRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("vault-backup-stage-" + [System.Guid]::NewGuid().ToString("N"))
[void][System.IO.Directory]::CreateDirectory($stagingRoot)

try {
    $includeFolders = @(
        "01_收件箱",
        "02_知识卡片",
        "03_项目索引",
        "04_执行记录",
        "07_问题与踩坑",
        "08_复盘与沉淀",
        "09_模板",
        "raw"
    )

    $includeFiles = @(
        "00_知识库总览.md",
        "AGENTS.md",
        "GEMINI.md",
        "CLAUDE.md",
        "Codex接入说明.md",
        "Claude接入说明.md",
        "Gemini接入说明.md"
    )

    $manifestEntries = New-Object System.Collections.ArrayList
    $sha256 = [System.Security.Cryptography.SHA256]::Create()

    function Get-FileSha256String {
        param([string]$FilePath)
        $stream = [System.IO.File]::OpenRead($FilePath)
        try {
            $hash = $sha256.ComputeHash($stream)
            return ([System.BitConverter]::ToString($hash)).Replace("-", "")
        }
        finally {
            $stream.Dispose()
        }
    }

    # Copy included folders
    foreach ($folder in $includeFolders) {
        $srcFolder = Join-Path $vaultRoot $folder
        if (-not (Test-Path -LiteralPath $srcFolder -PathType Container)) { continue }
        $dstFolder = Join-Path $stagingRoot $folder
        [void][System.IO.Directory]::CreateDirectory($dstFolder)

        foreach ($file in (Get-ChildItem -LiteralPath $srcFolder -Recurse -File)) {
            $relPath = $file.FullName.Substring($vaultRoot.Length + 1)
            $dstFile = Join-Path $stagingRoot $relPath
            $dstDir = Split-Path -Parent $dstFile
            if (-not (Test-Path -LiteralPath $dstDir -PathType Container)) {
                [void][System.IO.Directory]::CreateDirectory($dstDir)
            }
            [System.IO.File]::Copy($file.FullName, $dstFile, $true)

            $entry = [ordered]@{
                relativePath = $relPath
                sizeBytes = $file.Length
                sha256 = Get-FileSha256String -FilePath $file.FullName
            }
            [void]$manifestEntries.Add($entry)
        }
    }

    # Copy root markdown files
    foreach ($file in $includeFiles) {
        $srcFile = Join-Path $vaultRoot $file
        if (-not (Test-Path -LiteralPath $srcFile -PathType Leaf)) { continue }
        $dstFile = Join-Path $stagingRoot $file
        [System.IO.File]::Copy($srcFile, $dstFile, $true)

        $fileInfo = Get-Item -LiteralPath $srcFile
        $entry = [ordered]@{
            relativePath = $file
            sizeBytes = $fileInfo.Length
            sha256 = Get-FileSha256String -FilePath $srcFile
        }
        [void]$manifestEntries.Add($entry)
    }

    $manifest = [ordered]@{
        schemaVersion = 1
        snapshotTimestampUtc = $nowUtc.ToString("o")
        vaultRoot = $vaultRoot
        fileCount = $manifestEntries.Count
        files = $manifestEntries
    }

    $manifestPath = Join-Path $stagingRoot "backup-manifest.json"
    $manifestJson = $manifest | ConvertTo-Json -Depth 5
    [System.IO.File]::WriteAllText($manifestPath, $manifestJson, [System.Text.UTF8Encoding]::new($false))

    # Compress staging to zip
    if (Test-Path -LiteralPath $zipFilePath) { Remove-Item -LiteralPath $zipFilePath -Force }
    [System.IO.Compression.ZipFile]::CreateFromDirectory($stagingRoot, $zipFilePath, [System.IO.Compression.CompressionLevel]::Optimal, $false)

    # Verify zip integrity
    $zipArchive = [System.IO.Compression.ZipFile]::OpenRead($zipFilePath)
    $verifiedCount = $zipArchive.Entries.Count
    $zipArchive.Dispose()

    $zipFileHash = Get-FileSha256String -FilePath $zipFilePath
    $zipSize = (Get-Item -LiteralPath $zipFilePath).Length

    # Prune older backups
    $allBackups = @(Get-ChildItem -LiteralPath $TargetDir -Filter "vault-snapshot-*.zip" | Sort-Object CreationTimeUtc -Descending)
    if ($allBackups.Count -gt $RetentionCount) {
        for ($i = $RetentionCount; $i -lt $allBackups.Count; $i++) {
            Remove-Item -LiteralPath $allBackups[$i].FullName -Force -ErrorAction SilentlyContinue
        }
    }
    $retainedBackups = @(Get-ChildItem -LiteralPath $TargetDir -Filter "vault-snapshot-*.zip")

    $result = [ordered]@{
        ok = $true
        timestamp = $nowUtc.ToString("o")
        zipPath = $zipFilePath
        zipSizeBytes = $zipSize
        zipSha256 = $zipFileHash
        fileCount = $manifestEntries.Count
        verifiedArchiveEntries = $verifiedCount
        retainedSnapshotsCount = $retainedBackups.Count
    }
    return ($result | ConvertTo-Json)
}
finally {
    if (Test-Path -LiteralPath $stagingRoot) {
        Remove-Item -LiteralPath $stagingRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
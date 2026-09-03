@echo off
set "VAULT_DIR=%~dp0"
echo [Obsidian Knowledge Base Snapshot Backup]
echo Backing up private notes, cards, and execution records...
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%VAULT_DIR%backup-obsidian-vault.ps1" %*
if errorlevel 1 (
  echo.
  echo [ERROR] Backup failed.
  if "%~1"=="" pause
  exit /b 1
) else (
  echo.
  echo [SUCCESS] Vault snapshot created successfully.
  if "%~1"=="" pause
  exit /b 0
)

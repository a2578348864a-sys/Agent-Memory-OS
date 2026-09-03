@echo off
set "VAULT_DIR=%~dp0"
echo [Obsidian Knowledge Base Write Lease Reset]
echo Resetting expired or locked write leases to idle baseline...
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%VAULT_DIR%reset-obsidian-lease.ps1" %*
if errorlevel 1 (
  echo.
  echo [ERROR] Lease reset failed.
  if "%~1"=="" pause
) else (
  echo.
  echo [SUCCESS] Lease is now clean and idle. All agents unlocked.
  if "%~1"=="" pause
)

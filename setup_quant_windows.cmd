@echo off
setlocal
cd /d "%~dp0"
python -c "import sys; assert sys.version_info >= (3, 11)" >nul 2>&1
if errorlevel 1 (
  echo Install Python 3.11 or newer from python.org and add it to PATH first.
  pause
  exit /b 1
)
python -m venv quant_core\.venv
if errorlevel 1 goto failed
quant_core\.venv\Scripts\python.exe -m pip install -e quant_core
if errorlevel 1 goto failed
echo Optional quant core is ready. Restart SyncNote Community.
pause
exit /b 0
:failed
echo Setup failed. Read the error above.
pause
exit /b 1

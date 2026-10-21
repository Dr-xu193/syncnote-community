@echo off
setlocal
cd /d "%~dp0"
set "SYNCNOTE_FLUTTER="
for /f "delims=" %%F in ('where flutter.bat 2^>nul') do if not defined SYNCNOTE_FLUTTER set "SYNCNOTE_FLUTTER=%%F"
if not defined SYNCNOTE_FLUTTER if exist "D:\dev\flutter\bin\flutter.bat" set "SYNCNOTE_FLUTTER=D:\dev\flutter\bin\flutter.bat"
if not defined SYNCNOTE_FLUTTER (
  echo Flutter was not found. Add Flutter's bin folder to PATH.
  pause
  exit /b 1
)
call "%SYNCNOTE_FLUTTER%" build apk --release
if errorlevel 1 (
  echo BUILD FAILED. Read the error above.
  pause
  exit /b 1
)
echo BUILD SUCCEEDED.
echo APK: %~dp0build\app\outputs\flutter-apk\app-release.apk
start "" explorer.exe "%~dp0build\app\outputs\flutter-apk"
pause

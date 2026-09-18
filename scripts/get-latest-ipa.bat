@echo off
setlocal enabledelayedexpansion

rem Fetches the newest installable build from CI and files it under its build
rem number, so what is on the phone can always be traced back to a run.
rem
rem Usage:  get-latest-ipa.bat [-install] [-local]
rem         -install  also put it on the attached device
rem         -local    do not ask GitHub; use the newest build already here
rem
rem The IPA is ad-hoc signed for the devices in the provisioning profile, so it
rem installs as it is. Nothing here re-signs anything.

set REPO=rweijnen/fitcamxtra
set WORKFLOW_FILE=ios-build.yml
set ARTIFACT=FitCamXtra-adhoc-ipa
set DEST=%~dp0..\builds
set PMD3=%LOCALAPPDATA%\fitcamxtra-tools\pmd3\Scripts\pymobiledevice3.exe
set IMAZING=C:\Program Files\DigiDNA\iMazing\iMazing-CLI.exe

set WANT_INSTALL=
set LOCAL_ONLY=
for %%A in (%*) do (
  if /i "%%~A"=="-install" set WANT_INSTALL=1
  if /i "%%~A"=="-local" set LOCAL_ONLY=1
)

if not exist "%DEST%" mkdir "%DEST%"
if defined LOCAL_ONLY goto :use_local

where gh >nul 2>&1
if errorlevel 1 (
  echo The GitHub CLI is not on PATH. Install it from https://cli.github.com
  echo and run: gh auth login
  exit /b 1
)

rem One call, answered from gh's own cache when it was asked recently, so
rem running this twice over costs nothing. --jq rather than --template: a Go
rem template renders the run id as a float and no download can use that.
set ATTEMPT=0

:lookup
set /a ATTEMPT+=1
set RUNID=
set BUILD=
set FIELD=0
for /f "usebackq delims=" %%V in (`gh api "repos/%REPO%/actions/workflows/%WORKFLOW_FILE%/runs?branch=main&status=success&per_page=1" --cache 2m --jq ".workflow_runs[0].id, .workflow_runs[0].run_number" 2^>nul`) do (
  set /a FIELD+=1
  if !FIELD!==1 set RUNID=%%V
  if !FIELD!==2 set BUILD=%%V
)

if not "%RUNID%"=="" if not "%BUILD%"=="" goto :found

if !ATTEMPT! lss 3 (
  echo   GitHub did not answer; trying again ^(!ATTEMPT! of 3^)...
  %SystemRoot%\System32\timeout.exe /t 3 /nobreak >nul
  goto :lookup
)

echo Could not reach GitHub after 3 attempts.
echo The newest build already here can be used with: %~nx0 -local
exit /b 1

:found
set TARGET=%DEST%\FitCamXtra-b%BUILD%.ipa
if exist "%TARGET%" (
  echo Build %BUILD% is the latest, and is already here.
  goto :maybe_install
)

set STAGING=%TEMP%\fitcamxtra-ipa-%RANDOM%
echo Downloading build %BUILD% from run %RUNID%...
gh run download %RUNID% -R %REPO% -n %ARTIFACT% -D "%STAGING%"
if errorlevel 1 (
  echo   The download did not complete; trying once more...
  if exist "%STAGING%" rmdir /s /q "%STAGING%"
  %SystemRoot%\System32\timeout.exe /t 3 /nobreak >nul
  gh run download %RUNID% -R %REPO% -n %ARTIFACT% -D "%STAGING%"
)
if errorlevel 1 (
  echo That run has no %ARTIFACT%. It may predate the ad-hoc lane, or have been
  echo built without the signing secrets.
  if exist "%STAGING%" rmdir /s /q "%STAGING%"
  exit /b 1
)

move /y "%STAGING%\FitCamXtra.ipa" "%TARGET%" >nul
if errorlevel 1 (
  echo The artifact did not contain FitCamXtra.ipa. It held:
  dir /b "%STAGING%"
  rmdir /s /q "%STAGING%"
  exit /b 1
)
rmdir /s /q "%STAGING%"
echo Saved %TARGET%
goto :maybe_install

:use_local
set TARGET=
for /f "delims=" %%F in ('dir /b /o-d "%DEST%\FitCamXtra-b*.ipa" 2^>nul') do (
  if not defined TARGET set TARGET=%DEST%\%%F
)
if not defined TARGET (
  echo Nothing in %DEST% yet, so there is nothing to use offline.
  exit /b 1
)
echo Using %TARGET%

:maybe_install
if not defined WANT_INSTALL (
  echo.
  echo To put it on the phone: %~nx0 -install
  exit /b 0
)

rem pymobiledevice3 first: same protocols as libimobiledevice, no licence, and
rem it keeps up with current iOS. What it connects to is already running,
rem because Apple's own device service provides the usbmux endpoint.
if exist "%PMD3%" goto :install_pmd3
where pymobiledevice3 >nul 2>&1
if not errorlevel 1 (
  set PMD3=pymobiledevice3
  goto :install_pmd3
)
goto :try_imazing

:install_pmd3
echo Installing %TARGET% with pymobiledevice3...
"%PMD3%" apps install "%TARGET%"
if errorlevel 1 goto :try_imazing
echo Done.
exit /b 0

:try_imazing
if not exist "%IMAZING%" goto :try_ideviceinstaller
echo Trying iMazing...
"%IMAZING%" --device-install-app --udid any --source-path "%TARGET%" > "%TEMP%\imazing-install.log" 2>&1
findstr /i /c:"not activated" "%TEMP%\imazing-install.log" >nul
if not errorlevel 1 (
  echo   iMazing's CLI is installed but not licensed, so it did nothing. It
  echo   ends after a second reporting the command started and stopped, which
  echo   reads like success.
  goto :try_ideviceinstaller
)
findstr /i /c:"Command succeeded" "%TEMP%\imazing-install.log" >nul
if not errorlevel 1 (
  echo Done.
  exit /b 0
)
type "%TEMP%\imazing-install.log"

:try_ideviceinstaller
where ideviceinstaller >nul 2>&1
if errorlevel 1 (
  echo.
  echo Nothing here could install it. The file is at:
  echo   %TARGET%
  echo pymobiledevice3 is the easiest fix:
  echo   python -m venv "%%LOCALAPPDATA%%\fitcamxtra-tools\pmd3"
  echo   "%%LOCALAPPDATA%%\fitcamxtra-tools\pmd3\Scripts\pip" install pymobiledevice3
  exit /b 1
)

echo Installing with ideviceinstaller...
ideviceinstaller -i "%TARGET%"
if errorlevel 1 (
  echo The install failed. Check the phone is plugged in, unlocked and trusting
  echo this computer.
  exit /b 1
)
echo Done.
exit /b 0

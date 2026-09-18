@echo off
setlocal enabledelayedexpansion

rem Fetches the newest installable build from CI and files it under its build
rem number, so what is on the phone can always be traced back to a run.
rem
rem Usage:  get-latest-ipa.bat [-install]
rem         -install  also pushes it to the attached device with
rem                   ideviceinstaller, when that is on PATH.
rem
rem The IPA is ad-hoc signed for the devices in the provisioning profile, so it
rem installs as it is. Nothing here re-signs anything.

set REPO=rweijnen/fitcamxtra
set WORKFLOW=iOS build
set ARTIFACT=FitCamXtra-adhoc-ipa
set DEST=%~dp0..\builds

where gh >nul 2>&1
if errorlevel 1 (
  echo The GitHub CLI is not on PATH. Install it from https://cli.github.com and run: gh auth login
  exit /b 1
)

echo Looking for the newest successful build of "%WORKFLOW%"...

set RUNID=
for /f "usebackq delims=" %%R in (`gh run list -R %REPO% --workflow "%WORKFLOW%" --branch main --status success --limit 1 --json databaseId --jq ".[0].databaseId"`) do set RUNID=%%R

set BUILD=
for /f "usebackq delims=" %%N in (`gh run list -R %REPO% --workflow "%WORKFLOW%" --branch main --status success --limit 1 --json number --jq ".[0].number"`) do set BUILD=%%N

if "%RUNID%"=="" (
  echo No successful run found. Check: gh run list -R %REPO%
  exit /b 1
)

set TARGET=%DEST%\FitCamXtra-b%BUILD%.ipa
if not exist "%DEST%" mkdir "%DEST%"

if exist "%TARGET%" (
  echo Build %BUILD% is already here: %TARGET%
  goto :installed_check
)

set STAGING=%TEMP%\fitcamxtra-ipa-%RANDOM%
echo Downloading build %BUILD% from run %RUNID%...
gh run download %RUNID% -R %REPO% -n %ARTIFACT% -D "%STAGING%"
if errorlevel 1 (
  echo That run has no %ARTIFACT%. It may predate the ad-hoc lane, or it may be
  echo a build made without the signing secrets.
  if exist "%STAGING%" rmdir /s /q "%STAGING%"
  exit /b 1
)

move /y "%STAGING%\FitCamXtra.ipa" "%TARGET%" >nul
if errorlevel 1 (
  echo The artifact did not contain FitCamXtra.ipa.
  dir /b "%STAGING%"
  rmdir /s /q "%STAGING%"
  exit /b 1
)
rmdir /s /q "%STAGING%"
echo Saved %TARGET%

:installed_check
if /i not "%~1"=="-install" (
  echo.
  echo To put it on the phone: get-latest-ipa.bat -install
  echo Or drag the file onto iMazing or Sideloadly.
  exit /b 0
)

where ideviceinstaller >nul 2>&1
if errorlevel 1 (
  echo ideviceinstaller is not on PATH, so nothing was installed.
  echo It comes with libimobiledevice; iMazing and Sideloadly will also take
  echo the file above.
  exit /b 1
)

echo Installing build %BUILD% on the attached device...
ideviceinstaller -i "%TARGET%"
if errorlevel 1 (
  echo The install failed. Check the phone is plugged in, unlocked, and that it
  echo trusts this computer.
  exit /b 1
)
echo Done.
exit /b 0

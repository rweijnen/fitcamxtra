@echo off
setlocal enabledelayedexpansion

rem Fetches the newest installable build from CI and files it under its build
rem number, so what is on the phone can always be traced back to a run.
rem
rem Usage:  get-latest-ipa.bat [-install]
rem         -install  also pushes it to the attached device, using iMazing's
rem                   CLI when it is installed and ideviceinstaller otherwise.
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

rem Both values come from one call. Asking twice meant a network hiccup on the
rem second could leave the build number empty, and the file was then written
rem as FitCamXtra-b.ipa with nothing to say which build it was.
rem
rem Retried, because a TLS timeout reaching api.github.com is common enough
rem here to be worth riding out rather than reporting as "no build found".
set ATTEMPT=0

:lookup
set /a ATTEMPT+=1
set RUNID=
set BUILD=
for /f "usebackq tokens=1,2" %%N in (`gh run list -R %REPO% --workflow "%WORKFLOW%" --branch main --status success --limit 1 --json databaseId^,number --template "{{range .}}{{.number}} {{.databaseId}}{{end}}" 2^>nul`) do (
  set BUILD=%%N
  set RUNID=%%O
)

if not "%RUNID%"=="" if not "%BUILD%"=="" goto :found

if !ATTEMPT! lss 3 (
  echo   GitHub did not answer; trying again ^(!ATTEMPT! of 3^)...
  timeout /t 3 /nobreak >nul
  goto :lookup
)

echo Could not reach GitHub after 3 attempts, or no successful run was found.
echo Check with: gh run list -R %REPO%
exit /b 1

:found

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
  echo   The download did not complete; trying once more...
  if exist "%STAGING%" rmdir /s /q "%STAGING%"
  timeout /t 3 /nobreak >nul
  gh run download %RUNID% -R %REPO% -n %ARTIFACT% -D "%STAGING%"
)
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
  echo Or drag the file onto iMazing.
  exit /b 0
)

set IMAZING=C:\Program Files\DigiDNA\iMazing\iMazing-CLI.exe

if exist "%IMAZING%" (
  echo Installing build %BUILD% with iMazing...
  "%IMAZING%" --device-install-app --udid any --source-path "%TARGET%"
  if errorlevel 1 goto :install_failed
  echo Done.
  exit /b 0
)

where ideviceinstaller >nul 2>&1
if errorlevel 1 (
  echo Neither iMazing's CLI nor ideviceinstaller was found, so nothing was
  echo installed. The file above can be dragged onto iMazing instead.
  exit /b 1
)

echo Installing build %BUILD% with ideviceinstaller...
ideviceinstaller -i "%TARGET%"
if errorlevel 1 goto :install_failed
echo Done.
exit /b 0

:install_failed
echo The install failed. Check the phone is plugged in, unlocked and trusting
echo this computer. --device-list on the iMazing CLI says what it can see.
exit /b 1

#!/usr/bin/env pwsh -c
$ErrorActionPreference = 'Ignore'

taskkill /T /F /IM dotnet.exe
taskkill /T /F /IM testhost.exe
taskkill /T /F /IM iisexpress.exe
taskkill /T /F /IM iisexpresstray.exe
taskkill /T /F /IM w3wp.exe
taskkill /T /F /IM msbuild.exe
taskkill /T /F /IM vbcscompiler.exe
taskkill /T /F /IM git.exe
taskkill /T /F /IM vctip.exe
taskkill /T /F /IM chrome.exe
iisreset /restart

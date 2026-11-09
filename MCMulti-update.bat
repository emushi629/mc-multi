@echo off
rem MC Multi update tool: downloads the latest update.ps1 from the MC Multi site and runs it
powershell -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; $wc=New-Object Net.WebClient; $s=[Text.Encoding]::UTF8.GetString($wc.DownloadData('https://emushi629.github.io/mc-multi/update.ps1?t='+[DateTime]::Now.Ticks)); & ([ScriptBlock]::Create($s.TrimStart([char]0xFEFF)))"
echo.
pause

@echo off
rem iRequire: Windows ajaa taman SYSTEM-tunnuksella asennuksen lopussa,
rem ennen ensimmaista kirjautumista. Tassa vain rekisteroidaan varsinainen
rem jalkiasennus ajastetuksi tehtavaksi, jotta se jatkuu uudelleen-
rem kaynnistysten yli eika pidata tyopoydalle paasya.
if not exist "%SystemDrive%\iRequire\Logs" mkdir "%SystemDrive%\iRequire\Logs"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SystemDrive%\iRequire\PostInstall\Register-PostInstall.ps1" >> "%SystemDrive%\iRequire\Logs\setupcomplete.log" 2>&1
exit /b 0

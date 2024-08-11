@echo off
setlocal

set ORIGINAL_DIR=%CD%
set SCRIPT_DIR=%~dp0
cd /D %SCRIPT_DIR%
IF NOT EXIST Build mkdir Build

odin build Code/ -out:Build/StickONote.exe -o:none -debug

cd /D %ORIGINAL_DIR%
endlocal
exit

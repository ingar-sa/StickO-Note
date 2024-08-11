@echo off
setlocal

IF NOT EXIST Build mkdir Build

cd Build
StickONote.exe

endlocal
exit

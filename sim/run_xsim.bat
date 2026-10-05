@echo off
rem RVNE-ASYNC xsim flow (DEC-11, Vivado 2022.1).
rem   run_xsim.bat <top> [elab]
rem   <top>  top module to elaborate (e.g. rvne_top, tb_rvne_top)
rem   elab   stop after elaboration (D6.1); otherwise also run xsim
setlocal
if "%~1"=="" (
  echo usage: run_xsim.bat ^<top^> [elab]
  exit /b 2
)
set TOP=%~1
set MODE=%~2
cd /d "%~dp0"
call C:\Xilinx\Vivado\2022.1\settings64.bat >nul
if not exist work mkdir work
cd work

set EXTRA=
if exist "..\%TOP%.sv" set EXTRA=..\%TOP%.sv

call xvlog -sv -f ..\filelist.f %EXTRA% --log xvlog.log
if errorlevel 1 exit /b 1
call xelab %TOP% -debug typical -timescale 1ns/1ps -s %TOP%_snap --log xelab.log
if errorlevel 1 exit /b 1
if /i "%MODE%"=="elab" exit /b 0
call xsim %TOP%_snap -R --log xsim.log
exit /b %errorlevel%

@echo off
title ASI1 Oracle Test Environment
color 0A

echo ==========================================
echo    ASI1 ORACLE - LOCAL TEST LAUNCHER
echo ==========================================
echo.

echo [1/2] Booting up the ASI1 Oracle (Port 8001)...
start "ASI1 Oracle" cmd /k "python asi1_oracle.py"

timeout /t 3 /nobreak >nul

echo [2/2] Booting up the Dumb Buyer Bot (Port 8002)...
start "Buyer Bot" cmd /k "python test_buyer.py"

echo.
echo ==========================================
echo ✅ Test environment running!
echo Watch the two windows talk to each other.
echo ==========================================
pause

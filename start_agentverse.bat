@echo off
title SparkByte Agentverse Launcher
color 0D

echo ==========================================
echo    SPARKBYTE AGENTVERSE LAUNCHER
echo ==========================================
echo.

echo [1/2] Starting ngrok tunnel on port 8094...
:: Launch ngrok in a new minimized window
start /min cmd /c "ngrok http 8094"

:: Wait a few seconds for ngrok to establish the connection
timeout /t 3 /nobreak >nul

echo [2/2] Waking up SparkByte Python Agent...
:: Launch the Python agent in a new visible window
start "SparkByte Agent" cmd /k "python sparkbyte_agent.py"

echo.
echo ==========================================
echo ✅ ALL SYSTEMS GO!
echo.
echo IMPORTANT: If you are using the free tier of ngrok, your public URL 
echo might change every time you restart this script. If it does, you will 
echo need to update your Endpoint URL in the Agentverse dashboard!
echo ==========================================
pause

@echo off
rem Step 8: start the OpenAI-compatible server on the two-GPU engine, under the memory guard.
rem Edit config\xestrata-mixed.json first (copy it from config\xestrata-mixed.example.json).
call "%~dp0_env.cmd" || exit /b 1
if not exist "%~dp0..\config\xestrata-mixed.json" ( echo copy config\xestrata-mixed.example.json to config\xestrata-mixed.json and edit it & exit /b 1 )
if not exist "%XM_ROOT%\logs" mkdir "%XM_ROOT%\logs"
cd /d "%XM_ROOT%\xestrata" || exit /b 1
node "%~dp0guard-mem.cjs" 6 0.4 20 python -m serve.server --engine strata --config "%~dp0..\config\xestrata-mixed.json" --port 8097 >> "%XM_ROOT%\logs\serve.log" 2>&1
exit /b %ERRORLEVEL%

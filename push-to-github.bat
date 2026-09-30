@echo off
setlocal
cd /d "%~dp0"

where git >nul 2>nul
if errorlevel 1 (
  echo [ERROR] git not found in PATH. Install Git for Windows first.
  pause
  exit /b 1
)

for /f "delims=" %%i in ('git config user.name 2^>nul') do set GNAME=%%i
for /f "delims=" %%i in ('git config user.email 2^>nul') do set GMAIL=%%i
if "%GNAME%"=="" set /p GNAME=Commit author name, your GitHub username: 
if "%GMAIL%"=="" set /p GMAIL=Commit author email, the email of that GitHub account: 
if "%GNAME%"=="" (
  echo [ERROR] name is empty.
  pause
  exit /b 1
)
if "%GMAIL%"=="" (
  echo [ERROR] email is empty.
  pause
  exit /b 1
)

rem Identity is passed to this one commit through env vars below.
rem Nothing is written into your git config files.
set GIT_AUTHOR_NAME=%GNAME%
set GIT_AUTHOR_EMAIL=%GMAIL%
set GIT_COMMITTER_NAME=%GNAME%
set GIT_COMMITTER_EMAIL=%GMAIL%

set /p REPO=Paste your GitHub repo URL ^(https://github.com/user/repo.git^): 
if "%REPO%"=="" (
  echo [ERROR] empty URL.
  pause
  exit /b 1
)

if not exist ".git" (
  git init -q
  git branch -m main
  git add -A
  git commit -q -m "hongguo speed badge"
) else (
  git add -A
  git commit -q -m "update hongguo speed badge" 2>nul
)

git remote add origin "%REPO%" >nul 2>nul
git remote set-url origin "%REPO%"
git push -u origin main
if errorlevel 1 (
  echo.
  echo [ERROR] push failed. Check the repo URL and your GitHub login.
  pause
  exit /b 1
)

echo.
echo Pushed. Now open the repo page, click Actions, wait for the green check,
echo then download the artifact named hongguospeed-dylib
pause

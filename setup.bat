@echo off
echo Setting up ERC-4337 Smart Contract Wallet...

forge --version >nul 2>&1
if %errorlevel% neq 0 (
    echo Foundry is not installed. Install it first:
    echo    Run in Git Bash: curl -L https://foundry.paradigm.xyz ^| bash
    echo    Then: foundryup
    exit /b 1
)

REM Dependencies are vendored in lib\ - no forge install needed
forge build
if %errorlevel% neq 0 exit /b 1
forge test
if %errorlevel% neq 0 exit /b 1

if not exist .env (
    copy env.example .env
    echo Created .env from env.example - fill in your values before deploying.
)

echo Done. See README.md for deployment instructions.

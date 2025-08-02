@echo off
echo 🔐 Setting up ERC-4337 Smart Contract Wallet...

REM Check if Foundry is installed
forge --version >nul 2>&1
if %errorlevel% neq 0 (
    echo ❌ Foundry is not installed. Please install it first:
    echo    curl -L https://foundry.paradigm.xyz ^| bash
    echo    foundryup
    pause
    exit /b 1
)

echo ✅ Foundry is installed

REM Install dependencies
echo 📦 Installing dependencies...
forge install OpenZeppelin/openzeppelin-contracts
forge install foundry-rs/forge-std

REM Build contracts
echo 🔨 Building contracts...
forge build

REM Create .env file if it doesn't exist
if not exist .env (
    echo 📝 Creating .env file...
    (
        echo # Environment variables for ERC-4337 Smart Wallet
        echo PRIVATE_KEY=your_private_key_here
        echo GOERLI_RPC_URL=your_goerli_rpc_url
        echo SEPOLIA_RPC_URL=your_sepolia_rpc_url
        echo ETHERSCAN_API_KEY=your_etherscan_api_key
    ) > .env
    echo ⚠️  Please update .env with your actual values
)

echo ✅ Setup complete!
echo.
echo Next steps:
echo 1. Update .env with your private key and RPC URLs
echo 2. Run tests: forge test
echo 3. Deploy contracts: forge script scripts/Deploy.s.sol --rpc-url ^<your-rpc^> --broadcast
echo 4. Open ui/index.html in your browser to test the frontend
pause 
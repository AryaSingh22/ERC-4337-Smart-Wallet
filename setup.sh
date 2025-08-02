#!/bin/bash

echo "🔐 Setting up ERC-4337 Smart Contract Wallet..."

# Check if Foundry is installed
if ! command -v forge &> /dev/null; then
    echo "❌ Foundry is not installed. Please install it first:"
    echo "   curl -L https://foundry.paradigm.xyz | bash"
    echo "   foundryup"
    exit 1
fi

echo "✅ Foundry is installed"

# Install dependencies
echo "📦 Installing dependencies..."
forge install OpenZeppelin/openzeppelin-contracts
forge install foundry-rs/forge-std

# Build contracts
echo "🔨 Building contracts..."
forge build

# Create .env file if it doesn't exist
if [ ! -f .env ]; then
    echo "📝 Creating .env file..."
    cat > .env << EOF
# Environment variables for ERC-4337 Smart Wallet
PRIVATE_KEY=your_private_key_here
GOERLI_RPC_URL=your_goerli_rpc_url
SEPOLIA_RPC_URL=your_sepolia_rpc_url
ETHERSCAN_API_KEY=your_etherscan_api_key
EOF
    echo "⚠️  Please update .env with your actual values"
fi

echo "✅ Setup complete!"
echo ""
echo "Next steps:"
echo "1. Update .env with your private key and RPC URLs"
echo "2. Run tests: forge test"
echo "3. Deploy contracts: forge script scripts/Deploy.s.sol --rpc-url <your-rpc> --broadcast"
echo "4. Open ui/index.html in your browser to test the frontend" 
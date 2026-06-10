#!/bin/bash
set -e

echo "Setting up ERC-4337 Smart Contract Wallet..."

if ! command -v forge &> /dev/null; then
    echo "Foundry is not installed. Install it first:"
    echo "   curl -L https://foundry.paradigm.xyz | bash"
    echo "   foundryup"
    exit 1
fi

# Dependencies are vendored in lib/ - no forge install needed
forge build
forge test

if [ ! -f .env ]; then
    cp env.example .env
    echo "Created .env from env.example - fill in your values before deploying."
fi

echo "Done. See README.md for deployment instructions."

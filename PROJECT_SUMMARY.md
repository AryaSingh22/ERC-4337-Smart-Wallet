# ERC-4337 Smart Contract Wallet - Project Summary

## What this is

An ERC-4337 **EntryPoint v0.7** smart contract wallet built on the official
eth-infinitism account-abstraction contracts. See [README.md](README.md) for
full documentation and [SECURITY.md](SECURITY.md) for the security model.

## Capabilities

- **Counterfactual deployment**: `SmartWalletFactory` (CREATE2 + ERC1967 proxy);
  wallet addresses are known and fundable before deployment, and the wallet can
  deploy itself via `initCode` on its first UserOperation
- **Owner + session key validation**: session keys carry a validity window,
  cumulative spending limit, and optional pinned target; all keys are revoked
  automatically on any ownership change
- **Social recovery**: guardian threshold voting with execution timelock,
  overall timeout, owner cancellation, and gasless EIP-712 votes
- **Gasless transactions**: official `VerifyingPaymaster` (off-chain signed
  sponsorship)
- **ERC-1271** contract signatures, **ERC-721/1155** receiver callbacks,
  **UUPS** upgradeability

## Verification status

- 67 Foundry tests: 55 unit/fuzz, 8 end-to-end through the real EntryPoint
  (initCode deployment, sponsored ops, session key ops), 4 invariants under a
  randomized action handler
- CI: build + tests + coverage + Slither on every push
- **Not audited** — see the pre-deployment checklist in SECURITY.md

## Layout

```
src/SmartWallet.sol          # the account
src/SmartWalletFactory.sol   # CREATE2 factory
script/Deploy.s.sol          # factory + paymaster deployment
test/                        # unit, integration, invariant suites
ui/index.html                # static viem demo UI
lib/                         # vendored: account-abstraction v0.7.0, OZ v5.3.0, forge-std v1.9.7
```

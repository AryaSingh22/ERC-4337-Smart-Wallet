// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Script, console} from "forge-std/Script.sol";
import {EntryPoint} from "account-abstraction/core/EntryPoint.sol";
import {IEntryPoint} from "account-abstraction/interfaces/IEntryPoint.sol";
import {VerifyingPaymaster} from "account-abstraction/samples/VerifyingPaymaster.sol";

import {SmartWallet} from "../src/SmartWallet.sol";
import {SmartWalletFactory} from "../src/SmartWalletFactory.sol";

/**
 * @title Deploy
 * @dev Deploys the SmartWalletFactory and VerifyingPaymaster against the
 * canonical EntryPoint v0.7. On local dev chains without the EntryPoint,
 * a fresh EntryPoint instance is deployed first.
 *
 * Environment:
 *   PRIVATE_KEY        - deployer key (required)
 *   PAYMASTER_SIGNER   - off-chain sponsorship signer (optional, defaults to deployer)
 *   CREATE_DEMO_WALLET - set to "true" to create a demo wallet via the factory
 */
contract Deploy is Script {
    // Canonical EntryPoint v0.7 address (same on all networks)
    address constant ENTRYPOINT_V07 = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;

    uint256 constant GUARDIAN_THRESHOLD = 2;
    uint256 constant RECOVERY_TIMEOUT = 3 days;
    uint256 constant RECOVERY_EXECUTION_DELAY = 1 days;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        address paymasterSigner = vm.envOr("PAYMASTER_SIGNER", deployer);

        vm.startBroadcast(deployerPrivateKey);

        // Resolve or deploy the EntryPoint
        IEntryPoint entryPoint;
        if (ENTRYPOINT_V07.code.length > 0) {
            entryPoint = IEntryPoint(ENTRYPOINT_V07);
            console.log("Using canonical EntryPoint v0.7:", ENTRYPOINT_V07);
        } else {
            entryPoint = new EntryPoint();
            console.log("Deployed local EntryPoint:", address(entryPoint));
        }

        // Deploy the wallet factory (deploys the implementation internally)
        SmartWalletFactory factory = new SmartWalletFactory(entryPoint);
        console.log("SmartWalletFactory:", address(factory));
        console.log("SmartWallet implementation:", address(factory.accountImplementation()));

        // Deploy the verifying paymaster
        VerifyingPaymaster paymaster = new VerifyingPaymaster(entryPoint, paymasterSigner);
        console.log("VerifyingPaymaster:", address(paymaster));
        console.log("Paymaster signer:", paymasterSigner);

        // Fund the paymaster's EntryPoint deposit if the deployer can afford it
        if (deployer.balance >= 1 ether) {
            paymaster.deposit{value: 0.5 ether}();
            console.log("Paymaster EntryPoint deposit: 0.5 ETH");
        }

        // Optionally create a demo wallet
        if (vm.envOr("CREATE_DEMO_WALLET", false)) {
            address[] memory guardians = new address[](2);
            guardians[0] = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8; // replace with real guardians
            guardians[1] = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC;

            SmartWallet wallet = factory.createAccount(
                deployer, guardians, GUARDIAN_THRESHOLD, RECOVERY_TIMEOUT, RECOVERY_EXECUTION_DELAY, 0
            );
            console.log("Demo SmartWallet:", address(wallet));
        }

        vm.stopBroadcast();

        console.log("\n=== Deployment Summary ===");
        console.log("Network:", block.chainid);
        console.log("EntryPoint:", address(entryPoint));
        console.log("Factory:", address(factory));
        console.log("Paymaster:", address(paymaster));
        console.log("Deployer:", deployer);
    }
}

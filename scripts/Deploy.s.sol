// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import "../src/SmartWallet.sol";
import "../src/Paymaster.sol";
import "../src/interfaces/IEntryPoint.sol";

/**
 * @title Deploy
 * @dev Deployment script for SmartWallet and Paymaster contracts
 */
contract Deploy is Script {
    // EntryPoint addresses for different networks
    address constant ENTRYPOINT_GOERLI = 0x5FF137D4b0FDCD49DcA30c7CF57E578a026d2789;
    address constant ENTRYPOINT_SEPOLIA = 0x5FF137D4b0FDCD49DcA30c7CF57E578a026d2789;
    address constant ENTRYPOINT_MAINNET = 0x5FF137D4b0FDCD49DcA30c7CF57E578a026d2789;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        
        // Get network-specific entry point
        address entryPointAddress = getEntryPointAddress();
        
        vm.startBroadcast(deployerPrivateKey);
        
        // Deploy Paymaster
        Paymaster paymaster = new Paymaster(IEntryPoint(entryPointAddress));
        console.log("Paymaster deployed at:", address(paymaster));
        
        // Setup guardians (example addresses - replace with real ones)
        address[] memory guardians = new address[](3);
        guardians[0] = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8; // Example guardian 1
        guardians[1] = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC; // Example guardian 2
        guardians[2] = 0x90F79bf6EB2c4f870365E785982E1f101E93b906; // Example guardian 3
        
        // Deploy SmartWallet
        SmartWallet wallet = new SmartWallet(IEntryPoint(entryPointAddress), deployer, guardians);
        console.log("SmartWallet deployed at:", address(wallet));
        
        // Add wallet as verified user to paymaster
        paymaster.addVerifiedUser(address(wallet));
        console.log("Wallet added as verified user to paymaster");
        
        // Fund the paymaster (optional)
        paymaster.deposit{value: 1 ether}();
        console.log("Paymaster funded with 1 ETH");
        
        vm.stopBroadcast();
        
        console.log("\n=== Deployment Summary ===");
        console.log("Network:", block.chainid);
        console.log("EntryPoint:", entryPointAddress);
        console.log("Paymaster:", address(paymaster));
        console.log("SmartWallet:", address(wallet));
        console.log("Owner:", deployer);
        console.log("Guardians:", guardians[0], guardians[1], guardians[2]);
    }
    
    function getEntryPointAddress() internal view returns (address) {
        uint256 chainId = block.chainid;
        
        if (chainId == 1) { // Mainnet
            return ENTRYPOINT_MAINNET;
        } else if (chainId == 5) { // Goerli
            return ENTRYPOINT_GOERLI;
        } else if (chainId == 11155111) { // Sepolia
            return ENTRYPOINT_SEPOLIA;
        } else {
            // For local testing, use a mock address
            return address(0x5FF137D4b0FDCD49DcA30c7CF57E578a026d2789);
        }
    }
} 
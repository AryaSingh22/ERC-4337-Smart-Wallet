// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title IEntryPoint
 * @dev Interface for ERC-4337 EntryPoint contract
 */
interface IEntryPoint {
    /**
     * @dev UserOperation struct as defined in ERC-4337
     */
    struct UserOperation {
        address sender;
        uint256 nonce;
        bytes initCode;
        bytes callData;
        uint256 callGasLimit;
        uint256 verificationGasLimit;
        uint256 preVerificationGas;
        uint256 maxFeePerGas;
        uint256 maxPriorityFeePerGas;
        bytes paymasterAndData;
        bytes signature;
    }

    /**
     * @dev Simulates a UserOperation
     * @param userOp The UserOperation to simulate
     * @param offChainSigCheck Whether to check signature off-chain
     * @param target The target address for the operation
     * @param targetCallData The calldata for the target
     */
    function simulateUserOp(
        UserOperation calldata userOp,
        bool offChainSigCheck,
        address target,
        bytes calldata targetCallData
    ) external;

    /**
     * @dev Handles UserOperations
     * @param ops Array of UserOperations to handle
     * @param beneficiary The address to receive gas refunds
     */
    function handleOps(UserOperation[] calldata ops, address payable beneficiary) external;

    /**
     * @dev Gets the nonce for a sender
     * @param sender The sender address
     * @param key The nonce key
     * @return The current nonce
     */
    function getNonce(address sender, uint192 key) external view returns (uint256);
} 
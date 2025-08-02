// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./IEntryPoint.sol";

/**
 * @title IAccount
 * @dev Interface for ERC-4337 account contracts
 */
interface IAccount {
    /**
     * @dev Validates a UserOperation
     * @param userOp The UserOperation to validate
     * @param userOpHash The hash of the UserOperation
     * @param missingAccountFunds The amount of funds missing for the account
     * @return validationData Validation data for the operation
     */
    function validateUserOp(
        UserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 missingAccountFunds
    ) external returns (uint256 validationData);
} 
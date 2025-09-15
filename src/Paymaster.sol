// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./interfaces/IEntryPoint.sol";

/**
 * @title Paymaster
 * @dev Dummy paymaster that sponsors gas for verified users
 * This is a simplified implementation for demonstration purposes
 */
contract Paymaster {     
    // Events
    event GasSponsored(address indexed user, uint256 gasUsed, uint256 gasCost);
    event PaymasterDeposited(address indexed depositor, uint256 amount);

    // State variables
    IEntryPoint public immutable entryPoint;
    mapping(address => bool) public verifiedUsers;
    mapping(address => uint256) public userGasLimits;
    uint256 public constant DEFAULT_GAS_LIMIT = 100000; // 100k gas limit per user

    // Modifiers
    modifier onlyEntryPoint() {
        require(msg.sender == address(entryPoint), "Paymaster: caller is not the entry point");
        _;
    }

    constructor(IEntryPoint _entryPoint) {
        require(address(_entryPoint) != address(0), "Paymaster: invalid entry point");
        entryPoint = _entryPoint;
    }

    /**
     * @dev Validates a paymaster operation
     * @param userOp The UserOperation to validate
     * @param userOpHash The hash of the UserOperation
     * @param maxCost The maximum cost for this operation
     * @return context Context data for postOp
     * @return validationData Validation data
     */
    function validatePaymasterUserOp(
        UserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 maxCost
    ) external view returns (bytes memory context, uint256 validationData) {
        // Check if user is verified
        require(verifiedUsers[userOp.sender], "Paymaster: user not verified");
        
        // Check gas limit
        require(userOp.callGasLimit <= userGasLimits[userOp.sender], "Paymaster: gas limit exceeded");
        
        // Return context with user address and maxCost
        context = abi.encode(userOp.sender, maxCost);
        validationData = 0; // Validation successful
    }

    /**
     * @dev Post-operation callback
     * @param context Context data from validatePaymasterUserOp
     * @param actualGasCost The actual gas cost of the operation
     */
    function postOp(PostOpMode mode, bytes calldata context, uint256 actualGasCost) external onlyEntryPoint {
        (address user, uint256 maxCost) = abi.decode(context, (address, uint256));
        
        require(actualGasCost <= maxCost, "Paymaster: actual cost exceeds max cost");
        
        emit GasSponsored(user, actualGasCost, maxCost);
    }

    /**
     * @dev Adds a verified user
     * @param user The user address to verify
     */
    function addVerifiedUser(address user) external {
        require(user != address(0), "Paymaster: invalid user");
        require(!verifiedUsers[user], "Paymaster: user already verified");
        
        verifiedUsers[user] = true;
        userGasLimits[user] = DEFAULT_GAS_LIMIT;
    }

    /**
     * @dev Removes a verified user
     * @param user The user address to remove
     */
    function removeVerifiedUser(address user) external {
        require(verifiedUsers[user], "Paymaster: user not verified");
        
        verifiedUsers[user] = false;
        userGasLimits[user] = 0;
    }

    /**
     * @dev Sets gas limit for a user
     * @param user The user address
     * @param gasLimit The new gas limit
     */
    function setUserGasLimit(address user, uint256 gasLimit) external {
        require(verifiedUsers[user], "Paymaster: user not verified");
        require(gasLimit > 0, "Paymaster: invalid gas limit");
        
        userGasLimits[user] = gasLimit;
    }

    /**
     * @dev Deposits funds to the paymaster
     */
    function deposit() external payable {
        require(msg.value > 0, "Paymaster: deposit amount must be greater than 0");
        emit PaymasterDeposited(msg.sender, msg.value);
    }

    /**
     * @dev Withdraws funds from the paymaster
     * @param amount The amount to withdraw
     * @param target The target address to send funds to
     */
    function withdrawTo(address payable target, uint256 amount) external {
        require(target != address(0), "Paymaster: invalid target");
        require(amount <= address(this).balance, "Paymaster: insufficient balance");
        
        (bool success, ) = target.call{value: amount}("");
        require(success, "Paymaster: withdrawal failed");
    }

    /**
     * @dev Gets the balance of the paymaster
     * @return The current balance
     */
    function getBalance() external view returns (uint256) {
        return address(this).balance;
    }

    /**
     * @dev Checks if a user is verified
     * @param user The user address to check
     * @return Whether the user is verified
     */
    function isVerifiedUser(address user) external view returns (bool) {
        return verifiedUsers[user];
    }

    /**
     * @dev Gets the gas limit for a user
     * @param user The user address
     * @return The gas limit for the user
     */
    function getUserGasLimit(address user) external view returns (uint256) {
        return userGasLimits[user];
    }

    // PostOpMode enum
    enum PostOpMode {
        opSucceeded,
        opReverted,
        postOpReverted
    }

    // Allow the contract to receive ETH
    receive() external payable {}
} 

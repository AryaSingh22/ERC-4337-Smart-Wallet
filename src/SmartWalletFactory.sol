// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IEntryPoint} from "account-abstraction/interfaces/IEntryPoint.sol";

import {SmartWallet} from "./SmartWallet.sol";

/**
 * @title SmartWalletFactory
 * @dev CREATE2 factory for counterfactual SmartWallet deployment.
 *
 * A wallet address can be computed (getAddress) and funded before the wallet
 * exists; the wallet is then deployed through ERC-4337 initCode on the first
 * UserOperation, or directly via createAccount.
 *
 * Note: to be used in initCode by public bundlers, this factory must be
 * staked in the EntryPoint (ERC-7562 rules for factories).
 */
contract SmartWalletFactory {
    SmartWallet public immutable accountImplementation;

    event WalletCreated(address indexed wallet, address indexed owner, uint256 salt);

    constructor(IEntryPoint entryPoint) {
        accountImplementation = new SmartWallet(entryPoint);
    }

    /**
     * @dev Creates a SmartWallet behind an ERC1967 proxy, or returns the
     * existing one if it is already deployed (required for idempotent
     * initCode handling by the EntryPoint).
     */
    function createAccount(
        address owner,
        address[] calldata guardians,
        uint256 guardianThreshold,
        uint256 recoveryTimeout,
        uint256 recoveryExecutionDelay,
        uint256 salt
    ) external returns (SmartWallet ret) {
        address addr = getAddress(owner, guardians, guardianThreshold, recoveryTimeout, recoveryExecutionDelay, salt);
        if (addr.code.length > 0) {
            return SmartWallet(payable(addr));
        }
        ret = SmartWallet(
            payable(new ERC1967Proxy{salt: bytes32(salt)}(
                    address(accountImplementation),
                    abi.encodeCall(
                        SmartWallet.initialize,
                        (owner, guardians, guardianThreshold, recoveryTimeout, recoveryExecutionDelay)
                    )
                ))
        );
        emit WalletCreated(address(ret), owner, salt);
    }

    /**
     * @dev Computes the counterfactual wallet address for the given
     * parameters, as it would be deployed by createAccount.
     */
    function getAddress(
        address owner,
        address[] calldata guardians,
        uint256 guardianThreshold,
        uint256 recoveryTimeout,
        uint256 recoveryExecutionDelay,
        uint256 salt
    ) public view returns (address) {
        return Create2.computeAddress(
            bytes32(salt),
            keccak256(
                abi.encodePacked(
                    type(ERC1967Proxy).creationCode,
                    abi.encode(
                        address(accountImplementation),
                        abi.encodeCall(
                            SmartWallet.initialize,
                            (owner, guardians, guardianThreshold, recoveryTimeout, recoveryExecutionDelay)
                        )
                    )
                )
            )
        );
    }
}

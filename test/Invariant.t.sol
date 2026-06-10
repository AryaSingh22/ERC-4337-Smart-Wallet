// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Test} from "forge-std/Test.sol";
import {EntryPoint} from "account-abstraction/core/EntryPoint.sol";
import {IEntryPoint} from "account-abstraction/interfaces/IEntryPoint.sol";

import {SmartWallet} from "../src/SmartWallet.sol";
import {SmartWalletFactory} from "../src/SmartWalletFactory.sol";

/**
 * @dev Randomized action handler the fuzzer drives. All calls are pranked as
 * plausible actors (owner, guardians, strangers); reverts are swallowed so
 * the fuzzer explores deep sequences.
 */
contract WalletHandler is Test {
    SmartWallet public wallet;
    address[] public actors;
    uint256 public executedRecoveries;

    constructor(SmartWallet _wallet) {
        wallet = _wallet;
        for (uint256 i = 0; i < 8; i++) {
            actors.push(address(uint160(0x1000 + i)));
        }
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function addGuardian(uint256 actorSeed) external {
        vm.prank(wallet.owner());
        try wallet.addGuardian(_actor(actorSeed)) {} catch {}
    }

    function removeGuardian(uint256 actorSeed) external {
        vm.prank(wallet.owner());
        try wallet.removeGuardian(_actor(actorSeed)) {} catch {}
    }

    function updateOwner(uint256 actorSeed) external {
        vm.prank(wallet.owner());
        try wallet.updateOwner(_actor(actorSeed)) {} catch {}
    }

    function initiateRecovery(uint256 guardianSeed, uint256 newOwnerSeed) external {
        vm.prank(_actor(guardianSeed));
        try wallet.initiateRecovery(_actor(newOwnerSeed)) {} catch {}
    }

    function voteRecovery(uint256 guardianSeed, uint256 recoveryId) external {
        uint256 count = wallet.recoveryRequestCount();
        if (count == 0) return;
        vm.prank(_actor(guardianSeed));
        try wallet.voteRecovery((recoveryId % count) + 1) {} catch {}
    }

    function executeRecovery(uint256 recoveryId) external {
        uint256 count = wallet.recoveryRequestCount();
        if (count == 0) return;
        try wallet.executeRecovery((recoveryId % count) + 1) {
            executedRecoveries++;
        } catch {}
    }

    function cancelRecovery(uint256 recoveryId) external {
        uint256 count = wallet.recoveryRequestCount();
        if (count == 0) return;
        vm.prank(wallet.owner());
        try wallet.cancelRecovery((recoveryId % count) + 1) {} catch {}
    }

    function warp(uint256 by) external {
        vm.warp(block.timestamp + bound(by, 1 hours, 2 days));
    }
}

contract WalletInvariantTest is Test {
    SmartWallet public wallet;
    WalletHandler public handler;

    function setUp() public {
        EntryPoint entryPoint = new EntryPoint();
        SmartWalletFactory factory = new SmartWalletFactory(IEntryPoint(address(entryPoint)));

        address[] memory guardians = new address[](3);
        guardians[0] = address(0x1000);
        guardians[1] = address(0x1001);
        guardians[2] = address(0x1002);

        wallet = factory.createAccount(address(0x1007), guardians, 2, 3 days, 1 days, 0);
        handler = new WalletHandler(wallet);

        targetContract(address(handler));
    }

    /// The owner can never simultaneously be a guardian.
    function invariant_ownerNeverGuardian() public view {
        assertFalse(wallet.isGuardian(wallet.owner()));
    }

    /// The guardian set can never shrink below the recovery threshold.
    function invariant_guardiansAlwaysReachThreshold() public view {
        assertGe(wallet.getGuardianCount(), wallet.guardianThreshold());
    }

    /// Any executed recovery must have met the vote threshold, never been
    /// cancelled, and respected the timelock relative to its creation.
    function invariant_executedRecoveriesWereLegitimate() public view {
        uint256 count = wallet.recoveryRequestCount();
        for (uint256 id = 1; id <= count; id++) {
            (, uint256 timestamp, uint256 voteCount, bool executed, bool cancelled, uint256 executeAfter) =
                wallet.getRecoveryRequest(id);
            if (executed) {
                assertGe(voteCount, wallet.guardianThreshold());
                assertFalse(cancelled);
                assertGe(executeAfter, timestamp + wallet.recoveryExecutionDelay());
            }
        }
    }

    /// The owner is always a valid (non-zero) address.
    function invariant_ownerNonZero() public view {
        assertTrue(wallet.owner() != address(0));
    }
}

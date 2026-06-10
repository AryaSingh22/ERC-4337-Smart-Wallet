// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Test} from "forge-std/Test.sol";
import {EntryPoint} from "account-abstraction/core/EntryPoint.sol";
import {IEntryPoint} from "account-abstraction/interfaces/IEntryPoint.sol";
import {PackedUserOperation} from "account-abstraction/interfaces/PackedUserOperation.sol";
import {VerifyingPaymaster} from "account-abstraction/samples/VerifyingPaymaster.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import {SmartWallet} from "../src/SmartWallet.sol";
import {SmartWalletFactory} from "../src/SmartWalletFactory.sol";

/**
 * @dev End-to-end tests running complete UserOperations through the real
 * EntryPoint v0.7: counterfactual deployment via initCode, owner execution,
 * paymaster-sponsored (gasless) execution, and session key execution.
 */
contract IntegrationTest is Test {
    EntryPoint public entryPoint;
    SmartWalletFactory public factory;
    VerifyingPaymaster public paymaster;

    uint256 internal ownerKey = 0xA11CE;
    uint256 internal paymasterSignerKey = 0x9A43;
    uint256 internal sessionKeyPriv = 0x5E55;

    address public owner;
    address public paymasterSigner;
    address public sessionSigner;
    address payable public beneficiary = payable(address(0xFEE));
    address public recipient = address(0xCAFE);

    address[] internal guardians;

    function setUp() public {
        owner = vm.addr(ownerKey);
        paymasterSigner = vm.addr(paymasterSignerKey);
        sessionSigner = vm.addr(sessionKeyPriv);

        guardians.push(address(0x2));
        guardians.push(address(0x3));

        entryPoint = new EntryPoint();
        factory = new SmartWalletFactory(IEntryPoint(address(entryPoint)));
        paymaster = new VerifyingPaymaster(IEntryPoint(address(entryPoint)), paymasterSigner);

        // Fund the paymaster's EntryPoint deposit
        vm.deal(address(this), 100 ether);
        paymaster.deposit{value: 10 ether}();
    }

    // ---------- helpers ----------

    function _counterfactual(uint256 salt) internal view returns (address) {
        return factory.getAddress(owner, guardians, 2, 3 days, 1 days, salt);
    }

    function _initCode(uint256 salt) internal view returns (bytes memory) {
        return abi.encodePacked(
            address(factory), abi.encodeCall(factory.createAccount, (owner, guardians, 2, 3 days, 1 days, salt))
        );
    }

    function _buildOp(address sender, bytes memory initCode, bytes memory callData)
        internal
        view
        returns (PackedUserOperation memory op)
    {
        op.sender = sender;
        op.nonce = entryPoint.getNonce(sender, 0);
        op.initCode = initCode;
        op.callData = callData;
        // verificationGasLimit (high 128) | callGasLimit (low 128)
        op.accountGasLimits = bytes32((uint256(2_000_000) << 128) | 500_000);
        op.preVerificationGas = 100_000;
        // maxPriorityFeePerGas (high 128) | maxFeePerGas (low 128)
        op.gasFees = bytes32((uint256(1 gwei) << 128) | uint256(2 gwei));
    }

    function _signOp(PackedUserOperation memory op, uint256 key) internal view {
        bytes32 userOpHash = entryPoint.getUserOpHash(op);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, MessageHashUtils.toEthSignedMessageHash(userOpHash));
        op.signature = abi.encodePacked(r, s, v);
    }

    function _handleOps(PackedUserOperation memory op) internal {
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = op;
        entryPoint.handleOps(ops, beneficiary);
    }

    function _attachPaymaster(PackedUserOperation memory op, uint48 validUntil, uint48 validAfter) internal view {
        // paymasterAndData: paymaster (20) | validationGasLimit (16) | postOpGasLimit (16) | abi.encode(validUntil, validAfter) | signature
        bytes memory prefix =
            abi.encodePacked(address(paymaster), uint128(300_000), uint128(50_000), abi.encode(validUntil, validAfter));
        op.paymasterAndData = abi.encodePacked(prefix, new bytes(65));
        bytes32 pmHash = MessageHashUtils.toEthSignedMessageHash(paymaster.getHash(op, validUntil, validAfter));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(paymasterSignerKey, pmHash);
        op.paymasterAndData = abi.encodePacked(prefix, r, s, v);
    }

    // ---------- tests ----------

    function testWalletDeploysViaInitCodeAndExecutes() public {
        address sender = _counterfactual(0);
        assertEq(sender.code.length, 0, "wallet must not exist yet");
        vm.deal(sender, 10 ether);

        bytes memory callData = abi.encodeCall(SmartWallet.execute, (recipient, 1 ether, ""));
        PackedUserOperation memory op = _buildOp(sender, _initCode(0), callData);
        _signOp(op, ownerKey);

        _handleOps(op);

        assertGt(sender.code.length, 0, "wallet deployed");
        assertEq(SmartWallet(payable(sender)).owner(), owner);
        assertEq(recipient.balance, 1 ether);
        assertGt(beneficiary.balance, 0, "bundler compensated");
    }

    function testExistingWalletExecutesViaEntryPoint() public {
        SmartWallet wallet = factory.createAccount(owner, guardians, 2, 3 days, 1 days, 1);
        vm.deal(address(wallet), 10 ether);

        bytes memory callData = abi.encodeCall(SmartWallet.execute, (recipient, 2 ether, ""));
        PackedUserOperation memory op = _buildOp(address(wallet), "", callData);
        _signOp(op, ownerKey);

        _handleOps(op);

        assertEq(recipient.balance, 2 ether);
    }

    function testGaslessExecutionViaPaymaster() public {
        SmartWallet wallet = factory.createAccount(owner, guardians, 2, 3 days, 1 days, 2);
        // Wallet holds funds to transfer but pays NO gas - paymaster sponsors it
        vm.deal(address(wallet), 1 ether);

        bytes memory callData = abi.encodeCall(SmartWallet.execute, (recipient, 1 ether, ""));
        PackedUserOperation memory op = _buildOp(address(wallet), "", callData);
        _attachPaymaster(op, uint48(block.timestamp + 1 hours), 0);
        _signOp(op, ownerKey);

        uint256 paymasterDepositBefore = paymaster.getDeposit();
        _handleOps(op);

        assertEq(recipient.balance, 1 ether);
        assertEq(address(wallet).balance, 0, "wallet spent only the transfer amount");
        assertLt(paymaster.getDeposit(), paymasterDepositBefore, "paymaster paid the gas");
    }

    function testPaymasterRejectsUnsponsoredOp() public {
        SmartWallet wallet = factory.createAccount(owner, guardians, 2, 3 days, 1 days, 3);
        vm.deal(address(wallet), 1 ether);

        bytes memory callData = abi.encodeCall(SmartWallet.execute, (recipient, 0.5 ether, ""));
        PackedUserOperation memory op = _buildOp(address(wallet), "", callData);

        // Paymaster data signed by the WRONG key
        bytes memory prefix =
            abi.encodePacked(address(paymaster), uint128(300_000), uint128(50_000), abi.encode(uint48(0), uint48(0)));
        op.paymasterAndData = abi.encodePacked(prefix, new bytes(65));
        bytes32 pmHash = MessageHashUtils.toEthSignedMessageHash(paymaster.getHash(op, 0, 0));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xBEEF, pmHash);
        op.paymasterAndData = abi.encodePacked(prefix, r, s, v);
        _signOp(op, ownerKey);

        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = op;
        vm.expectRevert(); // AA34 signature error
        entryPoint.handleOps(ops, beneficiary);
    }

    function testSessionKeyExecutesEndToEnd() public {
        SmartWallet wallet = factory.createAccount(owner, guardians, 2, 3 days, 1 days, 4);
        vm.deal(address(wallet), 10 ether);

        vm.prank(owner);
        wallet.addSessionKey(sessionSigner, 0, uint48(block.timestamp + 1 days), 2 ether, recipient);

        bytes memory callData = abi.encodeCall(SmartWallet.execute, (recipient, 1 ether, ""));
        PackedUserOperation memory op = _buildOp(address(wallet), "", callData);
        _signOp(op, sessionKeyPriv);

        _handleOps(op);

        assertEq(recipient.balance, 1 ether);
        assertEq(wallet.getSessionKey(sessionSigner).spent, 1 ether);
    }

    function testExpiredSessionKeyRejectedByEntryPoint() public {
        SmartWallet wallet = factory.createAccount(owner, guardians, 2, 3 days, 1 days, 5);
        vm.deal(address(wallet), 10 ether);

        vm.prank(owner);
        wallet.addSessionKey(sessionSigner, 0, uint48(block.timestamp + 1 hours), 2 ether, address(0));

        vm.warp(block.timestamp + 2 hours); // key expired

        bytes memory callData = abi.encodeCall(SmartWallet.execute, (recipient, 1 ether, ""));
        PackedUserOperation memory op = _buildOp(address(wallet), "", callData);
        _signOp(op, sessionKeyPriv);

        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = op;
        vm.expectRevert(); // AA22 expired or not due
        entryPoint.handleOps(ops, beneficiary);
    }

    function testBatchExecutionViaEntryPoint() public {
        SmartWallet wallet = factory.createAccount(owner, guardians, 2, 3 days, 1 days, 6);
        vm.deal(address(wallet), 10 ether);

        SmartWallet.Call[] memory calls = new SmartWallet.Call[](2);
        calls[0] = SmartWallet.Call(address(0x111), 1 ether, "");
        calls[1] = SmartWallet.Call(address(0x222), 2 ether, "");

        bytes memory callData = abi.encodeCall(SmartWallet.executeBatch, (calls));
        PackedUserOperation memory op = _buildOp(address(wallet), "", callData);
        _signOp(op, ownerKey);

        _handleOps(op);

        assertEq(address(0x111).balance, 1 ether);
        assertEq(address(0x222).balance, 2 ether);
    }

    function testWalletAdministersItselfViaUserOp() public {
        SmartWallet wallet = factory.createAccount(owner, guardians, 2, 3 days, 1 days, 7);
        vm.deal(address(wallet), 10 ether);

        // Owner adds a guardian through a UserOperation (self-call path)
        bytes memory adminData = abi.encodeCall(SmartWallet.addGuardian, (address(0x777)));
        bytes memory callData = abi.encodeCall(SmartWallet.execute, (address(wallet), 0, adminData));
        PackedUserOperation memory op = _buildOp(address(wallet), "", callData);
        _signOp(op, ownerKey);

        _handleOps(op);

        assertTrue(wallet.isGuardian(address(0x777)));
    }

    receive() external payable {}
}

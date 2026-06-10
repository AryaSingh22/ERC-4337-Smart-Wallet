// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {BaseAccount} from "account-abstraction/core/BaseAccount.sol";
import {IEntryPoint} from "account-abstraction/interfaces/IEntryPoint.sol";
import {PackedUserOperation} from "account-abstraction/interfaces/PackedUserOperation.sol";
import {
    SIG_VALIDATION_SUCCESS, SIG_VALIDATION_FAILED, _packValidationData
} from "account-abstraction/core/Helpers.sol";

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {ERC721Holder} from "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/**
 * @title SmartWallet
 * @dev ERC-4337 (EntryPoint v0.7) smart contract account, deployed behind an
 * ERC1967 proxy by SmartWalletFactory.
 *
 * Features:
 * - Owner ECDSA validation of PackedUserOperations
 * - Session keys with validity window, spending limit, and target restriction
 * - Guardian-based social recovery with threshold voting, timelock, and
 *   EIP-712 gasless votes
 * - ERC-1271 contract signatures
 * - ERC-721 / ERC-1155 token receiver callbacks
 * - UUPS upgradeability (owner-gated)
 */
contract SmartWallet is
    BaseAccount,
    Initializable,
    UUPSUpgradeable,
    ReentrancyGuard,
    EIP712,
    ERC721Holder,
    ERC1155Holder,
    IERC1271
{
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;
    using EnumerableSet for EnumerableSet.AddressSet;

    bytes4 internal constant ERC1271_MAGIC_VALUE = 0x1626ba7e;
    bytes4 internal constant ERC1271_INVALID = 0xffffffff;

    bytes32 public constant RECOVERY_VOTE_TYPEHASH =
        keccak256("RecoveryVote(uint256 recoveryId,address newOwner,address guardian)");

    // Events
    event WalletInitialized(address indexed owner, address[] guardians, uint256 recoveryTimeout);
    event OwnerUpdated(address indexed oldOwner, address indexed newOwner);
    event GuardianAdded(address indexed guardian);
    event GuardianRemoved(address indexed guardian);
    event RecoveryInitiated(address indexed newOwner, uint256 indexed recoveryId);
    event RecoveryVoted(address indexed guardian, uint256 indexed recoveryId);
    event RecoveryReady(address indexed newOwner, uint256 indexed recoveryId, uint256 executeAfter);
    event RecoveryCompleted(address indexed oldOwner, address indexed newOwner, uint256 indexed recoveryId);
    event RecoveryCancelled(uint256 indexed recoveryId);
    event BatchExecuted(bytes32 indexed batchId, uint256 callCount);
    event CallExecuted(uint256 indexed callIndex, address indexed target, bool success);
    event SessionKeyAdded(
        address indexed key, uint48 validAfter, uint48 validUntil, uint256 spendingLimit, address allowedTarget
    );
    event SessionKeyRevoked(address indexed key);
    event SessionKeysCleared(uint256 newEpoch);

    // State variables
    address public owner;
    EnumerableSet.AddressSet private _guardians;
    mapping(uint256 => RecoveryRequest) private _recoveryRequests;
    uint256 public recoveryRequestCount;
    uint256 public guardianThreshold;
    uint256 public recoveryTimeout;
    uint256 public recoveryExecutionDelay; // Timelock delay after threshold met

    // Session keys are scoped to an epoch; bumping the epoch revokes all keys.
    uint256 public sessionKeyEpoch;
    mapping(uint256 => mapping(address => SessionKeyData)) private _sessionKeys;

    IEntryPoint private immutable _entryPoint;

    // Structs
    struct RecoveryRequest {
        address newOwner;
        uint256 timestamp;
        mapping(address => bool) guardianVotes;
        uint256 voteCount;
        bool executed;
        bool cancelled;
        uint256 executeAfter; // Timestamp when recovery can be executed
    }

    struct SessionKeyData {
        bool active;
        uint48 validAfter;
        uint48 validUntil; // 0 = no expiry
        address allowedTarget; // address(0) = any target (except this wallet)
        uint256 spendingLimit; // total wei the key may spend
        uint256 spent;
    }

    struct Call {
        address target;
        uint256 value;
        bytes data;
    }

    // Modifiers
    modifier onlyOwner() {
        require(msg.sender == owner, "SmartWallet: caller is not the owner");
        _;
    }

    /// @dev Allows direct owner calls and self-calls (i.e. via a UserOperation
    /// whose callData is execute(address(this), 0, adminCalldata)).
    modifier onlyOwnerOrSelf() {
        require(msg.sender == owner || msg.sender == address(this), "SmartWallet: caller is not the owner or wallet");
        _;
    }

    modifier onlyEntryPointOrOwner() {
        require(
            msg.sender == address(entryPoint()) || msg.sender == owner,
            "SmartWallet: caller is not the entry point or owner"
        );
        _;
    }

    modifier onlyGuardian() {
        require(_guardians.contains(msg.sender), "SmartWallet: caller is not a guardian");
        _;
    }

    constructor(IEntryPoint anEntryPoint) EIP712("SmartWallet", "1") {
        require(address(anEntryPoint) != address(0), "SmartWallet: invalid entry point");
        _entryPoint = anEntryPoint;
        _disableInitializers();
    }

    /**
     * @dev Initializes the wallet (called once by the factory via the proxy)
     * @param anOwner The initial owner of the wallet
     * @param guardians Array of guardian addresses
     * @param _guardianThreshold Minimum guardians required for recovery (min 2)
     * @param _recoveryTimeout Time window for recovery in seconds
     * @param _recoveryExecutionDelay Timelock after threshold met in seconds
     */
    function initialize(
        address anOwner,
        address[] calldata guardians,
        uint256 _guardianThreshold,
        uint256 _recoveryTimeout,
        uint256 _recoveryExecutionDelay
    ) external initializer {
        require(anOwner != address(0), "SmartWallet: invalid owner");
        require(guardians.length >= _guardianThreshold, "SmartWallet: insufficient guardians");
        require(_guardianThreshold >= 2, "SmartWallet: threshold must be at least 2");
        require(_recoveryTimeout > 0, "SmartWallet: recovery timeout must be positive");
        require(_recoveryExecutionDelay > 0, "SmartWallet: execution delay must be positive");
        require(_recoveryExecutionDelay < _recoveryTimeout, "SmartWallet: delay must be shorter than timeout");

        owner = anOwner;
        guardianThreshold = _guardianThreshold;
        recoveryTimeout = _recoveryTimeout;
        recoveryExecutionDelay = _recoveryExecutionDelay;

        for (uint256 i = 0; i < guardians.length; i++) {
            require(guardians[i] != address(0), "SmartWallet: invalid guardian");
            require(guardians[i] != anOwner, "SmartWallet: owner cannot be guardian");
            require(_guardians.add(guardians[i]), "SmartWallet: duplicate guardian");
        }

        emit WalletInitialized(anOwner, guardians, _recoveryTimeout);
    }

    /// @inheritdoc BaseAccount
    function entryPoint() public view override returns (IEntryPoint) {
        return _entryPoint;
    }

    // ---------------------------------------------------------------------
    // ERC-4337 validation
    // ---------------------------------------------------------------------

    /**
     * @dev Validates the userOp signature. Accepts either the owner or an
     * active session key whose policy permits the requested calls.
     * Returns SIG_VALIDATION_FAILED (1) instead of reverting on signature
     * mismatch, as required by the spec.
     */
    function _validateSignature(PackedUserOperation calldata userOp, bytes32 userOpHash)
        internal
        override
        returns (uint256 validationData)
    {
        bytes32 hash = userOpHash.toEthSignedMessageHash();
        (address signer, ECDSA.RecoverError err,) = hash.tryRecover(userOp.signature);
        if (err != ECDSA.RecoverError.NoError) {
            return SIG_VALIDATION_FAILED;
        }
        if (signer == owner) {
            return SIG_VALIDATION_SUCCESS;
        }

        SessionKeyData storage key = _sessionKeys[sessionKeyEpoch][signer];
        if (!key.active) {
            return SIG_VALIDATION_FAILED;
        }
        if (!_checkAndUpdateSessionPolicy(key, userOp.callData)) {
            return SIG_VALIDATION_FAILED;
        }
        // The EntryPoint enforces the time window; validation code must not
        // read block.timestamp directly.
        return _packValidationData(false, key.validUntil, key.validAfter);
    }

    /**
     * @dev Enforces a session key's policy against the userOp callData:
     * only execute/executeBatch, never targeting the wallet itself, optional
     * single allowed target, and a cumulative spending limit (accounted at
     * validation time).
     */
    function _checkAndUpdateSessionPolicy(SessionKeyData storage key, bytes calldata callData)
        internal
        returns (bool)
    {
        if (callData.length < 4) {
            return false;
        }
        bytes4 selector = bytes4(callData[:4]);
        uint256 totalValue = 0;

        if (selector == this.execute.selector) {
            (address target, uint256 value,) = abi.decode(callData[4:], (address, uint256, bytes));
            if (!_sessionTargetAllowed(key, target)) {
                return false;
            }
            totalValue = value;
        } else if (selector == this.executeBatch.selector) {
            Call[] memory calls = abi.decode(callData[4:], (Call[]));
            for (uint256 i = 0; i < calls.length; i++) {
                if (!_sessionTargetAllowed(key, calls[i].target)) {
                    return false;
                }
                totalValue += calls[i].value;
            }
        } else {
            return false;
        }

        if (key.spent + totalValue > key.spendingLimit) {
            return false;
        }
        key.spent += totalValue;
        return true;
    }

    function _sessionTargetAllowed(SessionKeyData storage key, address target) internal view returns (bool) {
        if (target == address(this)) {
            return false; // session keys can never administer the wallet
        }
        return key.allowedTarget == address(0) || key.allowedTarget == target;
    }

    // ---------------------------------------------------------------------
    // Execution
    // ---------------------------------------------------------------------

    /**
     * @dev Executes a single transaction
     * @param target The target contract address
     * @param value The amount of ETH to send
     * @param data The calldata to execute
     */
    function execute(address target, uint256 value, bytes calldata data) external onlyEntryPointOrOwner nonReentrant {
        require(target != address(0), "SmartWallet: invalid target");

        _call(target, value, data);

        emit CallExecuted(0, target, true);
    }

    /**
     * @dev Executes multiple transactions in a single batch
     * @param calls Array of calls to execute
     */
    function executeBatch(Call[] calldata calls) external onlyEntryPointOrOwner nonReentrant {
        require(calls.length > 0, "SmartWallet: empty batch");

        bytes32 batchId = keccak256(abi.encode(calls));

        for (uint256 i = 0; i < calls.length; i++) {
            require(calls[i].target != address(0), "SmartWallet: invalid target");

            _call(calls[i].target, calls[i].value, calls[i].data);

            emit CallExecuted(i, calls[i].target, true);
        }

        emit BatchExecuted(batchId, calls.length);
    }

    /**
     * @dev Internal call helper that bubbles up revert reasons
     */
    function _call(address target, uint256 value, bytes memory data) internal {
        // slither-disable-next-line arbitrary-send-eth
        (bool success, bytes memory result) = target.call{value: value}(data);
        if (!success) {
            // Bubble up the original revert reason
            assembly {
                revert(add(result, 32), mload(result))
            }
        }
    }

    // ---------------------------------------------------------------------
    // Session keys
    // ---------------------------------------------------------------------

    /**
     * @dev Registers a session key with a validity window and spending policy
     * @param key The session key address
     * @param validAfter First timestamp the key is valid (0 = immediately)
     * @param validUntil Last timestamp the key is valid (0 = no expiry)
     * @param spendingLimit Total wei the key may spend across all operations
     * @param allowedTarget Single target the key may call (address(0) = any)
     */
    function addSessionKey(
        address key,
        uint48 validAfter,
        uint48 validUntil,
        uint256 spendingLimit,
        address allowedTarget
    ) external onlyOwnerOrSelf {
        require(key != address(0), "SmartWallet: invalid session key");
        require(key != owner, "SmartWallet: owner cannot be session key");
        require(validUntil == 0 || validUntil > validAfter, "SmartWallet: invalid validity window");

        _sessionKeys[sessionKeyEpoch][key] = SessionKeyData({
            active: true,
            validAfter: validAfter,
            validUntil: validUntil,
            allowedTarget: allowedTarget,
            spendingLimit: spendingLimit,
            spent: 0
        });

        emit SessionKeyAdded(key, validAfter, validUntil, spendingLimit, allowedTarget);
    }

    /**
     * @dev Revokes a single session key
     */
    function revokeSessionKey(address key) external onlyOwnerOrSelf {
        require(_sessionKeys[sessionKeyEpoch][key].active, "SmartWallet: unknown session key");
        delete _sessionKeys[sessionKeyEpoch][key];
        emit SessionKeyRevoked(key);
    }

    /**
     * @dev Revokes all session keys by bumping the epoch.
     * Also called automatically on every ownership change.
     */
    function revokeAllSessionKeys() external onlyOwnerOrSelf {
        _clearSessionKeys();
    }

    function _clearSessionKeys() internal {
        sessionKeyEpoch++;
        emit SessionKeysCleared(sessionKeyEpoch);
    }

    /**
     * @dev Returns the session key data for the current epoch
     */
    function getSessionKey(address key) external view returns (SessionKeyData memory) {
        return _sessionKeys[sessionKeyEpoch][key];
    }

    // ---------------------------------------------------------------------
    // Owner management
    // ---------------------------------------------------------------------

    /**
     * @dev Updates the owner (only callable by current owner).
     * All session keys are revoked.
     * @param newOwner The new owner address
     */
    function updateOwner(address newOwner) external onlyOwnerOrSelf {
        require(newOwner != address(0), "SmartWallet: invalid new owner");
        require(newOwner != owner, "SmartWallet: same owner");
        require(!_guardians.contains(newOwner), "SmartWallet: guardian cannot be owner");

        address oldOwner = owner;
        owner = newOwner;
        _clearSessionKeys();

        emit OwnerUpdated(oldOwner, newOwner);
    }

    // ---------------------------------------------------------------------
    // Social recovery
    // ---------------------------------------------------------------------

    /**
     * @dev Initiates a recovery process (counts as the initiator's vote)
     * @param newOwner The proposed new owner
     */
    function initiateRecovery(address newOwner) external onlyGuardian {
        require(newOwner != address(0), "SmartWallet: invalid new owner");
        require(newOwner != owner, "SmartWallet: same owner");
        require(!_guardians.contains(newOwner), "SmartWallet: guardian cannot be owner");

        recoveryRequestCount++;
        RecoveryRequest storage request = _recoveryRequests[recoveryRequestCount];
        request.newOwner = newOwner;
        request.timestamp = block.timestamp;
        request.guardianVotes[msg.sender] = true;
        request.voteCount = 1;

        emit RecoveryInitiated(newOwner, recoveryRequestCount);
    }

    /**
     * @dev Votes on a recovery request (direct guardian transaction)
     * @param recoveryId The ID of the recovery request
     */
    function voteRecovery(uint256 recoveryId) external onlyGuardian {
        _castVote(recoveryId, msg.sender);
    }

    /**
     * @dev Casts a guardian's recovery vote via an EIP-712 signature, so the
     * guardian does not need ETH for gas. Anyone may relay the signature.
     * @param recoveryId The ID of the recovery request
     * @param guardian The guardian who signed the vote
     * @param signature EIP-712 signature over RecoveryVote(recoveryId,newOwner,guardian)
     */
    function voteRecoveryBySig(uint256 recoveryId, address guardian, bytes calldata signature) external {
        require(_guardians.contains(guardian), "SmartWallet: signer is not a guardian");

        RecoveryRequest storage request = _recoveryRequests[recoveryId];
        bytes32 structHash = keccak256(abi.encode(RECOVERY_VOTE_TYPEHASH, recoveryId, request.newOwner, guardian));
        bytes32 digest = _hashTypedDataV4(structHash);
        (address signer, ECDSA.RecoverError err,) = digest.tryRecover(signature);
        require(err == ECDSA.RecoverError.NoError && signer == guardian, "SmartWallet: invalid vote signature");

        _castVote(recoveryId, guardian);
    }

    function _castVote(uint256 recoveryId, address guardian) internal {
        RecoveryRequest storage request = _recoveryRequests[recoveryId];
        require(request.timestamp > 0, "SmartWallet: recovery request not found");
        require(!request.executed, "SmartWallet: recovery already executed");
        require(!request.cancelled, "SmartWallet: recovery was cancelled");
        require(block.timestamp <= request.timestamp + recoveryTimeout, "SmartWallet: recovery timeout");
        require(!request.guardianVotes[guardian], "SmartWallet: already voted");

        request.guardianVotes[guardian] = true;
        request.voteCount++;

        emit RecoveryVoted(guardian, recoveryId);

        // Start the timelock exactly when the threshold is reached
        if (request.voteCount == guardianThreshold) {
            request.executeAfter = block.timestamp + recoveryExecutionDelay;
            emit RecoveryReady(request.newOwner, recoveryId, request.executeAfter);
        }
    }

    /**
     * @dev Executes a recovery request (only after timelock delay).
     * All session keys are revoked.
     * @param recoveryId The ID of the recovery request
     */
    function executeRecovery(uint256 recoveryId) external {
        RecoveryRequest storage request = _recoveryRequests[recoveryId];
        require(request.timestamp > 0, "SmartWallet: recovery request not found");
        require(!request.executed, "SmartWallet: recovery already executed");
        require(!request.cancelled, "SmartWallet: recovery was cancelled");
        require(request.voteCount >= guardianThreshold, "SmartWallet: insufficient votes");
        require(block.timestamp >= request.executeAfter, "SmartWallet: timelock not expired");
        require(block.timestamp <= request.timestamp + recoveryTimeout, "SmartWallet: recovery timeout");
        // The guardian set may have changed since initiation; re-check here
        require(!_guardians.contains(request.newOwner), "SmartWallet: guardian cannot be owner");

        address oldOwner = owner;
        owner = request.newOwner;
        request.executed = true;
        _clearSessionKeys();

        emit RecoveryCompleted(oldOwner, request.newOwner, recoveryId);
    }

    /**
     * @dev Cancels a recovery request (only callable by current owner)
     * @param recoveryId The ID of the recovery request
     */
    function cancelRecovery(uint256 recoveryId) external onlyOwnerOrSelf {
        RecoveryRequest storage request = _recoveryRequests[recoveryId];
        require(request.timestamp > 0, "SmartWallet: recovery request not found");
        require(!request.executed, "SmartWallet: recovery already executed");
        require(!request.cancelled, "SmartWallet: recovery already cancelled");

        request.cancelled = true;
        emit RecoveryCancelled(recoveryId);
    }

    // ---------------------------------------------------------------------
    // Guardian management
    // ---------------------------------------------------------------------

    /**
     * @dev Adds a new guardian
     * @param guardian The guardian address to add
     */
    function addGuardian(address guardian) external onlyOwnerOrSelf {
        require(guardian != address(0), "SmartWallet: invalid guardian");
        require(guardian != owner, "SmartWallet: owner cannot be guardian");
        require(_guardians.add(guardian), "SmartWallet: already a guardian");

        emit GuardianAdded(guardian);
    }

    /**
     * @dev Removes a guardian (the threshold must remain reachable)
     * @param guardian The guardian address to remove
     */
    function removeGuardian(address guardian) external onlyOwnerOrSelf {
        require(_guardians.length() > guardianThreshold, "SmartWallet: insufficient guardians");
        require(_guardians.remove(guardian), "SmartWallet: not a guardian");

        emit GuardianRemoved(guardian);
    }

    // ---------------------------------------------------------------------
    // ERC-1271
    // ---------------------------------------------------------------------

    /**
     * @dev ERC-1271 signature validation. Accepts owner signatures over the
     * raw hash or its eth-signed-message variant.
     */
    function isValidSignature(bytes32 hash, bytes calldata signature) external view override returns (bytes4) {
        (address signer, ECDSA.RecoverError err,) = hash.tryRecover(signature);
        if (err == ECDSA.RecoverError.NoError && signer == owner) {
            return ERC1271_MAGIC_VALUE;
        }
        bytes32 ethHash = hash.toEthSignedMessageHash();
        (signer, err,) = ethHash.tryRecover(signature);
        if (err == ECDSA.RecoverError.NoError && signer == owner) {
            return ERC1271_MAGIC_VALUE;
        }
        return ERC1271_INVALID;
    }

    // ---------------------------------------------------------------------
    // EntryPoint deposit management
    // ---------------------------------------------------------------------

    /**
     * @dev Deposits ETH into the EntryPoint for this wallet
     */
    function addDeposit() external payable {
        entryPoint().depositTo{value: msg.value}(address(this));
    }

    /**
     * @dev Returns this wallet's deposit in the EntryPoint
     */
    function getDeposit() external view returns (uint256) {
        return entryPoint().balanceOf(address(this));
    }

    /**
     * @dev Withdraws from the wallet's EntryPoint deposit
     */
    function withdrawDepositTo(address payable withdrawAddress, uint256 amount) external onlyOwnerOrSelf {
        entryPoint().withdrawTo(withdrawAddress, amount);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    function isGuardian(address account) external view returns (bool) {
        return _guardians.contains(account);
    }

    function getGuardians() external view returns (address[] memory) {
        return _guardians.values();
    }

    function getGuardianCount() external view returns (uint256) {
        return _guardians.length();
    }

    /**
     * @dev Returns recovery request details
     */
    function getRecoveryRequest(uint256 recoveryId)
        external
        view
        returns (
            address newOwner,
            uint256 timestamp,
            uint256 voteCount,
            bool executed,
            bool cancelled,
            uint256 executeAfter
        )
    {
        RecoveryRequest storage request = _recoveryRequests[recoveryId];
        return (
            request.newOwner,
            request.timestamp,
            request.voteCount,
            request.executed,
            request.cancelled,
            request.executeAfter
        );
    }

    function hasGuardianVoted(uint256 recoveryId, address guardian) external view returns (bool) {
        return _recoveryRequests[recoveryId].guardianVotes[guardian];
    }

    // ---------------------------------------------------------------------
    // Upgrades & interfaces
    // ---------------------------------------------------------------------

    /// @dev UUPS upgrade authorization - owner only (directly or via self-call)
    function _authorizeUpgrade(address newImplementation) internal view override onlyOwnerOrSelf {
        (newImplementation);
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC1155Holder) returns (bool) {
        return interfaceId == type(IERC1271).interfaceId || interfaceId == type(IERC721Receiver).interfaceId
            || super.supportsInterface(interfaceId);
    }

    /**
     * @dev Allows the contract to receive ETH
     */
    receive() external payable {}

    /// @dev Reserved storage gap for future upgrades
    uint256[44] private __gap;
}

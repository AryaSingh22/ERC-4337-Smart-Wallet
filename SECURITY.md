# Security

## Reporting a vulnerability

Please report security issues privately to the repository owner (do not open a
public issue). Include a description, reproduction steps, and impact assessment.

## Security model

### Trust assumptions

- **Owner key**: full control of the wallet — execution, guardian management,
  session keys, upgrades, and recovery cancellation. Compromise of the owner key
  between recovery initiation and the timelock expiry can be mitigated by
  guardians out-voting a cancellation with a new request.
- **Guardians**: a `guardianThreshold` quorum plus the `recoveryExecutionDelay`
  timelock can replace the owner. Guardians must be chosen so that a quorum
  colluding is unacceptable to the user. The owner can cancel any pending
  recovery during the timelock.
- **EntryPoint**: the canonical audited ERC-4337 EntryPoint v0.7
  (`0x0000000071727De22E5E9d8BAf0edAc6f37da032`) is fully trusted.
- **Paymaster signer**: the `VerifyingPaymaster`'s off-chain signer decides
  which operations get sponsored; it cannot move wallet funds.
- **Session keys**: validation-time policy enforcement restricts session keys
  to `execute`/`executeBatch`, blocks calls targeting the wallet itself,
  optionally pins a single target, and enforces a cumulative wei spending
  limit. Spending is accounted at validation time, so a reverted operation
  still consumes its budgeted amount (conservative by design). ERC-20
  transfers are not value-limited — pin `allowedTarget` for token use cases.

### Invariants (enforced by tests)

- The owner is never simultaneously a guardian (checked at initialization,
  `updateOwner`, `addGuardian`, and re-checked at `executeRecovery` because the
  guardian set may change while a recovery is pending).
- The guardian set never shrinks below the recovery threshold.
- An executed recovery always reached the vote threshold, was never cancelled,
  and respected the timelock.
- Every ownership change (manual or recovery) revokes all session keys by
  bumping the session-key epoch.

### Known limitations

- The factory must be **staked in the EntryPoint** before public bundlers will
  accept `initCode` from it (ERC-7562 factory rules).
- `upgradeToAndCall` is owner-gated with no timelock; a compromised owner key
  can swap the implementation immediately. Consider a timelocked upgrade path
  for high-value deployments.
- Guardian votes are not invalidated when a guardian is removed mid-recovery;
  the threshold check uses the current threshold at execution time.
- This code has **not been professionally audited**.

## Pre-deployment checklist

- [ ] Professional audit of `src/` completed and findings resolved
- [ ] Slither / static analysis clean (`slither . --config-file slither.config.json`)
- [ ] Factory staked in the EntryPoint (`addStake`)
- [ ] Paymaster deposit funded and monitored; signer key in an HSM/KMS
- [ ] Guardian addresses verified out-of-band with their holders
- [ ] Recovery timeout/delay values reviewed for the threat model
- [ ] Upgrade procedure documented and rehearsed on a testnet
- [ ] Monitoring on RecoveryInitiated/RecoveryReady events (owner alerting)

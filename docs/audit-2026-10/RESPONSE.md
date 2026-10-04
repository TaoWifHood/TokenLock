# Response to the security review (v1.1)

Reviewed source: `src/TokenLock.sol` at sha256 `ff3366fa…f242d`. Fixed source: sha256 `98e50d12…cb92b`.
Every finding is listed below with what was done. One commit per change; each commit message names the findings
it closes.

## Code changes

| Finding | Sev. | Change | Commit subject |
|---|---|---|---|
| VULN-011, VULN-012, VULN-013 | M / L / I | `maxUnlockTime` = deployment + `MAX_LOCK_DURATION`, immutable; `extend` can never pass it. The repeated-extension and re-lock-after-expiry cases are bounded by that ceiling for the life of the lock. | an absolute ceiling on unlockTime, fixed at deploy |
| VULN-003 | L | The constructor refuses the token as beneficiary (`BeneficiaryIsToken`). | refuse the locked token as beneficiary |
| VULN-021, VULN-025, VULN-026, DOC-1, DOC-2 | L / I / I | `sweep` refuses the beneficiary and the lock itself (`NotSweepable`), checked on every call. The header now gives the real reason no reentrancy guard is needed, and says the beneficiary must authorise its own callers. | sweep refuses the beneficiary and the lock itself |
| VULN-033 | M | `deployChainId` is immutable; every beneficiary action reverts `WrongChain` on another chain. | bind every beneficiary action to the deployment chain |
| VULN-001 | M | The constructor requires a decodable `balanceOf` answer instead of `code.length != 0`, so a 7702-delegated wallet or a stub is refused. This is FIX-2 part (a). | the token must answer balanceOf, not merely have code |

## Not adopted as proposed

### FIX-1's one-line form — wrong under either reading

The proposal is `if (newUnlockTime > unlockTime + MAX_LOCK_DURATION) revert BadUnlockTime();`. Its base,
`unlockTime`, is the value `extend` itself moves, so the bound is not cumulative under either reading. Every
claim below runs as a test in `test/ExtendBoundReadings.t.sol`, which models the readings as pure predicates.

- **Read as a replacement, it is worse than the original.**
  - Each call moves the base forward, so ten calls in one block (one Safe batch) lock the balance for
    ten times `MAX_LOCK_DURATION`, about a century.
  - The original bound stops the second call (`test_replacement_stacksWithoutLimitInOneBlock`).
- **Read as an addition to the original bound, it changes nothing on a live lock.**
  - While `unlockTime > block.timestamp`, `unlockTime + D` is above `block.timestamp + D`, so the new line
    never binds. A fuzz test shows it accepts exactly what the original accepts
    (`testFuzz_addition_neverBindsOnALiveLock`).
  - On an expired lock it binds only slightly. A lock that expired ten days ago can still be re-locked for
    3,640 days (`test_addition_relocksAnExpiredLockNearlyFully`).
  - So the review's own "act on this now" case, an expired lock being re-locked for a decade, stays open
    under this fix.
- **What closes VULN-011/012/013:** a cumulative bound needs an anchor that never moves.
  - We anchor at deployment: `maxUnlockTime = deploy time + MAX_LOCK_DURATION`, immutable. We do not anchor
    at the first `unlockTime`, so every lock gets the same lifetime ceiling whatever its first duration.
  - No sequence of calls, however spaced in time, passes it (`testFuzz_shipped_neverPassesTheCeiling`, plus
    `test_extend_repeatedStepsStopAtTheCeiling` and `test_extend_afterExpiry_relockIsBoundedByTheCeiling`
    on the contract itself).

### FIX-2 part (b), measured delivery (VULN-002, Low) — correct, deferred

The finding stands. With a fee-on-transfer token, `Withdrawn`/`Swept` report the requested amount or the
pre-transfer balance, not what arrived. Part (a)'s deploy-time probe answers VULN-001; it does not answer this.
We deferred `_deliver` for three reasons:

- **The meaning of an event changes for every consumer.** The topics stay the same, but the number becomes
  "delivered", so every monitor has to be re-read.
- **It can refuse a legitimate transfer.** `NothingDelivered` reverts a dust transfer that credits zero
  shares on a share-based token; the review notes this trade-off itself.
- **It adds a call-then-read path.** Its soundness rests on FIX-3 and FIX-4, which are now in, and it would
  need its own review pass.

**What would change our answer:** if a lock is expected to sweep fee-on-transfer tokens, measured delivery
is the right default, and we will add `_deliver` as written in the review. Until then, the balances on chain
are the source of truth.

## The review's "act on this now" — proposed, pending the owner's confirmation

- No lock built from the reviewed source is funded again.
- Every new lock is deployed from the fixed source.
- Beneficiary Safes are 2-of-3 or better, so that one lost key does not strand the balance.

## The two questions — proposed answers, pending the owner's confirmation

- **Q1 → VULN-031 (Medium), proposed: no pre-Cancun chains.** Locks are deployed only where EIP-6780 is active, so a token's code cannot be replaced at its address. Recorded in the README's accepted items. No codehash check.
- **Q2 → VULN-033 (Medium), proposed:** a given lock lives on one chain only, and a deployment on another chain is a separate lock with its own arguments. The chain binding above stays as insurance against an accidental same-address deploy.

## Documentation

- **DOC-1, DOC-2:** contract header, see above.
- **DOC-3, VULN-022 (Low):** README accepted items now state that the beneficiary can delay withdrawal up to `maxUnlockTime` whatever its threshold, that a 2-of-3 Safe survives a lost key, and that an open relay or multicall must never be the beneficiary.
- **"10 years":** the README, the Safe guide and the deploy script's revert string now say 3650 days.
- **Deploy script:** its token check stays `code.length > 0`; the contract's `balanceOf` probe now refuses the same inputs at deploy, so the script check is a fast pre-flight, not the defence.
- **Test count:** the README now states 51: the 47 contract tests plus the 4 bound readings above. The review counted 43 against a suite that `forge test` reported as 39.

## Lower priority and environmental — unchanged

| Finding | Sev. | Decision |
|---|---|---|
| VULN-016 | L | Inherent: the locked token cannot be returned by `sweep`; documented. |
| VULN-017 | I | No constructor event or extra indexed topics; monitoring reads `unlockTime()` / `Extended`. Open for the reviewer. |
| VULN-004 | I | `sweep` on a non-ERC-20 keeps its empty revert data. |
| VULN-015 | I | No `MIN_LOCK_DURATION`; it fails safe, and the deploy script refuses an unlock within 2 h. |
| VULN-037 | I | `bytecode_hash = "none"` kept; verification goes through the standard JSON input in `docs/`. |
| VULN-035, VULN-040 | I | Environmental (clock reorgs, rollup upgrade authority); no code change implied. |

## Deployed locks

Locks already deployed run the reviewed source and are unchanged by this branch. A deployed lock is checked against
a build of the commit it was deployed from (`scripts/verify-deployed.mjs`).

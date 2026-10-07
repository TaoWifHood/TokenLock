# Response to the security review (v1.1)

Reviewed source: `src/TokenLock.sol` at sha256 `ff3366fa…f242d`. Fixed source: sha256 `4bc9d4f0…6cfb4`.
Every finding is listed below with what was done. There is one commit per change, and each commit message names the
findings it closes. Every recommendation in the review is adopted except two: FIX-1's one-line form, replaced by a
bound without its gaps, and `MIN_LOCK_DURATION`. Both are explained below.

## Code changes

| Finding | Sev. | Change | Commit subject |
|---|---|---|---|
| VULN-011, VULN-012, VULN-013 | M / L / I | `maxUnlockTime` = deployment + `MAX_LOCK_DURATION`, immutable; `extend` can never pass it. The repeated-extension and re-lock-after-expiry cases are bounded by that ceiling for the life of the lock. | an absolute ceiling on unlockTime, fixed at deploy |
| VULN-003 | L | The constructor refuses the token as beneficiary (`BeneficiaryIsToken`). This is FIX-3. | refuse the locked token as beneficiary |
| VULN-021, VULN-025, VULN-026, DOC-1, DOC-2 | L / I / I | `sweep` refuses the beneficiary and the lock itself (`NotSweepable`), checked on every call. This is FIX-4. The header gives the real reason no reentrancy guard is needed, and says the beneficiary must authorise its own callers. | sweep refuses the beneficiary and the lock itself |
| VULN-033 | M | `deployChainId` is immutable; every beneficiary action reverts `WrongChain` on another chain. | bind every beneficiary action to the deployment chain |
| VULN-001 | M | The constructor requires a decodable `balanceOf` answer alongside `code.length != 0`, so a 7702-delegated wallet or a stub (code, no answer) and a precompile (an answer, no code) are all refused. This is FIX-2 part (a); the code check was first dropped and is restored by the follow-up below. | the token must answer balanceOf, not merely have code |
| VULN-004 | I | `sweep` refuses an address with no code (`NotAContract`) before any call, so an EOA or a gas-eating precompile fails by name. | sweep refuses an address with no code by name |
| VULN-002 | L | FIX-2 part (b) as written: `withdraw` and `sweep` measure the beneficiary's balance around the transfer and report what arrived. A non-zero request that delivers nothing reverts `NothingDelivered`. The header's reentrancy reason is rewritten for the read after the transfer. | withdraw and sweep report what the beneficiary received |
| VULN-031 | M | `tokenCodehash` is pinned at deployment; `withdraw` reverts `TokenCodeChanged(deployed, current)` if the code at `token` changed. | withdraw refuses if the code at the token's address changed |
| VULN-017 | I | The constructor emits `Locked(token, beneficiary, unlockTime, maxUnlockTime)`. The existing events are unchanged. | emit Locked with the starting terms at deployment |
| VULN-001 follow-up, VULN-101, VULN-122, DELTA-4, VULN-107 (gas-sink leg) | M | Delta review: the first VULN-001 change replaced the code-length check instead of adding to it, so a codeless account that answers with a word (the sha256, ripemd160 and identity precompiles) passed. `code.length == 0` reverts `NotAContract` again, before the probe, so no call is made to a codeless address. This also closes the review's PoC: the code hash of a codeless address is 0 until it first receives ether, so a lock over one pinned 0 and 1 wei to the token's address bricked `withdraw`. Tests: `test_constructorRefusesTheSha256Precompile`, `test_constructorRefusesTheRipemd160Precompile`, `test_constructorRefusesTheIdentityPrecompile` and `test_constructorRefusesAPrecompileBeforeAndAfterItHoldsEther` in `test/TokenLockConstructor.t.sol`; `test_withdraw_oneWeiSentToTheToken_changesNothing` in `test/TokenLock.t.sol` shows that ether at a real token's address leaves its code hash and `withdraw` unchanged. | the token must have code as well as answer balanceOf |
| VULN-137 | — | Delta review: `withdraw` checks the `tokenCodehash` pin before the time gate, so a lock whose token code changed reverts `TokenCodeChanged` during the locked period instead of `StillLocked`. The set of accepted calls is unchanged. | withdraw checks the token code pin before the time gate |

### Notes on the adopted changes

- **FIX-2 part (b) is adopted because a fee-on-transfer token may be locked later.** For a token without a transfer fee, the reported numbers are unchanged. The two costs the review names are accepted:
  - A dust transfer on a share-based token that credits zero shares reverts; the beneficiary retries with more.
  - The number in `Withdrawn`/`Swept` now means "delivered".
  - The reentrancy argument for the new read is in the contract header: none of this contract's storage is read after a call, and the token, the only contract that can call back mid-transfer, can never be the beneficiary.
  - One new beneficiary rule is documented in the README: the beneficiary must keep what it receives during the call, because a beneficiary that forwards on receipt measures zero.
- **Fee-on-transfer operation is documented, not enforced:**
  - The lock's address belongs on the token's fee exclusion list before funding.
  - A token whose owner can raise the fee or revoke that exclusion bounds what the lock can return; the lock cannot defend against that.
- **The codehash pin goes in `withdraw` only.** That is the one function that moves `token`; `sweep(token)` is refused by address whatever the code. Where EIP-6780 is active the pin cannot fire against a token that was live at deployment, so it is defence in depth there. It is checked before the time gate (VULN-137), so a broken lock is visible as soon as the token's code changes.

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

### `MIN_LOCK_DURATION` (VULN-015, Info)

A floor in the constructor alone is a half-measure, because `extend(block.timestamp + 1)` on an expired lock still makes a one-second lock. A floor on `extend` too would forbid legitimate short re-locks. A too-short lock only opens early for its own beneficiary, so it fails safe. The deploy script keeps its 2-hour minimum lead.

## The two questions — proposed answers, pending the owner's confirmation

- **Q1 → VULN-031 (Medium), proposed: no pre-Cancun chains.** Locks are deployed only where EIP-6780 is active. The codehash pin above now makes `withdraw` refuse a replaced token on any chain, so this answer is a deployment rule backed by code.
- **Q2 → VULN-033 (Medium), proposed:** a given lock lives on one chain only, and a deployment on another chain is a separate lock with its own arguments. The chain binding above stays as insurance against an accidental same-address deploy.

## The review's "act on this now" — proposed, pending the owner's confirmation

- No lock built from the reviewed source is funded again.
- Every new lock is deployed from the fixed source.
- Beneficiary Safes are 2-of-3 or better, so that one lost key does not strand the balance.

## Documentation

- **DOC-1, DOC-2:** the contract header, see above.
- **DOC-3, VULN-022 (Low):** the README's accepted items now state three things:
  - the beneficiary can delay withdrawal up to `maxUnlockTime`, whatever its threshold;
  - a 2-of-3 Safe survives a lost key;
  - an open relay or multicall must never be the beneficiary.
- **"10 years":** the README, the Safe guide and the deploy script's revert string now say 3650 days. `MAX_LOCK_DURATION`'s NatSpec states unix seconds.
- **Deploy script:** its token check stays `code.length > 0`. The constructor makes the same check and then the `balanceOf` probe, so the script check is a fast pre-flight, not the defence.
- **Test count:** the README now states 100: the contract tests, the 4 bound readings above and the deploy-script tests. The review counted 43 against a suite that `forge test` reported as 39. `docs/audit-2026-10/TRACEABILITY.md` maps every finding to its tests, and `npm run mutations` shows each code fix is caught when undone.
- **ABI and standard JSON input** are regenerated for the fixed source. The standard input compiles to the same runtime bytecode as `forge build`.

## Lower priority and environmental — unchanged

| Finding | Sev. | Decision |
|---|---|---|
| VULN-016 | L | Inherent: the locked token cannot be returned by `sweep`; documented. |
| VULN-037 | I | `bytecode_hash = "none"` is kept on purpose. Verification goes through the standard JSON input in `docs/`, which reproduces the bytecode exactly. |
| VULN-035, VULN-040 | I | Environmental (clock reorgs, rollup upgrade authority); no code change implied. |

## Deployed locks

Locks already deployed run the reviewed source and are unchanged by this branch. A deployed lock is checked against
a build of the commit it was deployed from (`scripts/verify-deployed.mjs`).

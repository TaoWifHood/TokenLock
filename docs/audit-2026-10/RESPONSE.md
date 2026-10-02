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

- **FIX-1's one-line form** (`newUnlockTime > unlockTime + MAX_LOCK_DURATION`):
  - As a replacement for the current bound, each call moves the base, so repeated calls stack without limit in one block, which is worse than before.
  - As an addition, it never binds on a live lock, and it still allows almost a full re-lock of an expired one.
  - The absolute ceiling above closes VULN-011/012/013 without either gap.
- **FIX-2 part (b), measured delivery in events (VULN-002, Low):** not applied in this change.
  - `Withdrawn`/`Swept` still report the requested amount and the pre-transfer balance; balances remain the source of truth.
  - With part (a) in place, the phantom-token case behind VULN-001 is refused at deploy.
  - Open for the reviewer: we will add `_deliver` if you consider part (a) insufficient alone.

## The two questions — proposed answers, pending the owner's confirmation

- **Q1 → VULN-031 (Medium), proposed: no pre-Cancun chains.** Locks are deployed only where EIP-6780 is active, so a token's code cannot be replaced at its address. Recorded in the README's accepted items. No codehash check.
- **Q2 → VULN-033 (Medium), proposed:** a given lock lives on one chain only, and a deployment on another chain is a separate lock with its own arguments. The chain binding above stays as insurance against an accidental same-address deploy.

## Documentation

- **DOC-1, DOC-2:** contract header, see above.
- **DOC-3, VULN-022 (Low):** README accepted items now state that the beneficiary can delay withdrawal up to `maxUnlockTime` whatever its threshold, that a 2-of-3 Safe survives a lost key, and that an open relay or multicall must never be the beneficiary.
- **"10 years":** the README, the Safe guide and the deploy script's revert string now say 3650 days.
- **Deploy script:** its token check stays `code.length > 0`; the contract's `balanceOf` probe now refuses the same inputs at deploy, so the script check is a fast pre-flight, not the defence.
- **Test count:** the README now states 47. The review counted 43 against a suite that `forge test` reports as 39.

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

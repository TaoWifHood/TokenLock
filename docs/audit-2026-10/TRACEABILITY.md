# Every review finding → its disposition → the tests that pin it

Each row names the tests that fail if the finding came back. For every code fix this is checked, not
asserted: `npm run mutations` (`scripts/audit-mutations.mjs`) undoes the fix in a scratch copy of the source and
requires each test listed in its "undone" column to fail there, after the same tests pass on the real source.
Accepted and environmental findings are pinned by a test of the documented behaviour where one is possible.
The deployment-side checks run in `npm run rehearse` (`scripts/rehearse-deploy.mjs`), on a local anvil chain.

Test files: `T` = `test/TokenLock.t.sol`, `C` = `test/TokenLockConstructor.t.sol`, `I` = `test/TokenLockInvariant.t.sol`,
`E` = `test/ExtendBoundReadings.t.sol`, `D` = `test/DeployTokenLock.t.sol` (runs the real deploy script).

## Fixed in code

| Finding | Sev. | Claim | Disposition | Pinned by | Fix undone → caught by |
|---|---|---|---|---|---|
| VULN-011, VULN-012, VULN-013 | M / L / I | `extend` had no cumulative bound: repeated extensions, or a re-lock after expiry, could push the unlock out without limit | `maxUnlockTime` fixed at deployment; `extend` never passes it | T `test_constructor_setsTheCeilingAtDeploy`, `test_extend_toTheCeiling_succeeds_andOneSecondMore_reverts`, `test_extend_repeatedStepsStopAtTheCeiling`, `test_extend_afterExpiry_relockIsBoundedByTheCeiling`, `testFuzz_extendNeverShortens`; I `invariant_unlockNeverPassesTheCeiling` | ceiling relative to now → 2 tests; no ceiling → 3 tests |
| VULN-003 (FIX-3) | L | the token as beneficiary seals every exit | constructor refuses it (`BeneficiaryIsToken`) | T `test_constructor_rejectsTheTokenAsBeneficiary`; D `test_preflight_refusesTheTokenAsBeneficiary`; rehearsal: constructor refusal on the node | 1 test |
| VULN-021 (FIX-4) | L | `sweep(beneficiary)` calls into the beneficiary, which can re-enter | `sweep` refuses the beneficiary (`NotSweepable`) on every call | T `test_sweep_beneficiaryOrSelfAsToken_reverts`, `test_sweep_beneficiaryThatGainsCodeLater_isStillRefused` | 2 tests |
| VULN-025 (FIX-4) | I | a beneficiary codeless at deployment can gain code later, so only a runtime check holds | the check is in `sweep`, not the constructor | T `test_sweep_beneficiaryThatGainsCodeLater_isStillRefused` (etches token-like, re-entering code onto the beneficiary after deployment; asserts no call is made) | with VULN-021 |
| VULN-026 (FIX-4) | I | `sweep(lock)` calls the lock itself | `sweep` refuses the lock (`NotSweepable`) | T `test_sweep_beneficiaryOrSelfAsToken_reverts` | 1 test |
| VULN-033 | M | the same lock address on another chain is a different lock | `deployChainId` immutable; every action reverts `WrongChain` elsewhere | T `test_everyAction_onAnotherChain_reverts`; D `test_preflight_onAnotherChain_refuses`, `test_run_onAnotherChain_refuses`, `test_postflight_refusesALockBoundToAnotherChain`; rehearsal: script refuses a wrong `LOCK_CHAIN_ID`, verifier `--chain-id` | 1 test |
| VULN-001 (FIX-2a) | M | code alone is not a token: a 7702-delegated wallet or a stub has code | constructor requires a one-word `balanceOf` answer | C `test_constructorRefusesA7702DesignatedWallet`, `test_constructorRefusesAStopStub`, `test_constructorRefusesACodelessToken`; rehearsal: a contract that does not answer `balanceOf` is refused on the node | 2 tests |
| VULN-001 follow-up, VULN-101, VULN-122, DELTA-4, VULN-107 (gas-sink leg) | M | the first VULN-001 change replaced the code check; a precompile answers with a word, its code hash flips from 0 on 1 wei (bricking `withdraw`), and modexp/bn254/blake2f burn all forwarded gas | `code.length == 0` refused again, before any call | C `test_constructorRefusesTheSha256Precompile`, `test_constructorRefusesTheRipemd160Precompile`, `test_constructorRefusesTheIdentityPrecompile`, `test_constructorRefusesAPrecompileBeforeAndAfterItHoldsEther`, `test_constructorRefusesEveryPrecompileByNameWithoutCallingIt` (0x01–0x0a, gas-bounded); T `test_withdraw_oneWeiSentToTheToken_changesNothing` | 5 tests; the gas bound alone also catches it: the constructor's probe of modexp (0x05) burns 1,040,452,502 gas |
| VULN-137 | — | the code pin was checked after the time gate, so a broken lock looked healthy until unlock | pin checked first | T `test_withdraw_tokenCodeChanged_beforeUnlock_reportsTheChange` | 1 test |
| VULN-004 | I | `sweep` on a codeless address reverted with empty data or burned all gas | `sweep` refuses no-code addresses by name, before any call | T `test_sweep_addressWithoutCode_revertsNotAContract`, `test_sweep_everyAddressWithoutCode_revertsNotAContractWithoutCallingIt` (zero address, 0x01–0x0a, an EOA; gas-bounded) | 2 tests |
| VULN-002 (FIX-2b) | L | events reported the requested amount, not what arrived | delivery measured on the beneficiary's balance; zero delivered for a non-zero request reverts `NothingDelivered` | T `test_withdraw_feeOnTransfer_reportsWhatArrived`, `test_withdraw_feeOnTransfer_excludedLock_deliversInFull`, `test_withdraw_fullTax_revertsAndKeepsTheBalance`, `test_withdraw_phantomTransfer_reverts`, `test_withdraw_zero_isAllowedAndReportsZero`, `test_sweep_feeOnTransferReward_returnsWhatArrived`, `test_sweep_phantomTransfer_reverts`, `test_beneficiaryThatForwardsOnReceipt_cannotWithdraw` | reported = requested → 5 tests; no `NothingDelivered` → 4 tests |
| VULN-031 | M | pre-Cancun, the token's code can be replaced at the same address | `tokenCodehash` pinned; `withdraw` reverts `TokenCodeChanged` | T `test_constructor_pinsTheTokenCodehash`, `test_withdraw_tokenCodeChanged_reverts`; rehearsal: verifier reports a replaced token (control) | 2 tests |
| VULN-017 | I | a log-only reader could not learn a lock's starting terms | constructor emits `Locked` | T `test_constructor_emitsTheStartingTerms`; D `test_run_deploysTheEnvTerms_andTheLockWorksEndToEnd`; rehearsal: `Locked` in the deployment receipt | 2 tests |
| DOC-1 | — | the stated reason for no reentrancy guard was false | header rewritten | T `test_reentrantTokenCannotCallBack` | — (documentation) |
| DOC-2, VULN-022 | — / L | `msg.sender == beneficiary` is identity, not authorisation; no code fix is possible | documented: the beneficiary must authorise its callers | T `test_openRelayBeneficiary_letsAnyoneActThroughIt` pins the documented consequence | — (documented behaviour) |
| DOC-3 | — | a threshold choice does not limit `extend` | README: the ceiling, not the threshold, bounds the delay; use 2-of-3 | T `test_extend_toTheCeiling_succeeds_andOneSecondMore_reverts`, `test_extend_afterExpiry_relockIsBoundedByTheCeiling`; the rehearsal deploys to a 2-of-3 Safe | — (documented behaviour) |

## Not adopted as proposed

| Finding | Sev. | Disposition | Pinned by |
|---|---|---|---|
| FIX-1's one-line form | — | wrong under either reading; replaced by the deployment-anchored ceiling | E `test_replacement_stacksWithoutLimitInOneBlock`, `testFuzz_addition_neverBindsOnALiveLock`, `test_addition_relocksAnExpiredLockNearlyFully`, `testFuzz_shipped_neverPassesTheCeiling` |
| VULN-015 (`MIN_LOCK_DURATION`) | I | not adopted: a short lock fails safe; the deploy script keeps a 2 h floor | C `test_constructorAcceptsAOneSecondLock`; T `test_extend_afterExpiry_acceptsAOneSecondRelock`; D `test_preflight_refusesAnUnlockWithinTwoHours_andAcceptsExactlyTwo`, `test_preflight_refusesAnUnlockInThePast`; rehearsal: script refusals |

## Accepted and environmental

| Finding | Sev. | Disposition | Pinned by |
|---|---|---|---|
| VULN-016 | L | inherent: the locked token can never be swept, even to return a misdirected payment | T `test_sweep_lockedToken_reverts`, `test_sweep_lockedToken_revertsAfterUnlockToo`, `test_withdraw_tokenArrivingLaterIsLockedToo`, `test_topUp_fromAStranger_isLockedAndBelongsToTheBeneficiary` |
| VULN-037 | I | `bytecode_hash = "none"` kept; verification goes through the standard JSON input | rehearsal: the standard input's sources are byte-identical to `src/` and `node_modules/`, its settings equal `foundry.toml`, and solc 0.8.26 reproduces forge's creation and runtime bytecode and the deployed bytecode |
| VULN-035 | I | environmental: a clock moved back (a reorg) closes an open lock again | T `test_withdraw_isNotLatched_aClockThatMovesBackClosesTheLockAgain` |
| VULN-040 | I | environmental: a rollup's upgrade authority can rewrite any account | not testable in code |
| Q1 (pre-Cancun chains) | — | deployment rule: only chains with EIP-6780; the code pin backs it | README checklist step; VULN-031 tests |
| Q2 (one chain per lock) | — | deployment rule, backed by `deployChainId` | VULN-033 tests |
| "Act on this now" | — | deployment rules: fund no lock built from the reviewed source; 2-of-3 or better | README checklist; the deploy script accepts any threshold ≥ 1, so the 2-of-3 rule is the operator's to keep |

## Properties the review verified

| Property | Pinned by |
|---|---|
| only the beneficiary can act, at any time | T `testFuzz_strangerTakesNothing`, `test_withdraw_stranger_revertsEvenAfterUnlock`, `test_sweep_stranger_reverts`, `test_extend_stranger_reverts`; I `invariant_strangerNeverSucceeds` |
| `unlockTime` never decreases | T `test_extend_sameOrEarlier_reverts`, `testFuzz_extendToAnEarlierFutureTimeIsRefused`; I `invariant_unlockNeverShortened` |
| no fallback, no `receive`, no payable function | T `test_unknownSelector_reverts`, `test_plainEthSend_reverts` |
| `sweep` cannot be aliased onto the locked token | T `test_sweep_dirtyAddressBits_revert`, `test_sweep_lockedToken_reverts`, the VULN-004 sweep tests |
| runs on chains without the newer forks (`paris`) | rehearsal: no PUSH0, MCOPY, TLOAD, TSTORE, SELFDESTRUCT, DELEGATECALL, CALLCODE, CREATE or CREATE2 in creation or runtime; the same source built for cancun contains PUSH0 and fails the verifier |

# TokenLock

A single-purpose ERC-20 time lock for any EVM chain. One contract, 132 lines: no owner, no admin, no proxy, no
upgrade, no ETH path. Each lock is bound to the chain it was deployed on; no chain-specific opcode is used
(compiled for `paris`).

**Security review:** an external review of `src/TokenLock.sol` at sha256
`ff3366fabb6c0aac8c2c78f64c76446cefe7ea8a3bc1f96fb1b161c45f4f242d` was delivered to the owner; the response to
every finding is [`docs/audit-2026-10/RESPONSE.md`](docs/audit-2026-10/RESPONSE.md). The current source (sha256
`4bc9d4f0d2da44848bb878dfe6fac7993e6d6c5ff1b04a76e0e846407796cfb4`) applies those fixes; the changed lines await
the reviewer's delta check.
**Out of scope:** OpenZeppelin `SafeERC20`/`IERC20` (v5.6.1, unmodified, from npm), the deploy script, the tests.

## What it does
Each lock is created for ONE token, ONE beneficiary and ONE unlock time. `token`, `beneficiary`, `maxUnlockTime`
(deployment time + 3650 days), `deployChainId` and `tokenCodehash` are `immutable`. The constructor emits `Locked`
with the starting terms.

| function | who | when | effect |
|---|---|---|---|
| `withdraw(uint256 amount)` | beneficiary | `block.timestamp >= unlockTime` | sends `amount` of the locked token to the beneficiary; reverts `TokenCodeChanged` if the code at `token` differs from deployment, checked before the time gate, so it is reported while still locked |
| `sweep(IERC20 otherToken)` | beneficiary | any time | sends the lock's whole balance of any token **other than** the locked one; `sweep(token)` reverts `LockedToken`; the beneficiary or the lock itself as `otherToken` reverts `NotSweepable`; an address with no code reverts `NotAContract` |
| `extend(uint256 newUnlockTime)` | beneficiary | any time | moves the unlock strictly later (and into the future), never past `maxUnlockTime`; re-locks an expired lock within that ceiling |

Every function above reverts `WrongChain` on any chain other than `deployChainId`.

`Withdrawn` and `Swept` report what the beneficiary's balance rose by, measured, not what was requested: with a
fee-on-transfer token the event shows the smaller amount that arrived. A non-zero transfer that delivers nothing
(a 100% tax, or a `transfer` that returns true without moving anything) reverts `NothingDelivered`, and the tokens
stay in the lock.

Why `sweep` exists: a locked token may earn reward payouts in other tokens that arrive at the lock's address
unsolicited (holder distributions, airdrops). They stay collectable without touching the locked balance.

The constructor refuses a zero token or beneficiary, a token with no code or that does not answer `balanceOf` (`NotAContract`), the lock as
its own beneficiary (`BeneficiaryIsLock`), the token as beneficiary (`BeneficiaryIsToken`), and an unlock time in
the past or more than 3650 days ahead.

## Questions for the delta review
1. Does `maxUnlockTime` bound `unlockTime` for the life of the lock under every sequence of `extend` calls?
2. Can the `NotSweepable` and `WrongChain` checks be bypassed, or brick a legitimate `withdraw`/`sweep`?
3. Is the reason given in the header for needing no reentrancy guard now complete and true?
4. Can the constructor's `balanceOf` probe refuse a working ERC-20, or accept something that is not one in a way that matters?
5. `_deliver` reads the beneficiary's balance after the transfer: is the header's reentrancy reason still complete, and can the measurement be made to over- or under-report?
6. Can the `tokenCodehash` pin refuse a `withdraw` of a token that was live and unchanged at deployment?

## Known and accepted (please confirm, not re-report)
- `block.timestamp` can run ahead of wall-clock time on some chains (L2 sequencers), so a lock can open that much "early". The deploy script refuses an unlock closer than 2 h.
- ETH force-sent to the lock (selfdestruct / coinbase) is permanently lost — there is no ETH path in or out.
- The lock guarantees TIME, not QUORUM: whoever controls the beneficiary controls everything after unlock, and all other tokens at any time. Use a multisig with the threshold you actually want, and one that survives a lost key (2-of-3, not 2-of-2).
- The beneficiary can also `extend`, before or after unlock, up to `maxUnlockTime`. A threshold choice does not limit that; the ceiling does. A compromised beneficiary that steals nothing can still delay withdrawal until `maxUnlockTime`.
- `msg.sender == beneficiary` is an identity check. The beneficiary must authorise its own callers (a Safe); a multicall, batcher or open relay as beneficiary lets anyone act for it.
- The beneficiary must keep what it receives during the call: delivery is measured on its balance, so a beneficiary that forwards tokens on receipt measures nothing and reverts `NothingDelivered`.
- Deploy only to chains where EIP-6780 is active (post-Cancun), so the token's code cannot be replaced at the same address. Check the target chain's fork level before deploying. `tokenCodehash` makes `withdraw` refuse if it ever is.
- Locking an UPGRADEABLE token (or one reachable through more than one address) would make the `sweep(token)` refusal worthless. Lock only a fixed, non-upgradeable token.
- A fee-on-transfer token takes its fee on the way in and on every `withdraw` unless the lock is on the token's fee exclusion list: add the lock's address before funding it. A token whose owner can raise the fee or remove that exclusion bounds what the lock can return, and the lock cannot defend against it; lock such a token only if its fee is capped and the exclusion cannot be revoked.
- Any token other than the locked one is never "locked" here — it is sweepable at any time, by design.

## Static-analysis output you will see (`forge lint src/TokenLock.sol`)
Zero compiler errors or solc warnings. The Foundry linter reports, on the in-scope file only:
- `block-timestamp` ×4 (the constructor, `withdraw`, `extend`) — inherent to a TIME lock; the clock skew is the accepted item above.
- `low-level-calls` ×1 — the constructor's `balanceOf` probe, a `staticcall` so a non-token cannot revert with its own data or change state.
- `screaming-snake-case-immutable` ×5 (`token`, `beneficiary`, `maxUnlockTime`, `deployChainId`, `tokenCodehash`) and `unwrapped-modifier-logic` ×1 — style notes, deliberately not applied so the getters keep the names existing tools and the Safe guide call.

Every other lint line in a full `forge build` comes from the test files and mocks.

## Reproduce
```
npm install            # pinned: @openzeppelin/contracts 5.6.1, forge-std v1.16.2
forge build            # solc 0.8.26, evm paris, optimizer 200 runs, bytecode_hash none
forge test             # 65 tests: unit + constructor + stateful invariant fuzz + the review's extend-bound readings
RPC_URL=<rpc> node scripts/verify-deployed.mjs <lock-address>   # a deployed lock's runtime vs this source (build the commit it was deployed from)
```

## Deploy
`script/DeployTokenLock.s.sol` refuses a wrong chain, a token with no code, a beneficiary that does not answer
like a Safe or that is the token, and an unlock time that is too close or too far, all in simulation before anything
is broadcast.
See the usage block at the top of the script.

## Documents
- `docs/audit-2026-10/RESPONSE.md` — the response to each finding of the external review.
- `docs/SAFE-TX-BUILDER-GUIDE.md` — operating a lock from a Safe's Transaction Builder.
- `docs/TokenLock.abi.json` — ABI.
- `docs/TokenLock.standard-input.json` — Solidity standard JSON input for explorer verification.

## License
MIT

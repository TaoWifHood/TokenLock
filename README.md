# TokenLock

A single-purpose ERC-20 time lock for any EVM chain. One contract, 84 lines: no owner, no admin, no proxy, no
upgrade, no ETH path. The contract has no chain id check and no chain-specific opcode (compiled for `paris`).

**Audit scope:** `src/TokenLock.sol` only — sha256 `ff3366fabb6c0aac8c2c78f64c76446cefe7ea8a3bc1f96fb1b161c45f4f242d`.
**Out of scope:** OpenZeppelin `SafeERC20`/`IERC20` (v5.6.1, unmodified, from npm), the deploy script, the tests.

## What it does
Each lock is created for ONE token, ONE beneficiary and ONE unlock time. `token` and `beneficiary` are `immutable`.

| function | who | when | effect |
|---|---|---|---|
| `withdraw(uint256 amount)` | beneficiary | `block.timestamp >= unlockTime` | sends `amount` of the locked token to the beneficiary |
| `sweep(IERC20 otherToken)` | beneficiary | any time | sends the lock's whole balance of any token **other than** the locked one; `sweep(token)` reverts `LockedToken` |
| `extend(uint256 newUnlockTime)` | beneficiary | any time | moves the unlock strictly later (and into the future); max 3650 days ahead; re-locks an expired lock |

Why `sweep` exists: a locked token may earn reward payouts in other tokens that arrive at the lock's address
unsolicited (holder distributions, airdrops). They stay collectable without touching the locked balance.

The constructor refuses a zero token or beneficiary, a token address with no code (`NotAContract`), the lock as
its own beneficiary (`BeneficiaryIsLock`), and an unlock time in the past or more than 3650 days ahead.

## Questions we most want answered
1. Can anyone other than the beneficiary ever move the locked token, or move it before `unlockTime`?
2. Can `sweep` ever release the locked token (aliasing, proxies, a token with two addresses, rebasing)?
3. Can `extend` ever shorten a lock, or brick `withdraw`?
4. There is no reentrancy guard by design (every state-changer is `onlyBeneficiary`). Is that sound against a malicious `otherToken` in `sweep`?
5. Is there any way to strand the locked token permanently, other than the documented ones below?

## Known and accepted (please confirm, not re-report)
- `block.timestamp` can run ahead of wall-clock time on some chains (L2 sequencers), so a lock can open that much "early". The deploy script refuses an unlock closer than 2 h.
- ETH force-sent to the lock (selfdestruct / coinbase) is permanently lost — there is no ETH path in or out.
- The lock guarantees TIME, not QUORUM: whoever controls the beneficiary controls everything after unlock, and all other tokens at any time. Use a multisig with the threshold you actually want.
- Locking an UPGRADEABLE token (or one reachable through more than one address) would make the `sweep(token)` refusal worthless. Lock only a fixed, non-upgradeable token.
- Any token other than the locked one is never "locked" here — it is sweepable at any time, by design.

## Static-analysis output you will see (`forge lint src/TokenLock.sol`)
Zero compiler errors or solc warnings. The Foundry linter reports, on the in-scope file only:
- `block-timestamp` ×5 (the constructor, `withdraw`, `extend`) — inherent to a TIME lock; the clock skew is the accepted item above.
- `screaming-snake-case-immutable` ×2 (`token`, `beneficiary`) and `unwrapped-modifier-logic` ×1 — style notes, deliberately not applied so already-deployed bytecode keeps matching this source.

Every other lint line in a full `forge build` comes from the test files and mocks.

## Reproduce
```
npm install            # pinned: @openzeppelin/contracts 5.6.1, forge-std v1.16.2
forge build            # solc 0.8.26, evm paris, optimizer 200 runs, bytecode_hash none
forge test             # 39 tests: unit + constructor + stateful invariant fuzz
RPC_URL=<rpc> node scripts/verify-deployed.mjs <lock-address>   # a deployed lock's runtime vs this source
```

## Deploy
`script/DeployTokenLock.s.sol` refuses a wrong chain, a token with no code, a beneficiary that does not answer
like a Safe, and an unlock time that is too close or too far, all in simulation before anything is broadcast.
See the usage block at the top of the script.

## Documents
- `docs/SAFE-TX-BUILDER-GUIDE.md` — operating a lock from a Safe's Transaction Builder.
- `docs/TokenLock.abi.json` — ABI.
- `docs/TokenLock.standard-input.json` — Solidity standard JSON input for explorer verification.

## License
MIT

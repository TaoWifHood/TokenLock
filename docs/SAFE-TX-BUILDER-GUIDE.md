# Operating a TokenLock from a Safe's Transaction Builder

Exact inputs for the three functions when the beneficiary is a Safe. Produce every number with `cast`
(selectors, wei amounts, calldata) and paste it — do not retype.

## 0. What you need open
- The Safe that is the lock's beneficiary. Read its signers before funding: `cast call <SAFE> 'getOwners()(address[])'`
  and `'getThreshold()(uint256)'`. One signer means one key controls the lock; add signers before the real amount goes in.
- Safe app → **Apps → Transaction Builder**.
- The lock's address, with its source verified on the chain's explorer (or checked with `scripts/verify-deployed.mjs`).
- The ABI: paste the contents of `docs/TokenLock.abi.json` into the builder's ABI box. The method dropdown then
  shows `withdraw`, `sweep`, `extend`.

**In every transaction below: "To" = the lock address · "ETH value" = `0`.** The lock cannot receive ETH; a non-zero value reverts.

## 1. The format rules
| field type | write it as | never |
|---|---|---|
| `uint256` amount | a plain integer in the token's smallest unit (amount × 10^decimals), digits only | decimals (`5.5`), commas, spaces, quotes, `5e21` |
| `uint256` time | **unix SECONDS**, 10 digits today | milliseconds (13 digits), a date string |
| `address` | full checksummed `0x…` 42 characters | an ENS name, a shortened address |

Amounts for an 18-decimal token: `cast to-wei <amount> ether` (e.g. 1 → `1000000000000000000`).
Dates → seconds: `date -u -d '2027-03-20 21:00' +%s`; check one back with `date -u -d @<seconds>`.

## 2. The three functions

### `extend(uint256 newUnlockTime)` — selector `0x9714378c` — any time
- **Input:** `newUnlockTime` = unix seconds.
- **Must hold, or it reverts `BadUnlockTime`:** strictly LATER than the current `unlockTime` · later than the chain's clock · at most `maxUnlockTime()` (the deployment time + 3650 days, fixed for the life of the lock).
- ⚠ On some chains `block.timestamp` runs ahead of your wall clock. Read it: `cast block latest --field timestamp --rpc-url $R`.
- It also RE-LOCKS an expired lock — extending after the unlock date passed locks the tokens again, up to `maxUnlockTime()` and never past it. There is no undo: it can only ever move later.
- A millisecond timestamp fails safely (it is past `maxUnlockTime()` → `BadUnlockTime`).
- Calldata: `cast calldata 'extend(uint256)' <seconds>`.

### `sweep(address otherToken)` — selector `0x01681a62` — any time
- **Input:** the TOKEN ADDRESS to collect — **not an amount**.
- Sends the lock's WHOLE balance of that token to the beneficiary. Balance 0 → succeeds and moves 0 (harmless, costs gas).
- Passing the locked token's address reverts `LockedToken` — by design, sweep can never touch the locked token. (Use this as a safety test: simulate `sweep(<locked token>)` and watch it fail.)
- Passing the Safe's own address or the lock's address reverts `NotSweepable`; an address with no code (a wallet) reverts `NotAContract`.
- The `Swept` event and the return value are what actually arrived in the Safe (less than the lock's balance for a fee-on-transfer token).
- Calldata: `cast calldata 'sweep(address)' <token>`.

### `withdraw(uint256 amount)` — selector `0x2e1a7d4d` — ONLY after `unlockTime`
- **Input:** `amount` in the token's smallest unit. It is NOT "withdraw all" — you name the amount.
- Before the unlock date it reverts `StillLocked(unlockTime)`.
- `amount` greater than the lock's balance reverts (the token transfer fails). Read the exact balance first and paste it:
  `cast call <TOKEN> 'balanceOf(address)(uint256)' <LOCK> --rpc-url $R`.
- The `Withdrawn` event shows what actually arrived in the Safe. With a fee-on-transfer token that is less than `amount` unless the lock is on the token's fee exclusion list; a transfer that delivers nothing reverts `NothingDelivered` and the tokens stay in the lock.
- Calldata: `cast calldata 'withdraw(uint256)' <amount>`.

## 3. Putting tokens in (no function — a plain transfer)
From the Safe's normal **Send** screen: asset = the locked token, recipient = the lock address, amount in normal
units (the Send screen does the decimals). Tokens are locked the moment they arrive, under the lock's current date.

⚠ Send ONLY the lock's own token as the locked asset. Anything else that lands there is sweepable at any time.

⚠ Fee-on-transfer token: put the lock's address on the token's fee exclusion list BEFORE sending, or the fee is taken on the way in and again on every withdraw.

## 4. Read before you sign (free, no signature)
```
R=<rpc url>; LOCK=<lock address>
cast call $LOCK 'token()(address)'       --rpc-url $R   # must be the token you mean to lock
cast call $LOCK 'beneficiary()(address)' --rpc-url $R   # must be your Safe
cast call $LOCK 'unlockTime()(uint256)'  --rpc-url $R   # then: date -u -d @<value>
cast call <TOKEN> 'balanceOf(address)(uint256)' $LOCK --rpc-url $R
cast block latest --field timestamp --rpc-url $R        # the chain's clock
```
`token` and `beneficiary` are immutable — if either is wrong, do not fund the lock; deploy a new one.
`deployChainId()` must equal the chain you are on; on any other chain every action reverts `WrongChain`.

## 5. First use, small first
1. Deploy with `script/DeployTokenLock.s.sol` — dry-run first, `LOCK_EXPECTED_OWNER` set, unlock = chain timestamp + 2 h or more (the script refuses less).
2. Run the §4 reads. Verify the source on the explorer.
3. Send a small test amount. Confirm `balanceOf(lock)`.
4. In the builder, **Simulate** `sweep(<locked token>)` → must fail `LockedToken`. Simulate `withdraw(<test amount>)` → must fail `StillLocked`. Do not sign either.
5. `extend` to the real date → sign → re-read `unlockTime()`.
6. Send the real amount. Re-read the balance.

**Always press Simulate in the Transaction Builder before signing.** A red simulation with one of the contract's error names tells you exactly which rule you hit.

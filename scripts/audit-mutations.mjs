#!/usr/bin/env node
// Proves each fix the security review asked for is pinned by a test: for every entry below, a copy of the
// repo gets src/TokenLock.sol with that one fix undone, and every test named for it must FAIL there. The same
// tests must PASS on the unmodified source first. The repo itself is never modified.
//   npm run mutations
// Exit 0 only if every mutation is caught by every test named for it. Needs forge (PATH or ~/.foundry/bin).
import { spawnSync } from "node:child_process";
import { cpSync, existsSync, mkdtempSync, readFileSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const FORGE = [...(process.env.PATH ?? "").split(":"), join(homedir(), ".foundry", "bin")]
  .map((d) => join(d, "forge")).find((p) => existsSync(p));
if (!FORGE) { console.error("forge not found on PATH or in ~/.foundry/bin"); process.exit(2); }

// finding: the review ids the fix closes · undo: [text in the fixed source, text that undoes the fix] · tests
const MUTATIONS = [
  { finding: "VULN-011, VULN-012, VULN-013", what: "extend's ceiling moves with the clock instead of being fixed at deployment",
    undo: ["newUnlockTime > maxUnlockTime", "newUnlockTime > block.timestamp + MAX_LOCK_DURATION"],
    tests: ["test_extend_afterExpiry_relockIsBoundedByTheCeiling", "test_extend_repeatedStepsStopAtTheCeiling"] },
  { finding: "VULN-011, VULN-012, VULN-013", what: "extend has no ceiling",
    undo: [" || newUnlockTime > maxUnlockTime", ""],
    tests: ["test_extend_toTheCeiling_succeeds_andOneSecondMore_reverts", "test_extend_afterExpiry_relockIsBoundedByTheCeiling", "testFuzz_extendNeverShortens"] },
  { finding: "VULN-003 (FIX-3)", what: "the token is accepted as beneficiary",
    undo: ["        if (beneficiary_ == address(token_)) revert BeneficiaryIsToken();\n", ""],
    tests: ["test_constructor_rejectsTheTokenAsBeneficiary"] },
  { finding: "VULN-021, VULN-025 (FIX-4)", what: "sweep accepts the beneficiary as the token to sweep",
    undo: ["address(otherToken) == beneficiary || ", ""],
    tests: ["test_sweep_beneficiaryOrSelfAsToken_reverts", "test_sweep_beneficiaryThatGainsCodeLater_isStillRefused"] },
  { finding: "VULN-026 (FIX-4)", what: "sweep accepts the lock itself as the token to sweep",
    undo: [" || address(otherToken) == address(this)", ""],
    tests: ["test_sweep_beneficiaryOrSelfAsToken_reverts"] },
  { finding: "VULN-033", what: "beneficiary actions run on any chain",
    undo: ["        if (block.chainid != deployChainId) revert WrongChain(deployChainId, block.chainid);\n", ""],
    tests: ["test_everyAction_onAnotherChain_reverts"] },
  { finding: "VULN-001 (FIX-2a)", what: "the constructor does not require a balanceOf answer",
    undo: ["        if (!ok || ret.length < 32) revert NotAContract();\n", ""],
    tests: ["test_constructorRefusesA7702DesignatedWallet", "test_constructorRefusesAStopStub"] },
  { finding: "VULN-001 follow-up, VULN-101, VULN-122, DELTA-4, VULN-107", what: "the constructor does not require code at the token",
    undo: ["        if (address(token_).code.length == 0) revert NotAContract();\n", ""],
    tests: ["test_constructorRefusesTheSha256Precompile", "test_constructorRefusesTheRipemd160Precompile", "test_constructorRefusesTheIdentityPrecompile",
      "test_constructorRefusesAPrecompileBeforeAndAfterItHoldsEther", "test_constructorRefusesEveryPrecompileByNameWithoutCallingIt"] },
  { finding: "VULN-004", what: "sweep calls an address with no code",
    undo: ["        if (address(otherToken).code.length == 0) revert NotAContract();\n", ""],
    tests: ["test_sweep_addressWithoutCode_revertsNotAContract", "test_sweep_everyAddressWithoutCode_revertsNotAContractWithoutCallingIt"] },
  { finding: "VULN-002 (FIX-2b)", what: "withdraw and sweep report the requested amount, not what arrived",
    undo: ["delivered = balanceAfter > balanceBefore ? balanceAfter - balanceBefore : 0;", "delivered = amount; balanceAfter; balanceBefore;"],
    tests: ["test_withdraw_feeOnTransfer_reportsWhatArrived", "test_sweep_feeOnTransferReward_returnsWhatArrived", "test_withdraw_fullTax_revertsAndKeepsTheBalance",
      "test_withdraw_phantomTransfer_reverts", "test_beneficiaryThatForwardsOnReceipt_cannotWithdraw"] },
  { finding: "VULN-002 (FIX-2b)", what: "a transfer that delivers nothing succeeds",
    undo: ["        if (amount != 0 && delivered == 0) revert NothingDelivered();\n", ""],
    tests: ["test_withdraw_fullTax_revertsAndKeepsTheBalance", "test_withdraw_phantomTransfer_reverts", "test_sweep_phantomTransfer_reverts", "test_beneficiaryThatForwardsOnReceipt_cannotWithdraw"] },
  { finding: "VULN-031", what: "withdraw does not check the token code pin",
    undo: ["        if (current != tokenCodehash) revert TokenCodeChanged(tokenCodehash, current);\n", "        current;\n"],
    tests: ["test_withdraw_tokenCodeChanged_reverts", "test_withdraw_tokenCodeChanged_beforeUnlock_reportsTheChange"] },
  { finding: "VULN-137", what: "withdraw checks the time gate before the token code pin",
    undo: ["        bytes32 current = address(token).codehash;\n        if (current != tokenCodehash) revert TokenCodeChanged(tokenCodehash, current);\n        if (block.timestamp < unlockTime) revert StillLocked(unlockTime);\n",
      "        if (block.timestamp < unlockTime) revert StillLocked(unlockTime);\n        bytes32 current = address(token).codehash;\n        if (current != tokenCodehash) revert TokenCodeChanged(tokenCodehash, current);\n"],
    tests: ["test_withdraw_tokenCodeChanged_beforeUnlock_reportsTheChange"] },
  { finding: "VULN-017", what: "no Locked event at deployment",
    undo: ["        emit Locked(address(token_), beneficiary_, unlockTime_, ceiling);\n", ""],
    tests: ["test_constructor_emitsTheStartingTerms", "test_run_deploysTheEnvTerms_andTheLockWorksEndToEnd"] },
  { finding: "core", what: "the constructor accepts an unlock time in the past",
    undo: ["unlockTime_ <= block.timestamp ||", "unlockTime_ == block.timestamp ||"],
    tests: ["test_constructor_rejectsNowOrPast"] },
  { finding: "core", what: "the constructor accepts an unlock beyond 3650 days",
    undo: [" || unlockTime_ > ceiling", ""],
    tests: ["test_constructor_acceptsExactlyMaxDuration", "test_constructor_rejectsMillisecondTypo"] },
  { finding: "core", what: "the constructor accepts the lock as its own beneficiary",
    undo: ["        if (beneficiary_ == address(this)) revert BeneficiaryIsLock();\n", ""],
    tests: ["test_constructorRefusesItselfAsBeneficiary"] },
  { finding: "core", what: "extend accepts an earlier unlock time",
    undo: ["newUnlockTime <= unlockTime || ", ""],
    tests: ["test_extend_sameOrEarlier_reverts", "testFuzz_extendToAnEarlierFutureTimeIsRefused", "invariant_unlockNeverShortened"] },
  { finding: "core", what: "extend accepts a time already passed",
    undo: ["newUnlockTime <= block.timestamp || ", ""],
    tests: ["test_extend_afterExpiry_toAPastTime_reverts"] },
  { finding: "core", what: "withdraw has no time gate",
    undo: ["        if (block.timestamp < unlockTime) revert StillLocked(unlockTime);\n", ""],
    tests: ["test_withdraw_beforeUnlock_reverts", "test_withdraw_oneSecondBeforeUnlock_reverts"] },
  { finding: "core", what: "anyone can call",
    undo: ["        if (msg.sender != beneficiary) revert NotBeneficiary();\n", ""],
    tests: ["test_withdraw_stranger_revertsEvenAfterUnlock", "test_sweep_stranger_reverts", "test_extend_stranger_reverts", "testFuzz_strangerTakesNothing"] },
  { finding: "core", what: "sweep accepts the locked token",
    undo: ["        if (otherToken == token) revert LockedToken();\n", ""],
    tests: ["test_sweep_lockedToken_reverts", "test_sweep_lockedToken_revertsAfterUnlockToo", "test_withdraw_tokenArrivingLaterIsLockedToo"] },
];

const work = mkdtempSync(join(tmpdir(), "tokenlock-mutations-"));
for (const p of ["src", "test", "script", "foundry.toml", "remappings.txt"]) cpSync(join(root, p), join(work, p), { recursive: true });
symlinkSync(realpathSync(join(root, "node_modules")), join(work, "node_modules"));
const srcPath = join(work, "src/TokenLock.sol");
const original = readFileSync(srcPath, "utf8");

function runTests(tests) {
  const r = spawnSync(FORGE, ["test", "--force", "--json", "--match-test", `^(${tests.join("|")})\\(`], { cwd: work, encoding: "utf8", maxBuffer: 256 * 1024 * 1024 });
  const start = r.stdout.indexOf("{");
  if (start < 0) return { error: (r.stdout + r.stderr).slice(-1500) };
  const status = {};
  for (const suite of Object.values(JSON.parse(r.stdout.slice(start)))) {
    for (const [name, res] of Object.entries(suite.test_results)) status[name.replace(/\(.*$/, "")] = res.status;
  }
  return { status };
}

let failures = 0;
try {
  const allTests = [...new Set(MUTATIONS.flatMap((m) => m.tests))];
  const base = runTests(allTests);
  const baseOk = !base.error && allTests.every((t) => base.status[t] === "Success");
  console.log(`${baseOk ? "PASS" : "FAIL"}  control: all ${allTests.length} named tests exist and pass on the unmodified source`);
  if (!baseOk) {
    console.log(base.error ?? allTests.filter((t) => base.status[t] !== "Success").map((t) => `      ${t}: ${base.status[t] ?? "not found"}`).join("\n"));
    process.exit(1);
  }
  for (const m of MUTATIONS) {
    const [from, to] = m.undo;
    const count = original.split(from).length - 1;
    if (count !== 1) { failures++; console.log(`FAIL  [${m.finding}] ${m.what}: the fixed text occurs ${count} times, expected once`); continue; }
    writeFileSync(srcPath, original.replace(from, to));
    const r = runTests(m.tests);
    const caught = !r.error && m.tests.every((t) => r.status[t] === "Failure");
    if (!caught) failures++;
    console.log(`${caught ? "PASS" : "FAIL"}  [${m.finding}] ${m.what}: ${r.error ? `did not run: ${r.error}` : m.tests.map((t) => `${t} ${r.status[t] === "Failure" ? "fails" : `does NOT fail (${r.status[t] ?? "not found"})`}`).join(", ")}`);
  }
} finally {
  rmSync(work, { recursive: true, force: true });
}
console.log(`\n${MUTATIONS.length - failures}/${MUTATIONS.length} undone fixes caught by every test named for them.`);
process.exit(failures ? 1 : 0);

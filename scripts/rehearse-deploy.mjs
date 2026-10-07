#!/usr/bin/env node
// A fresh-deployment rehearsal on a throwaway local anvil chain. Nothing here can reach a public chain: it
// starts its own anvil on 127.0.0.1, refuses any chain id but 31337, and sends only from anvil's unlocked
// dev accounts (no private key is read or passed).
//   npm run rehearse            # build, full test suite, then every step below
//   npm run rehearse -- --skip-tests
// Steps: the deploy script's refusals in simulation · the constructor's refusals on the node · the real
// deploy through the script · verify-deployed.mjs on it, and on wrong deployments · the standard JSON input
// reproduces forge's bytecode and the deployed bytecode · opcode portability · a full lifecycle.
// Exit 0 only if every check passes. Needs forge, anvil and cast (PATH or ~/.foundry/bin) and solc 0.8.26
// (SOLC=<path>, else the svm install forge uses).
import { spawn, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, readFileSync } from "node:fs";
import { createServer } from "node:net";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const skipTests = process.argv.includes("--skip-tests");
const results = [];
let anvil;

const tool = (name) => {
  for (const dir of [...(process.env.PATH ?? "").split(":"), join(homedir(), ".foundry", "bin")]) {
    if (dir && existsSync(join(dir, name))) return join(dir, name);
  }
  throw new Error(`${name} not found on PATH or in ~/.foundry/bin`);
};
const FORGE = tool("forge"), ANVIL = tool("anvil"), CAST = tool("cast");
const SOLC = process.env.SOLC
  ?? [join(homedir(), ".local/share/svm/0.8.26/solc-0.8.26"), join(homedir(), ".svm/0.8.26/solc-0.8.26")].find(existsSync);

const childEnv = (extra = {}) => {
  const env = { ...process.env };
  for (const k of Object.keys(env)) if (/^(LOCK_|ETH_|FOUNDRY_|DAPP_)|PRIVATE_KEY|MNEMONIC/.test(k)) delete env[k];
  return { ...env, ...extra };
};
function run(cmd, args, { env = {}, input } = {}) {
  const r = spawnSync(cmd, args, { cwd: root, env: childEnv(env), input, encoding: "utf8", maxBuffer: 256 * 1024 * 1024 });
  return { code: r.status, out: (r.stdout ?? "") + (r.stderr ?? "") };
}
const cast = (...args) => {
  const r = run(CAST, args);
  if (r.code !== 0) throw new Error(`cast ${args.join(" ")}: ${r.out}`);
  return r.out.trim();
};

function check(ok, name, detail = "") {
  results.push({ ok, name });
  console.log(`${ok ? "PASS" : "FAIL"}  ${name}${detail ? ` — ${detail}` : ""}`);
  return ok;
}
function must(ok, name, detail) {
  if (!check(ok, name, detail)) throw new Error(`stopped: ${name}`);
}

// ── chain access ──────────────────────────────────────────────────────────────
let RPC;
async function rpc(method, params = []) {
  const res = await fetch(RPC, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }) });
  return res.json();
}
async function rpcOk(method, params) {
  const r = await rpc(method, params);
  if (r.error) throw new Error(`${method}: ${JSON.stringify(r.error)}`);
  return r.result;
}
async function send(tx) {
  const hash = await rpcOk("eth_sendTransaction", [tx]);
  let receipt = null;
  for (let i = 0; i < 100 && !receipt; i++) {
    receipt = await rpcOk("eth_getTransactionReceipt", [hash]);
    if (!receipt) await new Promise((r) => setTimeout(r, 50));
  }
  if (!receipt) throw new Error(`no receipt for ${hash}`);
  if (receipt.status !== "0x1") throw new Error(`transaction reverted: ${JSON.stringify(tx).slice(0, 200)}`);
  return receipt;
}
const revertData = (r) => (r.error?.data?.data ?? r.error?.data ?? "").toString().toLowerCase();
const word = (v) => BigInt(v).toString(16).padStart(64, "0");
const addrWord = (a) => a.toLowerCase().replace(/^0x/, "").padStart(64, "0");
const latestTs = async () => BigInt((await rpcOk("eth_getBlockByNumber", ["latest", false])).timestamp);
const balanceOf = async (tokenAddr, who) => BigInt(await rpcOk("eth_call", [{ to: tokenAddr, data: cast("calldata", "balanceOf(address)", who) }, "latest"]));
const artifact = (file, name) => JSON.parse(readFileSync(join(root, "out", file, `${name}.json`), "utf8"));
async function deploy(from, bytecode, argTypes, ...args) {
  const encoded = argTypes ? cast("abi-encode", `f(${argTypes})`, ...args).replace(/^0x/, "") : "";
  const receipt = await send({ from, data: bytecode + encoded, gas: "0x989680" });
  return { address: receipt.contractAddress, receipt };
}

async function freePort() {
  return new Promise((resolve, reject) => {
    const s = createServer();
    s.once("error", reject);
    s.listen(0, "127.0.0.1", () => { const { port } = s.address(); s.close(() => resolve(port)); });
  });
}
async function startAnvil() {
  const port = await freePort();
  RPC = `http://127.0.0.1:${port}`;
  anvil = spawn(ANVIL, ["--host", "127.0.0.1", "--port", String(port), "--chain-id", "31337", "--silent"], { stdio: "ignore" });
  for (let i = 0; i < 100; i++) {
    try { if ((await rpc("eth_chainId")).result) break; } catch {}
    await new Promise((r) => setTimeout(r, 100));
  }
  const id = BigInt(await rpcOk("eth_chainId"));
  must(id === 31337n, "anvil is up on a local throwaway chain", `${RPC}, chain id ${id}`);
}

// ── opcode scan ───────────────────────────────────────────────────────────────
// Walks instructions, skipping PUSH data and the trailing CBOR block, and counts opcodes that a chain
// without the newer forks cannot run, or that would contradict the contract's stated shape.
const FORBIDDEN = { 0x5f: "PUSH0", 0x5e: "MCOPY", 0x5c: "TLOAD", 0x5d: "TSTORE", 0xff: "SELFDESTRUCT", 0xf4: "DELEGATECALL", 0xf2: "CALLCODE", 0xf0: "CREATE", 0xf5: "CREATE2" };
function scanOpcodes(hex) {
  const b = Buffer.from(hex.replace(/^0x/, ""), "hex");
  const cborLen = b.readUInt16BE(b.length - 2);
  const end = b.length - 2 - cborLen;
  const found = {};
  for (let i = 0; i < end; i++) {
    const op = b[i];
    if (op >= 0x60 && op <= 0x7f) { i += op - 0x5f; continue; }
    if (FORBIDDEN[op]) found[FORBIDDEN[op]] = (found[FORBIDDEN[op]] ?? 0) + 1;
  }
  return found;
}

async function main() {
  console.log(`${run(FORGE, ["--version"]).out.split("\n")[0]} · solc ${SOLC ?? "(not found)"}`);
  must(SOLC && run(SOLC, ["--version"]).out.includes("0.8.26"), "solc 0.8.26 available for the standard-input check", SOLC ?? "set SOLC");

  // ── 2a. build and test ──
  const build = run(FORGE, ["build", "--force"]);
  must(build.code === 0, "forge build --force", build.code === 0 ? "" : build.out.slice(-2000));
  if (skipTests) console.log("SKIP  forge test (--skip-tests)");
  else {
    const t = run(FORGE, ["test"]);
    const m = t.out.match(/(\d+) tests passed, (\d+) failed, (\d+) skipped \((\d+) total tests\)/);
    must(t.code === 0 && m && m[2] === "0" && m[3] === "0", "forge test: full suite green", m ? m[0] : t.out.slice(-2000));
  }

  await startAnvil();
  const accounts = await rpcOk("eth_accounts");
  const [deployer, owner1, owner2, owner3, outsider] = accounts;

  // ── mocks ──
  const erc20 = artifact("Mocks.sol", "MockERC20").bytecode.object;
  const safeCode = artifact("Mocks.sol", "MockSafe").bytecode.object;
  const safeTokenCode = artifact("Mocks.sol", "SafeShapedToken").bytecode.object;
  const token = (await deploy(deployer, erc20)).address;
  const reward = (await deploy(deployer, erc20)).address;
  const safe = (await deploy(deployer, safeCode, "address[],uint256", `[${owner1},${owner2},${owner3}]`, "2")).address;
  const otherSafe = (await deploy(deployer, safeCode, "address[],uint256", `[${owner1},${owner2},${owner3}]`, "2")).address;
  const safeToken = (await deploy(deployer, safeTokenCode, "address[],uint256", `[${owner1},${owner2},${owner3}]`, "2")).address;
  console.log(`      token ${token} · reward ${reward} · Safe ${safe} (2 of 3)`);

  const now = await latestTs();
  const unlock = now + 90n * 86400n;
  const env = { LOCK_CHAIN_ID: "31337", LOCK_TOKEN: token, LOCK_BENEFICIARY: safe, LOCK_UNLOCK_TIME: String(unlock), LOCK_EXPECTED_OWNER: owner2 };
  const script = (extraEnv, broadcast) => run(FORGE, [
    "script", "script/DeployTokenLock.s.sol", "--rpc-url", RPC,
    ...(broadcast ? ["--broadcast", "--unlocked", "--sender", deployer] : []),
  ], { env: { ...env, ...extraEnv } });

  // ── 2b. the deploy script refuses each bad input in simulation ──
  const refusals = [
    ["a wrong chain id", { LOCK_CHAIN_ID: "1" }, "unexpected chain id (LOCK_CHAIN_ID)"],
    ["a token with no code", { LOCK_TOKEN: outsider }, "token has no code on this chain"],
    ["a beneficiary with no code", { LOCK_BENEFICIARY: outsider }, "beneficiary has no code on this chain"],
    ["a beneficiary that is not a Safe", { LOCK_BENEFICIARY: reward }, "beneficiary does not answer like a Safe"],
    ["a Safe without the expected owner", { LOCK_EXPECTED_OWNER: outsider }, "LOCK_EXPECTED_OWNER is not an owner of this Safe"],
    ["an unlock within 2 h", { LOCK_UNLOCK_TIME: String(now + 3600n) }, "unlock is in the past or within 2 h"],
    ["an unlock in the past", { LOCK_UNLOCK_TIME: String(now - 1n) }, "unlock is in the past or within 2 h"],
    ["an unlock beyond 3650 days", { LOCK_UNLOCK_TIME: String(now + 3651n * 86400n) }, "unlock beyond 3650 days"],
    ["an unlock in milliseconds", { LOCK_UNLOCK_TIME: String(unlock * 1000n) }, "unlock beyond 3650 days"],
    ["the token as beneficiary", { LOCK_TOKEN: safeToken, LOCK_BENEFICIARY: safeToken }, "beneficiary is the token"],
  ];
  const nonceBefore = await rpcOk("eth_getTransactionCount", [deployer, "latest"]);
  for (const [what, extra, msg] of refusals) {
    const r = script(extra, true);
    check(r.code !== 0 && r.out.includes(msg), `deploy script refuses ${what}`, `"${msg}"`);
  }
  check(await rpcOk("eth_getTransactionCount", [deployer, "latest"]) === nonceBefore, "no refused run broadcast anything", `deployer nonce still ${BigInt(nonceBefore)}`);
  const unset = run(FORGE, ["script", "script/DeployTokenLock.s.sol", "--rpc-url", RPC], { env: { ...env, LOCK_EXPECTED_OWNER: "" } });
  check(unset.code === 0 && unset.out.includes("WARNING: LOCK_EXPECTED_OWNER unset"), "an unset LOCK_EXPECTED_OWNER is warned about, not checked");

  // ── the constructor's own refusals, on the node, for a deploy that bypasses the script ──
  const lockArt = artifact("TokenLock.sol", "TokenLock");
  const creation = lockArt.bytecode.object.replace(/^0x/, "");
  const ctorCases = [
    ["a zero token", "0x0000000000000000000000000000000000000000", safe, unlock, "ZeroAddress()"],
    ["a zero beneficiary", token, "0x0000000000000000000000000000000000000000", unlock, "ZeroAddress()"],
    ["a codeless token (an EOA)", outsider, safe, unlock, "NotAContract()"],
    ["a codeless token (the sha256 precompile)", "0x0000000000000000000000000000000000000002", safe, unlock, "NotAContract()"],
    ["a token with code that does not answer balanceOf", safe, owner1, unlock, "NotAContract()"],
    ["the token as beneficiary", token, token, unlock, "BeneficiaryIsToken()"],
    ["an unlock time in the past", token, safe, now - 1n, "BadUnlockTime()"],
    ["an unlock beyond 3650 days", token, safe, now + 3651n * 86400n, "BadUnlockTime()"],
  ];
  for (const [what, t, b, u, err] of ctorCases) {
    const data = "0x" + creation + addrWord(t) + addrWord(b) + word(u);
    const r = await rpc("eth_call", [{ from: deployer, data, gas: "0x989680" }, "latest"]);
    check(revertData(r).startsWith(cast("sig", err)), `constructor refuses ${what}`, err);
  }

  // ── 2b. the real deploy, through the script ──
  const dep = script({}, true);
  must(dep.code === 0, "deploy script broadcasts the lock", dep.code === 0 ? "" : dep.out.slice(-2000));
  const broadcast = JSON.parse(readFileSync(join(root, "broadcast/DeployTokenLock.s.sol/31337/run-latest.json"), "utf8"));
  const deployTx = broadcast.transactions.find((t) => t.transactionType === "CREATE" && t.contractName === "TokenLock");
  const lock = deployTx.contractAddress;
  must(/^0x[0-9a-fA-F]{40}$/.test(lock ?? "") && dep.out.toLowerCase().includes(lock.toLowerCase()), "the script reports the lock it broadcast", lock);
  const receipt = await rpcOk("eth_getTransactionReceipt", [deployTx.hash]);
  must(receipt.status === "0x1" && receipt.contractAddress.toLowerCase() === lock.toLowerCase(), "the deployment is mined", `block ${BigInt(receipt.blockNumber)}`);
  const deployedAt = BigInt((await rpcOk("eth_getBlockByNumber", [receipt.blockNumber, false])).timestamp);
  const maxUnlock = deployedAt + 3650n * 86400n;

  // ── 2c. verify-deployed.mjs: the right lock passes, a wrong one fails ──
  const verify = (addr, ...flags) => run(process.execPath, ["scripts/verify-deployed.mjs", addr, ...flags], { env: { RPC_URL: RPC } });
  const terms = ["--token", token, "--beneficiary", safe, "--unlock-time", String(unlock), "--chain-id", "31337"];
  const good = verify(lock, ...terms);
  check(good.code === 0 && good.out.includes("MATCH — the deployed runtime is this source.") && good.out.includes("TERMS MATCH"), "verifier: the rehearsed lock matches the source and the intended terms");
  const wrongBen = verify(lock, ...terms.slice(0, 2), "--beneficiary", outsider, ...terms.slice(4));
  check(wrongBen.code === 1 && wrongBen.out.includes("TERMS MISMATCH — beneficiary"), "verifier: refuses the lock against another beneficiary");
  const wrongUnlock = verify(lock, ...terms.slice(0, 4), "--unlock-time", String(unlock + 1n), "--chain-id", "31337");
  check(wrongUnlock.code === 1 && wrongUnlock.out.includes("TERMS MISMATCH — unlockTime"), "verifier: refuses the lock against another unlock time");
  const wrongChain = verify(lock, ...terms.slice(0, 6), "--chain-id", "1");
  check(wrongChain.code === 1 && wrongChain.out.includes("TERMS MISMATCH — deployChainId"), "verifier: refuses the lock against another chain id");

  const wrongDep = script({ LOCK_BENEFICIARY: otherSafe }, true);
  must(wrongDep.code === 0, "a second lock is deployed with the wrong beneficiary (a Safe with the same owners)");
  const wrongLock = JSON.parse(readFileSync(join(root, "broadcast/DeployTokenLock.s.sol/31337/run-latest.json"), "utf8"))
    .transactions.find((t) => t.contractName === "TokenLock").contractAddress;
  const codeOnly = verify(wrongLock);
  check(codeOnly.code === 0 && codeOnly.out.includes("terms NOT checked"), "verifier without terms: the wrong lock's CODE matches, so terms must be passed");
  const wrongLockVerdict = verify(wrongLock, ...terms);
  check(wrongLockVerdict.code === 1 && wrongLockVerdict.out.includes("TERMS MISMATCH — beneficiary"), "verifier with terms: refuses the wrongly deployed lock");

  const input = JSON.parse(readFileSync(join(root, "docs/TokenLock.standard-input.json"), "utf8"));
  const cancunInput = structuredClone(input);
  cancunInput.settings.evmVersion = "cancun";
  const cancun = JSON.parse(run(SOLC, ["--standard-json"], { input: JSON.stringify(cancunInput) }).out).contracts["src/TokenLock.sol"].TokenLock.evm;
  const cancunLock = (await deploy(deployer, "0x" + cancun.bytecode.object, "address,address,uint256", token, safe, String(unlock))).address;
  const cancunVerdict = verify(cancunLock, ...terms);
  check(cancunVerdict.code === 1 && /MISMATCH — \d+ byte\(s\) differ/.test(cancunVerdict.out), "verifier: refuses the same source built for cancun instead of paris", cancunVerdict.out.match(/MISMATCH — [^\n]*/)?.[0]);
  const notALock = verify(token);
  check(notALock.code === 1 && notALock.out.includes("MISMATCH"), "verifier: refuses a contract that is not a lock");
  check(verify("0x000000000000000000000000000000000000dEaD").code === 1, "verifier: refuses an address with no code");

  // ── 2d. reproducibility ──
  const srcEqual = Object.entries(input.sources).every(([path, { content }]) => {
    const onDisk = join(root, path);
    return existsSync(onDisk) && readFileSync(onDisk, "utf8") === content;
  });
  check(srcEqual, "standard input: every embedded source is byte-identical to src/ and node_modules/", `${Object.keys(input.sources).length} files`);
  const toml = readFileSync(join(root, "foundry.toml"), "utf8");
  const tomlVal = (k) => toml.match(new RegExp(`^${k}\\s*=\\s*"?([^"\\n]+)"?`, "m"))?.[1];
  const s = input.settings;
  check(s.evmVersion === tomlVal("evm_version") && s.optimizer.enabled === (tomlVal("optimizer") === "true")
    && String(s.optimizer.runs) === tomlVal("optimizer_runs") && s.metadata.bytecodeHash === tomlVal("bytecode_hash") && s.viaIR === false,
    "standard input: compiler settings equal foundry.toml", `${s.evmVersion}, optimizer ${s.optimizer.runs} runs, bytecodeHash ${s.metadata.bytecodeHash}`);
  const solcOut = JSON.parse(run(SOLC, ["--standard-json"], { input: JSON.stringify(input) }).out);
  const errors = (solcOut.errors ?? []).filter((e) => e.severity === "error");
  must(errors.length === 0, "solc 0.8.26 compiles the standard input", errors.map((e) => e.message).join("; "));
  const solcEvm = solcOut.contracts["src/TokenLock.sol"].TokenLock.evm;
  const forgeCreation = creation.toLowerCase(), forgeRuntime = lockArt.deployedBytecode.object.replace(/^0x/, "").toLowerCase();
  const sha = (hex) => createHash("sha256").update(Buffer.from(hex, "hex")).digest("hex");
  check(solcEvm.bytecode.object === forgeCreation, "creation bytecode: solc standard input == forge out/", `${forgeCreation.length / 2} bytes, sha256 ${sha(forgeCreation)}`);
  check(solcEvm.deployedBytecode.object === forgeRuntime, "runtime bytecode: solc standard input == forge out/", `${forgeRuntime.length / 2} bytes, sha256 ${sha(forgeRuntime)}`);

  const tx = await rpcOk("eth_getTransactionByHash", [deployTx.hash]);
  const ctorArgs = cast("abi-encode", "f(address,address,uint256)", token, safe, String(unlock)).replace(/^0x/, "");
  check(tx.input.toLowerCase() === "0x" + forgeCreation + ctorArgs, "deployed creation input == forge creation bytecode + the ABI-encoded constructor arguments");

  const live = (await rpcOk("eth_getCode", [lock, "latest"])).replace(/^0x/, "").toLowerCase();
  const refs = lockArt.deployedBytecode.immutableReferences;
  const spans = Object.values(refs).flat();
  const inSpan = (byte) => spans.some(({ start, length }) => byte >= start && byte < start + length);
  let outside = 0, inside = 0;
  for (let i = 0; i < live.length / 2; i++) {
    if (live.slice(2 * i, 2 * i + 2) === forgeRuntime.slice(2 * i, 2 * i + 2)) continue;
    if (inSpan(i)) inside++; else outside++;
  }
  check(live.length === forgeRuntime.length && outside === 0, "deployed runtime == forge runtime outside the immutable slots", `${inside} byte(s) differ, all inside ${spans.length} immutable slots`);
  const tokenCodehash = cast("keccak", await rpcOk("eth_getCode", [token, "latest"])).toLowerCase();
  const expectedImmutables = new Map([
    [addrWord(token), "token"], [addrWord(safe), "beneficiary"], [word(maxUnlock), "maxUnlockTime"],
    [word(31337), "deployChainId"], [tokenCodehash.replace(/^0x/, ""), "tokenCodehash"],
  ]);
  const seen = new Map();
  for (const [id, ss] of Object.entries(refs)) {
    const values = new Set(ss.map(({ start, length }) => live.slice(start * 2, (start + length) * 2)));
    const zeroed = ss.every(({ start, length }) => /^0+$/.test(forgeRuntime.slice(start * 2, (start + length) * 2)));
    seen.set(id, values.size === 1 && zeroed ? expectedImmutables.get([...values][0]) : undefined);
  }
  const names = [...seen.values()];
  check(names.every(Boolean) && new Set(names).size === 5 && seen.size === 5,
    "each immutable slot holds exactly one of token, beneficiary, maxUnlockTime, deployChainId, tokenCodehash", names.join(", "));

  // ── portability ──
  const scans = { creation: scanOpcodes(forgeCreation), runtime: scanOpcodes(forgeRuntime), "cancun build": scanOpcodes(cancun.deployedBytecode.object) };
  check(Object.keys(scans.creation).length === 0 && Object.keys(scans.runtime).length === 0,
    "no PUSH0/MCOPY/TLOAD/TSTORE/SELFDESTRUCT/DELEGATECALL/CALLCODE/CREATE/CREATE2 in creation or runtime", JSON.stringify(scans.creation) + " " + JSON.stringify(scans.runtime));
  check((scans["cancun build"].PUSH0 ?? 0) > 0, "control: the same source built for cancun does contain PUSH0", `PUSH0 x${scans["cancun build"].PUSH0 ?? 0}`);

  // ── 2e. lifecycle on the node ──
  const topic = (sig) => cast("keccak", sig).toLowerCase();
  const logsOf = (rcpt, sig) => rcpt.logs.filter((l) => l.address.toLowerCase() === lock.toLowerCase() && l.topics[0].toLowerCase() === topic(sig));
  const lockedLogs = logsOf(receipt, "Locked(address,address,uint256,uint256)");
  check(lockedLogs.length === 1 && lockedLogs[0].topics[1].toLowerCase() === "0x" + addrWord(token) && lockedLogs[0].topics[2].toLowerCase() === "0x" + addrWord(safe)
    && lockedLogs[0].data.toLowerCase() === "0x" + word(unlock) + word(maxUnlock), "Locked(token, beneficiary, unlockTime, maxUnlockTime) emitted at deployment");

  const amount = 1_000_000n * 10n ** 18n;
  await send({ from: deployer, to: token, data: cast("calldata", "mint(address,uint256)", outsider, amount.toString()) });
  await send({ from: outsider, to: token, data: cast("calldata", "transfer(address,uint256)", lock, amount.toString()) });
  check(await balanceOf(token, lock) === amount, "deposit: a plain transfer in is held by the lock", `${amount} wei`);

  await rpcOk("anvil_impersonateAccount", [safe]);
  await rpcOk("anvil_setBalance", [safe, "0xde0b6b3a7640000"]);
  const asSafe = (data) => ({ from: safe, to: lock, data, gas: "0x7a120" });
  const callReverts = async (tx, err, ...args) => revertData(await rpc("eth_call", [tx, "latest"])) === cast("calldata", err, ...args).toLowerCase();

  const later = unlock + 30n * 86400n;
  const ext = await send(asSafe(cast("calldata", "extend(uint256)", later.toString())));
  const extLogs = logsOf(ext, "Extended(uint256,uint256)");
  check(extLogs.length === 1 && extLogs[0].data.toLowerCase() === "0x" + word(unlock) + word(later), "extend: Extended(old, new) emitted and unlockTime moved", `${unlock} -> ${later}`);

  await rpcOk("evm_setNextBlockTimestamp", ["0x" + unlock.toString(16)]);
  await rpcOk("evm_mine");
  check(await callReverts(asSafe(cast("calldata", "withdraw(uint256)", "1")), "StillLocked(uint256)", later.toString()), "withdraw at the old unlock time is refused StillLocked(new unlock)");
  check(await callReverts({ from: outsider, to: lock, data: cast("calldata", "withdraw(uint256)", "1") }, "NotBeneficiary()"), "a stranger's withdraw is refused NotBeneficiary");
  check(await callReverts(asSafe(cast("calldata", "sweep(address)", token)), "LockedToken()"), "sweep of the locked token is refused LockedToken");

  await send({ from: deployer, to: reward, data: cast("calldata", "mint(address,uint256)", lock, "5000") });
  const sw = await send(asSafe(cast("calldata", "sweep(address)", reward)));
  const swLogs = logsOf(sw, "Swept(address,uint256)");
  check(swLogs.length === 1 && swLogs[0].topics[1].toLowerCase() === "0x" + addrWord(reward) && swLogs[0].data.toLowerCase() === "0x" + word(5000)
    && await balanceOf(reward, safe) === 5000n, "sweep of a foreign token while locked: Swept(token, 5000) and the Safe holds it");

  await rpcOk("evm_setNextBlockTimestamp", ["0x" + later.toString(16)]);
  await rpcOk("evm_mine");
  const wd = await send(asSafe(cast("calldata", "withdraw(uint256)", amount.toString())));
  const wdLogs = logsOf(wd, "Withdrawn(uint256)");
  check(wdLogs.length === 1 && wdLogs[0].data.toLowerCase() === "0x" + word(amount) && await balanceOf(token, safe) === amount && await balanceOf(token, lock) === 0n,
    "withdraw at the new unlock time: Withdrawn(all) and the Safe holds the whole balance");
  check(await callReverts(asSafe(cast("calldata", "extend(uint256)", (maxUnlock + 1n).toString())), "BadUnlockTime()"), "extend past maxUnlockTime is refused BadUnlockTime");
  const after = verify(lock, ...terms.slice(0, 4), "--unlock-time", later.toString(), "--chain-id", "31337");
  check(after.code === 0 && after.out.includes("token code pin holds"), "verifier after the lifecycle: code, terms and token pin still hold");
  await rpcOk("anvil_setCode", [token, await rpcOk("eth_getCode", [safe, "latest"])]);
  const replaced = verify(lock, ...terms.slice(0, 4), "--unlock-time", later.toString(), "--chain-id", "31337");
  check(replaced.code === 1 && replaced.out.includes("withdraw reverts TokenCodeChanged"), "control: with other code put at the token's address, the verifier reports the broken pin");
}

try {
  await main();
} catch (e) {
  check(false, "rehearsal ran to the end", e.message);
} finally {
  anvil?.kill();
}
const failed = results.filter((r) => !r.ok).length;
console.log(`\n${results.length - failed}/${results.length} checks passed${failed ? `, ${failed} FAILED` : ""}.`);
process.exit(failed ? 1 : 0);

#!/usr/bin/env node
// Prove a DEPLOYED TokenLock runs exactly this repo's source, and optionally that it holds the intended terms.
//   forge build && RPC_URL=<rpc> node scripts/verify-deployed.mjs <lock-address> \
//     [--token <addr>] [--beneficiary <addr>] [--unlock-time <unix s>] [--chain-id <id>]
// Compares the on-chain runtime with out/TokenLock.sol/TokenLock.json byte for byte, ignoring only the
// immutable slots, and prints what those slots hold. The immutables are masked, so the code match alone
// says nothing about WHICH token, beneficiary or unlock time a lock has: pass the expected terms to have
// them checked through the getters, which the code match has just proven honest. `--unlock-time` is the
// current value, which `extend` can move later than the deployed one. Read-only; no dependencies.
// A lock deployed from an earlier commit must be checked against a build of that commit.
// Exit: 0 match (and every given term holds) · 1 mismatch · 2 usage · 3 RPC unreachable.
import { readFileSync } from "node:fs";

const args = process.argv.slice(2);
const addr = args[0], rpc = process.env.RPC_URL;
const usage = "usage: RPC_URL=<rpc> node scripts/verify-deployed.mjs <lock-address> [--token <addr>] [--beneficiary <addr>] [--unlock-time <unix s>] [--chain-id <id>]";
const flags = {};
for (let i = 1; i < args.length; i += 2) {
  const k = args[i], v = args[i + 1];
  if (!["--token", "--beneficiary", "--unlock-time", "--chain-id"].includes(k) || v === undefined) { console.error(usage); process.exit(2); }
  flags[k.slice(2)] = v;
}
if (!addr || !rpc) { console.error(usage); process.exit(2); }

const art = JSON.parse(readFileSync(new URL("../out/TokenLock.sol/TokenLock.json", import.meta.url), "utf8"));
const local = art.deployedBytecode.object.replace(/^0x/, "").toLowerCase();
const refs = art.deployedBytecode.immutableReferences ?? {}, spans = Object.values(refs).flat();
const headers = { "content-type": "application/json", ...(process.env.RPC_AUTH_BEARER ? { authorization: `Bearer ${process.env.RPC_AUTH_BEARER}` } : {}) };

async function rpcCall(method, params) {
  let res;
  for (let i = 0; ; i++) {
    try { res = await fetch(rpc, { method: "POST", headers, body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }) }); break; }
    catch (e) { if (i >= 2) { console.error(`RPC unreachable after 3 tries: ${e.cause?.code ?? e.message} — this is a network error, NOT a bytecode verdict`); process.exit(3); } }
  }
  return res.json();
}

const live = ((await rpcCall("eth_getCode", [addr, "latest"])).result ?? "0x").replace(/^0x/, "").toLowerCase();
if (!live) { console.error(`no code at ${addr}`); process.exit(1); }
const mask = (s) => { const a = s.split(""); for (const { start, length } of spans) for (let i = start * 2; i < (start + length) * 2; i++) a[i] = "0"; return a.join(""); };
const L = mask(live), M = mask(local); let diff = 0;
for (let i = 0; i < Math.max(L.length, M.length); i += 2) if (L.slice(i, i + 2) !== M.slice(i, i + 2)) diff++;
console.log(`live ${live.length / 2} bytes · local ${local.length / 2} bytes · ${spans.length} immutable slot(s)`);
for (const [id, ss] of Object.entries(refs)) console.log(`  immutable #${id} (${ss.length} refs) = ${[...new Set(ss.map((s) => "0x" + live.slice(s.start * 2 + 24, (s.start + s.length) * 2)))].join(", ")}`);
if (diff !== 0 || live.length !== local.length) { console.log(`MISMATCH — ${diff} byte(s) differ outside the immutable slots.`); process.exit(1); }
console.log("MATCH — the deployed runtime is this source.");

const sel = (sig) => { const s = art.methodIdentifiers[sig]; if (!s) throw new Error(`no selector for ${sig}`); return "0x" + s; };
async function read(sig) {
  const r = await rpcCall("eth_call", [{ to: addr, data: sel(sig) }, "latest"]);
  if (r.error || !r.result || r.result.length !== 66) { console.log(`MISMATCH — ${sig} did not answer with one word`); process.exit(1); }
  return r.result.toLowerCase();
}
const asAddr = (w) => "0x" + w.slice(26);
const terms = {
  token: asAddr(await read("token()")),
  beneficiary: asAddr(await read("beneficiary()")),
  unlockTime: BigInt(await read("unlockTime()")),
  maxUnlockTime: BigInt(await read("maxUnlockTime()")),
  deployChainId: BigInt(await read("deployChainId()")),
  tokenCodehash: await read("tokenCodehash()"),
};
const chainId = BigInt((await rpcCall("eth_chainId", [])).result);
const iso = (s) => new Date(Number(s) * 1000).toISOString();
console.log(`  token          ${terms.token}`);
console.log(`  beneficiary    ${terms.beneficiary}`);
console.log(`  unlockTime     ${terms.unlockTime} (${iso(terms.unlockTime)})`);
console.log(`  maxUnlockTime  ${terms.maxUnlockTime} (${iso(terms.maxUnlockTime)})`);
console.log(`  deployChainId  ${terms.deployChainId} (this RPC: ${chainId})`);
console.log(`  tokenCodehash  ${terms.tokenCodehash}`);

const bad = [];
if (terms.deployChainId !== chainId) bad.push(`deployChainId ${terms.deployChainId} is not this RPC's chain ${chainId}`);
// withdraw(0) from the beneficiary checks the token code pin first; if the code at the token's address changed it
// reverts TokenCodeChanged(deployed, current), recognised by its two-word length and its first word, the pinned hash.
const probe = await rpcCall("eth_call", [{ from: terms.beneficiary, to: addr, data: sel("withdraw(uint256)") + "0".repeat(64) }, "latest"]);
const revertData = (probe.error?.data?.data ?? probe.error?.data ?? "").toString().toLowerCase();
if (revertData.length === 2 + 8 + 128 && "0x" + revertData.slice(10, 74) === terms.tokenCodehash) bad.push("the code at the token's address changed since deployment: withdraw reverts TokenCodeChanged");
else console.log("  token code pin holds (withdraw(0) from the beneficiary does not report TokenCodeChanged)");

const eqAddr = (a, b) => a.toLowerCase() === b.toLowerCase();
if (flags.token !== undefined && !eqAddr(flags.token, terms.token)) bad.push(`token ${terms.token}, expected ${flags.token}`);
if (flags.beneficiary !== undefined && !eqAddr(flags.beneficiary, terms.beneficiary)) bad.push(`beneficiary ${terms.beneficiary}, expected ${flags.beneficiary}`);
if (flags["unlock-time"] !== undefined && BigInt(flags["unlock-time"]) !== terms.unlockTime) bad.push(`unlockTime ${terms.unlockTime}, expected ${flags["unlock-time"]}`);
if (flags["chain-id"] !== undefined && BigInt(flags["chain-id"]) !== terms.deployChainId) bad.push(`deployChainId ${terms.deployChainId}, expected ${flags["chain-id"]}`);
if (bad.length) { for (const b of bad) console.log(`TERMS MISMATCH — ${b}`); process.exit(1); }
const checked = Object.keys(flags);
console.log(checked.length ? `TERMS MATCH — ${checked.join(", ")} as expected.` : "terms NOT checked: pass --token, --beneficiary, --unlock-time and --chain-id to check them.");
process.exit(0);

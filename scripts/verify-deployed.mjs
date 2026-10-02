#!/usr/bin/env node
// Prove a DEPLOYED TokenLock runs exactly this repo's source.
//   forge build && RPC_URL=<rpc> node scripts/verify-deployed.mjs <lock-address>
// Compares the on-chain runtime with out/TokenLock.sol/TokenLock.json byte for byte, ignoring only the
// immutable slots, and prints what those slots hold. Read-only; no dependencies. A lock deployed from an
// earlier commit must be checked against a build of that commit.
import { readFileSync } from "node:fs";
const addr = process.argv[2], rpc = process.env.RPC_URL;
if (!addr || !rpc) { console.error("usage: RPC_URL=<rpc> node scripts/verify-deployed.mjs <lock-address>"); process.exit(2); }
const art = JSON.parse(readFileSync(new URL("../out/TokenLock.sol/TokenLock.json", import.meta.url), "utf8"));
const local = art.deployedBytecode.object.replace(/^0x/, "").toLowerCase();
const refs = art.deployedBytecode.immutableReferences ?? {}, spans = Object.values(refs).flat();
const headers = { "content-type": "application/json", ...(process.env.RPC_AUTH_BEARER ? { authorization: `Bearer ${process.env.RPC_AUTH_BEARER}` } : {}) };
let res;
for (let i = 0; ; i++) {
  try { res = await fetch(rpc, { method: "POST", headers, body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "eth_getCode", params: [addr, "latest"] }) }); break; }
  catch (e) { if (i >= 2) { console.error(`RPC unreachable after 3 tries: ${e.cause?.code ?? e.message} — this is a network error, NOT a bytecode verdict`); process.exit(3); } }
}
const live = ((await res.json()).result ?? "0x").replace(/^0x/, "").toLowerCase();
if (!live) { console.error(`no code at ${addr}`); process.exit(1); }
const mask = (s) => { const a = s.split(""); for (const { start, length } of spans) for (let i = start * 2; i < (start + length) * 2; i++) a[i] = "0"; return a.join(""); };
const L = mask(live), M = mask(local); let diff = 0;
for (let i = 0; i < Math.max(L.length, M.length); i += 2) if (L.slice(i, i + 2) !== M.slice(i, i + 2)) diff++;
console.log(`live ${live.length / 2} bytes · local ${local.length / 2} bytes · ${spans.length} immutable slot(s)`);
for (const [id, ss] of Object.entries(refs)) console.log(`  immutable #${id} (${ss.length} refs) = ${[...new Set(ss.map((s) => "0x" + live.slice(s.start * 2 + 24, (s.start + s.length) * 2)))].join(", ")}`);
if (diff === 0 && live.length === local.length) { console.log("MATCH — the deployed runtime is this source."); process.exit(0); }
console.log(`MISMATCH — ${diff} byte(s) differ outside the immutable slots.`); process.exit(1);

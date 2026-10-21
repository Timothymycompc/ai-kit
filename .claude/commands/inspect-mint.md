---
description: "Decode a token mint's extensions and live authorities, and flag integration risks"
---

Inspect the mint in $ARGUMENTS: what it takes to integrate, and who can still change it. Read-only. Extension meanings and per-extension rules: [token-extensions](../skills/token-extensions/SKILL.md); what an integrator has to handle: [Reading an unknown mint](../skills/token-extensions/SKILL.md#reading-an-unknown-mint) and [Token accounts and transfers](../skills/token-extensions/SKILL.md#token-accounts-and-transfers); venue policy and the pre-launch checks: [programs.md, Before launch](../skills/token-extensions/references/programs.md#before-launch).

## Inputs

| Input | Notes |
|---|---|
| `mint` | Required. |
| `rpc` or `cluster` | Default mainnet. Prefer the project's provider (`HELIUS_API_KEY` in `.env`: `https://mainnet.helius-rpc.com/?api-key=<key>`); public RPCs rate-limit. |
| `for` | `integrate` (default: a program, frontend or venue accepting the mint) or `issue` (an issuer reviewing their own mint before launch). |

## 1. Decode from raw bytes

Don't read extensions from RPC `jsonParsed` or `spl-token display`. Agave RPC nodes before 4.2 decode with `spl-token-2022-interface` 2.x, and for a mint that carries PermissionedBurn they return no `extensions` field at all, hiding a permanent delegate or hook on the same mint. `spl-token` 5.5.0 and a `--locked` 5.6.1 build use the same decoder. Decode with `@solana-program/token-2022` 0.19 on Kit 8 instead: from the project root if it already depends on both, otherwise from a scratch directory.

```bash
mkdir -p "${TMPDIR:-/tmp}/inspect-mint" && cd "${TMPDIR:-/tmp}/inspect-mint" && npm init -y >/dev/null && npm i -q '@solana/kit@^8.3' '@solana-program/token-2022@^0.19'
```

`@solana-program/token-2022` 0.19 peers `@solana/kit` `^8.3`. A workspace pinned to an older kit major keeps its pin — run from the scratch directory instead of moving it.

Write this block to `inspect-mint.mjs` in the directory you installed into — the kit ships no such file, so it has to be written before the run line below resolves (adjust that path if you installed at the project root).

```js
// node inspect-mint.mjs <mint> [rpc-url]: decode a mint from raw bytes (RPC jsonParsed can drop extensions)
import { address, createSolanaRpc, fetchEncodedAccount, unwrapOption } from '@solana/kit';
import { decodeMint, findExtraAccountMetaListPda, TOKEN_PROGRAM_ADDRESS, TOKEN_2022_PROGRAM_ADDRESS } from '@solana-program/token-2022';

const [mintArg, url = 'https://api.mainnet-beta.solana.com'] = process.argv.slice(2);
const rpc = createSolanaRpc(url);
const mint = address(mintArg);
const account = await fetchEncodedAccount(rpc, mint);
if (!account.exists) throw new Error('account not found on this cluster');
const is2022 = account.programAddress === TOKEN_2022_PROGRAM_ADDRESS;
if (!is2022 && account.programAddress !== TOKEN_PROGRAM_ADDRESS) throw new Error(`owned by ${account.programAddress}, not a token program`);
const len = account.data.length; // 82 = classic mint; extended mints carry account type 1 at byte 165 and are never 355 (multisig) bytes
if (len !== 82 && (len <= 165 || len === 355 || account.data[165] !== 1)) throw new Error('not a mint (token account or multisig)');
const { data } = decodeMint(account);
const extensions = unwrapOption(data.extensions) ?? [];
const hook = extensions.find((e) => e.__kind === 'TransferHook');
let hookMetaList = null;
if (hook && hook.programId !== '11111111111111111111111111111111') {
  const [pda] = await findExtraAccountMetaListPda({ mint }, { programAddress: hook.programId });
  hookMetaList = { address: pda, exists: (await fetchEncodedAccount(rpc, pda)).exists };
}
const { epoch } = await rpc.getEpochInfo().send();
const plain = (_, v) => typeof v === 'bigint' ? v.toString() : v instanceof Map ? Object.fromEntries(v)
  : v?.__option ? (v.__option === 'Some' ? v.value : null) : v;
console.log(JSON.stringify({ mint, program: is2022 ? 'Token-2022' : 'SPL Token', epoch, ...data, extensions, hookMetaList }, plain, 2));
```

```bash
node "${TMPDIR:-/tmp}/inspect-mint/inspect-mint.mjs" <MINT> <RPC_URL>
```

Kit's `__kind` names differ from the Rust ones — `ScaledUiAmountConfig`, `PausableConfig`, `ConfidentialTransferFee` ([Reading an unknown mint](../skills/token-extensions/SKILL.md#reading-an-unknown-mint)). Report the extension under the name the user will meet in their own tool.

## 2. Follow up

- **Hook program set** (not `1111...`): `solana program show <hook> -u <rpc>` for its upgrade authority (none means immutable). `hookMetaList.exists: false` means clients resolve no extra accounts, so the hook must work without them or every transfer fails. What a transfer then has to carry: [transfer-hooks](../skills/token-extensions/references/transfer-hooks.md).
- **Transfer fee:** the active fee is `newerTransferFee` once `epoch >= newerTransferFee.epoch`, else `olderTransferFee`. A newer fee with a future epoch is a scheduled change. The recipient gets `amount - fee`, so an integrator credits the balance delta ([fees](../skills/token-extensions/references/fees.md)).
- **ScaledUiAmount** with a future `newMultiplierEffectiveTimestamp`, or InterestBearing: the displayed amount will move; say by how much ([display-amounts](../skills/token-extensions/references/display-amounts.md)).
- **MetadataPointer** to another address: the metadata lives there (possibly another program); fetch it only if the report needs name or symbol ([metadata-groups](../skills/token-extensions/references/metadata-groups.md)).
- **Issuer-side extensions** (PermanentDelegate, Pausable, DefaultAccountState, PermissionedBurn, MintCloseAuthority, NonTransferable): what each authority can do, and which are permanent once set to None, is in [issuer-controls](../skills/token-extensions/references/issuer-controls.md).
- **SPL Token mint:** no extensions; report mint and freeze authority only.

## 3. Report

Print it in chat; write a file only if asked.

```
## Mint <address> (<cluster>, epoch <n>)
Program: <Token-2022 | SPL Token> | decimals <d> | supply <raw> | mint authority <addr|none> | freeze authority <addr|none>
### Extensions
| extension | state | authority | what it means for you |
### Who can still change this mint
- <authority address>: <what it can do, and when it takes effect>
### To integrate
- <transfer_checked, hook-aware path, fee netting from balance deltas, pause check, ...>
### Venues
| venue | accepts this extension set? | source read, on <date> |
### Flags
- high: <e.g. live permanent delegate, live hook with an upgradeable program, live pause authority>
- watch: <dormant extensions with live authorities, scheduled fee or multiplier changes, live mint or freeze authority>
```

For `issue`, add the checks from [programs.md, Before launch](../skills/token-extensions/references/programs.md#before-launch): authorities to revoke or move to a multisig (and the three that a multisig can't hold), and venues the extension set rules out.

## Guardrails

- Never ask for a private key; this command reads and never signs or sends.
- The kit records one venue's policy in full — Orca Whirlpools, in [programs.md](../skills/token-extensions/references/programs.md#before-launch), from its `is_supported_token_mint`. For any other venue, read that venue's own mint check, cite the source and date the row; don't fill the table from memory. Mark a devnet mint's venue column as not applicable.
- Report authorities as addresses and don't guess who controls one. Say whether it is a program (`getAccountInfo` shows `executable`); beyond that, "unknown" unless the user says.

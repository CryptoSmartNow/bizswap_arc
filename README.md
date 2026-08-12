# BizSwap — BOT Chain Technical Specification & Documentation

Upgradeable Solidity implementation of **BizSwap** RWA instruments on **BOT Chain**.

| Item | Value |
|------|--------|
| **Network** | BOT Chain Testnet (968) → Mainnet (677) |
| **Contract** | `BizSwap` (UUPS upgradeable ERC-721 orchestrator) |
| **Stablecoin** | **USDT only** (official BOT USDT) |
| **Collection** | ERC-721 name `BizSwap`, symbol `BIZ` |
| **Phases** | Phase 1 (registry) + Phase 2 (USDT distributions) |
| **Repo scope** | Contracts, Foundry tests, deploy/smoke scripts |

---

## 1. System Architecture

The project adopts a **Central Orchestrator Pattern**. A single upgradeable contract, **`BizSwap`**, manages the full lifecycle of three instrument types: **BizYield**, **BizCredit**, and **BizBond**.

Users and backends always interact with the **ERC1967 proxy** address. The implementation can be upgraded via UUPS without changing that address.

### Data Modeling (EVM storage)

Solana PDAs map to ordinary contract storage:

| Solana concept | BOT / Solidity equivalent |
|----------------|---------------------------|
| Program | `BizSwap` implementation + proxy |
| `GlobalConfig` PDA | Contract fields: roles, `revenueWallet`, `usdt` |
| `InstrumentConfig` PDA ×3 | `mapping(uint8 => Instrument) instruments` |
| `CertificateRecord` PDA | `mapping(uint256 => Certificate) certificates` + ERC-721 ownership |
| SPL mint + Metaplex | ERC-721 `tokenId` + `tokenURI` |
| Token freeze / thaw | Vesting status + `_update` transfer lock / `unlock()` |

#### Global config (roles & pointers)

- **`DEFAULT_ADMIN_ROLE`**: instrument setup, schedules, pause, upgrades, revenue wallet.
- **`MINTER_ROLE`**: backend hot key for `mintCertificate` only.
- **`DISTRIBUTOR_ROLE`**: fund distribution pool / open yield rounds.
- **`revenueWallet`**: treasury pointer (purchase funds still settle off-chain in Phase 1).
- **`usdt`**: official BOT USDT token address for this network (distributions only).

#### Instrument config (`instruments[id]`)

- `id`: `0` BizYield, `1` BizCredit, `2` BizBond  
- `supplyCap` / `currentSupply` (default cap **1,000** per instrument)  
- `minBuyInCents` (USDT cents, 2 decimals)  
- `totalInvestedCents` / `totalFeesCents`  

Default min buy-ins:

| ID | Instrument | Min buy-in |
|----|------------|------------|
| 0 | BizYield | $10 → `1_000` cents |
| 1 | BizCredit | $100 → `10_000` cents |
| 2 | BizBond | $1,000 → `100_000` cents |

#### Certificate record (`certificates[tokenId]`)

Per-purchase terms stored on-chain:

- `instrumentId`, `amountCents` (net principal), `feeCents`  
- `entitlementBps` (BizYield share of each revenue round; 10_000 = 100%)  
- `purchaseTime`, `vestEnd`, `yieldStart`  
- `status`: `Vesting` \| `Active` \| `Redeemed`  
- `serial`, `cycle`  

Ownership source of truth: **`ownerOf(tokenId)`** (ERC-721).

---

## 2. Technical Workflow

### Phase 1 — Minting pipeline

`mintCertificate` is called by **`MINTER_ROLE` only** (backend after payment confirmation):

1. **Validation**: minter role, instrument configured, supply &lt; cap, amount ≥ min buy-in, non-empty URI, non-zero recipient.
2. **Fee accounting**:  
   - **BizYield & BizBond**: `feeCents = net * 50 / 10_000` (0.5% **on top** of net).  
   - **BizCredit**: `feeCents = 0`.  
   - Certificate principal and entitlements use **net only**.
3. **State**: increment supply / totals; assign sequential `tokenId` and per-instrument `serial`.
4. **Status**: BizCredit → `Active`; BizYield / BizBond → `Vesting`.
5. **ERC-721**: `_safeMint` + `_setTokenURI`.
6. **Event**: `CertificateMinted`.

Purchase funds (fiat / stablecoin via ChainRails or ops) **do not enter the contract** on mint. Only **distribution USDT** is held for Phase 2 claims.

### Phase 1 — Lifecycle (vesting unlock)

`unlock(tokenId)` is **permissionless**:

- If status is `Vesting` and `block.timestamp >= vestEnd` → set `Active`, emit `CertificateUnlocked`.
- While `Vesting`, all transfers/burns revert (`TransferWhileVesting`).
- Already `Active` / `Redeemed`: no-op success for unlock.

### Phase 2 — Distributions (USDT only)

| Instrument | Funding | Claim math |
|------------|---------|------------|
| **BizYield** | `openYieldRound(usdtRaw)` | `roundTotal * entitlementBps / 10_000` once per round |
| **BizCredit** | `depositDistributionUsdt` | 12 weekly installments totaling **104.04%** of principal |
| **BizBond** | `depositDistributionUsdt` | **2.5%** of principal per quarter (default 8 quarters) |

- `claim(tokenId)`: owner-only; pays USDT to the certificate owner.  
- Requires `Active` (unlock first for Yield/Bond).  
- Credit/Bond schedules complete → status `Redeemed`.  
- Admin can `setClaimsPaused(true)`.

Default schedule config (set in `initialize`, overridable via `configureSchedules`):

- Credit first payment: **2026-06-15 00:00:00 UTC**  
- Credit: 12 × 7-day weeks, `creditTotalReturnBps = 10404`  
- Bond: 90-day quarters, `bondQuarterBps = 250`, max 8 quarters  

USDT raw units use **6 decimals**. Product amounts use **cents** (2 decimals):  
`raw = cents * 10^(decimals - 2)` → typically `cents * 10_000`.

---

## 3. Security Implementation

Hardened for common EVM / upgradeable-contract risks:

- **Access control**: OpenZeppelin `AccessControlUpgradeable`; privileged paths use `msg.sender` roles (never `tx.origin`).
- **Separation of powers**: admin vs minter vs distributor vs `revenueWallet` pointer.
- **Vesting lock on-chain**: enforced in ERC-721 `_update`, not a soft UI flag.
- **Checked arithmetic**: Solidity 0.8.x; custom errors for reverts.
- **Reentrancy**: `ReentrancyGuardUpgradeable` on USDT deposit/claim paths.
- **SafeERC20**: all USDT transfers.
- **CEI**: claim progress updated before USDT transfer.
- **UUPS**: `_disableInitializers()` on implementation; `_authorizeUpgrade` admin-only.
- **Pool solvency**: Credit/Bond claims revert if distribution pool is insufficient.
- **Deploy scripts**: initialize + configure instruments in one broadcast; optional admin handoff.

---

## 4. Engineering Best Practices

- **Solidity `^0.8.24`** + OpenZeppelin Contracts / Upgradeable **v5**.
- **Foundry** for unit tests (`vm.prank`, `vm.warp`) and forge scripts.
- **Precision**: financial product values in **USDT cents**; on-chain payouts in **USDT raw** via `AmountCodec`.
- **Basis points**: fee and entitlements use `10_000 = 100%`.
- **Idiomatic EVM**: single ERC-721 collection; instrument type in storage; events for indexers.
- **Upgradeable storage**: append new fields carefully; prefer upgrade tests when changing implementation.
- **Repo scope**: contracts + tests + scripts only (no backend/frontend in this package).

---

## 5. Development & Deployment

### Dependencies

- [Foundry](https://book.getfoundry.sh/) (`forge`, `cast`)
- OpenZeppelin contracts (via `lib/`)
- RPC access to BOT testnet/mainnet for deploy

### Networks

| Network | Chain ID | RPC | Explorer | USDT |
|---------|----------|-----|----------|------|
| **Testnet** | 968 | `https://rpc.bohr.life` | [scan.bohr.life](https://scan.bohr.life) | `0x75edC9335175Fc0552D51D48439F229c10420fe3` |
| **Mainnet** | 677 | `https://rpc.botchain.ai` | [scan.botchain.ai](https://scan.botchain.ai) | `0xaBabc7Ddc03e501d190C676BF3d92ef0e6e87a3C` |

Gas token: **BOT** (tBOT on testnet — [faucet](https://faucet.botchain.ai/basic)).

### Build & test

```bash
cd bizswap_botchain
forge build
forge test -vv
```

### Environment

```bash
cp .env.example .env
```

| Variable | Purpose |
|----------|---------|
| `DEPLOYER_PRIVATE_KEY` | Pays gas; bootstraps admin during deploy |
| `ADMIN` | Final admin address (after handoff) |
| `MINTER` | Backend mint authority |
| `REVENUE_WALLET` | Treasury pointer |
| `BOT_TESTNET_RPC` / `BOT_MAINNET_RPC` | JSON-RPC endpoints |
| `CONFIRM_MAINNET` | Must be `true` for mainnet deploy |
| `PROXY_ADDRESS` | For upgrade / smoke scripts |

### Deployment

Deploy **implementation + proxy**, configure three instruments, hand off admin if needed:

```bash
# Testnet (968)
forge script script/DeployTestnet.s.sol:DeployTestnet \
  --rpc-url $BOT_TESTNET_RPC --broadcast

# Mainnet (677) — requires CONFIRM_MAINNET=true
forge script script/DeployMainnet.s.sol:DeployMainnet \
  --rpc-url $BOT_MAINNET_RPC --broadcast
```

Record the **proxy** address in `deployments/testnet-968.json` or `deployments/mainnet-677.json`.

### Upgrade

```bash
PROXY_ADDRESS=0x... forge script script/Upgrade.s.sol:Upgrade \
  --rpc-url $RPC --broadcast
```

### Smoke checks

```bash
PROXY_ADDRESS=0x... forge script script/SmokeTestnet.s.sol:SmokeTestnet \
  --rpc-url $BOT_TESTNET_RPC

PROXY_ADDRESS=0x... forge script script/SmokeMainnet.s.sol:SmokeMainnet \
  --rpc-url $BOT_MAINNET_RPC
```

### Project layout

```text
bizswap_botchain/
├── src/
│   ├── BizSwap.sol
│   ├── interfaces/IBizSwap.sol
│   ├── libraries/AmountCodec.sol
│   └── mocks/MockUSDT.sol
├── test/BizSwap.t.sol
├── script/
│   ├── DeployTestnet.s.sol
│   ├── DeployMainnet.s.sol
│   ├── Upgrade.s.sol
│   ├── SmokeTestnet.s.sol
│   └── SmokeMainnet.s.sol
├── deployments/
├── foundry.toml
└── ROADMAP.md
```

---

## 6. Frontend / Client Integration Guide (EVM)

This section is for teams integrating a Next.js (or other) app with **BizSwap on BOT Chain**. Prefer **wagmi + viem** (or ethers.js). MetaMask and BO Wallet are supported BOT wallets.

### 1. Installation & setup

```bash
npm install viem wagmi @tanstack/react-query
```

Add BOT networks to the wallet (or use ChainList for mainnet 677):

```typescript
// chains.ts
import { defineChain } from "viem";

export const botTestnet = defineChain({
  id: 968,
  name: "BOT Testnet",
  nativeCurrency: { name: "BOT", symbol: "BOT", decimals: 18 },
  rpcUrls: { default: { http: ["https://rpc.bohr.life"] } },
  blockExplorers: { default: { name: "BOTScan", url: "https://scan.bohr.life" } },
});

export const botMainnet = defineChain({
  id: 677,
  name: "BOT Chain",
  nativeCurrency: { name: "BOT", symbol: "BOT", decimals: 18 },
  rpcUrls: { default: { http: ["https://rpc.botchain.ai"] } },
  blockExplorers: { default: { name: "BOTScan", url: "https://scan.botchain.ai" } },
});
```

Export ABI from Foundry artifacts (`out/BizSwap.sol/BizSwap.json`) or maintain a typed ABI module.

```typescript
// addresses.ts
export const BIZSWAP_PROXY = "0x..." as const; // proxy address from deployments/
export const USDT_ADDRESS = {
  968: "0x75edC9335175Fc0552D51D48439F229c10420fe3",
  677: "0xaBabc7Ddc03e501d190C676BF3d92ef0e6e87a3C",
} as const;
```

### 2. Loading the contract

```typescript
import { createPublicClient, http, getContract } from "viem";
import { botTestnet } from "./chains";
import { bizSwapAbi } from "./abi/BizSwap";
import { BIZSWAP_PROXY } from "./addresses";

export const publicClient = createPublicClient({
  chain: botTestnet,
  transport: http(),
});

export const bizSwap = getContract({
  address: BIZSWAP_PROXY,
  abi: bizSwapAbi,
  client: publicClient,
});
```

There are **no PDAs**. Read state via public getters:

- `instruments(uint8 instrumentId)`
- `certificates(uint256 tokenId)`
- `ownerOf(tokenId)`, `tokenURI(tokenId)`, `balanceOf(owner)`
- `quoteFee(instrumentId, netCents)`, `quoteGross(instrumentId, netCents)`
- `claimable(tokenId)`

### 3. Fetching instrument configuration

```typescript
const instrumentId = 1; // BizCredit
const inst = await bizSwap.read.instruments([instrumentId]);

console.log("Min buy-in (cents):", inst.minBuyInCents.toString());
console.log("Current supply:", inst.currentSupply.toString());
console.log(
  "Remaining cap:",
  (inst.supplyCap - inst.currentSupply).toString()
);
```

### 4. Listing user certificates

ERC-721 ownership is on the token. Prefer indexing `CertificateMinted` / `Transfer` events (BOT public mainnet RPC may limit `eth_getLogs` — use WebSocket, a dedicated RPC, or an indexer).

Minimal approach when you know `tokenId`s (from your backend DB):

```typescript
const tokenId = 1n;
const owner = await bizSwap.read.ownerOf([tokenId]);
const cert = await bizSwap.read.certificates([tokenId]);
const uri = await bizSwap.read.tokenURI([tokenId]);
```

### 5. The ChainRails purchase & minting flow

> [!IMPORTANT]
> **CRITICAL**: The frontend **must not** call `mintCertificate`. That function requires `MINTER_ROLE`, held by a backend hot key only.

1. **User selects instrument** and enters net investment (e.g. $400 BizYield).
2. **Platform fee (Yield & Bond only)**: show 0.5% **on top** of net:
   - Investment: $400.00  
   - Platform fee (0.5%): $2.00  
   - **Total pay**: $402.00  
   - BizShares / certificate principal: **$400.00**  
   - **BizCredit**: fee line is **$0.00**.
3. **Payment**: ChainRails (or ops) collects gross in the user’s rail; on BOT, settlement accounting is **USDT-denominated**. Off-chain purchase funds go to the revenue wallet — not into `BizSwap` on mint.
4. **Backend webhook**: confirm payment → call `mintCertificate` with the user’s **EVM address**, instrument id, **net** cents, entitlement BPS, vest/yield timestamps, cycle, metadata URI.
5. **UI**: poll `ownerOf` / events / backend until the new `tokenId` appears; show dashboard + explorer link to the proxy + token id.

Fee helpers on-chain:

```typescript
const netCents = 40_000n; // $400.00
const fee = await bizSwap.read.quoteFee([0, netCents]);   // BizYield → 200
const gross = await bizSwap.read.quoteGross([0, netCents]); // 40200
```

### 6. Unlocking vesting (Yield / Bond)

After `vestEnd`, anyone can unlock; typically the holder:

```typescript
import { createWalletClient, custom } from "viem";

// walletClient from wagmi / browser wallet on BOT chain
await walletClient.writeContract({
  address: BIZSWAP_PROXY,
  abi: bizSwapAbi,
  functionName: "unlock",
  args: [tokenId],
});
```

### 7. Claiming Phase 2 distributions (USDT)

Holders claim accrued USDT after schedules / yield rounds are funded by `DISTRIBUTOR_ROLE`:

```typescript
const claimable = await bizSwap.read.claimable([tokenId]);
if (claimable > 0n) {
  await walletClient.writeContract({
    address: BIZSWAP_PROXY,
    abi: bizSwapAbi,
    functionName: "claim",
    args: [tokenId],
  });
}
```

Distributor ops (admin tooling, not end-user UI):

- `depositDistributionUsdt(usdtRaw)` — approve USDT first, funds Credit/Bond pool  
- `openYieldRound(usdtRaw)` — approve USDT first, opens a BizYield revenue round  

### 8. Indexing note

Some BOT mainnet public RPCs disable `eth_getLogs`. For production dashboards, use:

- WebSocket subscriptions, or  
- A dedicated / third-party RPC, or  
- The Graph / Covalent-style indexer  

---

## 7. Public API summary

| Function | Access | Phase |
|----------|--------|--------|
| `initialize(...)` | once (proxy init) | 1 |
| `configureInstrument` | admin | 1 |
| `configureSchedules` | admin | 2 |
| `mintCertificate` | minter | 1 |
| `unlock` | anyone | 1 |
| `depositDistributionUsdt` | distributor | 2 |
| `openYieldRound` | distributor | 2 |
| `claim` | certificate owner | 2 |
| `claimable` | view | 2 |
| `quoteFee` / `quoteGross` | view | 1 |
| `pause` / `unpause` | admin | 1 |
| `setClaimsPaused` | admin | 2 |
| `upgradeToAndCall` | admin (UUPS) | ops |

---

## 8. Related docs

- Product roadmap / later versions: [`ROADMAP.md`](./ROADMAP.md)  
- BOT developer docs: [dev-docs.botchain.ai](https://dev-docs.botchain.ai/)  
- Solana reference implementation (historical): `../bizswap_solana/`  

---

**End of documentation.** Use the **proxy** address as the canonical BizSwap product address on BOT Chain.

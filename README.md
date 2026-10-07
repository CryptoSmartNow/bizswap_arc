# BizSwap — Arc Network Technical Specification & Documentation

Upgradeable Solidity implementation of **BizSwap** Real World Asset (RWA) instruments on **Arc Network**.

| Item                 | Value                                                                                          |
| -------------------- | ---------------------------------------------------------------------------------------------- |
| **Network**          | Arc Testnet (5042002) → Arc Mainnet (5042)                                                     |
| **Contract**         | `BizSwap` (UUPS upgradeable ERC-721 orchestrator)                                              |
| **Gas Token**        | **USDC** (Native 18 decimals, deterministic sub-second finality)                               |
| **Stablecoin Asset** | **USDC** (Canonical ERC-20 predeploy `0x3600000000000000000000000000000000000000`, 6 decimals) |
| **Collection**       | ERC-721 name `BizSwap`, symbol `BIZ`                                                           |
| **Phases**           | Phase 1 (registry & vesting) + Phase 2 (USDC distributions)                                    |
| **Tooling**          | Arc Foundry (`arc-forge`, `arc-cast`, `arc-anvil`) / Standard Foundry                          |

---

## 1. System Architecture

The project adopts a **Central Orchestrator Pattern**. A single upgradeable contract, **`BizSwap`**, manages the full lifecycle of three instrument types: **BizYield**, **BizCredit**, and **BizBond**.

Users and backend systems always interact with the **ERC1967 proxy** address. The implementation can be upgraded via UUPS without altering the canonical proxy address.

```mermaid
flowchart TD
    subgraph Arc Network
        USDC_Predeploy["Canonical USDC Predeploy<br/><code>0x3600000000000000000000000000000000000000</code>"]
        NativeGas["USDC Native Gas (18 decimals)<br/>Used for gas fees & sub-second execution"]
    end

    subgraph BizSwap System
        Proxy["BizSwap ERC1967 Proxy"]
        Impl["BizSwap Implementation (UUPS)"]
        YieldRounds["BizYield Revenue Rounds (USDC)"]
        CreditSchedules["BizCredit 12-Week Waterfall (USDC)"]
        BondSchedules["BizBond Quarterly Coupons (USDC)"]
    end

    Proxy --> Impl
    Impl --> YieldRounds
    Impl --> CreditSchedules
    Impl --> BondSchedules
    USDC_Predeploy -->|"depositDistributionUsdc / openYieldRound"| Impl
    Impl -->|"claim (safeTransfer)"| CertificateHolders["Certificate Holders"]
    NativeGas -.->|"Gas Payments"| Impl
```

### Data Modeling & Storage

| Concept            | Arc / Solidity Implementation                                      |
| ------------------ | ------------------------------------------------------------------ |
| Program            | `BizSwap` implementation + ERC1967 proxy                           |
| Global Config      | Contract fields: roles, `revenueWallet`, `usdc`, `usdcDecimals`    |
| Instrument Config  | `mapping(uint8 => Instrument) instruments`                         |
| Certificate Record | `mapping(uint256 => Certificate) certificates` + ERC-721 ownership |
| NFT Token          | ERC-721 `tokenId` + `tokenURI`                                     |
| Transfer Lock      | Vesting status + `_update` transfer lock / `unlock()`              |

#### Global Config (Roles & Pointers)

- **`DEFAULT_ADMIN_ROLE`**: Instrument setup, schedule configuration, pauses, UUPS upgrades, revenue wallet updates.
- **`MINTER_ROLE`**: Backend hot key for `mintCertificate` only.
- **`DISTRIBUTOR_ROLE`**: Funds distribution pool (`depositDistributionUsdc`) and opens yield rounds (`openYieldRound`).
- **`revenueWallet`**: Treasury pointer (off-chain purchase funds settle here in Phase 1).
- **`usdc`**: Canonical Arc USDC ERC-20 predeploy (`0x3600000000000000000000000000000000000000`).

#### Arc Stablecoin-Native Model

On Arc, the native gas token is USDC, and the native balance and the ERC-20 USDC interface are the **same pool of funds**:

- **Native view (18 decimals)**: Used for gas fees and `msg.value`.
- **ERC-20 view (6 decimals)**: At `0x3600000000000000000000000000000000000000`. Used for all BizSwap distribution deposits, pool tracking, and holder claims.
- **Dual-Interface Guard**: BizSwap enforces non-payable execution and rejects raw native transfers to prevent accidental native balance locking.

#### Instrument Config (`instruments[id]`)

- `id`: `0` BizYield, `1` BizCredit, `2` BizBond
- `supplyCap` / `currentSupply` (default cap **1,000** per instrument)
- `minBuyInCents` (USDC cents, 2 decimals)
- `totalInvestedCents` / `totalFeesCents`

Default minimum buy-ins:

| ID  | Instrument | Min Buy-In               |
| --- | ---------- | ------------------------ |
| 0   | BizYield   | $10 → `1_000` cents      |
| 1   | BizCredit  | $100 → `10_000` cents    |
| 2   | BizBond    | $1,000 → `100_000` cents |

#### Certificate Record (`certificates[tokenId]`)

Per-purchase terms stored on-chain:

- `instrumentId`, `amountCents` (net principal), `feeCents`
- `entitlementBps` (BizYield share of each revenue round; 10,000 = 100%)
- `purchaseTime`, `vestEnd`, `yieldStart`
- `status`: `Vesting` | `Active` | `Redeemed`
- `serial`, `cycle`

Source of truth for ownership: **`ownerOf(tokenId)`** (ERC-721 standard).

---

## 2. Technical Workflow

### Phase 1 — Minting Pipeline

`mintCertificate` is invoked by **`MINTER_ROLE` only** (backend after payment confirmation):

1. **Validation**: Minter role, instrument configured, supply < cap, amount ≥ min buy-in, non-empty URI, recipient != `address(0)`.
2. **Fee Accounting**:
   - **BizYield & BizBond**: `feeCents = net * 50 / 10_000` (0.5% **on top** of net).
   - **BizCredit**: `feeCents = 0`.
   - Certificate principal and entitlement calculations strictly use **net cents**.
3. **State Mutation**: Increments current supply and totals; allocates sequential `tokenId` and per-instrument `serial`.
4. **Status**: BizCredit → `Active`; BizYield / BizBond → `Vesting`.
5. **ERC-721**: `_safeMint` + `_setTokenURI`.
6. **Event**: Emits `CertificateMinted`.

> Purchase funds settle off-chain (or into the treasury `revenueWallet`). The `BizSwap` contract only holds **distribution USDC** for Phase 2 claims.

### Phase 1 — Lifecycle (Vesting Unlock)

`unlock(tokenId)` is **permissionless**:

- If status is `Vesting` and `block.timestamp >= vestEnd` → sets status to `Active`, emits `CertificateUnlocked`.
- While `Vesting`, all ERC-721 transfers/burns revert (`TransferWhileVesting`).
- Already `Active` / `Redeemed`: No-op success.

### Phase 2 — USDC Distributions

| Instrument    | Funding Mechanism                  | Claim Calculation                                        |
| ------------- | ---------------------------------- | -------------------------------------------------------- |
| **BizYield**  | `openYieldRound(usdcRaw)`          | `roundTotal * entitlementBps / 10_000` once per round    |
| **BizCredit** | `depositDistributionUsdc(usdcRaw)` | 12 weekly installments totaling **104.04%** of principal |
| **BizBond**   | `depositDistributionUsdc(usdcRaw)` | **2.5%** of principal per quarter (default 8 quarters)   |

- `claim(tokenId)`: Callable by certificate owner only; transfers 6-decimal USDC directly to owner.
- Requires `Active` status (Yield/Bond must be unlocked after vesting).
- Solvency Guard: Credit/Bond claims revert (`InsufficientPool`) if distribution pool balance is insufficient; Yield rounds protect round allocations.
- Admin emergency stop: `setClaimsPaused(true)` with emitted event.

Schedule parameters:

- Credit first payment default: **2026-06-15 00:00:00 UTC** (`1_781_481_600`)
- Credit: 12 × 7-day weeks, `creditTotalReturnBps = 10404`
- Bond: 90-day quarters, `bondQuarterBps = 250`, max 8 quarters

---

## 3. Network & Configuration

| Parameter          | Arc Testnet                                                | Arc Mainnet                                  |
| ------------------ | ---------------------------------------------------------- | -------------------------------------------- |
| **Chain ID**       | `5042002` (`0x4CEF52`)                                     | `5042` (`0x13B2`)                            |
| **RPC URL**        | `https://rpc.testnet.arc.io`                               | `https://rpc.mainnet.arc.io`                 |
| **WebSocket**      | `wss://rpc.testnet.arc.io`                                 | `wss://rpc.mainnet.arc.io`                   |
| **Explorer**       | [explorer.testnet.arc.io](https://explorer.testnet.arc.io) | [explorer.arc.io](https://explorer.arc.io)   |
| **Faucet**         | [faucet.circle.com](https://faucet.circle.com)             | N/A (fund with real USDC)                    |
| **USDC Predeploy** | `0x3600000000000000000000000000000000000000`               | `0x3600000000000000000000000000000000000000` |
| **Gas Pricing**    | Min base fee 20 Gwei (EWMA smoothed)                       | Min base fee 20 Gwei (EWMA smoothed)         |
| **Finality**       | Sub-second deterministic                                   | Sub-second deterministic                     |

---

## 4. Development & Testing

### Prerequisites

- [Arc Foundry](https://github.com/circlefin/arc-foundry) (`arc-forge`, `arc-cast`, `arc-anvil`) or standard Foundry
- OpenZeppelin Contracts Upgradeable v5

### Build and Test

Run with Arc Foundry targeting Arc's Osaka EVM runtime:

```bash
# Test with Arc Foundry on Arc network
arc-forge test --network arc -vv

# Or with standard Forge
forge test -vv
```

### Environment Configuration

```bash
cp .env.example .env
```

| Variable               | Description                                    |
| ---------------------- | ---------------------------------------------- |
| `DEPLOYER_PRIVATE_KEY` | Deployer key (must hold USDC for gas on Arc)   |
| `ADMIN`                | Final admin address (after deployment handoff) |
| `MINTER`               | Backend authority for `mintCertificate`        |
| `REVENUE_WALLET`       | Platform fee and treasury pointer              |
| `ARC_TESTNET_RPC_URL`  | `https://rpc.testnet.arc.io`                   |
| `ARC_MAINNET_RPC_URL`  | `https://rpc.mainnet.arc.io`                   |
| `CANONICAL_USDC`       | `0x3600000000000000000000000000000000000000`   |
| `CONFIRM_MAINNET`      | Must be `true` to broadcast on Arc Mainnet     |
| `PROXY_ADDRESS`        | Address of deployed BizSwap ERC1967 proxy      |

### Deployment

Deploy implementation + proxy, initialize instruments, and configure roles:

```bash
#load environmental variables first
source .env

# Arc Testnet (5042002)
forge script script/DeployTestnet.s.sol:DeployTestnet \
  --rpc-url $ARC_TESTNET_RPC_URL --broadcast

# Arc Mainnet (5042) — requires CONFIRM_MAINNET=true
forge script script/DeployMainnet.s.sol:DeployMainnet \
  --rpc-url $ARC_MAINNET_RPC_URL --broadcast
```

Deployment metadata is saved to `deployments/testnet-5042002.json` or `deployments/mainnet-5042.json`.

### Smoke Tests

```bash
# Testnet
PROXY_ADDRESS=0x... forge script script/SmokeTestnet.s.sol:SmokeTestnet \
  --rpc-url $ARC_TESTNET_RPC_URL

# Mainnet
PROXY_ADDRESS=0x... forge script script/SmokeMainnet.s.sol:SmokeMainnet \
  --rpc-url $ARC_MAINNET_RPC_URL
```

---

## 5. Frontend & Client Integration (viem & wagmi)

Arc is natively integrated into `viem/chains`. No custom chain definitions are required.

### 1. Installation

```bash
npm install viem wagmi @tanstack/react-query
```

### 2. Client Setup

```typescript
// client.ts
import { createPublicClient, http, getContract } from "viem";
import { arcTestnet, arc } from "viem/chains";
import { bizSwapAbi } from "./abi/BizSwap";

export const BIZSWAP_PROXY = "0x..." as const; // from deployments/
export const CANONICAL_USDC =
  "0x3600000000000000000000000000000000000000" as const;

export const publicClient = createPublicClient({
  chain: arcTestnet, // or `arc` for mainnet
  transport: http(),
});

export const bizSwap = getContract({
  address: BIZSWAP_PROXY,
  abi: bizSwapAbi,
  client: publicClient,
});
```

### 3. Reading Certificate & Instrument State

```typescript
// Read instrument config
const instrumentId = 0; // BizYield
const inst = await bizSwap.read.instruments([instrumentId]);

// Read certificate details
const tokenId = 1n;
const cert = await bizSwap.read.certificates([tokenId]);
const owner = await bizSwap.read.ownerOf([tokenId]);
const claimableUsdcRaw = await bizSwap.read.claimable([tokenId]);
```

### 4. Claiming Distributions

Certificate owners claim accrued USDC distributions:

```typescript
import { createWalletClient, custom } from "viem";

const claimable = await bizSwap.read.claimable([tokenId]);
if (claimable > 0n) {
  const hash = await walletClient.writeContract({
    address: BIZSWAP_PROXY,
    abi: bizSwapAbi,
    functionName: "claim",
    args: [tokenId],
  });
}
```

### 5. Distributor Operations

To fund distributions (admin / distributor backend):

```typescript
// 1. Approve USDC to BizSwap proxy
await usdcContract.write.approve([BIZSWAP_PROXY, amountUsdcRaw]);

// 2. Deposit into Credit/Bond pool
await bizSwap.write.depositDistributionUsdc([amountUsdcRaw]);

// OR open a BizYield round
await bizSwap.write.openYieldRound([amountUsdcRaw]);
```

---

## 6. Public API Summary

| Function                  | Access      | Purpose                                                       |
| ------------------------- | ----------- | ------------------------------------------------------------- |
| `initialize(...)`         | initializer | Initialize proxy with admin, minter, revenue wallet, and USDC |
| `configureInstrument`     | admin       | Update supply caps and minimum buy-ins                        |
| `configureSchedules`      | admin       | Update schedule parameters before locking                     |
| `lockSchedules`           | admin       | Permanently lock financial schedule parameters                |
| `mintCertificate`         | minter      | Mint RWA certificate NFT after payment verification           |
| `unlock`                  | anyone      | Unlock certificate after vesting end timestamp                |
| `depositDistributionUsdc` | distributor | Deposit USDC into Credit/Bond distribution pool               |
| `openYieldRound`          | distributor | Fund and open a new BizYield revenue round                    |
| `closeYieldRound`         | distributor | Mark a yield round closed (bookkeeping)                       |
| `claim`                   | token owner | Claim all matured USDC payouts                                |
| `claimable`               | view        | Preview claimable USDC for a certificate                      |
| `quoteFee` / `quoteGross` | view        | Calculate 0.5% fee on net buy-ins                             |
| `setClaimsPaused`         | admin       | Pause or unpause holder distribution claims                   |
| `upgradeToAndCall`        | admin       | UUPS implementation contract upgrade                          |

---

**Canonical BizSwap on Arc**: All interactions and frontend integrations must point to the **ERC1967 Proxy** address on Arc Testnet or Arc Mainnet.

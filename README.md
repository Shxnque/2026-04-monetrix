# Monetrix audit details

- Total Prize Pool: $22,000 in USDC
  - HM awards: up to $19,200 in USDC
    - If no valid Highs or Mediums are found, the HM pool is $0
  - QA awards: $800 in USDC
  - Judge awards: $1,500 in USDC
  - Scout awards: $500 in USDC
- [Read our guidelines for more details](https://docs.code4rena.com/competitions)
- Starts April 24, 2026 20:00 UTC
- Ends May 04, 2026 20:00 UTC

### ❗ Important notes for wardens

1. A coded, runnable PoC is required for all High/Medium submissions to this audit.
   - This repo includes a PoC template at [`test/c4/C4Submission.t.sol`](https://github.com/code-423n4/2026-04-monetrix/blob/main/test/c4/C4Submission.t.sol).
   - Edit that file in place and write your exploit inside the body of `test_submissionValidity`. Do **not** copy it to a new file.
   - Submissions will be marked as Insufficient if the PoC is not runnable and working with the provided test suite.
   - Exception: PoC is optional (though recommended) for wardens with signal ≥ 0.4.
2. Judging phase risk adjustments (upgrades/downgrades):
   - High- or Medium-risk submissions downgraded by the judge to Low-risk (QA) will be ineligible for awards.
   - Upgrading a Low-risk finding from a QA report to a Medium- or High-risk finding is not supported.
   - Wardens are encouraged to select the appropriate risk level carefully during the submission phase.

## V12 findings

[V12](https://v12.zellic.io/) is [Zellic](https://zellic.io)'s in-house AI auditing tool. It is the only autonomous Solidity auditor that [reliably finds Highs and Criticals](https://www.zellic.io/blog/introducing-v12/). All issues found by V12 will be judged as out of scope and ineligible for awards.

V12 findings will be posted in this section within the first two days of the competition.

## Publicly known issues

_Anything included in this section is considered a publicly known issue and is therefore ineligible for awards._

- **Operator is a trusted hot-wallet role, not a trust-minimized actor.** Operator has immediate-effect authority over the hedge, bridge, yield, BLP and HLP pipelines. Risks arising purely from Operator compromise or inaction — e.g. refusing to call `fundRedemptions`, submitting invalid params to `withdrawFromBlp`, or manually toggling `setHlpDepositEnabled` — are mitigated off-chain via monitoring and a multi-Operator key policy, not by contract-level guards.
- **A single UPGRADER role can replace all 9 proxy implementations (including the ACL itself).** Governor / `DEFAULT_ADMIN_ROLE` sits behind a 24h timelock; UPGRADER sits behind 48h. Role-splitting across the proxy set is a roadmap item, not a v1 requirement.

# Overview

Monetrix is a USDC-backed synthetic dollar protocol deployed on HyperEVM, the EVM chain of the Hyperliquid ecosystem. Users deposit USDC into the Vault and receive USDM 1:1, a 6-decimal stablecoin. USDM holders can stake into sUSDM — an ERC-4626 wrapper with cooldown-based unstaking — to earn yield generated off-chain by a delta-neutral strategy.

The backing of USDM is composed of:

- USDC held in the Vault and the Redeem Escrow (EVM side)
- Spot USDC and whitelisted spot assets held by the Vault's HyperCore L1 account
- USDC supplied into the Portfolio Margin (0x811) pool for registered slots
- Signed perp account value (long-spot / short-perp delta-neutral hedge)
- Signed HLP equity (mark-to-market)

The Accountant reads backing across these venues through HyperCore precompiles and enforces a four-gate `settle` pipeline (initialization, minimum interval, distributable-surplus cap, annualized-APR cap) before any yield can be declared. Yield accrues into sUSDM via `injectYield`, while a configurable share is routed to the Insurance Fund and the Foundation.

All user-facing contracts are UUPS-upgradeable; role authority is split across DEFAULT_ADMIN (48h timelock), UPGRADER (48h), GOVERNOR (24h), OPERATOR (instant, code-bounded), and GUARDIAN (instant pause-only).

## Links

- **Previous audits:** N/A
- **Documentation:** N/A
- **Website:** N/A
- **X/Twitter:** https://x.com/MonetrixFinance

# Scope

### Files in scope
*Note: The nSLoC counts in the following table have been automatically generated and may differ depending on the definition of what a "significant" line of code represents. As such, they should be considered indicative rather than absolute representations of the lines involved in each contract.*

| File                                                                                                                                                      | nSLOC    |
| --------------------------------------------------------------------------------------------------------------------------------------------------------- | -------- |
| [src/core/ActionEncoder.sol](https://github.com/code-423n4/2026-04-monetrix/blob/main/src/core/ActionEncoder.sol)                                         | 131      |
| [src/core/InsuranceFund.sol](https://github.com/code-423n4/2026-04-monetrix/blob/main/src/core/InsuranceFund.sol)                                         | 38       |
| [src/core/MonetrixAccountant.sol](https://github.com/code-423n4/2026-04-monetrix/blob/main/src/core/MonetrixAccountant.sol)                               | 220      |
| [src/core/MonetrixConfig.sol](https://github.com/code-423n4/2026-04-monetrix/blob/main/src/core/MonetrixConfig.sol)                                       | 162      |
| [src/core/MonetrixVault.sol](https://github.com/code-423n4/2026-04-monetrix/blob/main/src/core/MonetrixVault.sol)                                         | 438      |
| [src/core/PrecompileReader.sol](https://github.com/code-423n4/2026-04-monetrix/blob/main/src/core/PrecompileReader.sol)                                   | 129      |
| [src/core/RedeemEscrow.sol](https://github.com/code-423n4/2026-04-monetrix/blob/main/src/core/RedeemEscrow.sol)                                           | 53       |
| [src/core/TokenMath.sol](https://github.com/code-423n4/2026-04-monetrix/blob/main/src/core/TokenMath.sol)                                                 | 61       |
| [src/core/YieldEscrow.sol](https://github.com/code-423n4/2026-04-monetrix/blob/main/src/core/YieldEscrow.sol)                                             | 34       |
| [src/governance/IMonetrixAccessController.sol](https://github.com/code-423n4/2026-04-monetrix/blob/main/src/governance/IMonetrixAccessController.sol)     | 9        |
| [src/governance/MonetrixAccessController.sol](https://github.com/code-423n4/2026-04-monetrix/blob/main/src/governance/MonetrixAccessController.sol)       | 37       |
| [src/governance/MonetrixGovernedUpgradeable.sol](https://github.com/code-423n4/2026-04-monetrix/blob/main/src/governance/MonetrixGovernedUpgradeable.sol) | 36       |
| [src/interfaces/HyperCoreConstants.sol](https://github.com/code-423n4/2026-04-monetrix/blob/main/src/interfaces/HyperCoreConstants.sol)                   | 27       |
| [src/interfaces/IHyperCore.sol](https://github.com/code-423n4/2026-04-monetrix/blob/main/src/interfaces/IHyperCore.sol)                                   | 21       |
| [src/interfaces/IMonetrixAccountant.sol](https://github.com/code-423n4/2026-04-monetrix/blob/main/src/interfaces/IMonetrixAccountant.sol)                 | 6        |
| [src/interfaces/IRedeemEscrow.sol](https://github.com/code-423n4/2026-04-monetrix/blob/main/src/interfaces/IRedeemEscrow.sol)                             | 9        |
| [src/interfaces/IYieldEscrow.sol](https://github.com/code-423n4/2026-04-monetrix/blob/main/src/interfaces/IYieldEscrow.sol)                               | 5        |
| [src/tokens/USDM.sol](https://github.com/code-423n4/2026-04-monetrix/blob/main/src/tokens/USDM.sol)                                                       | 48       |
| [src/tokens/sUSDM.sol](https://github.com/code-423n4/2026-04-monetrix/blob/main/src/tokens/sUSDM.sol)                                                     | 237      |
| [src/tokens/sUSDMEscrow.sol](https://github.com/code-423n4/2026-04-monetrix/blob/main/src/tokens/sUSDMEscrow.sol)                                         | 25       |
| **Totals**                                                                                                                                                | **1726** |

### Files out of scope

| File                                                                                                                                    |
| --------------------------------------------------------------------------------------------------------------------------------------- |
| [lib/\*\*.\*\*](https://github.com/code-423n4/2026-04-monetrix/tree/main/lib) (forge-std, OpenZeppelin, hyper-evm-lib)                  |
| [test/\*\*.\*\*](https://github.com/code-423n4/2026-04-monetrix/tree/main/test) (unit, fork, invariant, simulator, mocks, PoC template) |

# Additional context

## Areas of concern (where to focus for bugs)

1. **Accountant 4-gate settle pipeline — HIGHEST PRIORITY.** Any vector that allows yield declaration to bypass Gates 1–4, over-report `totalBackingSigned()`, or break `Σ proposedYield ≤ Σ surplus`. File: [`src/core/MonetrixAccountant.sol`](https://github.com/code-423n4/2026-04-monetrix/blob/main/src/core/MonetrixAccountant.sol).
2. **HyperCore precompile read semantics.** Decimal conversions, EVM↔L1 unit boundaries, fail-closed decoding of short responses, and interactions between `tokenInfo` / `perpAssetInfo` / `oraclePx`. Files: [`src/core/PrecompileReader.sol`](https://github.com/code-423n4/2026-04-monetrix/blob/main/src/core/PrecompileReader.sol), [`MonetrixAccountant._readL1Backing`](https://github.com/code-423n4/2026-04-monetrix/blob/main/src/core/MonetrixAccountant.sol).
3. **Bridge + redemption coverage under bank-run conditions.** Behavior of `keeperBridge`, `requestRedeem`, `fundRedemptions`, `claimRedeem` under sustained outflows or when the Vault's EVM USDC is bridged away.
4. **sUSDM cooldown + escrow isolation.** Physical-isolation invariants between `sUSDM` and `sUSDMEscrow`; rate monotonicity under `cooldownShares`, `cooldownAssets`, `claimUnstake`, `injectYield`.
5. **ActionEncoder / PrecompileReader libraries.** Wire-format correctness for CoreWriter actions (buy-spot / short-perp / deposit-HLP / etc.) and truncation / boundary behavior of `uint64` amounts.
6. **Decimal and unit-conversion boundaries.** `TokenMath.usdcEvmToL1Wei`, `usdcL1WeiToEvm`, `spotNotionalUsdcFromPerpPx`, and perp↔spot wei conversions.

## Main invariants

### Protocol-level

**INV-1 — Peg solvency (soft invariant).** USDM total liability is covered by the composite backing:

```
totalBackingSigned() =
    USDC.balanceOf(Vault)
  + USDC.balanceOf(RedeemEscrow)
  + Σ L1 spot USDC
  + Σ L1 spot × oraclePx               (whitelist)
  + Σ 0x811 supplied USDC / spot × px  (registered slots)
  + perp accountValue (signed)
  + HLP equity (signed, MtM)
```

Under normal operation: `totalBackingSigned() ≥ int256(USDM.totalSupply())`.

This is a **soft** invariant — `deposit` does not gate on backing (it mints 1:1); only `settle` indirectly enforces it via Gate 3 (surplus > 0). Transient violations can occur during bank-runs, sustained negative funding, or L1 oracle anomalies. Recovery path: `InsuranceFund.withdraw → Vault` (Governor, 24h timelock).

Code refs: [`MonetrixAccountant.sol:117`](https://github.com/code-423n4/2026-04-monetrix/blob/main/src/core/MonetrixAccountant.sol#L117) (`totalBackingSigned`), [`:180`](https://github.com/code-423n4/2026-04-monetrix/blob/main/src/core/MonetrixAccountant.sol#L180) (`surplus`).

**INV-2 — sUSDM exchange rate is monotonically non-decreasing.** Under normal operation:

```
rate(t) = totalAssets(t) / totalSupply(t)
```

- `rate` increases only on `injectYield` (balance goes up, rate monotone up).
- `cooldownShares` / `cooldownAssets` leave `rate` unchanged: `Δassets = -shares × rate`, `Δsupply = -shares` → rate invariant.
- `claimUnstake` does not change `rate`: USDM is released from `sUSDMEscrow`, independent of `sUSDM.balanceOf()`.

Code refs: [`sUSDM.sol:102`](https://github.com/code-423n4/2026-04-monetrix/blob/main/src/tokens/sUSDM.sol#L102) (`totalAssets`), [`:234`](https://github.com/code-423n4/2026-04-monetrix/blob/main/src/tokens/sUSDM.sol#L234) (`injectYield`), [`sUSDMEscrow.sol:33`](https://github.com/code-423n4/2026-04-monetrix/blob/main/src/tokens/sUSDMEscrow.sol#L33) (`deposit`), [`:38`](https://github.com/code-423n4/2026-04-monetrix/blob/main/src/tokens/sUSDMEscrow.sol#L38) (`release`).

**INV-3 — Redemption accounting correctness.** `RedeemEscrow.totalOwed` precisely tracks outstanding unclaimed USDM redemption commitments:

- `requestRedeem` ⇒ `totalOwed += usdmAmount`
- `claimRedeem` ⇒ `totalOwed -= usdmAmount`

Add/sub are symmetric; no other path mutates `totalOwed`.

- **INV-3a (No silent haircut):** `payOut` precondition `require(balance ≥ amount)`; reverts otherwise. Claimants never receive less than owed. Code ref: [`RedeemEscrow.sol:49`](https://github.com/code-423n4/2026-04-monetrix/blob/main/src/core/RedeemEscrow.sol#L49).
- **INV-3b (reclaim cannot erode obligations):** `reclaimTo` precondition `require(balance ≥ amount + totalOwed)`. Compound Operator actions cannot drain escrow below `totalOwed`. Code ref: [`RedeemEscrow.sol:62`](https://github.com/code-423n4/2026-04-monetrix/blob/main/src/core/RedeemEscrow.sol#L62).

**INV-4 — sUSDM unstake balance ≡ commitments.** `USDM.balanceOf(sUSDMEscrow) == sUSDM.totalPendingClaims`.

- `cooldown`: `totalPendingClaims += assets` synchronized with `escrow.deposit(assets)`.
- `claimUnstake`: `totalPendingClaims -= amount` synchronized with `escrow.release(amount)`.

Code refs: [`sUSDM.sol:171-172`](https://github.com/code-423n4/2026-04-monetrix/blob/main/src/tokens/sUSDM.sol#L171-L172), [`:202-203`](https://github.com/code-423n4/2026-04-monetrix/blob/main/src/tokens/sUSDM.sol#L202-L203), [`:227-228`](https://github.com/code-423n4/2026-04-monetrix/blob/main/src/tokens/sUSDM.sol#L227-L228).

### Yield pipeline (4-gate atomic settle)

**INV-5 — Gate 1: initialization.** `settleDailyPnL` reverts when `lastSettlementTime == 0`. `lastSettlementTime` is set once by Governor via `initializeSettlement()`, then advanced only by `settle` itself. Code refs: [`MonetrixAccountant.sol:206`](https://github.com/code-423n4/2026-04-monetrix/blob/main/src/core/MonetrixAccountant.sol#L206), [`:312-314`](https://github.com/code-423n4/2026-04-monetrix/blob/main/src/core/MonetrixAccountant.sol#L312-L314).

**INV-6 — Gate 2: minimum interval.** `require(block.timestamp ≥ lastSettlementTime + minSettlementInterval)`. Code ref: [`MonetrixAccountant.sol:209`](https://github.com/code-423n4/2026-04-monetrix/blob/main/src/core/MonetrixAccountant.sol#L209).

**INV-7 — Gate 3: distributable cap.** `require(proposedYield ≤ distributableSurplus())`, where `distributableSurplus() = surplus() - shortfall()` and `surplus() = totalBackingSigned() - int256(USDM.totalSupply())`. Code refs: [`MonetrixAccountant.sol:213-215`](https://github.com/code-423n4/2026-04-monetrix/blob/main/src/core/MonetrixAccountant.sol#L213-L215), [`:187`](https://github.com/code-423n4/2026-04-monetrix/blob/main/src/core/MonetrixAccountant.sol#L187).

**INV-8 — Gate 4: annualized APR cap.**

```
require(proposedYield ≤ USDM.totalSupply() × maxAnnualYieldBps × Δt / (10000 × 1 year))
```

- `maxAnnualYieldBps` is Governor-settable (24h timelock).
- `Config.setMaxAnnualYieldBps` enforces `(0, MAX_ANNUAL_YIELD_BPS_CAP]`.
- `MAX_ANNUAL_YIELD_BPS_CAP = 1500` (contract constant; only changeable via UUPS upgrade).
- Initial deployed value: `1200` (12% APR).

Code refs: [`MonetrixAccountant.sol:217-221`](https://github.com/code-423n4/2026-04-monetrix/blob/main/src/core/MonetrixAccountant.sol#L217-L221), [`MonetrixConfig.sol:56`](https://github.com/code-423n4/2026-04-monetrix/blob/main/src/core/MonetrixConfig.sol#L56), [`:151-156`](https://github.com/code-423n4/2026-04-monetrix/blob/main/src/core/MonetrixConfig.sol#L151-L156), [`:88`](https://github.com/code-423n4/2026-04-monetrix/blob/main/src/core/MonetrixConfig.sol#L88).

**INV-9 — Cumulative yield bounded by cumulative surplus.** `Σ (proposedYield across all settles) ≤ Σ (realized surplus over same window)`. Jointly enforced by INV-7 and INV-8 under trusted Operator reporting. `totalSettledYield` is the on-chain cumulative counter. Code refs: [`MonetrixAccountant.sol:62`](https://github.com/code-423n4/2026-04-monetrix/blob/main/src/core/MonetrixAccountant.sol#L62), [`:224`](https://github.com/code-423n4/2026-04-monetrix/blob/main/src/core/MonetrixAccountant.sol#L224).

### Access control

**INV-10 — USDM mint/burn callable only by Vault.** `USDM.mint` and `USDM.burn` gated by `onlyVault`. Code refs: [`USDM.sol:22`](https://github.com/code-423n4/2026-04-monetrix/blob/main/src/tokens/USDM.sol#L22), [`:46`](https://github.com/code-423n4/2026-04-monetrix/blob/main/src/tokens/USDM.sol#L46), [`:53`](https://github.com/code-423n4/2026-04-monetrix/blob/main/src/tokens/USDM.sol#L53).

**INV-11 — sUSDM.injectYield callable only by Vault.** `sUSDM.injectYield` gated by `onlyVault`. Code refs: [`sUSDM.sol:79`](https://github.com/code-423n4/2026-04-monetrix/blob/main/src/tokens/sUSDM.sol#L79), [`:234`](https://github.com/code-423n4/2026-04-monetrix/blob/main/src/tokens/sUSDM.sol#L234).

**INV-12 — Escrow fund movements gated by Vault.**

- `RedeemEscrow.{addObligation, payOut, reclaimTo}`: `onlyVault`
- `YieldEscrow.{pullForDistribution}`: `onlyVault`
- `sUSDMEscrow.{deposit, release}`: `onlySUSDM`

Code refs: [`RedeemEscrow.sol:76-79`](https://github.com/code-423n4/2026-04-monetrix/blob/main/src/core/RedeemEscrow.sol#L76-L79), [`YieldEscrow.sol:48`](https://github.com/code-423n4/2026-04-monetrix/blob/main/src/core/YieldEscrow.sol#L48), [`sUSDMEscrow.sol:21`](https://github.com/code-423n4/2026-04-monetrix/blob/main/src/tokens/sUSDMEscrow.sol#L21).

**INV-13 — Accountant privileged surface callable only by Vault.** `Accountant.{settleDailyPnL, notifyVaultSupply}` gated by `onlyVault`. Code refs: [`MonetrixAccountant.sol:46`](https://github.com/code-423n4/2026-04-monetrix/blob/main/src/core/MonetrixAccountant.sol#L46), [`:202`](https://github.com/code-423n4/2026-04-monetrix/blob/main/src/core/MonetrixAccountant.sol#L202), [`:250`](https://github.com/code-423n4/2026-04-monetrix/blob/main/src/core/MonetrixAccountant.sol#L250).

## Trusted roles in the protocol

| Role             | Description                                                                                                                                                                                                                                                                                                                                                                       | Granted To                        |
| ---------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------- |
| DEFAULT_ADMIN    | Grants / revokes all roles; authorizes ACL upgrade. Sits behind a 48h timelock.                                                                                                                                                                                                                                                                                                   | Multisig (48h timelock)           |
| UPGRADER         | Authorizes UUPS upgrade of all 9 proxies (Vault, USDM, sUSDM, Config, Accountant, RedeemEscrow, YieldEscrow, InsuranceFund, ACL). Sits behind a 48h timelock.                                                                                                                                                                                                                     | Multisig (48h timelock)           |
| GOVERNOR         | All Config / Accountant / Vault setters; `InsuranceFund.withdraw`; Vault emergency paths (`emergencyRawAction`, `emergencyBridgePrincipalFromL1` — intentionally bypass both pause flags). Sits behind a 24h timelock.                                                                                                                                                            | Multisig (24h timelock)           |
| OPERATOR         | Bridge, hedge, HLP, BLP, yield pipeline (`settle` / `distributeYield`), `fundRedemptions`, `reclaimFromRedeemEscrow`. Code-bounded: Operator can only move funds among Vault ↔ L1 own account / Vault ↔ Escrows / sUSDM / InsuranceFund / Foundation. All destination addresses are pre-set by Governor. Operator **cannot** route funds to an external EOA or arbitrary address. | Hot wallet (instant, no timelock) |
| GUARDIAN         | Two independent pause switches: `pause` freezes user flows + mixed paths (`deposit` / `redeem` / `keeperBridge` / `settle` / `distributeYield`); `pauseOperator` freezes all Operator paths. No fund authority.                                                                                                                                                                   | Hot wallet (instant, no timelock) |
| Vault (contract) | Via `onlyVault`: `USDM.mint/burn`, `sUSDM.injectYield`, Escrow fund movements, `Accountant.settleDailyPnL / notifyVaultSupply`.                                                                                                                                                                                                                                                   | Vault contract (msg.sender)       |

**Trust tiers.** DEFAULT_ADMIN / UPGRADER / GOVERNOR are held by the same multisig in production, wrapped behind different timelocks. OPERATOR is the largest instant-trust surface in v1; mitigation via off-chain monitoring, multi-Operator redundancy, and Guardian dual-pause. GUARDIAN has pause authority only, no fund access. There are no in-contract roles (no MINTER / KEEPER etc.) — all consolidated into direct `onlyVault` checks.

## Running tests

The codebase uses a Foundry installation to compile and run tests.

### Pre-requisites

- [foundry](https://book.getfoundry.sh/getting-started/installation)
- A HyperEVM testnet RPC endpoint (only needed to run the fork suite)

### Build

```shell
git clone --recurse-submodules https://github.com/code-423n4/2026-04-monetrix
cd 2026-04-monetrix
forge build
```

Compiler config: `solc 0.8.28`, `via_ir=true`, `optimizer_runs=200`, EVM target `Cancun` — all auto-resolved from [`foundry.toml`](https://github.com/code-423n4/2026-04-monetrix/blob/main/foundry.toml).

### Test

**Run all non-fork tests:**

```shell
forge test -vvv
```

**Run the PoC template only:**

```shell
forge test --match-path "test/c4/C4Submission.t.sol" -vvv
```

**Run targeted unit suites:**

```shell
forge test --match-path "test/Monetrix.t.sol" -vvv
forge test --match-path "test/MonetrixAccountant.t.sol" -vvv
forge test --match-path "test/Governance.t.sol" -vvv
```

**Run fork tests (requires testnet RPC):**

```shell
export FOUNDRY_ETH_RPC_URL=https://rpc.hyperliquid-testnet.xyz/evm
forge test --match-path "test/MonetrixFork.t.sol" -vvv
```

**Gas report:**

```shell
forge test --gas-report
```

**Coverage:**

```shell
forge coverage --report summary
```

## Miscellaneous

Employees of Monetrix and employees' family members are ineligible to participate in this audit.

Code4rena's rules cannot be overridden by the contents of this README. In case of doubt, please check with C4 staff.

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
    - This repo includes a basic template to run the test suite.
    - PoCs must use the test suite provided in this repo.
    - Your submission will be marked as Insufficient if the POC is not runnable and working with the provided test suite.
    - Exception: PoC is optional (though recommended) for wardens with signal ≥ 0.4.
2. Judging phase risk adjustments (upgrades/downgrades):
    - High- or Medium-risk submissions downgraded by the judge to Low-risk (QA) will be ineligible for awards.
    - Upgrading a Low-risk finding from a QA report to a Medium- or High-risk finding is not supported.
    - As such, wardens are encouraged to select the appropriate risk level carefully during the submission phase.

## V12 findings

[V12](https://v12.zellic.io/) is [Zellic](https://zellic.io)'s in-house AI auditing tool. It is the only autonomous auditor that [reliably finds Highs and Criticals](https://www.zellic.io/blog/introducing-v12/). All issues found by V12 will be judged as out of scope and ineligible for awards.

V12 findings will typically be posted in this section within the first two days of the competition.  

## Publicly known issues

_Anything included in this section is considered a publicly known issue and is therefore ineligible for awards._

Operator is a trusted hot-wallet role, not a trust-minimized actor. Operator has immediate-effect authority over hedge/bridge/yield/BLP/HLP
pipelines. Risks arising purely from Operator compromise or inaction (e.g. refusing to call `fundRedemptions`, submitting invalid params to `withdrawFromBlp`, manually toggling `setHlpDepositEnabled`) are mitigated by off-chain monitoring + multi-Operator key policy, not by contract-level guards.

Governor / DEFAULT_ADMIN_ROLE sits behind a 24h timelock; UPGRADER behind 48h. We accept that a single UPGRADER role can replace all 9 proxy implementations (incl. ACL itself). Role-splitting is a roadmap item, not a v1 requirement.

✅ SCOUTS: Please format the response above 👆 so its not a wall of text and its readable.

# Overview

[ ⭐️ SPONSORS: add info here ]

## Links

- **Previous audits:**  N/A
  - ✅ SCOUTS: If there are multiple report links, please format them in a list.
- **Documentation:** 
- **X/Twitter:** https://x.com/MonetrixFinance

---

# Scope

[ ✅ SCOUTS: add scoping and technical details here ]

### Files in scope
- ✅ This should be completed using the `metrics.md` file
- ✅ Last row of the table should be Total: SLOC
- ✅ SCOUTS: Have the sponsor review and and confirm in text the details in the section titled "Scoping Q amp; A"

*For sponsors that don't use the scoping tool: list all files in scope in the table below (along with hyperlinks) -- and feel free to add notes to emphasize areas of focus.*

| Contract | SLOC | Purpose | Libraries used |  
| ----------- | ----------- | ----------- | ----------- |
| [contracts/folder/sample.sol](https://github.com/code-423n4/repo-name/blob/contracts/folder/sample.sol) | 123 | This contract does XYZ | [`@openzeppelin/*`](https://openzeppelin.com/contracts/) |

### Files out of scope
✅ SCOUTS: List files/directories out of scope

# Additional context

## Areas of concern (where to focus for bugs)
1. Accountant 4-gate settle pipeline — HIGHEST PRIORITY
  File: src/core/MonetrixAccountant.sol

2. HyperCore precompile read semantic
File: src/core/PrecompileReader.sol, MonetrixAccountant._readL1Backing

3  Bridge + redemption coverage under bank-run
Files: Vault.keeperBridge / requestRedeem / fundRedemptions / claimRedeem

4 sUSDM cooldown + escrow isolation

5 ActionEncoder / PrecompileReader libraries

6  Decimal & unit-conversion boundary



✅ SCOUTS: Please format the response above 👆 so its not a wall of text and its readable.

## Main invariants

Protocol-level

INV-1 (Peg solvency — soft invariant)
  USDM total liability is covered by a composite backing:
    totalBackingSigned() =
        USDC.balanceOf(Vault)
      + USDC.balanceOf(RedeemEscrow)
      + Σ L1 spot USDC
      + Σ L1 spot × oraclePx  (whitelist)
      + Σ 0x811 supplied USDC / spot × oraclePx  (registered slots)
      + perp accountValue (signed)
      + HLP equity (signed, MtM)
  Under normal operation:
    totalBackingSigned() ≥ int256(USDM.totalSupply())

  Soft invariant — `deposit` does NOT gate on backing (mints 1:1);
  only `settle` indirectly enforces it via Gate 3 (surplus > 0). Transient
  violations can occur during bank-run, sustained negative funding, or L1
  oracle anomalies. Recovery: InsuranceFund.withdraw → Vault (Governor,
  24h timelock).

  Code refs: MonetrixAccountant.sol:117 (totalBackingSigned), :180 (surplus)

  ---

  INV-2 (sUSDM exchange rate monotonically non-decreasing)
  Under normal operation sUSDM exchange rate strictly non-decreases:
    rate(t) = totalAssets(t) / totalSupply(t)
  - rate increases only on injectYield (+balance, rate monotone up)
  - cooldownShares / cooldownAssets leave rate unchanged:
    Δassets = -shares × rate, Δsupply = -shares → rate invariant
  - claimUnstake does not change rate: USDM is released from
    sUSDMEscrow, independent of sUSDM.balanceOf()

  Code refs: sUSDM.sol:102 (totalAssets), :234 (injectYield),
             sUSDMEscrow.sol:33 (deposit), :38 (release)

  ---

 INV-3 (Redemption accounting correctness)
  RedeemEscrow.totalOwed precisely tracks "outstanding unclaimed USDM
  redemption commitments":
    requestRedeem ⇒ totalOwed += usdmAmount
    claimRedeem   ⇒ totalOwed -= usdmAmount
  add/sub are symmetric; no other path mutates totalOwed.

  **INV-3a (No silent haircut)**: payOut precondition
  require(balance ≥ amount); reverts otherwise. Claimants never receive
  less than owed.
  Code ref: RedeemEscrow.sol:49

  **INV-3b (reclaim cannot erode obligations)**: reclaimTo precondition
  require(balance ≥ amount + totalOwed). Even compound Operator actions
  cannot drain escrow below totalOwed.
  Code ref: RedeemEscrow.sol:62

  ---

 INV-4 (sUSDM unstake balance ≡ commitments)
  USDM.balanceOf(sUSDMEscrow) == sUSDM.totalPendingClaims

  cooldown: totalPendingClaims += assets synchronized with
  escrow.deposit(assets);
  claimUnstake: totalPendingClaims -= amount synchronized with
  escrow.release(amount). Symmetric.

  Code refs: sUSDM.sol:171-172, :202-203, :227-228


 Yield pipeline (4-gate atomic settle)

   INV-5 (Gate 1 — initialization)
  settleDailyPnL reverts when lastSettlementTime == 0.
  lastSettlementTime is set once by Governor via initializeSettlement(),
  then advanced only by settle itself.
  Code refs: MonetrixAccountant.sol:206, :312-314

 INV-6 (Gate 2 — minimum interval)
  require(block.timestamp ≥ lastSettlementTime + minSettlementInterval)
  Code ref: MonetrixAccountant.sol:209
INV-7 (Gate 3 — distributable cap)
  require(proposedYield ≤ distributableSurplus())
    distributableSurplus() = surplus() - shortfall()
    surplus() = totalBackingSigned() - int256(USDM.totalSupply())
  Code refs: MonetrixAccountant.sol:213-215, :187 (distributableSurplus),
  :180 (surplus)

INV-8 (Gate 4 — annualized APR cap)
  require(proposedYield ≤ USDM.totalSupply() × maxAnnualYieldBps × Δt
                           / (10000 × 1 year))
  Where:
  - maxAnnualYieldBps is a Governor-settable parameter (24h timelock)
  - Config.setMaxAnnualYieldBps enforces (0, MAX_ANNUAL_YIELD_BPS_CAP]
  - MAX_ANNUAL_YIELD_BPS_CAP = 1500 (contract constant; only changeable
    via UUPS upgrade)
  - Initial deployed value: 1200 (12% APR)
  Code refs: MonetrixAccountant.sol:217-221, MonetrixConfig.sol:56,
  :151-156, :88

INV-9 (Cumulative yield bounded by cumulative surplus)
  Σ (proposedYield across all settles) ≤ Σ (realized surplus over same
  window). Jointly enforced by INV-7 and INV-8 under trusted Operator
  reporting. totalSettledYield is the on-chain cumulative counter.
  Code refs: MonetrixAccountant.sol:62, :224


 Access control

 INV-10 (USDM mint/burn callable only by Vault)
  USDM.mint and USDM.burn gated by onlyVault.
  Code refs: USDM.sol:22 (onlyVault), :46 (mint), :53 (burn)

INV-11 (sUSDM.injectYield callable only by Vault)
  sUSDM.injectYield gated by onlyVault.
  Code refs: sUSDM.sol:79 (onlyVault), :234 (injectYield)

INV-12 (Escrow fund movements gated by Vault)
  - RedeemEscrow.{addObligation, payOut, reclaimTo}: onlyVault
  - YieldEscrow.{pullForDistribution}: onlyVault
  - sUSDMEscrow.{deposit, release}: onlySUSDM
  Code refs: RedeemEscrow.sol:76-79, YieldEscrow.sol:48,
  sUSDMEscrow.sol:21

INV-13 (Accountant privileged surface callable only by Vault)
  Accountant.{settleDailyPnL, notifyVaultSupply} gated by onlyVault.
  Code refs: MonetrixAccountant.sol:46 (onlyVault),
  :202 (settleDailyPnL guard), :250 (notifyVaultSupply guard)


✅ SCOUTS: Please format the response above 👆 so its not a wall of text and its readable.

## All trusted roles in the protocol

- DEFAULT_ADMIN (48h timelock)
    Grants/revokes all roles; authorizes ACL upgrade.

  - UPGRADER (48h timelock)
    Authorizes upgrade of all 9 UUPS proxies (Vault, USDM, sUSDM,
    Config, Accountant, RedeemEscrow, YieldEscrow, InsuranceFund, ACL).

  - GOVERNOR (24h timelock)
    All Config / Accountant / Vault setters; InsuranceFund.withdraw;
    Vault emergency paths (emergencyRawAction,
    emergencyBridgePrincipalFromL1 — intentionally bypass both pause
    flags).

OPERATOR (instant, no timelock)
    Bridge, hedge, HLP, BLP, yield pipeline (settle / distributeYield),
    fundRedemptions, reclaimFromRedeemEscrow.
    The scope is code-bounded: Operator can only open/close/repair
    positions on HyperCore L1, deposit/withdraw HLP / BLP, and move funds
    among Vault ↔ L1 own account / Vault ↔ Escrows / sUSDM /
    InsuranceFund / Foundation. All destination addresses are pre-set by
    Governor via Config / Vault wiring; Operator cannot route funds to
    an external EOA or arbitrary address.

  - GUARDIAN (instant, no timelock)
    Two independent pause switches:
    `pause` freezes user flows + mixed paths (deposit / redeem /
    keeperBridge / settle / distributeYield);
    `pauseOperator` freezes all Operator paths.
    No fund authority.

  - Vault (contract address, msg.sender binding)
    Via onlyVault: USDM.mint/burn, sUSDM.injectYield, Escrow fund
    movements, Accountant.settleDailyPnL / notifyVaultSupply.

  Trust tiers:
  - DEFAULT_ADMIN / UPGRADER / GOVERNOR are held by the same multisig
    in production, wrapped behind different timelocks.
  - OPERATOR is the largest instant-trust surface in v1; mitigation
    via off-chain monitoring, multi-Operator redundancy, and Guardian
    dual-pause.
  - GUARDIAN has pause authority only, no fund access.
  - No "in-contract" roles (no MINTER / KEEPER etc.) — all consolidated
    into direct `onlyVault` checks.

✅ SCOUTS: Please format the response above 👆 using the template below👇

| Role                                | Description                       |
| --------------------------------------- | ---------------------------- |
| Owner                          | Has superpowers                |
| Administrator                             | Can change fees                       |

✅ SCOUTS: Please format the response above 👆 so its not a wall of text and its readable.

## Running tests

Compile
    forge build

  Compiler config: solc 0.8.28, via_ir=true, optimizer_runs=200,
  EVM target Cancun (auto-resolved from foundry.toml, no flags needed).

  Run tests

  All tests (unit + fork):
    forge test -vvv

  Unit tests only:
    forge test --match-path "test/Monetrix.t.sol" -vvv
    forge test --match-path "test/MonetrixAccountant.t.sol" -vvv
    forge test --match-path "test/Governance.t.sol" -vvv

  Fork tests only (requires testnet RPC):
    export FOUNDRY_ETH_RPC_URL=https://rpc.hyperliquid-testnet.xyz/evm
    forge test --match-path "test/MonetrixFork.t.sol" -vvv

  Single test by name:
    forge test --match-test <testName> -vvv

  Gas report:
    forge test --gas-report

  Coverage:
    forge coverage --report summary

✅ SCOUTS: Please format the response above 👆 using the template below👇

```bash
git clone https://github.com/code-423n4/2023-08-arbitrum
git submodule update --init --recursive
cd governance
foundryup
make install
make build
make sc-election-test
```
To run code coverage
```bash
make coverage
```

✅ SCOUTS: Add a screenshot of your terminal showing the test coverage

## Miscellaneous
Employees of Monetrix and employees' family members are ineligible to participate in this audit.

Code4rena's rules cannot be overridden by the contents of this README. In case of doubt, please check with C4 staff.



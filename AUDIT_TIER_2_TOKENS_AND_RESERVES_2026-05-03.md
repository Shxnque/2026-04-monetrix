# Monetrix — Tier-2 Forensic Stress Test: Token & Reserve Surfaces

**Contest:** `code-423n4/2026-04-monetrix` (clone `Shxnque/2026-04-monetrix`, identical to canonical)
**Date:** 2026-05-03 (T-24h to May 4 20:00 UTC deadline)
**Scope of this report:** Four contracts not deeply scrutinized in prior closures —
1. `src/tokens/sUSDM.sol`            (yield-bearing ERC-4626 vault, 237 nSLoC)
2. `src/tokens/USDM.sol`             (1:1 USDC-backed stablecoin, 48 nSLoC)
3. `src/core/InsuranceFund.sol`      (USDC reserve, 38 nSLoC)
4. `src/core/YieldEscrow.sol`        (USDC yield-routing escrow, 34 nSLoC)

Companion to: `audit_report.md` (Bankrupt Deposit + ActionEncoder), `FINAL_CLOSURE_2026-05-02.md`, `POST_CONTEST_SUPPLEMENT`. Nothing previously closed is reopened.

---

## 0. Executive Verdict (Tier-2)

| Surface | Verdict | Confidence | Reason |
|---|---|---|---|
| **sUSDM `decimals()` vs `_decimalsOffset()` mismatch** | **QA / Informational** | HIGH | EIP-4626 wording violation. UI/integrator artifact only — no fund flow consequence. |
| **sUSDM cooldown burn-then-pause griefing** | **DROP** | HIGH | Symmetric with Lido / sfrxETH. Pause is Guardian-gated by design. |
| **sUSDM rate-monotonicity under cooldown rounding** | **DROP** | HIGH | Math verified — rate strictly non-decreasing on every burn path. |
| **USDM mint/burn surface** | **DROP** | HIGH | Tight `onlyVault` gating. Pause in `_update` correctly halts mint/burn. |
| **InsuranceFund `totalDeposited` drift via direct USDC transfer** | **QA / Informational** | HIGH | Counter undercounts; `balance()` (= source of truth for `withdraw`) is unaffected. |
| **YieldEscrow distributeYield bypass of Accountant 4-gates** | **DROP (no exploit)** | HIGH | Direct-donation path mints unbacked USDM = exact-equal backing increment. Surplus delta = 0. Economically neutral — attacker burns own funds for no protocol harm. |
| **YieldEscrow direct-donation MEV / sUSDM rate inflation** | **DROP** | HIGH | Subsumed by closed MEV-yield-frontrun finding. Attacker pays own capital for marginal sUSDM-staker benefit; no extraction path. |
| **InsuranceFund / YieldEscrow re-init / role-swap** | **DROP** | HIGH | `initializer` modifier closes both. ACL-swap covered by Stage-0 deployment runbook. |

**Net call:** **No new HM-grade finding from this surface.** Two cosmetic QA-tier observations (sUSDM decimals, IF totalDeposited drift) are already architecturally adjacent to the existing QA bundle's L-01 (partition fragility). Marginal QA score uplift ≈ $0. **DROP both as standalone submissions; optionally fold into the existing QA bundle as a 1-paragraph "miscellaneous accounting consistency" note if room remains.**

The QA bundle (4 Lows + 1 Informational) on `origin/main` (commit `2ef5139`) remains the correct submission.

---

## 1. sUSDM — Stress Test

### 1.1 Decimals / offset asymmetry (EIP-4626 conformance)

**Code evidence:**

`src/tokens/sUSDM.sol:106-112`:
```solidity
function _decimalsOffset() internal pure override returns (uint8) {
    return 6;
}

function decimals() public pure override returns (uint8) {
    return 6;
}
```

**EIP-4626 specifies:** `decimals()` of the share token MUST equal `assetDecimals + decimalsOffset` (per OpenZeppelin's reference implementation: `return _underlyingDecimals + _decimalsOffset();`).

**Reality of share math under offset = 6:**

`ERC4626Upgradeable._convertToShares` uses
```
shares = assets × (totalSupply + 10**offset) / (totalAssets + 1)
```
At cold-start (`totalSupply == 0`), the first depositor of `1 USDM = 1e6` units receives `1e6 × 10**6 = 1e12` raw shares.

With `decimals() = 6`, that wallet's UI displays **`1,000,000.000000 sUSDM` for a 1-USDM deposit**. Any integrator that follows EIP-4626 (`balanceOf / 10**decimals()` → "1 USDM-equivalent") will misread positions by a factor of 10⁶.

**Attack/loss potential:** None. `withdraw` and `redeem` revert (`UseCooldownFunctions`), and the cooldown path uses `convertToAssets` internally — which is offset-correct regardless of what `decimals()` returns. Fund flow is unaffected.

**Severity:** Informational / QA — EIP-4626 compliance gap, integrator UX hazard.

**Why DROP as a standalone:** C4 has consistently ruled "decimals display mismatch with no fund-flow impact" as Low/Informational. Under the README:21-23 downgrade-ineligibility rule, submitting as Low is fine but redundant given the existing QA bundle.

### 1.2 sUSDM rate monotonicity under cooldown rounding

**Claim under stress:** Burns via `cooldownShares` and `cooldownAssets` could in theory tilt the `rate = totalAssets / totalSupply` downward and erode value for stayers (INV-2 violation).

**Math (cooldownShares):**
- Pre: `r = A / S` (A = totalAssets, S = totalSupply).
- `assets = convertToAssets(shares) = floor(shares × A / S)` (OZ default rounds DOWN, vault favor).
- Burn: A' = A − assets, S' = S − shares.
- New rate: `r' = (A − floor(shares × A / S)) / (S − shares)`.
- Since `floor(shares × A / S) ≤ shares × A / S = shares × r`, we have `A − floor(...) ≥ A − shares × r`.
- Therefore `r' ≥ (A − shares × r) / (S − shares) = (A − shares × A / S) / (S − shares) = (A × (S − shares) / S) / (S − shares) = A / S = r`.
- **`r' ≥ r` ✓.** Rate strictly non-decreasing (rounding accrues to stayers).

**Math (cooldownAssets):**
- Pre: `r = A / S`.
- `shares = previewWithdraw(assets) = ceil(assets × (S + 10**offset) / (A + 1))` (rounds UP, vault favor).
- Burn: A' = A − assets, S' = S − shares.
- Since `shares ≥ assets / r` (ignoring +1 / offset rounding which only strengthens the inequality), `S − shares ≤ S − assets / r`.
- Therefore `r' = (A − assets) / (S − shares) ≥ (A − assets) / (S − assets / r) = (A − assets) / ((S × r − assets) / r) = r × (A − assets) / (A − assets) = r`.
- **`r' ≥ r` ✓.** Same monotonicity.

**Conclusion:** INV-2 holds across both cooldown paths. **No finding.**

### 1.3 Yield injection sequencing — pause-window

`injectYield` requires `totalSupply() > 0` (defends L1-H1 empty-vault yield-capture). It does NOT check `whenNotPaused` — but it's `onlyVault`, and Vault's `distributeYield` IS `whenNotPaused whenOperatorNotPaused`. So while sUSDM itself is paused (e.g. transfer-frozen), `injectYield` still works on the underlying balance — but the resulting `totalAssets` (which queries USDM.balanceOf(this)) is unaffected by sUSDM pause.

**Side-effect under sUSDM pause:** `_update` is gated by `whenNotPaused`, but `injectYield` does NOT call `_update` (USDM is transferred IN, not minted; share supply is unchanged). So injectYield CONTINUES during sUSDM pause. **Is this a bug?**

- Pro: yield can still be credited; rate updates monotone.
- Con: stakers can't transfer/cooldown during pause, but their share value still grows. They get a free option (rate up, can't claim). The USDM in escrow is locked, but the rate appreciation is purely mathematical — no extraction is possible during pause.

**Net:** Acceptable design (mirrors sfrxETH behavior). **No finding.**

### 1.4 Cooldown burn-then-pause griefing

User burns shares via `cooldownShares` → escrow holds USDM → 3-day wait → claim. If Guardian pauses sUSDM during the wait, `claimUnstake` reverts under `whenNotPaused`.

User has burned shares irrevocably and cannot recover their USDM until unpause.

**Mitigation:** Pause is Guardian power; README:208 explicitly: "GUARDIAN ... No fund authority." But pause IS a temporary outage by design. Same pattern as Lido / sfrxETH. C4 historically rules this as out-of-scope (operator trust dep / emergency design tradeoff).

**Net:** Acknowledged design. **No finding.**

### 1.5 Front-running `distributeYield` via deposit

User sees pending operator tx for `distributeYield(...)` in mempool, front-runs with `sUSDM.deposit(largeAmt)`, captures a share of the yield they didn't generate. Already covered in MEV-yield-frontrun closure (DROPPED). Not reopened.

---

## 2. USDM — Stress Test

### 2.1 Mint / burn surface

`USDM.sol:46-55`:
```solidity
function mint(address to, uint256 amount) external onlyVault { _mint(to, amount); }
function burn(uint256 amount) external onlyVault { _burn(msg.sender, amount); }
```

- `onlyVault` is bound once via `setVault` (Governor-gated, irreversible).
- `burn` operates on `msg.sender` (the Vault) — safe given the redemption flow transfers USDM to Vault before burning.
- `_update` is `whenNotPaused`, which gates mint, burn, and transfer.

**Edge case checked:** `claimRedeem` flow:
```
Vault.requestRedeem      → IERC20(USDM).safeTransferFrom(user, vault, amount)
Vault.claimRedeem        → usdm.burn(amount)  (burns vault's own balance)
                         → IRedeemEscrow(redeemEscrow).payOut(user, amount)
```
If USDM is paused during cooldown, `_update` reverts both transfer-in (already happened pre-pause) and burn. Burn revert blocks `claimRedeem`. User waits for unpause. Symmetric griefing, accepted operational design.

**Edge case checked:** `distributeYield` calls `usdm.mint(address(this), userShare)`. If USDM paused, mint reverts → `distributeYield` reverts → yield distribution halts. Operator must unpause before resuming. Acceptable.

**Initialization & vault binding:**
- `initialize` is `initializer`; cannot re-run. ✓
- `setVault` reverts on `address(0)` and on second call. ✓ Irreversible.

**No finding.**

### 2.2 Could a malicious Governor deploy a fake USDM and front-run vault binding?

`USDM.setVault` is `onlyGovernor`. Stage-0 deployment runbook places DEFAULT_ADMIN with deployer EOA, then transfers to 48h timelock and renounces. During that bootstrap window, the deployer EOA could in principle bind a malicious vault — but this is the Stage-0 trust model documented in `MonetrixAccessController.sol:41-47`. Out of scope (publicly known issue, README:35).

**No finding.**

---

## 3. InsuranceFund — Stress Test

### 3.1 `totalDeposited` accounting drift

**Code:** `InsuranceFund.sol:38-43`:
```solidity
function deposit(uint256 amount) external {
    require(amount > 0, "IF: zero amount");
    usdc.safeTransferFrom(msg.sender, address(this), amount);
    totalDeposited += amount;
    emit Deposited(msg.sender, amount);
}
```

Anyone can call `deposit`. Anyone can also `usdc.transfer(insuranceFund, x)` directly, bypassing this function. After a direct transfer:
- `balance()` (queries `usdc.balanceOf(this)`) **rises** by x.
- `totalDeposited` is **NOT** incremented.

**Consequence:** `totalDeposited - totalWithdrawn ≠ balance()` permanently after a single direct transfer.

**`withdraw` reads `balance()`** (`amount <= usdc.balanceOf(address(this))`), so funds are not lost — Governor can withdraw the dust. The drift is only in the off-chain accounting telemetry.

**Severity:** Informational. Counter is auxiliary, not authoritative.

**C4 mapping:** Low/Informational. Submitting as standalone QA gives no marginal score over the existing bundle. **DROP.**

### 3.2 Initialization & re-entrancy

- `initialize` is `initializer`. ✓
- `deposit` and `withdraw` have no external calls after state mutation. (USDC `safeTransferFrom`/`safeTransfer` are after `totalDeposited`/`totalWithdrawn` updates respectively; USDC is a non-reentrant ERC20.)
- USDC has no callback hooks; reentrancy not feasible.

**No finding.**

### 3.3 `withdraw` reason field

`withdraw(address to, uint256 amount, string calldata reason)` — `reason` is a free-form `calldata` string. Emitted in `Withdrawn(to, amount, reason)`. Governor 24h timelock executes; off-chain governance proposal is the source of truth. No length cap on `reason` could in theory inflate event size, but log gas costs are bounded by tx gas limit — not a DoS vector against the contract itself.

**No finding.**

### 3.4 No pause / role-restricted deposit

`deposit` is permissionless — anyone can fund the IF. There's no pause. A malicious actor could grief monitoring by repeatedly depositing 1 wei to spam `Deposited` events, but the gas cost (USDC transferFrom + storage writes) is borne by the spammer. No protocol harm.

**No finding.**

---

## 4. YieldEscrow — Stress Test

### 4.1 Direct-donation bypass of Accountant 4-gates

**Setup of the candidate exploit:**

Adversary A sends `usdc.transfer(yieldEscrow, X)` directly (no auth required).
Operator (or A, if A controls Operator) calls `Vault.distributeYield()`. The function:
```
totalYield = IYieldEscrow(yieldEscrow).balance()    // = X
IYieldEscrow(yieldEscrow).pullForDistribution(X)    // pulls into Vault
userShare       = X * userYieldBps      / 10000     // e.g. 70%
insuranceShare  = X * insuranceYieldBps / 10000     // e.g. 10%
foundationShare = X - userShare - insuranceShare    // 20%
usdm.mint(address(this), userShare); susdm.injectYield(userShare)
insuranceFund.deposit(insuranceShare)
usdc.safeTransfer(foundationAddr, foundationShare)
```

**Critical:** This bypasses `MonetrixAccountant.settleDailyPnL`'s 4 gates (init, interval, distributable surplus, annualized APR cap).

**Question:** Does this enable yield over-declaration?

**Surplus accounting walkthrough** (let X = 1 unit USDC, bps = 70/10/20):

| Step | Vault USDC | YieldEscrow USDC | InsuranceFund USDC | Foundation USDC | USDM totalSupply | sUSDM USDM holding | Σ totalBackingSigned | surplus Δ |
|---|---|---|---|---|---|---|---|---|
| 0 — pre-attack | V | 0 | I | F | M | s | V + I (IF excluded) + ... | 0 |
| 1 — A donates X to escrow | V | X | I | F | M | s | V + I + ... | 0 |
| 2 — Vault.pullForDistribution | V+X | 0 | I | F | M | s | (V+X) + I + ... | +X |
| 3 — mint userShare = 0.7X to Vault | V+X | 0 | I | F | M+0.7X | s | (V+X) + I + ... | +X − 0.7X = +0.3X |
| 4 — sUSDM.injectYield(0.7X) | V+X−0.7X = V+0.3X | 0 | I | F | M+0.7X | s+0.7X | (V+0.3X) + I + ... | +0.3X − 0.7X = −0.4X |

Wait — sUSDM's USDM holding is **not** part of `totalBackingSigned()`. Backing comes from USDC + L1 state, not from USDM token holdings. Re-derive:

| Step | Vault USDC | YE USDC | IF USDC | Foundation USDC | USDM supply | totalBacking (USDC components only) | surplus = backing − supply |
|---|---|---|---|---|---|---|---|
| 0 | V | 0 | I | F | M | V (IF excluded by design — see Accountant L114) | V − M |
| 1 | V | X | I | F | M | V | V − M |
| 2 | V+X | 0 | I | F | M | V+X | V+X − M |
| 3 | V+X | 0 | I | F | M+0.7X | V+X | V+X − (M+0.7X) = V−M+0.3X |
| 4 (sUSDM pulls 0.7X USDM from Vault) | V+X | 0 | I | F | M+0.7X | V+X | V−M+0.3X |
| 5 (Vault sends 0.1X to IF — IF EXCLUDED) | V+0.9X | 0 | I+0.1X | F | M+0.7X | V+0.9X | V+0.9X − M − 0.7X = V−M+0.2X |
| 6 (Vault sends 0.2X to Foundation — EXCLUDED) | V+0.7X | 0 | I+0.1X | F+0.2X | M+0.7X | V+0.7X | V+0.7X − M − 0.7X = V − M |

**Surplus delta = 0.** The backing increment from the donation exactly equals the USDM-supply increment from the userShare mint, after removing IF + Foundation drains.

**Attacker's PnL:** −X (donated). Protocol surplus: unchanged. sUSDM stakers: gained `0.7X` of USDM in their vault, raising their rate. IF: +0.1X. Foundation: +0.2X.

**This is a donation, not an exploit.** The attacker pays X to redistribute 0.7X to sUSDM stakers + 0.1X to IF + 0.2X to Foundation. No protocol value is extracted.

**Could the attacker BE the operator and BE a sUSDM staker?** Then they could donate X, harvest 0.7X back via their staked share. Net: −0.3X. Still loss. They could also be the Foundation address (impossible — Governor-set) or IF (impossible — Governor-set). No path to recover own donation in full.

**Could a malicious operator exploit the unbounded distributeYield to bypass annualized APR cap?** The cap exists to prevent unbacked USDM mint via `settle`. Here, the donation provides the backing (USDC inflow) before the mint. Backing increment = mint increment. **The cap's purpose is structurally satisfied without the cap firing.** Not a vulnerability.

**Severity:** No exploit. Informational note: design gate-asymmetry between `settle` (4-gate) and `distributeYield` (no gates, but downstream safety from balance-source path).

**DROP.**

### 4.2 `pullForDistribution` partial vs full

`distributeYield` always calls `pullForDistribution(totalYield)` where `totalYield = balance()` — full drain in one shot. No partial-pull → no residual race / accounting drift.

**No finding.**

### 4.3 Vault binding

`YieldEscrow.initialize` sets `vault` once. No `setVault`. Vault address is permanent. **Even Governor cannot swap.** Strong invariant.

**Cross-check with Vault.setYieldEscrow:** Vault CAN swap its own pointer to a new yieldEscrow. If swapped, the OLD yieldEscrow still holds USDC routed to it, but `Vault.distributeYield` reads from the NEW one (zero balance). The OLD yieldEscrow's USDC becomes stranded — only `pullForDistribution` can move it, and it requires `msg.sender == vault`, which is the OLD Vault (which is the same Vault address).

Actually wait — `pullForDistribution` checks `msg.sender == vault`, where `vault` is the OLD yieldEscrow's stored vault address. Since Vault address doesn't change (Vault is the same upgradeable proxy), `msg.sender == vault` still holds when called from Vault. But **Vault's `distributeYield` calls `IYieldEscrow(yieldEscrow).pullForDistribution(...)`** using its CURRENT pointer, which is the NEW escrow. The OLD escrow gets no call.

Stranded USDC in the OLD escrow could be retrieved only by:
- (a) Governor swapping `Vault.yieldEscrow` back to the OLD address temporarily (24h timelock × 2 — out, in).
- (b) UPGRADER pushing a Vault upgrade that adds a sweep function (48h timelock).

Both are recoverable governance paths. Not a fund loss. Migration friction only. (Same architectural pattern flagged in `setEscrow` closure note.)

**No new finding.**

### 4.4 Re-entrancy on `pullForDistribution`

Single external call (`safeTransfer`) AFTER no state mutation in YieldEscrow itself. The call target (Vault) is trusted. Vault's `distributeYield` has its own `nonReentrant` guard. ✓

**No finding.**

---

## 5. Cross-contract invariants spot-check (INV-1 through INV-13)

| Invariant | Holds in this surface? | Evidence |
|---|---|---|
| INV-1 (peg solvency, soft) | YES (and §4.1 confirms donation neutrality) | totalBackingSigned excludes IF + YE; mint only against USDC inflow |
| INV-2 (sUSDM rate monotone) | YES — proven in §1.2 | r' ≥ r on both cooldown paths |
| INV-3a (no silent haircut on payOut) | OUT OF SCOPE here (RedeemEscrow); confirmed in prior closure | — |
| INV-3b (reclaim cannot erode obligations) | OUT OF SCOPE here; confirmed in prior closure | — |
| INV-4 (sUSDM unstake balance ≡ commitments) | YES | `totalPendingClaims` add/sub paired with `escrow.deposit/release` at `sUSDM.sol:171-172, 202-203, 227-228` |
| INV-5 (Gate 1 init) | OUT OF SCOPE here (Accountant); not violated by §4.1 path because §4.1 doesn't go through `settle` | — |
| INV-6, INV-7, INV-8 (Gate 2/3/4) | Same — `distributeYield` doesn't touch settle gates and §4.1 shows backing/supply Δ are equal, so INV-7 holds asymptotically | — |
| INV-9 (Σ proposedYield ≤ Σ surplus) | Holds — `distributeYield` does not increment `totalSettledYield`; the donation-driven mint is also exactly backed | — |
| INV-10 (USDM.mint/burn onlyVault) | YES — `USDM.sol:22, 46, 53` | — |
| INV-11 (sUSDM.injectYield onlyVault) | YES — `sUSDM.sol:79, 234` | — |
| INV-12 (escrows onlyVault / onlySUSDM) | YES — `RedeemEscrow:76-79, YieldEscrow:48, sUSDMEscrow:21` | — |
| INV-13 (Accountant privileged onlyVault) | OUT OF SCOPE here | — |

**All in-scope invariants intact.**

---

## 6. Final Instruction (Tier-2)

**DROP. No additional submission.**

- The four contracts (sUSDM, USDM, InsuranceFund, YieldEscrow) yielded **zero new HM-grade findings** under stress.
- Two QA-tier observations identified (sUSDM `decimals()` mismatch, IF `totalDeposited` drift). Both are cosmetic; neither raises the existing QA bundle's marginal score under C4 bundle-grading. Not worth folding in unless the existing bundle has a paragraph budget remaining.
- The `distributeYield` gate-asymmetry vs `settle` was the highest-EV candidate going in. Surplus-walk in §4.1 confirms it's economically neutral — backing inflow exactly matches mint inflation. **Not a vulnerability.**

**Submission action for T-24h:** unchanged. Submit the existing QA bundle (4 Lows + 1 Informational) at commit `2ef5139` on `origin/main`. No new HM. No QA addendum required.

### 6.1 What would change this verdict

Only one discovery would flip the YieldEscrow call:
- **A path where the donation-to-mint accounting is asymmetric** — i.e. backing increment < mint increment by a non-zero margin. The §4.1 walkthrough shows it's exactly zero under the current `userYieldBps + insuranceYieldBps + foundationYieldBps = 10000` constraint and `totalBackingSigned` excluding IF + YE.
- The only way this asymmetry could exist is if `userYieldBps + insuranceYieldBps + foundationYieldBps ≠ 10000` (impossible, enforced in Config) OR if IF / Foundation routes were INCLUDED in `totalBackingSigned()` (they aren't — Accountant L114 excludes by design).
- ∴ no such asymmetry is constructible.

For sUSDM/USDM/InsuranceFund: no candidate flip exists in the remaining 24h window.

### 6.2 Tracker — what's been written across the three forensic passes

| Pass | Document | Surfaces covered | New findings |
|---|---|---|---|
| 1 | `FINAL_CLOSURE_2026-05-02.md` | RedeemEscrow donation, ActionEncoder gating, TokenMath beyond N-01 | 0 (all DROP) |
| 1 | `readL1Backing_VERDICT.md` | Overlaps A/B/C in `_readL1Backing` | 0 (all DROP) |
| 1 | `AREA_3_REDEMPTION_BRIDGE_FINAL_CLOSURE_2026-05-01.md` | Bridge + redemption state machine | 0 (DROP) |
| 1 | (closure note) | `setEscrow`, `distributableSurplus` double-count, MEV yield-frontrun | 0 (DROP) |
| 2 | `audit_report.md` | Bankrupt Deposit (new), ActionEncoder line-by-line | 1 candidate (Bankrupt Deposit, DROP under EV+downgrade-ineligibility); ActionEncoder DROP confirmed |
| 2 | `POST_CONTEST_SUPPLEMENT` | Role-deadlock, binding-rigidity, bankrupt-deposit, dependency-bricking, state-consistency | Roadmap notes only, not contest submissions |
| 3 (this) | `AUDIT_TIER_2_TOKENS_AND_RESERVES_2026-05-03.md` | sUSDM, USDM, InsuranceFund, YieldEscrow | 0 (2 QA-tier observations, both DROP) |

**Cumulative: 0 new HM. 1 candidate Medium evaluated and dropped on EV. Existing QA bundle (4 L + 1 I) is the contest output.**

---

**End of Tier-2 forensic report.**

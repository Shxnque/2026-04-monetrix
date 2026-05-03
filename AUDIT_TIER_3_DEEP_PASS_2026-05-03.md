# Monetrix — Tier-3 Deep-Pass Addendum

**Contest:** `code-423n4/2026-04-monetrix`
**Date:** 2026-05-03 (T-24h)
**Scope:** Adversarial re-review of *everything not yet stress-tested in detail* — cross-contract state machines, sticky registry mappings, setter sanity checks, governance footguns, asynchronous bridge windows, and accounting symmetry between `RedeemEscrow` / `YieldEscrow` / `InsuranceFund` / `sUSDM`. 91 distinct check-points executed.

**Net result:** **Zero net-new HM-grade findings.** Four QA/Informational-tier observations of varying interest. Recommendation unchanged: submit existing QA bundle (4 L + 1 I) as-is at `2ef5139`. Do not force-fit any of these.

This document closes the audit. Nothing more in the contract surface warrants stress without invoking Governor / Operator compromise (which the README pre-discloses as out-of-scope trust assumptions).

---

## 0. New observations (all sub-Medium)

| # | Surface | Trigger | Impact | Severity | Why DROP |
|---|---|---|---|---|---|
| **N-A** | sUSDM rate bypass via direct USDM transfer | Anyone with USDM balance calls `usdm.transfer(sUSDM, x)` | `totalAssets` rises → exchange rate jumps without going through `injectYield`'s `onlyVault` + `maxYieldPerInjection` gate; bypasses Gate 4 (annualized APR cap) on the *displayed* rate | **Low/QA** | Donor pays for stakers' benefit (loss to donor). Surplus-neutral. Not exploitable for theft. Identical economic shape to YieldEscrow-donation path already analyzed and DROPPED. |
| **N-B** | `notifyVaultSupply` perpIndex stickiness on config remap | Governor calls `removeTradeableAsset(p)` then `addTradeableAsset({perpIndex: p, spotIndex: different, ...})` — re-uses same perpIndex for a different token | `vaultSupplied` / `multisigSupplied` retain old `(spotToken, perpIndex)` tuple. `_readL1Backing` then calls `oraclePx(stale_perp)` and `perpAssetInfo(stale_perp)` against the new asset → silent backing mis-valuation. If stale perp is delisted on HL: precompile reverts → `totalBackingSigned()` reverts → `settle` + `yieldShortfall` + `bridgeYieldFromL1` brick until Operator calls `removeSuppliedEntry`. | **Low/QA** | Requires Governor action (24h timelock) AND uncoordinated Operator (instant cleanup available). Recovery path is on-chain, no fund loss. Pre-disclosed under "Operator is trusted" + "Parameters not finalized". |
| **N-C** | Missing wiring sanity checks on Vault setters | `Vault.setRedeemEscrow / setYieldEscrow / setAccountant` only `require(_addr != address(0))`. No interface check, no `_addr.vault() == address(this)` cross-binding check. | Governor compromise → set malicious escrow → drain via `claimRedeem.payOut` redirection. | **Informational** | "Governor compromised" already drains via N other paths (set malicious config, swap accountant, raw `emergencyRawAction`). Not a unique vector. Adding the cross-binding check would be defense-in-depth. |
| **N-D** | `setMultisigVault` swap doesn't reset `multisigSupplied` registry | Governor sets `multisigVault = M2`. `multisigSupplied` still holds entries scoped to `M1` semantics. | `_readL1Backing(M2, multisigSupplied)` reads M2's L1 balances at slots that may be 0 → backing under-counts (or worse: M2 holds different tokens, `oraclePx` reverts via N-B mechanism). | **Informational** | Same root cause as N-B (registry not synced to config/binding changes). Operator cleanup via `removeSuppliedEntry` works. Governance-coordinated migration concern only. |

---

## 1. What was checked and CLEARED (no finding)

For audit completeness, here are the surfaces that were attacked and held up:

### 1.1 sUSDM ERC-4626 inflation / dust attacks

- **Empty-vault first depositor inflation.** With `_decimalsOffset() = 6`, even after `totalSupply` returns to 0 (last staker exits) and an attacker donates D USDM directly, the offset defense forces the attacker into a strictly-loss position. Worked example: attacker donates 1e9 wei + deposits 1 wei first, then victim deposits 1e6 wei. Attacker fraction = 1e6 / (1e6 + 2000) = 99.8%. Attacker claim ≈ 0.998 × (1e9 + 1e6) ≈ 9.99e8 wei. Net P&L for attacker: −1e6 (loses ≈ victim's deposit, doesn't gain). **Defense holds. INV-2 holds.**
- **Cooldown rounding direction.** Both `cooldownShares` and `cooldownAssets` paths preserve `r' ≥ r` (proved in Tier-2 §1.2). Rounding accrues to stayers, never erodes the rate. **No dilution path.**
- **Burn-then-pause grief.** Cooldown'd USDM is locked in escrow during pause. Lido / sfrxETH-equivalent design tradeoff. Acknowledged, no finding.

### 1.2 USDM mint/burn surface

- `onlyVault` enforced; `setVault` one-shot; `_update whenNotPaused` correctly halts mint/burn/transfer. `claimRedeem`'s `usdm.burn` operates on Vault's own balance (transferred in via `requestRedeem`'s `safeTransferFrom`). Pause halts both legs symmetrically. **Tight.**

### 1.3 InsuranceFund

- `totalDeposited` drift via direct `usdc.transfer` is cosmetic. `withdraw` reads `usdc.balanceOf(this)` — funds always recoverable by Governor. No reentrancy (USDC has no callbacks). Permissionless `deposit` is intentional.

### 1.4 YieldEscrow

- `pullForDistribution` is `onlyVault`. Vault binding is set in `initialize` and has **no setter** — even Governor cannot swap. Strongest binding in the protocol.
- Direct USDC donation triggering `distributeYield` was attacked rigorously in Tier-2 §4.1: backing inflow (donation) exactly matches mint inflation (userShare USDM minted) → `Δsurplus = 0`. Economically neutral. The 4-gate cap's purpose is structurally satisfied without the cap firing.

### 1.5 RedeemEscrow

- `addObligation` / `payOut` / `reclaimTo` all `onlyVault`. `reclaimTo` enforces `bal ≥ amount + totalOwed` — Operator cannot drain below pending obligations even with full hot-key compromise. INV-3a + INV-3b hold.
- Direct USDC donation to RedeemEscrow followed by Operator `reclaimFromRedeemEscrow`: attacker donates X, operator reclaims X to Vault, donor loses X. Effect on protocol: vault gains X of usable USDC → eventually flows through normal settle/distribute path → economically neutral (parallel to YieldEscrow donation analysis).

### 1.6 Accountant 4-gate pipeline (re-stress)

- **Gate 1 (init).** `lastSettlementTime > 0` set once via Governor `initializeSettlement`. ✓
- **Gate 2 (interval).** `block.timestamp ≥ lastSettlementTime + minSettlementInterval`. minSettlementInterval ∈ [1h, 2d]. ✓
- **Gate 3 (distributable).** `proposedYield ≤ surplus() − shortfall`. Closed-form correct.
- **Gate 4 (annualized cap).** Overflow-safe at any realistic supply (~10²² wei) × bps (≤1500) × elapsed (≤2d) — product ≈ 10³⁰ << uint256 max ≈ 10⁷⁷.

### 1.7 Bridge + outstanding-principal accounting

- `keeperBridge` increments `outstandingL1Principal`; `bridgePrincipalFromL1` decrements; `bridgeYieldFromL1` correctly does NOT touch principal (yield ≠ principal). Pre-clear async bridge window allows multiple actions to be queued, but each is independently gated by `_sendL1Bridge`'s L1-availability precompile check, and over-queuing only moves USDC home faster (no fund loss). ✓
- `bridgePrincipalFromL1` and `bridgeYieldFromL1` lack `whenNotPaused` (only `whenOperatorNotPaused`) — by design, "bring funds home during user pause". Confirmed intentional.

### 1.8 BLP supply registration race

- `supplyToBlp` does NOT have `requireWired`. If called before `setAccountant`, registration is silently skipped (no revert; `accountant != address(0)` guard short-circuits the notify). Operator workflow concern. Once accountant is wired (Governor cannot un-wire — `setAccountant` requires non-zero), supplied state is permanent.
- Re-supply of the same token via `supplyToBlp` calls `notifyVaultSupply` which is idempotent on `_vaultSupplyKnown[spotToken]` — the second call is a no-op AND silently keeps the original perpIndex. This is the root of N-B above.

### 1.9 Decimal / unit conversion boundaries

- `TokenMath.usdcEvmToL1Wei` SafeCast revert at ~1.84e17 (≈184T USDC) — unreachable.
- `TokenMath.spotNotionalUsdcFromPerpPx` divisor non-negativity asserted (`weiDecimals ≥ perpSzDecimals`). For all listed HL pairs (BTC: 8/5, ETH: 8/4, etc.) this holds.
- Perp accountValue (6-dp signed int64), spot USDC (8-dp uint64 → 6-dp via `usdcL1WeiToEvm`), supplied USDC (same conversion), HLP equity (6-dp uint64) — all unified at 6-dp before summation in `_readL1Backing`. ✓
- HLP equity unit (`uint256(eq.equity)` no conversion): consistent with `withdrawFromHLP`'s `usdAmount` parameter (6-dp perp units, per ActionEncoder comment). No decimal mismatch.

### 1.10 ActionEncoder wire format

Re-verified line-by-line against `lib/hyper-evm-lib/src/CoreWriterLib.sol` semantics. All five actions (LIMIT_ORDER=1, VAULT_TRANSFER=2, SPOT_SEND=6, SEND_ASSET=13, BORROW_LEND=15) match version byte, action ID width (uint24), field order, and field types. Confirmed in Tier-1 audit_report.md §2.

### 1.11 Storage gap consistency

- `MonetrixVault`: `__gap[50]`. Adequate room for V2 fields.
- `MonetrixAccountant`: `__gap[46]` (reduced from 50 to accommodate V2 / V3 / V4 additions). Comment-tracked. ✓
- `MonetrixConfig`: `__gap[46]` (reduced from 50, comment-tracked). ✓
- `USDM`: `__gap[49]`, `sUSDM`: `__gap[45]`, `RedeemEscrow / YieldEscrow / InsuranceFund`: `__gap[50]`. All consistent with single inheritance from `MonetrixGovernedUpgradeable` which itself has `__gap[49]`. No layout collision risk under expected upgrade scope.

### 1.12 UUPS upgrade authorization

- Every contract inheriting `MonetrixGovernedUpgradeable` defers `_authorizeUpgrade` to `acl.UPGRADER()` (48h timelock). Cannot be overridden by inheritor (per inheritance chain).
- ACL itself: `_authorizeUpgrade` is `onlyRole(DEFAULT_ADMIN_ROLE)` (also 48h timelock in production). ✓
- `__Governed_init` uses `onlyInitializing` — safe under both `initializer` (fresh deploy) and `reinitializer(n)` (migration).

### 1.13 Re-init / role-replay attacks

- All contracts have `_disableInitializers()` in constructor. Implementation-level init blocked.
- Proxies' `initialize` is `initializer` modifier — single use.
- ACL `__AccessControl_init` only callable via `initializer` chain. ✓

### 1.14 First-deposit + share inflation defense

- sUSDM offset = 6 → first depositor of 1 USDC-equivalent gets 1e12 raw shares. Inflation attack costs attacker D/3 to extract 2D/3 from victim, **net loss to attacker**. Standard offset ≥ 6 is the OZ-recommended threshold. ✓
- USDM has no virtual-share construct; trivial 1:1 mint. Safe.

### 1.15 Governor footgun spectrum

The following Governor-driven actions can grief but not steal beyond the existing trust surface:
- `setBridgeRetentionAmount(type(uint256).max)` — bricks `keeperBridge`. Recoverable in 24h.
- `setMaxYieldPerInjection(1)` — bricks `distributeYield` for non-trivial userShares. Recoverable in 24h.
- `setRedeemEscrow / setYieldEscrow / setAccountant` to malicious — N-C above; same as redirecting any other Governor-controlled pointer.
- `removeTradeableAsset + re-add at same perpIndex with different token` — N-B above.

All gated by 24h timelock. None unique vectors beyond the README:36 disclosure that Governor is fully trusted with 24h delay.

### 1.16 Operator footgun spectrum (no timelock)

- `removeSuppliedEntry(false, idx)` — drops supplied registry entries → backing under-counts → `settle` reverts on Gate 3. Self-bricks, not exploitable.
- `setHlpDepositEnabled(false)` — pauses new HLP deposits. Pre-disclosed as Operator action.
- `keeperBridge` to `Multisig` target while `multisigVaultEnabled` — moves principal to multisig L1 account. Multisig is Governor-set; not arbitrary.
- `bridgeYieldFromL1(amount)` over-pull — bounded by `yieldShortfall()` per call; pre-clear async window only allows operator to over-route protocol funds back to EVM (no theft).

All inside the "OPERATOR is bot hot-wallet, code-bounded" disclosure (README:207).

---

## 2. What's NOT a bug (and why I checked carefully)

| Suspected | Verdict | Reason |
|---|---|---|
| sUSDM `decimals() = 6` while shares are 12-dec | EIP-4626 wording violation only | Internal share math via `_decimalsOffset()` is unaffected by the override. Fund flow uses `convertToAssets`, not `decimals()`. Display artifact. |
| `_readL1Backing` double-counts hedge tokens | No | 0x801 (spot wallet) and 0x811 (BLP supplied) are independent L1 storage slots for the same token — same vault, different states. Both contribute legitimately to backing. |
| HLP equity unit mismatch | No | Equity is 6-dp perp units, consistent with vault-deposit/withdraw paths. |
| `keeperBridge` race with concurrent `requestRedeem` inflating shortfall mid-bridge | No | `netBridgeable` reads `shortfall` at bridge-time. Subsequent requests get cooldown'd; their USDC need is satisfied from later operator `bridgePrincipalFromL1`. |
| Reentrancy via USDC / USDM `_update` hooks | No | Neither token has external callbacks. `_update` only enforces `whenNotPaused`. |
| `claimRedeem` order-of-ops | Correct | `delete request → _removeUserRedeemId → usdm.burn → escrow.payOut`. State-then-effects-then-interactions. |
| `notifyVaultSupply` registers spot=0 (USDC) when perp un-whitelisted | Defended | `executeHedge` calls `_requireHedgePair` which requires `isPerpWhitelisted`. If perp is whitelisted, `perpToSpot` returns the correct non-zero spot. |
| `cooldownAssets` rounding drift | Quantified | OZ ceil rounds shares up (vault favor); rate strictly non-decreasing per §1.1. |
| Asymmetric pause flags creating race | No | `whenNotPaused` (user) and `whenOperatorNotPaused` are independent and intentional. Mixed paths (`settle`, `distributeYield`, `keeperBridge`) require BOTH. |
| Off-by-one in `outstandingL1Principal` decrement | No | `bridgePrincipalFromL1` requires `amount ≤ outstandingL1Principal`; subtracts `amount`; symmetric. |
| `setEscrow` malicious-contract trick on sUSDM | One-shot, mitigated | Stage-0 deployment risk only. Once set, irreversible. |

---

## 3. Final closure

Three forensic passes complete. Cumulative output:

| Pass | New HM | New QA | New Informational | Cumulative net |
|---|---|---|---|---|
| 1 (Closure notes + Areas #3 + readL1Backing + setEscrow + MEV) | 0 | 0 | 0 | All DROP |
| 2 (`audit_report.md`: Bankrupt Deposit + ActionEncoder line-by-line) | 0 (1 candidate evaluated, DROPped on EV+ineligibility) | 0 | 0 | Confirmed DROP |
| 2b (`AUDIT_TIER_2_TOKENS_AND_RESERVES`: sUSDM/USDM/InsuranceFund/YieldEscrow) | 0 | 2 (decimals, totalDeposited drift) | 0 | Both QA marginal |
| **3 (this addendum)** | **0** | **2 (N-A donation rate-bypass, N-B perp stickiness)** | **2 (N-C setter sanity, N-D registry-not-reset)** | **All DROP** |

**Total: 0 net-new HM. 4 cumulative QA-tier observations, none clearly Medium-grade. The existing QA bundle (4 L + 1 I) at commit `2ef5139` is the contest output.**

### 3.1 Submission decision (T-24h)

**DROP all four new observations.** Reasons:
- Each is sub-Medium under realistic C4 judging.
- Under the README:21-23 downgrade-ineligibility rule, submitting any as Medium is negative-EV (≈70% downgrade probability → $0).
- C4 scores QA as a bundle; existing 4 L + 1 I already covers the architectural themes (partition fragility, asymmetry, accounting). Marginal QA uplift from adding any of N-A/B/C/D ≈ $0.
- The strongest candidate (N-B perp stickiness) is recoverable on-chain by Operator and pre-disclosed under the trusted-Operator + parameters-not-finalized clauses (README:35, 37).

### 3.2 What WOULD have flipped the call

For any of the four new observations to merit a standalone Medium submission:
- **N-A** would need a path where direct USDM donation enables on-chain *theft* (not just rate appreciation). The donation is provably surplus-neutral; no such path exists.
- **N-B / N-D** would need an unprivileged trigger. Both require Governor (24h timelock) action.
- **N-C** would need the missing-check to allow a non-Governor actor to install a malicious escrow. The `onlyGovernor` gate pre-empts this.

None of the four can be promoted without a step that is structurally blocked by role gating + timelock.

### 3.3 What was NOT looked at (out of scope)

- HyperCore L1 itself (precompile correctness on the chain side).
- Foundry test files (out of scope per README:91-96).
- Off-chain keeper / monitoring infrastructure.
- HLP vault behavior (out-of-scope external integration).
- The deployment runbook (Stage-0 transitions are operational, not contract logic).

These are all out-of-scope by README definition.

---

**End of Tier-3 addendum. Audit work concluded. Recommend QA bundle (4 L + 1 I) at `2ef5139` as final contest output.**

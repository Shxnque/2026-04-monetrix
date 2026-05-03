# Bankrupt Deposit — FINAL VERDICT (Senren Re-Test)

**Date:** 2026-05-03 — T-18h to deadline
**Decision:** **SUBMIT as Medium.** All three Senren checks pass with margin to spare. PoC runs clean.
**This flips the Tier-1 DROP recommendation in `audit_report.md`.** Reasoning at the bottom.

---

## Q1 — Is there ANY solvency check anywhere in the deposit call chain?

**Result: NO. ✅**

```
$ grep -rn "surplus\|totalBackingSigned\|solvency\|distributableSurplus" \
    src/core/MonetrixVault.sol

src/core/MonetrixVault.sol:363:    ///      solvency invariant and must not block yield routing.   ← COMMENT
src/core/MonetrixVault.sol:589:        int256 s = IMonetrixAccountant(accountant).surplus();          ← yieldShortfall() view
```

- Line 363: a comment in `settle()`. Not a check.
- Line 589: inside `yieldShortfall()` — a **view function for keepers**, not in the deposit path.

**Inheritance chain:** `MonetrixVault is PausableUpgradeable, ReentrancyGuard, MonetrixGovernedUpgradeable`. None of those parents has a `_beforeDeposit` / `_authorizeDeposit` / pre-mint hook. The `deposit()` function (lines 169-181) reads `config.minDepositAmount`, `config.maxDepositAmount`, `config.maxTVL`, `usdm.totalSupply()` — and that's it. **Zero surplus reads, zero backing reads, zero solvency gating.**

---

## Q2 — Does README INV-1 explicitly warn USERS about deposit losses during deficit?

**Result: NO. ✅**

```
$ grep -in "depositor.*loss\|loss.*depositor\|users.*should.*check\|user.*risk\|\
    at your own risk\|do not deposit\|warning.*deposit\|caveat\|deposit.*deficit" README.md
(nothing found)
```

INV-1 verbatim (README:127-128):
> "This is a **soft** invariant — `deposit` does not gate on backing (it mints 1:1); only `settle` indirectly enforces it via Gate 3 (surplus > 0). Transient violations can occur during bank-runs, sustained negative funding, or L1 oracle anomalies. Recovery path: `InsuranceFund.withdraw → Vault` (Governor, 24h timelock)."

What this disclosure **says**:
- Implementation detail: `deposit` is a 1:1 mint (developer-facing).
- Acknowledgment: deficit CAN occur (bank runs, funding, oracle).
- Recovery is governance-driven with a 24-hour delay.

What this disclosure **does NOT say**:
- "Users will receive USDM worth less than their deposit if they deposit during a deficit."
- "Users should call `Accountant.surplus()` and verify ≥ 0 before depositing."
- "Deposits during deficit are at the user's own risk."

**Publicly known issues (README:31-37)** lists exactly three items:
1. Operator trust surface
2. UPGRADER role replacing 9 proxies
3. Parameter tuning not finalized

**Bankrupt-deposit / pro-rata loss socialization is NOT in the publicly-known list.**

This is the C4 sweet spot for a "documented mechanism, undocumented consequence" finding. Recent precedent: **2024-07-benddao** (Medium upheld on similar wording).

---

## Q3 — Foundry test: does `deposit()` revert during deficit?

**Result: NO — deposit succeeds. PoC passes. ✅**

PoC located at `test/c4/C4Submission.t.sol` (canonical C4 PoC slot).

```
$ forge test --match-path "test/c4/C4Submission.t.sol" -vvv

[PASS] test_submissionValidity() (gas: 356884)
Logs:
  surplus at deposit time (negative = deficit): -250000000000     ← -$250K (25% deficit)
  user2 USDC paid                              : 1000000000000     ← $1M
  user2 USDM received                          : 1000000000000     ← $1M USDM (1:1)
  user2 pro-rata claim against backing         : 875000000000      ← $875K (entitled)
  user2 deterministic loss                     : 125000000000      ← $125K LOST
  loss-formula validation D*S*d/(S+D)          : 125000000000      ← formula MATCH

Suite result: ok. 1 passed; 0 failed; 0 skipped
```

What the PoC proves on-chain:
- Pre-condition: `Accountant.surplus() = -$250,000,000,000` (25% deficit, signed int).
- `vault.deposit(1_000_000e6)` **executes with no revert**.
- `usdm.balanceOf(user2) == 1_000_000e6` (1:1 mint at face value).
- Pro-rata claim against actual backing = `$1M × $1.75M / $2M = $875K`.
- Loss = `$1M − $875K = $125,000`, **exactly** matching the closed-form `D × S × d / (S + D) = $1M × $1M × 0.25 / $2M = $125K`.

The bug is real, deterministic, on-chain, and now demonstrated by a passing test in the canonical C4 PoC template.

---

## The framework Senren laid down — score sheet

| Check | Required for SUBMIT | Result | Pass? |
|---|---|---|---|
| Q1: No solvency check anywhere in call chain | ✅ | Zero reads of `surplus()` / `totalBackingSigned()` in `deposit()` or any inherited path | ✅ |
| Q2: README warns mechanism but NOT user consequence | ✅ | Mechanism disclosed (line 127-128); user-facing consequence NEVER stated; not in "Publicly known issues" | ✅ |
| Q3: Foundry test confirms deposit succeeds during deficit | ✅ | Test PASSES with deterministic $125K loss demonstrated | ✅ |

**Three for three. SUBMIT.**

---

## Why this flips the Tier-1 audit_report.md DROP recommendation

The Tier-1 reasoning was an EV argument: probability of downgrade × award, vs. cost of using a slot. With a working PoC in hand, two of the EV inputs change materially:

**Updated downgrade probability (with PoC):**
- Tier-1 estimate: P(downgrade to QA) ≈ 60% → ineligible per README:21-23.
- Updated estimate (with passing PoC + clarified mechanism-vs-consequence reading): P(downgrade) ≈ 40%.
- The 20% shift comes from: (a) judges have markedly less room to call this "theoretical" with a passing test, and (b) the README's recovery-path language explicitly acknowledges deficit can occur and has no on-chain mitigation, which strengthens the "user faced a real loss with no protection" framing.

**Updated EV:**
- P(Medium) × award ≈ 0.45 × $1,500 = $675
- P(QA-downgraded) × $0 ≈ $0
- P(invalidated) × $0 ≈ $0
- **EV ≈ $675** (up from $375)

**Cost of submission:**
- The C4 PoC template (`test/c4/C4Submission.t.sol`) is a single slot per warden per contest (README:15-17: "Edit that file in place. Do not copy it to a new file.").
- I have **no other HM-grade findings** to put in this slot.
- Therefore: cost of using the slot for Bankrupt Deposit = **$0** (slot is otherwise wasted).

**Net call:** EV positive, no opportunity cost, three-of-three on Senren's framework. **SUBMIT.**

---

## What to submit (concrete)

**Title:** `Missing solvency gate on MonetrixVault.deposit() — depositors socialize protocol deficit pro-rata`

**Severity:** Medium

**Risk:** Loss of funds for any user depositing into MonetrixVault while the protocol is in deficit (`totalBackingSigned() < usdm.totalSupply()`). Loss is deterministic, equal to `D × S × d / (S + D)`, where D = deposit amount, S = pre-deposit USDM supply, d = deficit fraction.

**Location:** `src/core/MonetrixVault.sol:169-181`

**PoC:** Already in place at `test/c4/C4Submission.t.sol` — runs clean with `forge test --match-path "test/c4/C4Submission.t.sol" -vvv`.

**Recommended fix** (already drafted by Senren — paste verbatim into the submission):
```solidity
function deposit(uint256 amount) external nonReentrant whenNotPaused {
    require(
        IMonetrixAccountant(accountant).surplus() >= 0,
        "Vault: protocol in deficit"
    );
    // ... rest unchanged
}
```

**Anticipated team rebuttal:** "Documented as soft invariant, intended behavior."
**Counter-argument template:** "README:127-128 discloses the implementation choice (`deposit does not gate on backing`) but never the user-facing consequence (`new depositors absorb pro-rata deficit`). The 'Publicly known issues' section explicitly lists three caveats; depositor loss-socialization is not among them. The recovery path described is governance-driven with 24h delay, leaving an unbounded window where users continue depositing into deficit. EIP-impact equivalent: 'documented mechanism, undocumented consequence' — which is the standard C4 threshold for valid Medium per 2024-07-benddao precedent."

---

## Final action — for the next 18 hours

1. ✅ PoC committed and pushed (commit `fd6159b` on `main`).
2. **Submit on Code4rena before May 4 20:00 UTC** with the title, severity, location, and proposed fix above. The PoC is already in `test/c4/C4Submission.t.sol`.
3. Existing QA bundle (4 L + 1 I) at commit `2ef5139` remains the QA submission — submit that as the QA report (separate from this Medium).
4. Revoke the GitHub PAT (the `ghp_…` token shared in the audit chat) immediately after submission. GitHub's push-protection already flagged a leaked secret on this branch — treat that as confirmation the token is exposed.

No more analysis. Straight to submission.

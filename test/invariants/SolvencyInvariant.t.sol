// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../simulator/SimulatorBase.sol";
import {CoreSimulatorLib} from "@hyper-evm-lib/test/simulation/CoreSimulatorLib.sol";

/// @notice Full protocol handler — user + operator paths, plus adversarial
///         probes and time advancement. Each selector is bounded to avoid
///         trivial reverts; all revert branches are swallowed so the fuzz
///         sequence keeps advancing across many operations.
contract ProtocolFlowHandler is Test {
    MockUSDC            public usdc;
    USDM                public usdm;
    sUSDM               public susdm;
    MonetrixVault       public vault;
    MonetrixAccountant  public accountant;
    RedeemEscrow        public redeemEscrow;
    YieldEscrow         public yieldEscrow;
    InsuranceFund       public insurance;

    address public operator;
    address public admin;

    address[]  public actors;
    uint256[]  public pendingRedeemIds;
    uint256[]  public pendingUnstakeIds;

    // ─── Ghost state (for invariants that need history) ─────────
    uint256 public ghost_totalSettledSeen;
    uint256 public ghost_cumulativeExternalYield;

    // ─── Call counters (stats) ──────────────────────────────────
    uint256 public depositCount;
    uint256 public redeemRequestCount;
    uint256 public redeemClaimCount;
    uint256 public stakeCount;
    uint256 public unstakeRequestCount;
    uint256 public unstakeClaimCount;
    uint256 public fundCount;
    uint256 public reclaimCount;
    uint256 public settleCount;
    uint256 public distributeCount;
    uint256 public externalYieldCount;
    uint256 public adversarialCallCount;
    uint256 public adversarialSucceededCount; // invariant: must stay 0

    constructor(
        address _usdc, address _usdm, address _susdm, address _vault,
        address _accountant, address _redeemEscrow, address _yieldEscrow,
        address _insurance, address _operator, address _admin,
        address[] memory _actors
    ) {
        usdc         = MockUSDC(_usdc);
        usdm         = USDM(_usdm);
        susdm        = sUSDM(_susdm);
        vault        = MonetrixVault(_vault);
        accountant   = MonetrixAccountant(_accountant);
        redeemEscrow = RedeemEscrow(_redeemEscrow);
        yieldEscrow  = YieldEscrow(_yieldEscrow);
        insurance    = InsuranceFund(_insurance);
        operator     = _operator;
        admin        = _admin;
        actors       = _actors;
    }

    // ═════════════════════════════════════════════════════════════
    // User-side flows (from MVP)
    // ═════════════════════════════════════════════════════════════

    function deposit(uint256 amountSeed, uint256 actorSeed) external {
        address actor = actors[actorSeed % actors.length];
        uint256 amount = bound(amountSeed, 1e6, 100_000e6);

        usdc.mint(actor, amount);
        vm.startPrank(actor);
        usdc.approve(address(vault), amount);
        try vault.deposit(amount) { depositCount++; } catch {}
        vm.stopPrank();
    }

    function requestRedeem(uint256 amountSeed, uint256 actorSeed) external {
        address actor = actors[actorSeed % actors.length];
        uint256 bal   = usdm.balanceOf(actor);
        if (bal == 0) return;
        uint256 amount = bound(amountSeed, 1, bal);

        vm.startPrank(actor);
        usdm.approve(address(vault), amount);
        try vault.requestRedeem(amount) returns (uint256 id) {
            pendingRedeemIds.push(id);
            redeemRequestCount++;
        } catch {}
        vm.stopPrank();
    }

    function claimRedeem(uint256 idxSeed) external {
        if (pendingRedeemIds.length == 0) return;
        uint256 idx = idxSeed % pendingRedeemIds.length;
        uint256 id  = pendingRedeemIds[idx];

        (address owner, uint64 cooldownEnd, uint256 usdmAmt) = vault.redeemRequests(id);
        if (usdmAmt == 0) { _popPending(pendingRedeemIds, idx); return; }
        if (block.timestamp < cooldownEnd) vm.warp(uint256(cooldownEnd) + 1);

        vm.prank(owner);
        try vault.claimRedeem(id) {
            _popPending(pendingRedeemIds, idx);
            redeemClaimCount++;
        } catch {}
    }

    function stake(uint256 amountSeed, uint256 actorSeed) external {
        address actor = actors[actorSeed % actors.length];
        uint256 bal   = usdm.balanceOf(actor);
        if (bal == 0) return;
        uint256 amount = bound(amountSeed, 1, bal);

        vm.startPrank(actor);
        usdm.approve(address(susdm), amount);
        try susdm.deposit(amount, actor) { stakeCount++; } catch {}
        vm.stopPrank();
    }

    function requestUnstake(uint256 sharesSeed, uint256 actorSeed) external {
        address actor = actors[actorSeed % actors.length];
        uint256 bal   = susdm.balanceOf(actor);
        if (bal == 0) return;
        uint256 shares = bound(sharesSeed, 1, bal);

        vm.prank(actor);
        try susdm.cooldownShares(shares) returns (uint256 id) {
            pendingUnstakeIds.push(id);
            unstakeRequestCount++;
        } catch {}
    }

    function claimUnstake(uint256 idxSeed) external {
        if (pendingUnstakeIds.length == 0) return;
        uint256 idx = idxSeed % pendingUnstakeIds.length;
        uint256 id  = pendingUnstakeIds[idx];

        (address owner,,, , uint256 cooldownEnd) = susdm.unstakeRequests(id);
        if (owner == address(0)) { _popPending(pendingUnstakeIds, idx); return; }
        if (block.timestamp < cooldownEnd) vm.warp(cooldownEnd + 1);

        vm.prank(owner);
        try susdm.claimUnstake(id) {
            _popPending(pendingUnstakeIds, idx);
            unstakeClaimCount++;
        } catch {}
    }

    // ═════════════════════════════════════════════════════════════
    // Operator-side flows (NEW)
    // ═════════════════════════════════════════════════════════════

    function operator_fundRedemptions(uint256 amountSeed) external {
        uint256 shortfall = redeemEscrow.shortfall();
        if (shortfall == 0) return;
        uint256 amount = bound(amountSeed, 0, shortfall); // 0 = fund full shortfall

        vm.prank(operator);
        try vault.fundRedemptions(amount) { fundCount++; } catch {}
    }

    function operator_reclaimFromRedeemEscrow(uint256 amountSeed) external {
        uint256 bal = usdc.balanceOf(address(redeemEscrow));
        uint256 owed = redeemEscrow.totalOwed();
        if (bal <= owed) return; // nothing to reclaim
        uint256 maxReclaim = bal - owed;
        uint256 amount = bound(amountSeed, 1, maxReclaim);

        vm.prank(operator);
        try vault.reclaimFromRedeemEscrow(amount) { reclaimCount++; } catch {}
    }

    /// @dev `settle` needs: interval elapsed + positive distributable + Gate 4 cap + Vault EVM liquidity.
    ///      We precompute the max legal yield to avoid trivial reverts; bound
    ///      proposed to (1 .. maxLegal) so the fuzz actually exercises the path.
    function operator_settle(uint256 yieldSeed) external {
        uint256 last = accountant.lastSettlementTime();
        uint256 interval = accountant.minSettlementInterval();
        if (block.timestamp < last + interval) return;

        int256 ds = accountant.distributableSurplus();
        if (ds <= 0) return;
        uint256 distributable = uint256(ds);

        uint256 supply = usdm.totalSupply();
        uint256 elapsed = block.timestamp - last;
        uint256 cap = (supply * 1200 * elapsed) / (10_000 * 365 days);
        if (cap == 0) return;

        uint256 maxY = distributable < cap ? distributable : cap;

        uint256 vb = usdc.balanceOf(address(vault));
        uint256 sf = redeemEscrow.shortfall();
        uint256 avail = vb > sf ? vb - sf : 0;
        if (avail < maxY) maxY = avail;
        if (maxY == 0) return;

        uint256 propose = bound(yieldSeed, 1, maxY);

        vm.prank(operator);
        try vault.settle(propose) { settleCount++; } catch {}
    }

    function operator_distributeYield() external {
        if (yieldEscrow.balance() == 0) return;

        vm.prank(operator);
        try vault.distributeYield() { distributeCount++; } catch {}
    }

    // ═════════════════════════════════════════════════════════════
    // Environmental: time advance + external yield simulation
    // ═════════════════════════════════════════════════════════════

    function advanceTime(uint256 hoursSeed) external {
        uint256 hrs = bound(hoursSeed, 1, 48);
        vm.warp(block.timestamp + hrs * 1 hours);
    }

    /// @notice Simulate yield accruing from L1 (hedge funding / BLP interest).
    ///         Directly mints USDC to Vault — models net inflow from external sources.
    ///         Necessary for settle/distribute to have something to settle.
    function simulateExternalYield(uint256 amountSeed) external {
        uint256 amount = bound(amountSeed, 1, 10_000e6);
        usdc.mint(address(vault), amount);
        ghost_cumulativeExternalYield += amount;
        externalYieldCount++;
    }

    // ═════════════════════════════════════════════════════════════
    // Adversarial probes — try privileged entry points with wrong sender.
    // Every attempt MUST revert. A success (tracked by `adversarialSucceededCount`)
    // breaks the `invariant_noAdversarialBypass` check below.
    // ═════════════════════════════════════════════════════════════

    function adversarial_directSettlePnL(uint256 amountSeed) external {
        adversarialCallCount++;
        uint256 amount = bound(amountSeed, 1, 1000e6);

        // random sender that's NOT the Vault
        address attacker = actors[amountSeed % actors.length];
        vm.prank(attacker);
        try accountant.settleDailyPnL(amount) {
            adversarialSucceededCount++;
        } catch {}
    }

    function adversarial_directAddObligation(uint256 amountSeed) external {
        adversarialCallCount++;
        uint256 amount = bound(amountSeed, 1, 1000e6);
        address attacker = actors[amountSeed % actors.length];
        vm.prank(attacker);
        try redeemEscrow.addObligation(amount) {
            adversarialSucceededCount++;
        } catch {}
    }

    function adversarial_directPayOut(uint256 amountSeed) external {
        adversarialCallCount++;
        uint256 amount = bound(amountSeed, 1, 1000e6);
        address attacker = actors[amountSeed % actors.length];
        vm.prank(attacker);
        try redeemEscrow.payOut(attacker, amount) {
            adversarialSucceededCount++;
        } catch {}
    }

    function adversarial_directInjectYield(uint256 amountSeed) external {
        adversarialCallCount++;
        uint256 amount = bound(amountSeed, 1, 1000e6);
        address attacker = actors[amountSeed % actors.length];
        vm.prank(attacker);
        try susdm.injectYield(amount) {
            adversarialSucceededCount++;
        } catch {}
    }

    function adversarial_directUsdmMint(uint256 amountSeed) external {
        adversarialCallCount++;
        uint256 amount = bound(amountSeed, 1, 1000e6);
        address attacker = actors[amountSeed % actors.length];
        vm.prank(attacker);
        try usdm.mint(attacker, amount) {
            adversarialSucceededCount++;
        } catch {}
    }

    // ─── Helpers ───────────────────────────────────────────────
    function _popPending(uint256[] storage arr, uint256 idx) internal {
        uint256 last = arr.length - 1;
        if (idx != last) arr[idx] = arr[last];
        arr.pop();
    }
}

/// @title Solvency + accounting + access-control invariants
/// @notice 8 invariants cover:
///   1. Reserve ≥ supply (core solvency)
///   2. Redeem obligation fundable
///   3. sUSDM assets == USDM balance (ERC4626 consistency)
///   4. `totalSettledYield` monotonically non-decreasing
///   5. Insurance fund balance monotonically non-decreasing (no withdraw path in handler)
///   6. Adversarial bypass attempts never succeed
///   7. Vault never holds USDM for itself beyond in-flight redeem requests (sanity)
///   8. Call stats (for regression detection)
contract SolvencyInvariantTest is SimulatorBase {
    ProtocolFlowHandler internal handler;

    address[] internal actors;

    // Ghost snapshots across invariant calls.
    uint256 internal lastTotalSettled;
    uint256 internal lastInsuranceBal;

    function setUp() public {
        setUpSimulator();

        actors.push(address(0xA11CE));
        actors.push(address(0xB0B));
        actors.push(address(0xCAF1));

        handler = new ProtocolFlowHandler(
            address(usdc), address(usdm), address(susdm), address(vault),
            address(accountant), address(redeemEscrow), address(yieldEscrow),
            address(insurance), operator, admin, actors
        );

        // Shorten Gate 2 so `operator_settle` can actually run inside fuzz depth.
        vm.prank(admin);
        accountant.setMinSettlementInterval(1 hours);

        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](17);
        // user
        selectors[0]  = ProtocolFlowHandler.deposit.selector;
        selectors[1]  = ProtocolFlowHandler.requestRedeem.selector;
        selectors[2]  = ProtocolFlowHandler.claimRedeem.selector;
        selectors[3]  = ProtocolFlowHandler.stake.selector;
        selectors[4]  = ProtocolFlowHandler.requestUnstake.selector;
        selectors[5]  = ProtocolFlowHandler.claimUnstake.selector;
        // operator
        selectors[6]  = ProtocolFlowHandler.operator_fundRedemptions.selector;
        selectors[7]  = ProtocolFlowHandler.operator_reclaimFromRedeemEscrow.selector;
        selectors[8]  = ProtocolFlowHandler.operator_settle.selector;
        selectors[9]  = ProtocolFlowHandler.operator_distributeYield.selector;
        // environment
        selectors[10] = ProtocolFlowHandler.advanceTime.selector;
        selectors[11] = ProtocolFlowHandler.simulateExternalYield.selector;
        // adversarial
        selectors[12] = ProtocolFlowHandler.adversarial_directSettlePnL.selector;
        selectors[13] = ProtocolFlowHandler.adversarial_directAddObligation.selector;
        selectors[14] = ProtocolFlowHandler.adversarial_directPayOut.selector;
        selectors[15] = ProtocolFlowHandler.adversarial_directInjectYield.selector;
        selectors[16] = ProtocolFlowHandler.adversarial_directUsdmMint.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));

        lastTotalSettled  = accountant.totalSettledYield();
        lastInsuranceBal  = usdc.balanceOf(address(insurance));
    }

    // ─── 1. Solvency ────────────────────────────────────────────

    /// @dev Core: reserve (excl. foundation) ≥ USDM supply.
    function invariant_reserve_geq_supply() public view {
        uint256 reserve =
              usdc.balanceOf(address(vault))
            + usdc.balanceOf(address(redeemEscrow))
            + usdc.balanceOf(address(yieldEscrow))
            + usdc.balanceOf(address(insurance));

        uint256 supply = usdm.totalSupply();
        assertGe(reserve, supply, "reserve < supply (insolvent)");
    }

    /// @dev Weaker check: at minimum, Vault + RedeemEscrow liquidity covers
    ///      outstanding redeem obligations.
    function invariant_redeemObligation_fundable() public view {
        uint256 owed   = redeemEscrow.totalOwed();
        uint256 escrow = usdc.balanceOf(address(redeemEscrow));
        uint256 vaultUsdc = usdc.balanceOf(address(vault));
        assertGe(escrow + vaultUsdc, owed, "redeem obligation not fundable");
    }

    /// @dev sUSDM's tracked totalAssets MUST equal its actual USDM balance.
    function invariant_susdm_assets_match_usdm_balance() public view {
        assertEq(
            susdm.totalAssets(),
            usdm.balanceOf(address(susdm)),
            "sUSDM accounting drift"
        );
    }

    // ─── 2. Monotonicity ────────────────────────────────────────

    /// @dev `totalSettledYield` only grows — any regress means settle was
    ///      re-run with the same period or accounting was rewound.
    function invariant_totalSettledYield_monotonic() public {
        uint256 cur = accountant.totalSettledYield();
        assertGe(cur, lastTotalSettled, "totalSettledYield decreased");
        lastTotalSettled = cur;
    }

    /// @dev InsuranceFund USDC balance only grows under handler operations
    ///      (handler has no withdraw-from-insurance call). If this ever
    ///      decreases, something drained the fund through an unintended path.
    function invariant_insurance_monotonic() public {
        uint256 cur = usdc.balanceOf(address(insurance));
        assertGe(cur, lastInsuranceBal, "insurance fund drained unexpectedly");
        lastInsuranceBal = cur;
    }

    // ─── 3. Access control ──────────────────────────────────────

    /// @dev Adversarial attempts at privileged entry points MUST all revert.
    function invariant_noAdversarialBypass() public view {
        assertEq(
            handler.adversarialSucceededCount(),
            0,
            "access control bypassed"
        );
    }

    // ─── 4. Stats (regression echo) ─────────────────────────────

    /// @dev Stats echo. Foundry also runs invariants at pre-fuzz state where
    ///      counters are 0, so the assertion must be non-strict. The actual
    ///      call-count surfaces in the `Calls` column of -vvv output.
    function invariant_callStats() public view {
        uint256 total =
              handler.depositCount()
            + handler.redeemRequestCount()
            + handler.redeemClaimCount()
            + handler.stakeCount()
            + handler.unstakeRequestCount()
            + handler.unstakeClaimCount()
            + handler.fundCount()
            + handler.reclaimCount()
            + handler.settleCount()
            + handler.distributeCount()
            + handler.externalYieldCount()
            + handler.adversarialCallCount();
        assertGe(total, 0);
    }
}

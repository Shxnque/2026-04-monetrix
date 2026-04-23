// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./SimulatorBase.sol";
import {CoreSimulatorLib} from "@hyper-evm-lib/test/simulation/CoreSimulatorLib.sol";
import {PrecompileLib} from "@hyper-evm-lib/src/PrecompileLib.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title EVM→L1 USDC bridge bound-check verification (post-fix state)
/// @notice Verifies `HyperCoreConstants.toL1Wei` behaves as a safe domain
///         boundary converter: multiplies in uint256 then SafeCast-downcasts
///         to uint64, reverting on overflow instead of silently truncating.
///
///         Historical context: an earlier `_sendL1Bridge` implementation wrote
///
///             uint64 l1Amount = uint64(amount) * uint64(100);
///
///         which had two failure regimes because Solidity 0.8 checks arithmetic
///         but not casts:
///           Regime 1 — DOS: `amount ∈ (uint64.max/100, uint64.max]` → cast
///             doesn't truncate, but the × 100 overflows uint64 → arithmeticError.
///           Regime 2 — Silent loss: `amount ≥ 2^64` with low-64 ≤ uint64.max/100
///             → cast truncates silently, × 100 fits, EVM debits full amount
///             while L1 only moves (amount mod 2^64)×100 wei. High-severity bug.
///
///         The fix — `SafeCast.toUint64(evmAmount * EVM_TO_L1_PRECISION)` in
///         uint256 domain — collapses both regimes into one clean revert:
///         `SafeCast.SafeCastOverflowedUintDowncast(64, overflowValue)`.
///
///         Pin-test mapping:
///           test_boundary_maxSafe_succeeds          — still succeeds
///           test_boundCheck_justAboveMaxSafe        — pre-fix: arithmeticError → post-fix: SafeCast revert
///           test_boundCheck_uint64MaxAmount         — pre-fix: arithmeticError → post-fix: SafeCast revert
///           test_boundCheck_above2to64              — pre-fix: PASS (silent loss) → post-fix: SafeCast revert
///           test_boundCheck_multipleWraps           — pre-fix: PASS (silent loss) → post-fix: SafeCast revert
contract BridgeUint64TruncationTest is SimulatorBase {
    uint256 constant MAX_SAFE = uint256(type(uint64).max) / 100; // ≈ 1.8446e17
    uint256 constant WRAP_UNIT = uint256(type(uint64).max) + 1; // 2^64

    function setUp() public {
        setUpSimulator();
        PrecompileLib.TokenInfo memory usdcInfo = PrecompileLib.TokenInfo({
            name: "USDC",
            spots: new uint64[](0),
            deployerTradingFeeShare: 0,
            deployer: address(0),
            evmContract: address(usdc),
            szDecimals: 8,
            weiDecimals: 8,
            evmExtraWeiDecimals: -2
        });
        hyperCore.registerTokenInfo(0, usdcInfo);
    }

    function _seed(uint256 amount) internal {
        // Slot index of Vault.outstandingL1Principal (verify via `forge inspect MonetrixVault storage-layout`).
        vm.store(address(vault), bytes32(uint256(60)), bytes32(amount));
        CoreSimulatorLib.forceSpotBalance(address(vault), 0, type(uint64).max);
    }

    /// Expected revert signature from `SafeCast.toUint64`: the overflow value
    /// is the uint256 product `amount * EVM_TO_L1_PRECISION`.
    function _expectSafeCastRevert(uint256 overflowValue) internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                SafeCast.SafeCastOverflowedUintDowncast.selector, uint8(64), overflowValue
            )
        );
    }

    // ─────────────────────────────────────────────────────────────
    // Happy path — largest amount that fits cleanly in uint64.
    // ─────────────────────────────────────────────────────────────

    /// amount = MAX_SAFE. Product = MAX_SAFE × 100 = uint64.max - 15. Fits.
    /// This is the largest valid bridge amount supported by the current
    /// decimal offset (6-dp EVM → 8-dp L1).
    function test_boundary_maxSafe_succeeds() public {
        uint256 amount = MAX_SAFE;
        _seed(amount);

        uint64 l1Before = _readSpot(address(vault), USDC_TOKEN);

        vm.prank(admin);
        vault.emergencyBridgePrincipalFromL1(amount);
        CoreSimulatorLib.nextBlock();

        uint64 l1After = _readSpot(address(vault), USDC_TOKEN);
        uint256 evmReceived = usdc.balanceOf(address(vault));

        uint64 expectedL1Move = uint64(amount) * 100;
        assertEq(uint256(l1Before - l1After), uint256(expectedL1Move), "L1 moved exactly amount*100");
        assertEq(evmReceived, amount, "EVM received full amount");
    }

    // ─────────────────────────────────────────────────────────────
    // Pre-fix Regime 1 (DOS) — now a clean SafeCast revert.
    // ─────────────────────────────────────────────────────────────

    function test_boundCheck_justAboveMaxSafe_reverts() public {
        uint256 amount = MAX_SAFE + 1;
        _seed(amount);
        uint256 olpBefore = vault.outstandingL1Principal();

        _expectSafeCastRevert(amount * 100);
        vm.prank(admin);
        vault.emergencyBridgePrincipalFromL1(amount);

        assertEq(vault.outstandingL1Principal(), olpBefore, "OLP unchanged on revert");
    }

    function test_boundCheck_uint64MaxAmount_reverts() public {
        uint256 amount = uint256(type(uint64).max);
        _seed(amount);

        _expectSafeCastRevert(amount * 100);
        vm.prank(admin);
        vault.emergencyBridgePrincipalFromL1(amount);
    }

    // ─────────────────────────────────────────────────────────────
    // Pre-fix Regime 2 (silent loss) — now a clean SafeCast revert.
    // These are the critical "bug killed" assertions.
    // ─────────────────────────────────────────────────────────────

    /// Pre-fix behavior: amount = 2^64 + 7 silently truncated to 7, L1 moved
    /// only 700 wei while EVM debited 1.8e19. Post-fix: uint256 product ≫
    /// uint64.max → SafeCast reverts, no state change.
    function test_boundCheck_above2to64_reverts() public {
        uint256 amount = WRAP_UNIT + 7;
        _seed(amount);

        _expectSafeCastRevert(amount * 100);
        vm.prank(admin);
        vault.emergencyBridgePrincipalFromL1(amount);

        assertEq(vault.outstandingL1Principal(), amount, "OLP unchanged on revert");
        assertEq(usdc.balanceOf(address(vault)), 0, "no EVM credit on revert");
    }

    /// Pre-fix: 3-wrap silent loss (L1 still moved 700 wei, but EVM debited
    /// 3·2^64 + 7 — loss scaled linearly). Post-fix: same clean revert as
    /// single-wrap case, confirming the fix is uniform across all truncation
    /// magnitudes.
    function test_boundCheck_multipleWraps_reverts() public {
        uint256 amount = 3 * WRAP_UNIT + 7;
        _seed(amount);

        _expectSafeCastRevert(amount * 100);
        vm.prank(admin);
        vault.emergencyBridgePrincipalFromL1(amount);
    }
}

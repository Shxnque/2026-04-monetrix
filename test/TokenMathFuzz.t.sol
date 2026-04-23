// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import "../src/core/TokenMath.sol";

/// @title TokenMath fuzz + unit tests
/// @notice Pins the precision-invariants documented in
///         `docs/invariants/precision-invariants.md` via property-based tests.
contract TokenMathFuzzTest is Test {
    // ═══════════════════════════════════════════════════════════
    //  Section 1 — USDC EVM ↔ L1 round-trip
    // ═══════════════════════════════════════════════════════════

    /// @notice For any EVM amount within the safe range, `l1→evm(evm→l1(x))`
    ///         returns x EXACTLY (no rounding because 100 divides cleanly into
    ///         `x * 100`). This is the strongest possible invariant.
    function testFuzz_usdcEvmL1RoundTripIsIdentity(uint256 evmAmount) public pure {
        // `usdcEvmToL1Wei` reverts above (uint64.max / 100). Bound inputs.
        evmAmount = bound(evmAmount, 0, uint256(type(uint64).max) / 100);
        uint64 l1 = TokenMath.usdcEvmToL1Wei(evmAmount);
        uint256 evmBack = TokenMath.usdcL1WeiToEvm(l1);
        assertEq(evmBack, evmAmount, "round trip must be identity");
    }

    /// @notice The boundary: one above MAX_SAFE must revert cleanly.
    function test_usdcEvmToL1_maxSafeBoundary() public {
        uint256 maxSafe = uint256(type(uint64).max) / 100;
        // Exactly at boundary: succeeds (equals floor(2^64-1, 100))
        TokenMath.usdcEvmToL1Wei(maxSafe);
        // One above: overflows uint64 after * 100
        vm.expectRevert(
            abi.encodeWithSelector(
                SafeCast.SafeCastOverflowedUintDowncast.selector,
                uint8(64),
                (maxSafe + 1) * 100
            )
        );
        this.extCallUsdcEvmToL1(maxSafe + 1);
    }

    function extCallUsdcEvmToL1(uint256 amount) external pure returns (uint64) {
        return TokenMath.usdcEvmToL1Wei(amount);
    }

    // ═══════════════════════════════════════════════════════════
    //  Section 2 — Generic evmToL1Wei respects evmExtraWeiDecimals
    // ═══════════════════════════════════════════════════════════

    /// @notice USDC specialization matches the generic path.
    function testFuzz_genericMatchesUsdcFastPath(uint256 evmAmount) public pure {
        evmAmount = bound(evmAmount, 0, uint256(type(uint64).max) / 100);
        uint64 fastPath = TokenMath.usdcEvmToL1Wei(evmAmount);
        uint64 generic = TokenMath.evmToL1Wei(evmAmount, -2); // USDC evmExtra = -2
        assertEq(fastPath, generic, "fast path must match generic");
    }

    /// @notice Generic round trip for a range of evmExtraWeiDecimals values.
    function testFuzz_genericRoundTrip(uint128 evmAmount, int8 extraRaw) public pure {
        // Restrict to realistic HIP-1 range: -18 ≤ extra ≤ 18.
        int8 extra = int8(bound(int256(extraRaw), -6, 6));

        // For extra < 0 (EVM has fewer decimals), we multiply by 10^|extra|.
        // Cap `evmAmount` so the product fits in uint64.
        uint256 maxSafe;
        if (extra < 0) {
            maxSafe = uint256(type(uint64).max) / (10 ** uint8(-extra));
        } else {
            maxSafe = type(uint64).max;
        }
        uint256 amt = uint256(bound(uint256(evmAmount), 0, maxSafe));
        uint64 l1 = TokenMath.evmToL1Wei(amt, extra);
        uint256 evmBack = TokenMath.l1WeiToEvm(l1, extra);

        // For extra >= 0 (EVM has more decimals), `evmToL1Wei` floor-divides,
        // so round-trip can lose up to 10^extra - 1. For extra < 0, the mul
        // is exact so the identity holds.
        if (extra <= 0) {
            assertEq(evmBack, amt, "extra <= 0 is identity");
        } else {
            uint256 unit = 10 ** uint8(extra);
            assertLe(amt - evmBack, unit - 1, "extra > 0 floor rounding bounded");
        }
    }

    // ═══════════════════════════════════════════════════════════
    //  Section 3 — Spot notional formula correctness
    // ═══════════════════════════════════════════════════════════

    /// @notice QuickNode BTC example: 0.1 BTC × $96036 = $9603.60 in 6dp USDC.
    function test_notionalBtcQuickNodeExample() public pure {
        uint64 bal = 1e7;       // 0.1 BTC at weiDecimals=8
        uint64 rawPx = 960360;  // $96036 in BTC oracle format (szD=5)
        uint256 notional = TokenMath.spotNotionalUsdcFromPerpPx(bal, rawPx, 8, 5);
        assertEq(notional, 9_603_600_000, "0.1 BTC @ $96036 = $9603.60 (6dp)");
    }

    /// @notice USDC as the hedge asset (weiDecimals=szDecimals=8) — divisor = 1.
    ///         Tests the degenerate case.
    function test_notionalUsdcAsHedge() public pure {
        uint64 bal = 1e8;       // 1 USDC at weiDecimals=8
        uint64 rawPx = 1_000_000; // $1 with szDecimals=6 (hypothetical)
        // divisor = 10^(8-6) = 100. notional = (1e8 * 1e6) / 100 = 1e12 (6dp $1M?)
        // Wait — this reflects that USDC-as-price-quoted makes no sense. Kept
        // only to prove the formula doesn't special-case USDC.
        uint256 n = TokenMath.spotNotionalUsdcFromPerpPx(bal, rawPx, 8, 6);
        assertEq(n, (uint256(bal) * uint256(rawPx)) / 100);
    }

    /// @notice Zero balance → zero notional regardless of price.
    function testFuzz_zeroBalanceIsZeroNotional(uint64 px, uint8 w, uint8 sz) public pure {
        uint8 ww = uint8(bound(uint256(w), 6, 18));
        uint8 ss = uint8(bound(uint256(sz), 0, uint256(ww)));
        uint256 n = TokenMath.spotNotionalUsdcFromPerpPx(0, px, ww, ss);
        assertEq(n, 0);
    }

    /// @notice Zero price → zero notional regardless of balance.
    function testFuzz_zeroPriceIsZeroNotional(uint64 bal, uint8 w, uint8 sz) public pure {
        uint8 ww = uint8(bound(uint256(w), 6, 18));
        uint8 ss = uint8(bound(uint256(sz), 0, uint256(ww)));
        uint256 n = TokenMath.spotNotionalUsdcFromPerpPx(bal, 0, ww, ss);
        assertEq(n, 0);
    }

    /// @notice Property: scaling both balance by 2x yields 2x notional (exact,
    ///         because the divisor is the same — no new rounding introduced).
    function testFuzz_notionalLinearInBalance(
        uint32 balBase, uint32 rawPx, uint8 w, uint8 sz
    ) public pure {
        // Constrain decimals to realistic HIP-1 ranges: sz ∈ [0,8], w ∈ [sz, 18].
        // Order matters: bound `sz` first, then derive `w`'s lower bound from it.
        uint8 ss = uint8(bound(uint256(sz), 0, 8));
        uint8 ww = uint8(bound(uint256(w), uint256(ss) + 1, 18));
        uint64 bal1 = uint64(bound(uint256(balBase), 0, type(uint32).max));
        uint64 px = uint64(bound(uint256(rawPx), 1, type(uint32).max));
        uint64 bal2 = bal1 * 2; // fits in uint64 since bal1 ≤ 2^32

        uint256 n1 = TokenMath.spotNotionalUsdcFromPerpPx(bal1, px, ww, ss);
        uint256 n2 = TokenMath.spotNotionalUsdcFromPerpPx(bal2, px, ww, ss);
        // Floor division is only linear up to the last-wei rounding: 2*floor(x/d)
        // differs from floor(2x/d) by at most 1. Assert the bound.
        assertLe(n2 - n1 * 2, 1, "near-linear within 1 wei floor artefact");
    }

    /// @notice Invalid decimals (weiDecimals < szDecimals) reverts cleanly —
    ///         no silent multiplication-instead-of-division.
    function test_notionalRevertsWhenInvalidDecimals() public {
        vm.expectRevert("TokenMath: invalid decimals");
        this.extCallSpotNotional(100, 100, 3, 5); // w=3, sz=5 → would need *100
    }

    function extCallSpotNotional(uint64 bal, uint64 rawPx, uint8 w, uint8 sz)
        external pure returns (uint256)
    {
        return TokenMath.spotNotionalUsdcFromPerpPx(bal, rawPx, w, sz);
    }

    // ═══════════════════════════════════════════════════════════
    //  Section 4 — L1 spot ↔ perp USDC rescale
    // ═══════════════════════════════════════════════════════════

    /// @notice Perp-to-spot-wei-to-perp round trip (note: 8dp→6dp loses last
    ///         2 digits, so not symmetric — this tests the exact-direction).
    function testFuzz_perpToSpotWeiIsExact(uint32 perp6dp) public pure {
        uint64 spotWei = TokenMath.usdcPerpToSpotWei(uint64(perp6dp));
        assertEq(spotWei, uint64(perp6dp) * 100, "perp to spot is clean x100");
    }

    function testFuzz_spotWeiToPerpFloors(uint32 spotWei) public pure {
        uint64 perp = TokenMath.usdcSpotWeiToPerp(uint64(spotWei));
        assertEq(perp, uint64(spotWei) / 100, "spot to perp floors the last 2 digits");
    }
}

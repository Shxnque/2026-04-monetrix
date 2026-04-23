// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import "../src/core/TokenMath.sol";

/// @dev External wrapper — `vm.expectRevert` needs the revert to happen at a
///      deeper call depth than the cheatcode invocation, but library internal
///      functions inline into the caller's bytecode (same depth). The wrapper
///      puts the call across an external boundary.
contract ToL1WeiHarness {
    function call(uint256 amount) external pure returns (uint64) {
        return TokenMath.usdcEvmToL1Wei(amount);
    }
}

/// @title TokenMath.usdcEvmToL1Wei EVM→L1 bound check (post-fix)
/// @notice Sibling of `test/VaultUint64TruncationPoC.t.sol`. Same bug class
///         (`amount * 100` overflows uint64 for amount > MAX_SAFE), same fix
///         path (`SafeCast.toUint64` in `toL1Wei`), same revert signature.
///
///         `toL1Wei` is the single chokepoint for EVM 6-dp → L1 8-dp scaling —
///         every write path (ActionEncoder.sendSpotSend, sendBridgeToL1) routes
///         through it. These tests pin the fix so future callers cannot silently
///         regress to pre-fix behavior.
contract ActionEncoderBoundCheckTest is Test {
    uint256 constant MAX_SAFE = uint256(type(uint64).max) / 100; // ≈ 1.8446e17

    ToL1WeiHarness harness;

    function setUp() public {
        harness = new ToL1WeiHarness();
    }

    /// Largest `amount` whose `amount * 100` fits in uint64 — must succeed.
    function test_toL1Wei_maxSafe_succeeds() public view {
        uint64 l1 = harness.call(MAX_SAFE);
        assertEq(uint256(l1), MAX_SAFE * 100);
    }

    /// One unit above the safe boundary — product overflows uint64.
    function test_toL1Wei_overflow_reverts() public {
        uint256 amount = MAX_SAFE + 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                SafeCast.SafeCastOverflowedUintDowncast.selector,
                uint8(64),
                amount * 100
            )
        );
        harness.call(amount);
    }

    /// Upper edge of the pre-fix DOS regime: amount = uint64.max.
    function test_toL1Wei_uint64MaxAmount_reverts() public {
        uint256 amount = uint256(type(uint64).max);
        vm.expectRevert(
            abi.encodeWithSelector(
                SafeCast.SafeCastOverflowedUintDowncast.selector,
                uint8(64),
                amount * 100
            )
        );
        harness.call(amount);
    }
}

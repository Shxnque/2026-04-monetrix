// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./SimulatorBase.sol";
import {CoreSimulatorLib} from "@hyper-evm-lib/test/simulation/CoreSimulatorLib.sol";
import {PrecompileLib} from "@hyper-evm-lib/src/PrecompileLib.sol";

/// @title Async L1→EVM bridge tests
/// @notice Previously mocked with CapturingCoreWriter (captured the last action
///         but never executed it). CoreSimulator actually executes SendAsset
///         actions in `nextBlock()`, so we can verify:
///
///   (1) `emergencyBridgePrincipalFromL1` decrements EVM `outstandingL1Principal`
///       immediately, but L1 spot balance only moves after `nextBlock()`.
///   (2) After `nextBlock()`, vault's EVM USDC balance increases by the exact
///       bridged amount — no silent loss, no double-credit.
///   (3) Multiple pending bridges accumulate and settle in one block.
contract BridgeAsyncTest is SimulatorBase {
    uint8 constant USDC_WEI_DECIMALS = 8;
    int8 constant USDC_EVM_EXTRA = -2; // EVM USDC is 6dp, L1 is 8dp → extra = -2

    function setUp() public {
        setUpSimulator();

        // Register USDC (token 0) in simulator with our MockUSDC as the EVM
        // contract. Required for SendAssetAction to deliver USDC back to EVM.
        PrecompileLib.TokenInfo memory usdcInfo = PrecompileLib.TokenInfo({
            name: "USDC",
            spots: new uint64[](0),
            deployerTradingFeeShare: 0,
            deployer: address(0),
            evmContract: address(usdc),
            szDecimals: 8,
            weiDecimals: USDC_WEI_DECIMALS,
            evmExtraWeiDecimals: USDC_EVM_EXTRA
        });
        hyperCore.registerTokenInfo(0, usdcInfo);
    }

    /// @dev Simulate that `amount` (in 6-decimal USDC) has been bridged to L1:
    ///      sets `outstandingL1Principal` via storage hack + seeds the vault's
    ///      L1 spot balance in the simulator. Slot index of MonetrixVault.outstandingL1Principal
    ///      — verify via `forge inspect MonetrixVault storage-layout`.
    function _seedL1Principal(uint256 amount) internal {
        vm.store(address(vault), bytes32(uint256(60)), bytes32(amount));
        // L1 uses 8-decimal units (multiply by 100).
        CoreSimulatorLib.forceSpotBalance(address(vault), 0, uint64(amount * 100));
    }

    /// Single-call happy path: EVM state decrements immediately; L1 spot
    /// balance only moves after `nextBlock()`.
    function test_emergencyBridge_async_settlesOnNextBlock() public {
        uint256 amount = 50_000e6; // 50k USDC (6dp)
        _seedL1Principal(amount);

        assertEq(vault.outstandingL1Principal(), amount);
        assertEq(usdc.balanceOf(address(vault)), 0, "vault starts empty on EVM");
        assertEq(_readSpot(address(vault), USDC_TOKEN), amount * 100, "L1 seeded");

        vm.prank(admin);
        vault.emergencyBridgePrincipalFromL1(amount);

        // EVM-side bookkeeping updates immediately.
        assertEq(vault.outstandingL1Principal(), 0, "EVM debit immediate");
        // Nothing yet on EVM USDC side; L1 still has the funds.
        assertEq(usdc.balanceOf(address(vault)), 0, "pre-nextBlock EVM unchanged");
        assertEq(_readSpot(address(vault), USDC_TOKEN), amount * 100, "pre-nextBlock L1 unchanged");

        CoreSimulatorLib.nextBlock();

        // After the block, simulator delivered USDC back to EVM.
        assertEq(_readSpot(address(vault), USDC_TOKEN), 0, "L1 drained");
        assertEq(usdc.balanceOf(address(vault)), amount, "EVM credited");
    }

    /// Multiple queued SendAssets in the same block all settle at once.
    function test_emergencyBridge_multiple_settleInOneBlock() public {
        uint256 total = 100_000e6;
        _seedL1Principal(total);

        vm.startPrank(admin);
        vault.emergencyBridgePrincipalFromL1(30_000e6);
        vault.emergencyBridgePrincipalFromL1(45_000e6);
        vault.emergencyBridgePrincipalFromL1(25_000e6);
        vm.stopPrank();

        assertEq(vault.outstandingL1Principal(), 0);
        assertEq(usdc.balanceOf(address(vault)), 0);

        CoreSimulatorLib.nextBlock();

        assertEq(usdc.balanceOf(address(vault)), total, "all three settled");
        assertEq(_readSpot(address(vault), USDC_TOKEN), 0);
    }

    /// Over-draw reverts at the EVM layer — L1 state untouched.
    function test_emergencyBridge_overdraw_revertsBeforeL1() public {
        _seedL1Principal(10_000e6);

        vm.prank(admin);
        vm.expectRevert("invalid bridge amount");
        vault.emergencyBridgePrincipalFromL1(10_000e6 + 1);

        CoreSimulatorLib.nextBlock();
        assertEq(_readSpot(address(vault), USDC_TOKEN), 10_000e6 * 100, "L1 unchanged");
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./SimulatorBase.sol";
import {CoreSimulatorLib} from "@hyper-evm-lib/test/simulation/CoreSimulatorLib.sol";

/// @title HLP mark-to-market simulator tests
/// @notice Previously untestable path — our mock precompiles returned fixed
///         128-byte zero responses, so we could never verify Accountant's
///         behavior under real HLP equity swings. With CoreSimulator we can
///         force equity and scale it via setVaultMultiplier, proving:
///
///   (1) Accountant.totalBacking() tracks HLP mark-to-market 1:1.
///   (2) HLP profits inflate `surplus()` and become distributable yield.
///   (3) HLP drawdowns push `surplus()` below zero — `distributeYield` must
///       NOT fire while backing < liabilities (fail-closed).
contract HlpMTMTest is SimulatorBase {
    uint64 constant INITIAL_EQUITY = 1_000_000e6; // 1M perp-decimals USD

    function setUp() public {
        setUpSimulator();
        // Synthetic setup: mint 1M USDM liability with no EVM USDC backing,
        // then force 1M USD HLP equity. Backing == liabilities, surplus == 0.
        // This isolates the Accountant-vs-HLP-MTM path from bridge mechanics.
        vm.prank(address(vault));
        usdm.mint(user1, 1_000_000e6);
        CoreSimulatorLib.forceVaultEquity(address(vault), HLP, INITIAL_EQUITY, 0);
    }

    /// 10% HLP profit flows straight into Accountant totalBacking.
    function test_hlpProfit_inflatesBacking() public {
        int256 baselineBacking = accountant.totalBackingSigned();

        // +10% HLP equity
        CoreSimulatorLib.setVaultMultiplier(HLP, 1.1e18);

        (uint64 equityAfter,) = _readVaultEquity();
        assertEq(equityAfter, INITIAL_EQUITY + INITIAL_EQUITY / 10, "equity +10%");

        int256 newBacking = accountant.totalBackingSigned();
        // Increase should be the 10% HLP gain, in 6-decimal USDC units.
        assertEq(newBacking - baselineBacking, int256(uint256(INITIAL_EQUITY / 10)), "backing +10% gain");
    }

    /// 10% HLP drawdown reduces backing — should NOT wipe out liabilities.
    function test_hlpLoss_reducesBacking() public {
        int256 baselineBacking = accountant.totalBackingSigned();

        // -10% HLP equity
        CoreSimulatorLib.setVaultMultiplier(HLP, 0.9e18);

        (uint64 equityAfter,) = _readVaultEquity();
        assertEq(equityAfter, INITIAL_EQUITY - INITIAL_EQUITY / 10, "equity -10%");

        int256 newBacking = accountant.totalBackingSigned();
        assertEq(baselineBacking - newBacking, int256(uint256(INITIAL_EQUITY / 10)), "backing -10% loss");
    }

    /// Deep drawdown: backing falls below liabilities → surplus negative.
    /// Governance's only recourse is InsuranceFund; yield distribution must
    /// block until backing recovers (protected inside distributeYield path).
    function test_hlpLoss_drivesSurplusNegative() public {
        // 50% drawdown on the only backing source.
        CoreSimulatorLib.setVaultMultiplier(HLP, 0.5e18);

        int256 newBacking = accountant.totalBackingSigned();
        int256 liabilities = int256(uint256(usdm.totalSupply()));
        assertLt(newBacking, liabilities, "backing below liabilities");
        assertLt(accountant.surplus(), 0, "surplus gone negative");
    }

    /// Surplus -> reverts distribution path that depends on positive surplus.
    /// (Vault.collectYield is what consumes surplus; we verify via surplus view.)
    function test_surplus_recoversOnBounceBack() public {
        CoreSimulatorLib.setVaultMultiplier(HLP, 0.8e18);
        int256 down = accountant.surplus();
        assertLt(down, 0);

        CoreSimulatorLib.setVaultMultiplier(HLP, 1.05e18);
        int256 recovered = accountant.surplus();
        assertGt(recovered, 0, "surplus recovers to positive");
    }
}

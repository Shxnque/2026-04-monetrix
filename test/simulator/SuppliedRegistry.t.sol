// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./SimulatorBase.sol";

/// @title Accountant supplied-token registry (0x811 activation tracking)
/// @notice Verifies the fail-closed design: Accountant iterates only the
///         `vaultSupplied` / `multisigSupplied` registries for 0x811 reads.
///         Missing entries → no read attempt → no revert. Registered entries
///         → strict read → reverts if slot was never activated on HL.
///
///         Vault hooks auto-register on `supplyToBlp` (always) and on
///         `executeHedge` (only when `pmEnabled`). Multisig entries are
///         written by the keeper via `addMultisigSupplyToken`.
contract SuppliedRegistryTest is SimulatorBase {
    function setUp() public {
        setUpSimulator();
    }

    /// Empty registry → Accountant skips 0x811 entirely → totalBacking succeeds
    /// regardless of precompile stub (including a "would-revert" stub).
    function test_emptyRegistry_skipsSuppliedReads() public view {
        assertEq(accountant.vaultSuppliedLength(), 0);
        assertEq(accountant.multisigSuppliedLength(), 0);
        accountant.totalBacking();
    }

    /// `supplyToBlp(USDC, _)` auto-registers USDC on the vault registry.
    function test_supplyToBlp_usdc_autoRegisters() public {
        vm.prank(operator);
        vault.supplyToBlp(USDC_TOKEN, 1_000_000);

        assertEq(accountant.vaultSuppliedLength(), 1);
        (uint64 spotToken, uint32 perpIndex) = accountant.vaultSupplied(0);
        assertEq(spotToken, USDC_TOKEN);
        assertEq(perpIndex, 0, "USDC has no perp pricing");
    }

    /// Repeated `supplyToBlp` for the same token is a no-op on the registry.
    function test_supplyToBlp_idempotent() public {
        vm.startPrank(operator);
        vault.supplyToBlp(USDC_TOKEN, 1_000_000);
        vault.supplyToBlp(USDC_TOKEN, 500_000);
        vault.supplyToBlp(USDC_TOKEN, 250_000);
        vm.stopPrank();

        assertEq(accountant.vaultSuppliedLength(), 1, "one entry, not three");
    }

    /// `supplyToBlp` with a non-whitelisted spot token reverts — prevents
    /// registration with perpIndex=0 which would break oracle-priced reads.
    function test_supplyToBlp_unknownSpot_reverts() public {
        vm.prank(operator);
        vm.expectRevert("spot not whitelisted");
        vault.supplyToBlp(1105, 1_000_000);
    }

    /// Whitelisted hedge token registers with the correct perpIndex.
    function test_supplyToBlp_hedgeToken_registersPerpPair() public {
        vm.prank(admin);
        config.addTradeableAsset(MonetrixConfig.TradeableAsset({perpIndex: 4, spotIndex: 1105, spotPairAssetId: 11105}));

        vm.prank(operator);
        vault.supplyToBlp(1105, 1_000_000);

        (uint64 spotToken, uint32 perpIndex) = accountant.vaultSupplied(0);
        assertEq(spotToken, 1105);
        assertEq(perpIndex, 4, "perpIndex resolved from Config");
    }

    /// Only Vault may write to the vault registry (via `notifyVaultSupply`).
    function test_notifyVaultSupply_onlyVault() public {
        vm.prank(operator);
        vm.expectRevert(MonetrixAccountant.NotVault.selector);
        accountant.notifyVaultSupply(USDC_TOKEN, 0);

        vm.prank(admin);
        vm.expectRevert(MonetrixAccountant.NotVault.selector);
        accountant.notifyVaultSupply(USDC_TOKEN, 0);
    }

    /// `addMultisigSupplyToken` is operator-gated and append-only idempotent.
    function test_multisigRegistry_operatorOnly_idempotent() public {
        vm.startPrank(admin);
        accountant.setConfig(address(config));
        config.addTradeableAsset(MonetrixConfig.TradeableAsset({perpIndex: 4, spotIndex: 1105, spotPairAssetId: 11105}));
        vm.stopPrank();

        vm.prank(user1);
        vm.expectRevert();
        accountant.addMultisigSupplyToken(USDC_TOKEN);

        vm.startPrank(operator);
        accountant.addMultisigSupplyToken(USDC_TOKEN);
        accountant.addMultisigSupplyToken(USDC_TOKEN); // idempotent
        accountant.addMultisigSupplyToken(1105);
        vm.stopPrank();

        assertEq(accountant.multisigSuppliedLength(), 2);
        (uint64 t0, uint32 p0) = accountant.multisigSupplied(0);
        (uint64 t1, uint32 p1) = accountant.multisigSupplied(1);
        assertEq(t0, USDC_TOKEN);
        assertEq(p0, 0);
        assertEq(t1, 1105);
        assertEq(p1, 4);
    }

    /// `executeHedge` does NOT auto-register when Vault is non-PM — ensures
    /// we don't register slots that HL hasn't actually activated on 0x811.
    function test_executeHedge_nonPm_noRegistration() public {
        vm.prank(admin);
        config.addTradeableAsset(MonetrixConfig.TradeableAsset({perpIndex: 4, spotIndex: 1105, spotPairAssetId: 11105}));

        ActionEncoder.HedgeParams memory params = ActionEncoder.HedgeParams({
            spotAsset: 11105,
            perpAsset: 4,
            size: 1e8,
            spotPrice: 100e8,
            perpPrice: 100e8,
            cloid: 0,
            tif: uint8(3),
            spotReduceOnly: false,
            perpReduceOnly: false
        });
        vm.prank(operator);
        vault.executeHedge(1, params);

        assertEq(accountant.vaultSuppliedLength(), 0, "non-PM hedge must not register");
    }

    /// `executeHedge` auto-registers the spot token under PM — matches the
    /// actual 0x811 activation trigger (PM auto-supply on non-zero balance).
    function test_executeHedge_pm_registersSpot() public {
        vm.prank(admin);
        config.addTradeableAsset(MonetrixConfig.TradeableAsset({perpIndex: 4, spotIndex: 1105, spotPairAssetId: 11105}));
        vm.prank(admin);
        vault.setPmEnabled(true);

        ActionEncoder.HedgeParams memory params = ActionEncoder.HedgeParams({
            spotAsset: 11105,
            perpAsset: 4,
            size: 1e8,
            spotPrice: 100e8,
            perpPrice: 100e8,
            cloid: 0,
            tif: uint8(3),
            spotReduceOnly: false,
            perpReduceOnly: false
        });
        vm.prank(operator);
        vault.executeHedge(1, params);

        assertEq(accountant.vaultSuppliedLength(), 1);
        (uint64 spotToken, uint32 perpIndex) = accountant.vaultSupplied(0);
        assertEq(spotToken, 1105);
        assertEq(perpIndex, 4);
    }
}

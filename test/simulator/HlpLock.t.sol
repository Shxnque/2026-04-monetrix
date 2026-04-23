// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./SimulatorBase.sol";
import {CoreSimulatorLib} from "@hyper-evm-lib/test/simulation/CoreSimulatorLib.sol";

/// @title HLP 4-day lockup simulator tests
/// @notice HLP deposits carry a mandatory 4-day withdrawal lock. Precompile
///         0x802 exposes `lockedUntil` as a **millisecond** epoch (verified on
///         testnet: 1776791164093 ms). `withdrawFromHLP` guards against
///         submissions during the lock because L1 silently drops them with no
///         event — the operator would assume success and downstream accounting
///         would diverge.
contract HlpLockTest is SimulatorBase {
    uint64 constant EQUITY = 500_000e6;

    function setUp() public {
        setUpSimulator();
        // Seed vault's HLP equity with a 4-day lock. Unit: ms (matches real
        // precompile output).
        CoreSimulatorLib.forceVaultEquity(
            address(vault),
            HLP,
            EQUITY,
            uint64((block.timestamp + 4 days) * 1000)
        );
    }

    /// During the lock window the guard reverts — prevents silent L1 drop.
    function test_withdraw_duringLock_reverts() public {
        (uint64 equity, uint64 lockedUntil) = _readVaultEquity();
        assertEq(equity, EQUITY);
        assertGt(lockedUntil, block.timestamp * 1000, "lock still active");

        vm.prank(operator);
        vm.expectRevert("HLP still locked");
        vault.withdrawFromHLP(100_000e6);
    }

    /// Withdraw amount > equity is rejected at the EVM layer regardless of lock.
    function test_withdraw_amountExceedsEquity_reverts() public {
        vm.prank(operator);
        vm.expectRevert("exceeds hlp equity");
        vault.withdrawFromHLP(EQUITY + 1);
    }

    /// Advancing past the lock expiration — equity still intact, withdrawal
    /// continues to pass EVM gate. Production L1 would now execute the
    /// withdrawal.
    function test_withdraw_afterLockExpires_succeeds() public {
        vm.warp(block.timestamp + 4 days + 1);

        (, uint64 lockedUntil) = _readVaultEquity();
        assertLe(lockedUntil, block.timestamp * 1000, "lock expired");

        vm.prank(operator);
        vault.withdrawFromHLP(100_000e6);
    }

    /// Lock is per-deposit in production. The simulator models it as a single
    /// lockedUntil field per (account, vault). Verify our precompile helper
    /// reads that field through the 64-byte ABI response exactly as Accountant
    /// does (sanity that length check >=64 is correct).
    function test_lockedUntil_roundtrip_via64ByteResponse() public view {
        (bool ok, bytes memory res) = HyperCoreConstants.PRECOMPILE_VAULT_EQUITY.staticcall(
            abi.encode(address(vault), HLP)
        );
        assertTrue(ok);
        assertEq(res.length, 64, "bug_005: must be 64 bytes, not 16");
        (uint64 equity, uint64 lockedUntil) = abi.decode(res, (uint64, uint64));
        assertEq(equity, EQUITY);
        assertEq(lockedUntil, uint64((block.timestamp + 4 days) * 1000));
    }
}

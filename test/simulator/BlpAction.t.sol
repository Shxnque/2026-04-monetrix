// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./SimulatorBase.sol";

/// @title BLP (action 15) simulator smoke test
/// @notice CoreSimulator's HyperCore does NOT dispatch action 15 (BORROW_LEND) —
///         see `lib/hyper-evm-lib/.../HyperCore.sol:executeRawAction`. That means
///         these tests verify only **integration wire**: Vault → ActionEncoder →
///         CoreWriterSim accepts the raw bytes (version check passes, action
///         enqueues, event emits) without reverting. Semantic BLP state changes
///         (supplied balance, spot deduction, interest accrual) are NOT modeled;
///         those require either a simulator extension or mainnet staging.
contract BlpActionTest is SimulatorBase {
    function setUp() public {
        setUpSimulator();
    }

    /// Supply path integrates without reverting through the real CoreWriter address.
    function test_supplyToBlp_integratesWithCoreWriterSim() public {
        vm.prank(operator);
        vault.supplyToBlp(USDC_TOKEN, 1_000_000_000); // 10 USDC L1 wei (8-dp)
    }

    /// Withdraw path integrates without reverting; includes amount=0 (HL max).
    function test_withdrawFromBlp_integratesWithCoreWriterSim_maxAmount() public {
        vm.prank(operator);
        vault.withdrawFromBlp(USDC_TOKEN, 0);
    }

    /// Withdraw with explicit amount also integrates without reverting.
    function test_withdrawFromBlp_integratesWithCoreWriterSim_explicitAmount() public {
        vm.prank(operator);
        vault.withdrawFromBlp(USDC_TOKEN, 500_000_000);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/tokens/USDM.sol";
import "../src/tokens/sUSDM.sol";
import {sUSDMEscrow} from "../src/tokens/sUSDMEscrow.sol";
import "../src/core/MonetrixConfig.sol";
import "../src/core/MonetrixVault.sol";
import "../src/core/MonetrixAccountant.sol";
import "../src/core/InsuranceFund.sol";

import "./mocks/MockUSDC.sol";
import "./mocks/MockCoreDepositWallet.sol";
import "../src/interfaces/HyperCoreConstants.sol";
import "../src/core/RedeemEscrow.sol";
import "../src/core/YieldEscrow.sol";
import "../src/governance/MonetrixAccessController.sol";

// Minimal mock for CoreWriter (accepts any sendRawAction)
contract MockCoreWriter {
    function sendRawAction(bytes calldata) external {}
}

/// @dev CoreWriter mock that records every raw action for wire-format assertions.
contract CapturingCoreWriter {
    bytes[] public actions;

    function sendRawAction(bytes calldata action) external {
        actions.push(action);
    }

    function actionsLength() external view returns (uint256) {
        return actions.length;
    }

    function lastAction() external view returns (bytes memory) {
        require(actions.length > 0, "no actions");
        return actions[actions.length - 1];
    }
}

/// @notice Controllable mock precompile for testing.
/// @dev Returns 128 zero bytes by default so Accountant's fail-closed readers
/// (which require length >= 128/96/64/32 depending on precompile) decode to
/// "no position / zero balance" rather than reverting.
contract MockPrecompile {
    mapping(bytes32 => bytes) public responses;

    function setResponse(bytes calldata callData, bytes calldata response) external {
        responses[keccak256(callData)] = response;
    }

    fallback(bytes calldata data) external payable returns (bytes memory) {
        bytes memory r = responses[keccak256(data)];
        if (r.length == 0) return new bytes(128);
        return r;
    }
}

contract MonetrixV2Test is Test {
    MockUSDC usdc;
    USDM usdm;
    sUSDM susdm;
    sUSDMEscrow unstakeEscrow;
    MonetrixConfig config;
    MonetrixVault vault;
    MonetrixAccountant accountant;
    RedeemEscrow redeemEscrow;
    YieldEscrow yieldEscrow;
    InsuranceFund insurance;

    MockCoreDepositWallet depositWallet;
    MonetrixAccessController acl;

    address admin = address(0xAD);
    address user1 = address(0x1);
    address user2 = address(0x2);
    address foundation = address(0xF0);
    address operator = address(0xBB);

    function setUp() public {
        vm.startPrank(admin);

        usdc = new MockUSDC();
        depositWallet = new MockCoreDepositWallet(address(usdc));

        // Deploy ACL first — admin is the sole DEFAULT_ADMIN for the duration of tests
        MonetrixAccessController aclImpl = new MonetrixAccessController();
        ERC1967Proxy aclProxy =
            new ERC1967Proxy(address(aclImpl), abi.encodeCall(MonetrixAccessController.initialize, (admin)));
        acl = MonetrixAccessController(address(aclProxy));

        // Deploy USDM proxy
        USDM usdmImpl = new USDM();
        ERC1967Proxy usdmProxy = new ERC1967Proxy(address(usdmImpl), abi.encodeCall(USDM.initialize, (address(acl))));
        usdm = USDM(address(usdmProxy));

        // Deploy InsuranceFund proxy
        InsuranceFund insImpl = new InsuranceFund();
        ERC1967Proxy insProxy = new ERC1967Proxy(
            address(insImpl), abi.encodeCall(InsuranceFund.initialize, (address(usdc), address(acl)))
        );
        insurance = InsuranceFund(address(insProxy));

        // Deploy Config proxy
        MonetrixConfig configImpl = new MonetrixConfig();
        ERC1967Proxy configProxy = new ERC1967Proxy(
            address(configImpl),
            abi.encodeCall(MonetrixConfig.initialize, (address(insurance), foundation, address(acl)))
        );
        config = MonetrixConfig(address(configProxy));

        // Deploy sUSDM proxy
        sUSDM susdmImpl = new sUSDM();
        ERC1967Proxy susdmProxy = new ERC1967Proxy(
            address(susdmImpl), abi.encodeCall(sUSDM.initialize, (address(usdm), address(config), address(acl)))
        );
        susdm = sUSDM(address(susdmProxy));

        // Deploy Vault proxy
        MonetrixVault vaultImpl = new MonetrixVault();
        ERC1967Proxy vaultProxy = new ERC1967Proxy(
            address(vaultImpl),
            abi.encodeCall(
                MonetrixVault.initialize,
                (
                    address(usdc),
                    address(usdm),
                    address(susdm),
                    address(config),
                    address(depositWallet),
                    address(acl)
                )
            )
        );
        vault = MonetrixVault(address(vaultProxy));

        // Deploy MonetrixAccountant proxy
        MonetrixAccountant acctImpl = new MonetrixAccountant();
        ERC1967Proxy acctProxy = new ERC1967Proxy(
            address(acctImpl),
            abi.encodeCall(
                MonetrixAccountant.initialize, (address(vault), address(usdc), address(usdm), address(acl))
            )
        );
        accountant = MonetrixAccountant(address(acctProxy));

        // Deploy RedeemEscrow proxy
        RedeemEscrow redeemImpl = new RedeemEscrow();
        ERC1967Proxy redeemProxy = new ERC1967Proxy(
            address(redeemImpl),
            abi.encodeCall(RedeemEscrow.initialize, (address(usdc), address(vault), address(acl)))
        );
        redeemEscrow = RedeemEscrow(address(redeemProxy));

        // Deploy YieldEscrow proxy
        YieldEscrow yieldImpl = new YieldEscrow();
        ERC1967Proxy yieldProxy = new ERC1967Proxy(
            address(yieldImpl),
            abi.encodeCall(YieldEscrow.initialize, (address(usdc), address(vault), address(acl)))
        );
        yieldEscrow = YieldEscrow(address(yieldProxy));

        // Grant roles on the ACL. In tests admin plays Governor+Operator+Guardian
        // so the existing `vm.prank(admin)` call patterns keep working.
        acl.grantRole(acl.GOVERNOR(), admin);
        acl.grantRole(acl.GUARDIAN(), admin);
        acl.grantRole(acl.OPERATOR(), admin);
        acl.grantRole(acl.OPERATOR(), operator);
        acl.grantRole(acl.UPGRADER(), admin);

        // Direct-vault binding replaces former VAULT_CALLER grant.
        usdm.setVault(address(vault));
        susdm.setVault(address(vault));

        // Set test-friendly parameters (bridgeInterval default 6h from init)
        config.setCooldowns(3 days, 7 days);

        // Deploy sUSDMEscrow (non-upgradeable, dumb fund custody)
        unstakeEscrow = new sUSDMEscrow(address(usdm), address(susdm));
        susdm.setEscrow(address(unstakeEscrow));

        vault.setAccountant(address(accountant));
        vault.setRedeemEscrow(address(redeemEscrow));
        vault.setYieldEscrow(address(yieldEscrow));
        accountant.setConfig(address(config));

        vm.stopPrank();

        // Install mock precompiles so accountant's totalBacking reflects bridged funds
        MockPrecompile perpMargin = new MockPrecompile();
        vm.etch(HyperCoreConstants.PRECOMPILE_ACCOUNT_MARGIN_SUMMARY, address(perpMargin).code);
        MockPrecompile spotBal = new MockPrecompile();
        vm.etch(HyperCoreConstants.PRECOMPILE_SPOT_BALANCE, address(spotBal).code);
        MockPrecompile oraclePx = new MockPrecompile();
        vm.etch(HyperCoreConstants.PRECOMPILE_ORACLE_PX, address(oraclePx).code);
        MockPrecompile vaultEquity = new MockPrecompile();
        vm.etch(HyperCoreConstants.PRECOMPILE_VAULT_EQUITY, address(vaultEquity).code);
        MockPrecompile suppliedBal = new MockPrecompile();
        vm.etch(HyperCoreConstants.PRECOMPILE_SUPPLIED_BALANCE, address(suppliedBal).code);

        // Fund users
        usdc.mint(user1, 1_000_000e6);
        usdc.mint(user2, 1_000_000e6);
    }

    /// @dev Seed vault's L1 spot USDC. M-01 guard in `_sendL1Bridge` reads
    /// `spot + supplied`. Tests using only spot can call this helper; the PM
    /// case uses `_mockVaultL1SuppliedUsdc` instead (supplied pool only).
    function _mockVaultL1SpotUsdc(uint64 l1Amount8dp) internal {
        MockPrecompile(payable(HyperCoreConstants.PRECOMPILE_SPOT_BALANCE)).setResponse(
            abi.encode(address(vault), uint64(HyperCoreConstants.USDC_TOKEN_INDEX)),
            abi.encode(l1Amount8dp, uint64(0), uint64(0))
        );
    }

    /// @dev Seed vault's L1 supplied (PM) USDC. Layout for 0x811:
    /// `(uint64, uint64, uint64, uint64 supplied)` — reader takes the 4th slot.
    function _mockVaultL1SuppliedUsdc(uint64 l1Amount8dp) internal {
        MockPrecompile(payable(HyperCoreConstants.PRECOMPILE_SUPPLIED_BALANCE)).setResponse(
            abi.encode(address(vault), uint64(HyperCoreConstants.USDC_TOKEN_INDEX)),
            abi.encode(uint64(0), uint64(0), uint64(0), l1Amount8dp)
        );
    }

    // --- Helpers ---

    function _depositAs(address user, uint256 amount) internal {
        vm.startPrank(user);
        usdc.approve(address(vault), amount);
        vault.deposit(amount);
        vm.stopPrank();
        // Sync mock precompile so Accountant sees bridged funds as perp accountValue
        _syncPerpBacking();
    }

    /// @dev Stake a portion of user's USDM into sUSDM so distributeYield has
    /// stakers (otherwise Vault.distributeYield routes userShare to foundation
    /// per the L1-H1/L5-M5 empty-vault guard).
    function _stakeAs(address user, uint256 amount) internal {
        vm.startPrank(user);
        usdm.approve(address(susdm), amount);
        susdm.deposit(amount, user);
        vm.stopPrank();
    }

    /// @dev Sync the mock 0x080F precompile to reflect the current L1 principal.
    /// In production, the real precompile reflects the real L1 state. In tests,
    /// we mirror outstandingL1Principal (what the accountant thinks was bridged)
    /// into the mock's response so totalBacking() returns a sensible value.
    function _syncPerpBacking() internal {
        int64 accountValue = int64(int256(vault.outstandingL1Principal()));
        bytes memory key = abi.encode(uint32(0), address(vault));
        bytes memory res = abi.encode(accountValue, uint64(0), uint64(0), int64(0));
        MockPrecompile(payable(HyperCoreConstants.PRECOMPILE_ACCOUNT_MARGIN_SUMMARY)).setResponse(key, res);
    }

    /// @dev Simulate `amount` of surplus (backing > supply) by boosting the
    /// mock perp backing. Does NOT call vault.settle — downstream tests that
    /// need YE balance should mint USDC into yieldEscrow directly. This keeps
    /// the helper independent of the Vault's all-or-nothing EVM-USDC guard.
    function _primeDistributable(uint256 amount) internal {
        if (accountant.lastSettlementTime() == 0) {
            _syncPerpBacking();
            vm.prank(admin);
            accountant.initializeSettlement();
        }

        int64 currentValue = int64(int256(vault.outstandingL1Principal() + amount));
        bytes memory key = abi.encode(uint32(0), address(vault));
        bytes memory res = abi.encode(currentValue, uint64(0), uint64(0), int64(0));
        MockPrecompile(payable(HyperCoreConstants.PRECOMPILE_ACCOUNT_MARGIN_SUMMARY)).setResponse(key, res);
    }

    function _depositAndStake(address user, uint256 depositAmt, uint256 stakeAmt) internal {
        _depositAs(user, depositAmt);
        vm.startPrank(user);
        usdm.approve(address(susdm), stakeAmt);
        susdm.deposit(stakeAmt, user);
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════
    //                     DEPOSIT / MINT
    // ═══════════════════════════════════════════════════════════

    function test_deposit_mintsUSDM() public {
        uint256 amount = 10_000e6;
        _depositAs(user1, amount);
        assertEq(usdm.balanceOf(user1), amount);
        assertEq(usdc.balanceOf(address(vault)), amount);
    }

    function test_deposit_belowMinimum_reverts() public {
        vm.startPrank(user1);
        usdc.approve(address(vault), 50e6);
        vm.expectRevert("deposit out of range");
        vault.deposit(50e6);
        vm.stopPrank();
    }

    function test_deposit_aboveMaximum_reverts() public {
        usdc.mint(user1, 2_000_000e6);
        vm.startPrank(user1);
        usdc.approve(address(vault), 2_000_000e6);
        vm.expectRevert("deposit out of range");
        vault.deposit(2_000_000e6);
        vm.stopPrank();
    }

    function test_deposit_paused_reverts() public {
        vm.prank(admin);
        vault.pause();
        vm.startPrank(user1);
        usdc.approve(address(vault), 1_000e6);
        vm.expectRevert();
        vault.deposit(1_000e6);
        vm.stopPrank();
    }

    function test_deposit_tvlCap_reverts() public {
        vm.prank(admin);
        config.setMaxTVL(5_000e6);
        _depositAs(user1, 3_000e6);
        vm.startPrank(user2);
        usdc.approve(address(vault), 3_000e6);
        vm.expectRevert("TVL cap exceeded");
        vault.deposit(3_000e6);
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════
    //                   AUTO-BRIDGE & KEEPER
    // ═══════════════════════════════════════════════════════════

    function test_autoBridge_triggersOnThreshold() public {
        _depositAs(user1, 60_000e6);
        // Trigger keeperBridge (auto-bridge was removed from deposit; keeper does it now)
        vm.warp(block.timestamp + 6 hours);
        vm.prank(operator);
        vault.keeperBridge(MonetrixVault.BridgeTarget.Vault);
        assertEq(usdc.balanceOf(address(vault)), 0);
    }

    function test_deposit_belowThreshold_noBridge() public {
        _depositAs(user1, 10_000e6);
        assertEq(usdc.balanceOf(address(vault)), 10_000e6);
    }

    function test_keeperBridge_afterInterval() public {
        _depositAs(user1, 10_000e6);
        vm.warp(block.timestamp + 6 hours);
        vm.prank(operator);
        vault.keeperBridge(MonetrixVault.BridgeTarget.Vault);
        assertEq(usdc.balanceOf(address(vault)), 0);
    }

    function test_keeperBridge_tooEarly_reverts() public {
        _depositAs(user1, 10_000e6);
        vm.warp(block.timestamp + 3 hours);
        vm.prank(operator);
        vm.expectRevert("too early");
        vault.keeperBridge(MonetrixVault.BridgeTarget.Vault);
    }

    function test_setMultisigVault_success() public {
        vm.prank(admin);
        vault.setMultisigVault(address(0xCC));
        assertEq(vault.multisigVault(), address(0xCC));
    }

    function test_setMultisigVault_nonAdmin_reverts() public {
        vm.prank(user1);
        vm.expectRevert();
        vault.setMultisigVault(address(0xCC));
    }

    function test_setMultisigVault_clearToZero() public {
        vm.startPrank(admin);
        vault.setMultisigVault(address(0xCC));
        assertEq(vault.multisigVault(), address(0xCC));
        vault.setMultisigVault(address(0));
        assertEq(vault.multisigVault(), address(0));
        vm.stopPrank();
    }

    /// @notice Accountant and multisigVault can coexist (no mutual exclusion).
    function test_setMultisigVault_coexistsWithAccountant() public {
        // Accountant is already set in setUp
        vm.startPrank(admin);
        vault.setMultisigVault(address(0xCC));
        assertEq(vault.multisigVault(), address(0xCC));
        assertTrue(vault.accountant() != address(0));
        vm.stopPrank();
    }

    function test_bridgeToCore_usesMultisigVault() public {
        vm.prank(admin);
        vault.setMultisigVault(address(0xCC));

        // Deposit then explicitly trigger keeperBridge; verify funds leave EVM.
        _depositAs(user1, 60_000e6);
        vm.warp(block.timestamp + 6 hours);
        vm.prank(operator);
        vault.keeperBridge(MonetrixVault.BridgeTarget.Vault);
        assertEq(usdc.balanceOf(address(vault)), 0); // bridged to multisigVault
    }

    /// @notice Regression guard: when redemptions partially reserve cash, the
    /// keeper-bridge gate must still trigger so the safe portion of pending
    /// deposits is bridged. Previously this case (60k pending / 20k reserved /
    /// 50k threshold) was skipped because the gate read `netBridgeable` (= 40k)
    /// against the 50k threshold and bailed.
    function test_autoBridge_partialReserve_bridgesSafePortion() public {
        // 1. User1 deposits 20_000 USDC and then requests redeem of the same
        //    amount so there are 20k reserved redemptions against 20k cash.
        _depositAs(user1, 20_000e6);
        vm.startPrank(user1);
        usdm.approve(address(vault), 20_000e6);
        vault.requestRedeem(20_000e6);
        vm.stopPrank();

        assertEq(redeemEscrow.totalOwed(), 20_000e6);

        // 2. User2 deposits 60k USDC. vault balance is now above threshold.
        //    Keeper-bridge should take the safe portion
        //    (balance - reservedForRedemptions shortfall) and bridge it, not skip.
        uint256 balanceBefore = usdc.balanceOf(address(vault));
        _depositAs(user2, 60_000e6);

        // 3. Trigger keeperBridge — bridges netBridgeable = vault_balance - redeemEscrow.shortfall().
        //    redeemEscrow.shortfall() = 0 (20k USDC is already in redeemEscrow).
        //    So netBridgeable = balanceBefore + 60k = 60k > 0.
        vm.warp(block.timestamp + 6 hours);
        vm.prank(operator);
        vault.keeperBridge(MonetrixVault.BridgeTarget.Vault);

        // Bridging occurred: vault USDC dropped from (balanceBefore + 60k) to 0
        uint256 balanceAfter = usdc.balanceOf(address(vault));
        assertTrue(balanceAfter < balanceBefore + 60_000e6, "auto-bridge should fire on partial reserve");
    }

    function test_autoBridge_skipsWhenRedemptionsReserveAllUSDC() public {
        // Reproduce: pending redemptions >= vault USDC balance
        // → keeperBridge would revert with "no USDC to bridge"; deposit itself succeeds

        // 1. User1 deposits 1000 USDC then keeper bridges it out (bridgeInterval = 6h default)
        _depositAs(user1, 1_000e6);
        vm.warp(block.timestamp + 6 hours);
        vm.prank(operator);
        vault.keeperBridge(MonetrixVault.BridgeTarget.Vault);
        assertEq(usdc.balanceOf(address(vault)), 0);

        // 3. User1 requests redeem of 800 USDM → redeemEscrow.totalOwed = 800
        // vault USDC = 0, redeemEscrow gets 0 (vault is empty)
        vm.startPrank(user1);
        usdm.approve(address(vault), 800e6);
        vault.requestRedeem(800e6);
        vm.stopPrank();
        assertEq(redeemEscrow.totalOwed(), 800e6);

        // State: vault USDC = 0, redeemEscrow.totalOwed = 800, redeemEscrow balance = 0
        // redeemEscrow.shortfall() = 800
        // User2 deposits 600 USDC → vault USDC = 600
        // netBridgeable = max(0, 600 - shortfall(800)) = 0 → keeperBridge would revert
        // Deposit itself must still succeed (no revert on deposit path)
        _depositAs(user2, 600e6);

        // Deposit succeeded, USDM minted, vault USDC stays (bridge not called)
        assertEq(usdm.balanceOf(user2), 600e6);
        assertEq(usdc.balanceOf(address(vault)), 600e6);
    }

    // ═══════════════════════════════════════════════════════════
    //                   REDEEM QUEUE (RequestId)
    // ═══════════════════════════════════════════════════════════

    function test_requestRedeem_locksUSDM() public {
        _depositAs(user1, 10_000e6);
        vm.startPrank(user1);
        usdm.approve(address(vault), 5_000e6);
        uint256 reqId = vault.requestRedeem(5_000e6);
        vm.stopPrank();
        assertEq(reqId, 0);
        assertEq(usdm.balanceOf(user1), 5_000e6);
        assertEq(redeemEscrow.totalOwed(), 5_000e6);
    }

    function test_claimRedeem_afterCooldown() public {
        _depositAs(user1, 10_000e6);
        vm.startPrank(user1);
        usdm.approve(address(vault), 10_000e6);
        uint256 reqId = vault.requestRedeem(10_000e6);
        vm.stopPrank();
        // Operator funds the redemption shortfall (lazy funding model)
        vm.prank(operator);
        vault.fundRedemptions(0);
        vm.warp(block.timestamp + 3 days);
        vm.prank(user1);
        vault.claimRedeem(reqId);
        assertEq(usdc.balanceOf(user1), 1_000_000e6);
        assertEq(usdm.balanceOf(user1), 0);
        assertEq(redeemEscrow.totalOwed(), 0);
    }

    function test_claimRedeem_beforeCooldown_reverts() public {
        _depositAs(user1, 10_000e6);
        vm.startPrank(user1);
        usdm.approve(address(vault), 10_000e6);
        uint256 reqId = vault.requestRedeem(10_000e6);
        vm.warp(block.timestamp + 2 days);
        vm.expectRevert("invalid claim");
        vault.claimRedeem(reqId);
        vm.stopPrank();
    }

    function test_claimRedeem_otherUser_reverts() public {
        _depositAs(user1, 10_000e6);
        vm.startPrank(user1);
        usdm.approve(address(vault), 5_000e6);
        vault.requestRedeem(5_000e6);
        vm.stopPrank();
        vm.warp(block.timestamp + 3 days);
        vm.prank(user2);
        vm.expectRevert("invalid claim");
        vault.claimRedeem(0);
    }

    // ═══════════════════════════════════════════════════════════
    //                     sUSDM STAKING (ERC-4626)
    // ═══════════════════════════════════════════════════════════

    function test_stake_deposit() public {
        _depositAs(user1, 10_000e6);
        vm.startPrank(user1);
        usdm.approve(address(susdm), 10_000e6);
        uint256 shares = susdm.deposit(10_000e6, user1);
        vm.stopPrank();
        assertGt(shares, 0);
        assertEq(usdm.balanceOf(user1), 0);
        assertGt(susdm.balanceOf(user1), 0);
    }

    function test_exchangeRate_increasesAfterYield() public {
        _depositAndStake(user1, 10_000e6, 10_000e6);
        uint256 assetsBefore = susdm.convertToAssets(susdm.balanceOf(user1));

        // Distribute yield: vault mints USDM to itself, approves sUSDM to pull
        vm.startPrank(address(vault));
        usdm.mint(address(vault), 1_000e6);
        usdm.approve(address(susdm), 1_000e6);
        susdm.injectYield(1_000e6);
        vm.stopPrank();

        uint256 assetsAfter = susdm.convertToAssets(susdm.balanceOf(user1));
        assertGt(assetsAfter, assetsBefore);
    }

    function test_cooldownShares_and_claim() public {
        _depositAndStake(user1, 10_000e6, 10_000e6);
        uint256 shares = susdm.balanceOf(user1);

        vm.startPrank(user1);
        uint256 reqId = susdm.cooldownShares(shares);
        vm.warp(block.timestamp + 7 days);
        susdm.claimUnstake(reqId);
        vm.stopPrank();

        assertEq(susdm.balanceOf(user1), 0);
        assertGt(usdm.balanceOf(user1), 0);
    }

    function test_cooldownShares_beforeExpiry_reverts() public {
        _depositAndStake(user1, 10_000e6, 10_000e6);
        uint256 shares = susdm.balanceOf(user1);

        vm.startPrank(user1);
        uint256 reqId = susdm.cooldownShares(shares);
        vm.warp(block.timestamp + 5 days);
        vm.expectRevert();
        susdm.claimUnstake(reqId);
        vm.stopPrank();
    }

    function test_unstake_doesNotChangeRate() public {
        _depositAndStake(user1, 10_000e6, 10_000e6);
        _depositAndStake(user2, 10_000e6, 10_000e6);

        uint256 rateBefore = susdm.convertToAssets(1e12); // use large number for precision

        vm.startPrank(user1);
        susdm.cooldownShares(susdm.balanceOf(user1));
        vm.stopPrank();

        uint256 rateAfter = susdm.convertToAssets(1e12);
        assertEq(rateBefore, rateAfter);
    }

    function test_withdraw_reverts() public {
        vm.expectRevert();
        susdm.withdraw(100, address(this), address(this));
    }

    function test_redeem_reverts() public {
        vm.expectRevert();
        susdm.redeem(100, address(this), address(this));
    }

    // ═══════════════════════════════════════════════════════════
    //                  YIELD DISTRIBUTION
    // ═══════════════════════════════════════════════════════════

    function test_distributeYield_splits70_10_20() public {
        _depositAs(user1, 100_000e6);
        _stakeAs(user1, 1_000e6);  // ensure sUSDM has stakers (L1-H1 guard)
        usdc.mint(address(yieldEscrow), 1_000e6);

        vm.prank(admin);
        vault.distributeYield();

        // 70% = 700 USDM minted to sUSDM (on top of pre-staked 1000)
        assertEq(usdm.balanceOf(address(susdm)), 1_000e6 + 700e6);
        // 10% = 100 USDC to insurance
        assertEq(usdc.balanceOf(address(insurance)), 100e6);
        // 20% = 200 USDC to foundation
        assertEq(usdc.balanceOf(foundation), 200e6);
    }

    function test_distributeYield_customRatio() public {
        vm.prank(admin);
        config.setYieldBps(8000, 1000);

        _depositAs(user1, 100_000e6);
        _stakeAs(user1, 1_000e6);  // ensure sUSDM has stakers (L1-H1 guard)
        usdc.mint(address(yieldEscrow), 1_000e6);

        vm.prank(admin);
        vault.distributeYield();

        assertEq(usdm.balanceOf(address(susdm)), 1_000e6 + 800e6);  // pre-staked + yield
        assertEq(usdc.balanceOf(address(insurance)), 100e6);
        assertEq(usdc.balanceOf(foundation), 100e6);
    }

    // ═══════════════════════════════════════════════════════════
    //                   HEDGE EXECUTION (on Vault)
    // ═══════════════════════════════════════════════════════════

    function test_executeHedge_onlyKeeper() public {
        ActionEncoder.HedgeParams memory params = ActionEncoder.HedgeParams({
            spotAsset: 10151,
            perpAsset: 1,
            size: 100_000_000,
            spotPrice: 300000000000,
            perpPrice: 300000000000,
            cloid: uint128(0),
            tif: uint8(3),
            spotReduceOnly: false,
            perpReduceOnly: false
        });
        vm.prank(user1);
        vm.expectRevert();
        vault.executeHedge(0, params);
    }

    function test_executeHedge_zeroSize_reverts() public {
        ActionEncoder.HedgeParams memory params = ActionEncoder.HedgeParams({
            spotAsset: 10151,
            perpAsset: 1,
            size: 0,
            spotPrice: 300000000000,
            perpPrice: 300000000000,
            cloid: uint128(0),
            tif: uint8(3),
            spotReduceOnly: false,
            perpReduceOnly: false
        });
        vm.prank(operator);
        vm.expectRevert("zero size");
        vault.executeHedge(0, params);
    }

    function test_bridgePrincipalFromL1_onlyOperator() public {
        vm.prank(user1);
        vm.expectRevert();
        vault.bridgePrincipalFromL1(1000);
    }

    function test_bridgeYieldFromL1_onlyOperator() public {
        vm.prank(user1);
        vm.expectRevert();
        vault.bridgeYieldFromL1(1000);
    }

    function test_emergencyRawAction_onlyAdmin() public {
        vm.prank(operator);
        vm.expectRevert();
        vault.emergencyRawAction(hex"01");
    }

    // ═══════════════════════════════════════════════════════════
    //                   INSURANCE FUND
    // ═══════════════════════════════════════════════════════════

    function test_insuranceFund_anyoneCanDeposit() public {
        usdc.mint(admin, 10_000e6);
        vm.startPrank(admin);
        usdc.approve(address(insurance), 10_000e6);
        insurance.deposit(10_000e6);
        vm.stopPrank();
        assertEq(usdc.balanceOf(address(insurance)), 10_000e6);
    }

    function test_insuranceFund_adminWithdraw() public {
        // Deposit via yield distribution
        _depositAs(user1, 100_000e6);
        usdc.mint(address(yieldEscrow), 1_000e6);
        vm.prank(admin);
        vault.distributeYield();

        uint256 insBal = usdc.balanceOf(address(insurance));
        assertGt(insBal, 0);

        vm.prank(admin);
        insurance.withdraw(admin, insBal, "test withdraw");
        assertEq(usdc.balanceOf(address(insurance)), 0);
    }

    // ═══════════════════════════════════════════════════════════
    //                   CONFIG
    // ═══════════════════════════════════════════════════════════

    /// @dev Yield bps live on MonetrixConfig (static configuration, admin-controlled).
    function test_config_setYieldBps_exceedReverts() public {
        vm.prank(admin);
        vm.expectRevert("Config: bps exceed 10000");
        config.setYieldBps(9000, 2000);
    }

    function test_config_foundationYieldBps_default() public view {
        // Default init: userYieldBps=7000, insuranceYieldBps=1000
        assertEq(config.foundationYieldBps(), 2000);
    }

    function test_config_setDepositLimits() public {
        vm.prank(admin);
        config.setDepositLimits(50e6, 500_000e6);
        assertEq(config.minDepositAmount(), 50e6);
        assertEq(config.maxDepositAmount(), 500_000e6);
    }

    // ═══════════════════════════════════════════════════════════
    //                   EMERGENCY WITHDRAW
    // ═══════════════════════════════════════════════════════════

    // ═══════════════════════════════════════════════════════════
    //                   VIEW HELPERS
    // ═══════════════════════════════════════════════════════════

    function test_vaultBalance_lazyFundModel() public {
        _depositAs(user1, 10_000e6);
        assertEq(usdc.balanceOf(address(vault)), 10_000e6);

        vm.startPrank(user1);
        usdm.approve(address(vault), 3_000e6);
        vault.requestRedeem(3_000e6);
        vm.stopPrank();
        // requestRedeem only records obligation (lazy-fund model); USDC stays in vault
        assertEq(usdc.balanceOf(address(vault)), 10_000e6);

        // Operator funds the shortfall → 3k moves from vault to redeemEscrow
        vm.prank(operator);
        vault.fundRedemptions(0);
        assertEq(usdc.balanceOf(address(vault)), 7_000e6);

        // Simulate yield arriving in vault
        usdc.mint(address(vault), 500e6);
        assertEq(usdc.balanceOf(address(vault)), 7_500e6);
    }

    function test_canKeeperBridge() public {
        _depositAs(user1, 10_000e6);
        assertFalse(vault.canKeeperBridge());
        vm.warp(block.timestamp + 6 hours);
        assertTrue(vault.canKeeperBridge());
    }

    // ═══════════════════════════════════════════════════════════
    //          AUDIT FIXES — REGRESSION TESTS
    // ═══════════════════════════════════════════════════════════

    // F-1: distributeYield pulls from YieldEscrow — cannot touch vault or redeem USDC
    function test_distributeYield_respectsReserved() public {
        // Deposit below auto-bridge threshold (50k) so USDC stays in vault
        _depositAs(user1, 40_000e6);
        _stakeAs(user1, 1_000e6);  // ensure sUSDM has stakers (L1-H1 guard)
        // pendingDeposits=40_000, vault balance=40_000, yieldEscrow balance=0

        // user1 requests redeem for 30k — 30k USDC moves from vault to redeemEscrow
        vm.startPrank(user1);
        usdm.approve(address(vault), 30_000e6);
        vault.requestRedeem(30_000e6);
        vm.stopPrank();
        // vault balance=10_000, redeemEscrow balance=30_000, yieldEscrow balance=0

        // distributeYield with empty yieldEscrow must revert — YieldEscrow has no funds
        vm.prank(admin);
        vm.expectRevert("no yield");
        vault.distributeYield();

        // Route yield into YieldEscrow (simulates L1 yield being bridged and collected)
        usdc.mint(address(yieldEscrow), 5_000e6);
        // yieldEscrow balance=5_000

        // Now distributeYield should succeed — YieldEscrow has the funds
        vm.prank(admin);
        vault.distributeYield();
        // 70%=3500 USDM to sUSDM (on top of pre-staked 1000), 10%=500 USDC to insurance, 20%=1000 USDC to foundation
        assertEq(usdm.balanceOf(address(susdm)), 1_000e6 + 3_500e6);
        assertEq(usdc.balanceOf(address(insurance)), 500e6);
        assertEq(usdc.balanceOf(foundation), 1_000e6);
    }

    // F-3: partial bridge bridges only netBridgeable and increments outstandingL1Principal
    function test_partialBridge_bridgesNetBridgeable() public {
        _depositAs(user1, 10_000e6);

        // Reserve 8k via redeem request — lazy-fund model: obligation recorded, USDC stays in vault
        vm.startPrank(user1);
        usdm.approve(address(vault), 8_000e6);
        vault.requestRedeem(8_000e6);
        vm.stopPrank();

        vm.warp(block.timestamp + 6 hours);

        // Keeper triggers bridge — only 2k can bridge (netBridgeable = vault_bal(10k) - shortfall(8k) = 2k)
        vm.prank(operator);
        vault.keeperBridge(MonetrixVault.BridgeTarget.Vault);

        // 2k bridged: vault USDC = 10k - 2k = 8k (retained to cover 8k redemption shortfall), OLP = 2k
        assertEq(usdc.balanceOf(address(vault)), 8_000e6);
        assertEq(vault.outstandingL1Principal(), 2_000e6);
    }

    // F-4: cooldownAssets uses precise asset value from burned shares
    function test_cooldownAssets_preciseValue() public {
        _depositAndStake(user1, 10_000e6, 10_000e6);

        // Inject yield to shift exchange rate (makes rounding non-trivial)
        vm.startPrank(address(vault));
        usdm.mint(address(vault), 333e6);
        usdm.approve(address(susdm), 333e6);
        susdm.injectYield(333e6);
        vm.stopPrank();

        uint256 pendingBefore = susdm.totalPendingClaims();

        // cooldownAssets with an amount that may cause rounding
        vm.startPrank(user1);
        uint256 requestedAssets = 5_001e6; // odd amount to trigger rounding
        uint256 reqId = susdm.cooldownAssets(requestedAssets);
        vm.stopPrank();

        // With previewWithdraw (ceil rounding), user gets exactly what they asked for
        (,, uint256 storedUsdmAmount,,) = susdm.unstakeRequests(reqId);
        assertEq(storedUsdmAmount, requestedAssets, "user should get exact requested assets");

        // totalPendingClaims tracks the exact requested amount
        assertEq(susdm.totalPendingClaims(), pendingBefore + requestedAssets);
    }

    // F-5: distributeYield pulls from YieldEscrow — deposits in vault are structurally isolated
    function test_distributeYield_cannotSpendPendingDeposits() public {
        // Deposit below auto-bridge threshold → USDC stays in vault
        _depositAs(user1, 30_000e6);
        // pendingDeposits=30_000, vault balance=30_000, yieldEscrow balance=0
        // distributeYield must revert — YieldEscrow is empty

        vm.prank(admin);
        vm.expectRevert("no yield");
        vault.distributeYield();

        // Structural isolation: even if someone sneaks USDC into vault,
        // distributeYield only reads yieldEscrow — vault USDC is never touched
        usdc.mint(address(vault), 5_000e6);
        vm.prank(admin);
        vm.expectRevert("no yield");
        vault.distributeYield();
    }

    // F-6: only yield actually routed into YieldEscrow is distributable
    function test_distributeYield_onlyRealYield() public {
        _depositAs(user1, 30_000e6);
        _stakeAs(user1, 1_000e6);  // ensure sUSDM has stakers (L1-H1 guard)
        // pendingDeposits=30_000, vault balance=30_000, yieldEscrow balance=0

        // Simulate yield bridged back from L1 and routed to YieldEscrow
        usdc.mint(address(yieldEscrow), 1_000e6);
        // yieldEscrow balance=1_000

        // Can distribute from yieldEscrow
        // yield=1_000 → insurance=100, foundation=200
        vm.prank(admin);
        vault.distributeYield();

        assertEq(usdc.balanceOf(foundation), 200e6);
        assertEq(usdc.balanceOf(address(insurance)), 100e6);
    }

    // (wireRoles / setVault idempotency tests removed — those one-time
    //  wiring functions no longer exist; role grants go through the ACL.)

    // ═══════════════════════════════════════════════════════════
    //    AUDIT FIX TESTS — F-01 ~ F-05, F-09
    // ═══════════════════════════════════════════════════════════

    // F-01: bridgeYieldFromL1 sends to vault via _sendL1Bridge
    function test_bridgeYieldFromL1_sendsToVault() public {
        _mockVaultL1SpotUsdc(type(uint64).max);
        vm.etch(HyperCoreConstants.CORE_WRITER, address(new MockCoreWriter()).code);
        _primeDistributable(1_000e6); // set up 1k of approved yield
        vm.prank(operator);
        vault.bridgeYieldFromL1(1_000e6);
    }

    // F-01b: bridgePrincipalFromL1 requires OLP > 0
    function test_bridgePrincipalFromL1_requiresOLP() public {
        vm.etch(HyperCoreConstants.CORE_WRITER, address(new MockCoreWriter()).code);
        // No deposits bridged → OLP=0 → cannot withdraw
        vm.prank(operator);
        vm.expectRevert("invalid bridge amount");
        vault.bridgePrincipalFromL1(1_000e6);
    }

    // F-03: claimRedeem correctly updates redeemEscrow.totalOwed and pays user from RedeemEscrow
    function test_claimRedeem_reconcilesPendingDeposits() public {
        // Deposit 10k (below 50k auto-bridge threshold) → vault balance = 10k
        _depositAs(user1, 10_000e6);
        assertEq(usdc.balanceOf(address(vault)), 10_000e6);

        // Request redeem 8k → only records obligation; USDC stays in vault (lazy-fund model)
        vm.startPrank(user1);
        usdm.approve(address(vault), 8_000e6);
        uint256 reqId = vault.requestRedeem(8_000e6);
        vm.stopPrank();
        assertEq(redeemEscrow.totalOwed(), 8_000e6, "obligation recorded");
        assertEq(usdc.balanceOf(address(redeemEscrow)), 0, "redeemEscrow unfunded until operator funds");
        assertEq(usdc.balanceOf(address(vault)), 10_000e6, "vault still holds 10k");

        // Operator funds the shortfall: 8k USDC moves from vault → redeemEscrow
        vm.prank(operator);
        vault.fundRedemptions(0);
        assertEq(usdc.balanceOf(address(redeemEscrow)), 8_000e6, "redeemEscrow funded");
        assertEq(usdc.balanceOf(address(vault)), 2_000e6, "vault has 2k remainder");

        // Warp past cooldown and claim
        vm.warp(block.timestamp + 3 days);
        vm.prank(user1);
        vault.claimRedeem(reqId);

        // After claim: user received 8k from redeemEscrow, redeemEscrow.totalOwed = 0
        assertEq(redeemEscrow.totalOwed(), 0, "redemptions cleared");
        assertEq(usdc.balanceOf(user1), 1_000_000e6 - 10_000e6 + 8_000e6, "user balance correct");
        assertEq(usdc.balanceOf(address(redeemEscrow)), 0, "redeemEscrow empty after payout");
        assertEq(usdc.balanceOf(address(vault)), 2_000e6, "vault unchanged after payout");
    }

    // F-02: distributeYield distributes exactly what is in YieldEscrow
    function test_distributeYield_requiresFullYieldBacking() public {
        _depositAs(user1, 100_000e6);
        // After auto-bridge: vault balance=0, OLP=100_000

        // Empty yieldEscrow → distributeYield reverts
        vm.prank(admin);
        vm.expectRevert("no yield");
        vault.distributeYield();

        // Inject 1000 USDC into yieldEscrow — distributeYield distributes it all
        // After pull: vault=1000, L1=100k → backing=101k >= supply(100k)+1k ✓
        usdc.mint(address(yieldEscrow), 1_000e6);
        vm.prank(admin);
        vault.distributeYield();
    }

    // F-05: distributeYield reads insuranceFund from config
    function test_distributeYield_usesConfigInsuranceFund() public {
        // Deploy a new InsuranceFund
        InsuranceFund newInsImpl = new InsuranceFund();
        ERC1967Proxy newInsProxy =
            new ERC1967Proxy(address(newInsImpl), abi.encodeCall(InsuranceFund.initialize, (address(usdc), admin)));
        InsuranceFund newInsurance = InsuranceFund(address(newInsProxy));

        // Admin updates config to point to new InsuranceFund
        vm.prank(admin);
        config.setInsuranceFund(address(newInsurance));

        // Deposit + yield
        _depositAs(user1, 100_000e6);
        usdc.mint(address(yieldEscrow), 1_000e6);

        vm.prank(admin);
        vault.distributeYield();

        // Insurance share (10% = 100) should go to NEW insurance fund
        assertEq(usdc.balanceOf(address(newInsurance)), 100e6);
        // Old insurance fund should have 0
        assertEq(usdc.balanceOf(address(insurance)), 0);
    }

    // ═══════════════════════════════════════════════════════════
    //       SOLVENCY + DUAL-CHANNEL WITHDRAWAL TESTS
    // ═══════════════════════════════════════════════════════════

    // Peg: trying to distribute more than real backing → blocked
    function test_distributeYield_solvencyCheck_blocks() public {
        vm.etch(HyperCoreConstants.CORE_WRITER, address(new MockCoreWriter()).code);

        // Deposit 100k → backing = 100k, supply = 100k
        _depositAs(user1, 100_000e6);

        // Try to distribute yield — yieldEscrow is empty → reverts
        vm.prank(admin);
        vm.expectRevert("no yield");
        vault.distributeYield();
    }

    // Peg: distributing real yield (yield in YieldEscrow) passes
    function test_distributeYield_solvencyCheck_passes() public {
        vm.etch(HyperCoreConstants.CORE_WRITER, address(new MockCoreWriter()).code);

        // Deposit 100k → backing = 100k, supply = 100k
        _depositAs(user1, 100_000e6);
        _stakeAs(user1, 1_000e6);  // ensure sUSDM has stakers (L1-H1 guard)

        // Simulate 2k yield routed into YieldEscrow (e.g. from L1 profit bridged and routed)
        usdc.mint(address(yieldEscrow), 2_000e6);

        // pullForDistribution moves 2k from yieldEscrow → vault (vault now has 2k)
        // Peg: backing = 2k(vault) + 100k(L1) = 102k >= supply(100k) + 2k ✓
        vm.prank(admin);
        vault.distributeYield();

        assertEq(usdm.balanceOf(address(susdm)), 1_000e6 + 1_400e6);
        assertEq(usdc.balanceOf(address(insurance)), 200e6);
        assertEq(usdc.balanceOf(foundation), 400e6);
    }

    // OLP increments on bridge
    function test_outstandingL1Principal_incrementsOnBridge() public {
        assertEq(vault.outstandingL1Principal(), 0);

        // First deposit + keeperBridge
        // lastBridgeTimestamp starts at block.timestamp (1). Warp past first interval.
        _depositAs(user1, 60_000e6);
        vm.warp(block.timestamp + 6 hours); // → 21601; lastBridgeTimestamp set to 21601
        vm.prank(operator);
        vault.keeperBridge(MonetrixVault.BridgeTarget.Vault);
        assertEq(vault.outstandingL1Principal(), 60_000e6);
        assertEq(usdc.balanceOf(address(vault)), 0);

        // Second deposit → keeper bridge after second interval.
        // Use absolute time: first bridge set lastBridgeTimestamp=21601; need >=43201.
        _depositAs(user2, 10_000e6);
        assertEq(vault.outstandingL1Principal(), 60_000e6); // unchanged until bridge
        vm.warp(43201); // 21601 + 21600 = 43201
        vm.prank(operator);
        vault.keeperBridge(MonetrixVault.BridgeTarget.Vault);
        assertEq(vault.outstandingL1Principal(), 70_000e6);
    }

    // bridgePrincipalFromL1 decrements OLP
    function test_bridgePrincipalFromL1_decrementsOLP() public {
        vm.etch(HyperCoreConstants.CORE_WRITER, address(new MockCoreWriter()).code);
        _mockVaultL1SpotUsdc(type(uint64).max);

        _depositAs(user1, 60_000e6);
        vm.warp(block.timestamp + 6 hours);
        vm.prank(operator);
        vault.keeperBridge(MonetrixVault.BridgeTarget.Vault); // bridge → OLP=60k
        assertEq(vault.outstandingL1Principal(), 60_000e6);

        // Create a pending redemption so withdraw has a shortfall to cover
        vm.startPrank(user1);
        usdm.approve(address(vault), 20_000e6);
        vault.requestRedeem(20_000e6);
        vm.stopPrank();

        vm.prank(operator);
        vault.bridgePrincipalFromL1(20_000e6);
        assertEq(vault.outstandingL1Principal(), 40_000e6);
    }

    // bridgeYieldFromL1 does NOT change OLP. We prime surplus via settlement
    // to represent realistic state before bridging yield.
    function test_bridgeYieldFromL1_noOLPChange() public {
        vm.etch(HyperCoreConstants.CORE_WRITER, address(new MockCoreWriter()).code);
        _mockVaultL1SpotUsdc(type(uint64).max);

        _depositAs(user1, 60_000e6);
        vm.warp(block.timestamp + 6 hours);
        vm.prank(operator);
        vault.keeperBridge(MonetrixVault.BridgeTarget.Vault); // bridge → OLP=60k
        _primeDistributable(5_000e6); // settle with 5k of recognized profit

        vm.prank(operator);
        vault.bridgeYieldFromL1(5_000e6);
        assertEq(vault.outstandingL1Principal(), 60_000e6); // unchanged
    }

    // bridgePrincipalFromL1 exceeding OLP reverts
    function test_bridgePrincipalFromL1_exceedsOLP_reverts() public {
        vm.etch(HyperCoreConstants.CORE_WRITER, address(new MockCoreWriter()).code);

        _depositAs(user1, 60_000e6); // auto-bridge → OLP=60k

        // Create pending redemption larger than OLP (impossible in practice
        // since user can only redeem up to their USDM, but we request the
        // full 60k to create a matching shortfall)
        vm.startPrank(user1);
        usdm.approve(address(vault), 60_000e6);
        vault.requestRedeem(60_000e6);
        vm.stopPrank();

        vm.prank(operator);
        vm.expectRevert("invalid bridge amount");
        vault.bridgePrincipalFromL1(60_001e6);
    }

    // M-01 regression: _sendL1Bridge reverts when vault's L1 USDC (spot +
    // supplied) is below the requested amount. Prevents phantom SEND_ASSET
    // actions that L1 would silently drop (hedge still parked in perp/HLP, or
    // multisig's SPOT_SEND step 1 not yet settled).
    function test_bridgePrincipalFromL1_revertsWhenL1SpotInsufficient() public {
        vm.etch(HyperCoreConstants.CORE_WRITER, address(new MockCoreWriter()).code);
        // Default state: both spot (0x801) and supplied (0x811) mocks return
        // zero — simulates "hedge funds are parked in perp, no USDC on L1".

        _depositAs(user1, 60_000e6);
        vm.warp(block.timestamp + 6 hours);
        vm.prank(operator);
        vault.keeperBridge(MonetrixVault.BridgeTarget.Vault);

        vm.startPrank(user1);
        usdm.approve(address(vault), 20_000e6);
        vault.requestRedeem(20_000e6);
        vm.stopPrank();

        vm.prank(operator);
        vm.expectRevert("L1 USDC insufficient (unwind hedge or wait for settlement)");
        vault.bridgePrincipalFromL1(20_000e6);

        // Fix the mock so just enough is available, then bridge-back succeeds.
        _mockVaultL1SpotUsdc(20_000e6 * 100); // 6-dp → 8-dp wei
        vm.prank(operator);
        vault.bridgePrincipalFromL1(20_000e6);
        assertEq(vault.outstandingL1Principal(), 40_000e6);
    }

    // M-01 PM regression: vault under Portfolio Margin has spot=0 and USDC
    // parked in the 0x811 supplied pool. SEND_ASSET pulls from supplied
    // directly — validated on testnet via PM EOA 0xadD6Fc118AED4FbeFB0f69d1c9Cc4114c15225Bc
    // (spot=0, supplied>0) executing SEND_ASSET to USDC_SYSTEM_ADDRESS with
    // the EVM bridge fee. Guard must accept spot + supplied, not spot alone —
    // but only after governor flips `pmEnabled` (matches the ops-level PM
    // enablement step on the L1 account).
    function test_bridgePrincipalFromL1_succeedsWhenSuppliedCoversAmount() public {
        vm.etch(HyperCoreConstants.CORE_WRITER, address(new MockCoreWriter()).code);

        _depositAs(user1, 60_000e6);
        vm.warp(block.timestamp + 6 hours);
        vm.prank(operator);
        vault.keeperBridge(MonetrixVault.BridgeTarget.Vault);

        vm.startPrank(user1);
        usdm.approve(address(vault), 20_000e6);
        vault.requestRedeem(20_000e6);
        vm.stopPrank();

        // PM shape: spot stays at default 0, all USDC sits in supplied pool.
        _mockVaultL1SuppliedUsdc(20_000e6 * 100); // 6-dp → 8-dp wei

        // pmEnabled defaults to false → supplied is ignored, bridge must revert.
        vm.prank(operator);
        vm.expectRevert("L1 USDC insufficient (unwind hedge or wait for settlement)");
        vault.bridgePrincipalFromL1(20_000e6);

        // Governor flips the flag once ops has enabled PM on the L1 account.
        vm.prank(admin);
        vault.setPmEnabled(true);

        vm.prank(operator);
        vault.bridgePrincipalFromL1(20_000e6);
        assertEq(vault.outstandingL1Principal(), 40_000e6);
    }

    // Strict-mode regression: PrecompileReader.suppliedBalance must propagate
    // the 0x811 revert (never-supplied account) instead of silently returning
    // 0. This enforces the main-net PM activation ordering invariant — flipping
    // `pmEnabled` before PM is actually activated on L1 must fail loudly rather
    // than mask a misconfiguration. Operational contract: ops keeps
    // `pmEnabled=false` until PM is opened + auto-supply has occurred.
    function test_suppliedBalance_revertsWhenNeverSupplied() public {
        vm.etch(HyperCoreConstants.CORE_WRITER, address(new MockCoreWriter()).code);

        _depositAs(user1, 60_000e6);
        vm.warp(block.timestamp + 6 hours);
        vm.prank(operator);
        vault.keeperBridge(MonetrixVault.BridgeTarget.Vault);

        vm.startPrank(user1);
        usdm.approve(address(vault), 20_000e6);
        vault.requestRedeem(20_000e6);
        vm.stopPrank();

        // Simulate ops mistakenly flipping pmEnabled before PM activation.
        vm.prank(admin);
        vault.setPmEnabled(true);

        // 0x811 reverts (fresh L1 account, never supplied).
        vm.mockCallRevert(
            HyperCoreConstants.PRECOMPILE_SUPPLIED_BALANCE,
            abi.encode(address(vault), uint64(HyperCoreConstants.USDC_TOKEN_INDEX)),
            "supplied precompile unavailable"
        );
        _mockVaultL1SpotUsdc(20_000e6 * 100);

        // Bridge must surface the precompile failure, not silently succeed.
        vm.prank(operator);
        vm.expectRevert(bytes("PrecompileReader: supplied balance read failed"));
        vault.bridgePrincipalFromL1(20_000e6);
    }

    // Setter access control: only GOVERNOR may flip `pmEnabled`.
    function test_setPmEnabled_onlyGovernor() public {
        assertEq(vault.pmEnabled(), false);

        // Non-governor (operator here) must be rejected.
        vm.prank(operator);
        vm.expectRevert();
        vault.setPmEnabled(true);

        vm.prank(admin);
        vault.setPmEnabled(true);
        assertEq(vault.pmEnabled(), true);

        vm.prank(admin);
        vault.setPmEnabled(false);
        assertEq(vault.pmEnabled(), false);
    }

    // Surplus view — read directly from Accountant (Vault.maxDistributableYield wrapper removed)
    function test_accountantSurplus_formula() public {
        // Initial: no deposits → systemUSDC=0, supply=0 → surplus=0
        assertEq(accountant.surplus(), 0);

        // Deposit 100k → auto-bridge → OLP=100k, balance=0, supply=100k
        _depositAs(user1, 100_000e6);
        assertEq(accountant.surplus(), 0);

        // Add 5k "yield" USDC to vault
        usdc.mint(address(vault), 5_000e6);
        assertEq(accountant.surplus(), 5_000e6);
    }


    function test_solvencyAfterDistribution_zero() public {
        vm.etch(HyperCoreConstants.CORE_WRITER, address(new MockCoreWriter()).code);

        _depositAs(user1, 100_000e6);
        usdc.mint(address(yieldEscrow), 3_000e6);
        // YieldEscrow excluded from backing → surplus reads vault+L1 vs supply
        assertEq(accountant.surplus(), 0);

        vm.prank(admin);
        vault.distributeYield();

        // After distribution: user share minted as USDM → supply up; vault balance drained
        // net surplus should be back at ≤0
        assertLe(accountant.surplus(), 0);
    }

    // Full cycle: deposit → bridge → withdrawYield → distribute → claimRedeem
    function test_dualChannel_fullCycle() public {
        vm.etch(HyperCoreConstants.CORE_WRITER, address(new MockCoreWriter()).code);
        _mockVaultL1SpotUsdc(type(uint64).max);

        // 1. Deposit 100k then keeperBridge → OLP=100k
        _depositAs(user1, 100_000e6);
        _stakeAs(user1, 1_000e6);  // ensure sUSDM has stakers (L1-H1 guard)
        vm.warp(block.timestamp + 6 hours);
        vm.prank(operator);
        vault.keeperBridge(MonetrixVault.BridgeTarget.Vault);
        // _stakeAs moves USDM to sUSDM but USDC stays in Vault, so bridgeable = 100k
        assertEq(vault.outstandingL1Principal(), 100_000e6);
        assertEq(usdc.balanceOf(address(vault)), 0);

        // 2. Yield accrues on L1; settlement records 2k of surplus
        _primeDistributable(2_000e6);

        // 3. Withdraw yield from L1 and simulate USDC arriving in yieldEscrow
        vm.prank(operator);
        vault.bridgeYieldFromL1(2_000e6);
        usdc.mint(address(yieldEscrow), 2_000e6); // simulate L1 yield arrival collected into yieldEscrow

        // 4. Distribute yield
        vm.prank(admin);
        vault.distributeYield();
        assertEq(usdm.balanceOf(address(susdm)), 1_000e6 + 1_400e6); // pre-staked + 70% of yield

        // 5. User requests redeem
        vm.startPrank(user1);
        usdm.approve(address(vault), 50_000e6);
        uint256 reqId = vault.requestRedeem(50_000e6);
        vm.stopPrank();

        // 6. Withdraw principal from L1 to fund redemption (shortfall gate
        // only allows withdrawing exactly the uncovered amount)
        uint256 shortfall = vault.redemptionShortfall();
        vm.prank(operator);
        vault.bridgePrincipalFromL1(shortfall);
        usdc.mint(address(vault), shortfall); // simulate L1 principal return

        // Fund RedeemEscrow from Vault so claimRedeem can pay out
        vm.prank(operator);
        vault.fundRedemptions(0);

        // 7. Claim redeem
        vm.warp(block.timestamp + 3 days);
        vm.prank(user1);
        vault.claimRedeem(reqId);
        assertEq(usdc.balanceOf(user1), 950_000e6); // started with 1M, deposited 100k, got 50k back
    }

    // ═══════════════════════════════════════════════════════════
    //          USER REQUEST TRACKING — VAULT REDEEM
    // ═══════════════════════════════════════════════════════════

    function test_getUserRedeemIds_empty() public view {
        uint256[] memory ids = vault.getUserRedeemIds(user1);
        assertEq(ids.length, 0);
    }

    function test_getUserRedeemIds_singleRequest() public {
        _depositAs(user1, 10_000e6);
        vm.startPrank(user1);
        usdm.approve(address(vault), 5_000e6);
        uint256 reqId = vault.requestRedeem(5_000e6);
        vm.stopPrank();

        uint256[] memory ids = vault.getUserRedeemIds(user1);
        assertEq(ids.length, 1);
        assertEq(ids[0], reqId);
    }

    function test_getUserRedeemRequests_returnsDetails() public {
        _depositAs(user1, 10_000e6);
        vm.startPrank(user1);
        usdm.approve(address(vault), 5_000e6);
        vault.requestRedeem(5_000e6);
        vm.stopPrank();

        MonetrixVault.RedeemRequestDetail[] memory details = vault.getUserRedeemRequests(user1);
        assertEq(details.length, 1);
        assertEq(details[0].requestId, 0);
        assertEq(details[0].usdmAmount, 5_000e6);
        assertGt(details[0].cooldownEnd, block.timestamp);
    }

    function test_getUserRedeemIds_multipleRequests() public {
        _depositAs(user1, 10_000e6);
        vm.startPrank(user1);
        usdm.approve(address(vault), 10_000e6);
        uint256 id0 = vault.requestRedeem(3_000e6);
        uint256 id1 = vault.requestRedeem(4_000e6);
        uint256 id2 = vault.requestRedeem(3_000e6);
        vm.stopPrank();

        uint256[] memory ids = vault.getUserRedeemIds(user1);
        assertEq(ids.length, 3);
        assertEq(ids[0], id0);
        assertEq(ids[1], id1);
        assertEq(ids[2], id2);
    }

    function test_getUserRedeemIds_removedAfterClaim() public {
        _depositAs(user1, 10_000e6);
        vm.startPrank(user1);
        usdm.approve(address(vault), 5_000e6);
        uint256 reqId = vault.requestRedeem(5_000e6);
        vm.stopPrank();
        vm.prank(operator);
        vault.fundRedemptions(0);
        vm.warp(block.timestamp + 3 days);
        vm.prank(user1);
        vault.claimRedeem(reqId);

        uint256[] memory ids = vault.getUserRedeemIds(user1);
        assertEq(ids.length, 0);
    }

    function test_getUserRedeemIds_swapAndPop_middleElement() public {
        _depositAs(user1, 10_000e6);
        vm.startPrank(user1);
        usdm.approve(address(vault), 9_000e6);
        uint256 id0 = vault.requestRedeem(3_000e6);
        vault.requestRedeem(3_000e6); // id1 — will be claimed
        uint256 id2 = vault.requestRedeem(3_000e6);
        vm.stopPrank();
        vm.prank(operator);
        vault.fundRedemptions(0);
        vm.warp(block.timestamp + 3 days);
        vm.prank(user1);
        vault.claimRedeem(1); // claim middle element

        uint256[] memory ids = vault.getUserRedeemIds(user1);
        assertEq(ids.length, 2);
        assertEq(ids[0], id0);
        assertEq(ids[1], id2); // id2 swapped into position 1
    }

    function test_getUserRedeemIds_userIsolation() public {
        _depositAs(user1, 10_000e6);
        _depositAs(user2, 10_000e6);

        vm.startPrank(user1);
        usdm.approve(address(vault), 5_000e6);
        vault.requestRedeem(5_000e6);
        vm.stopPrank();

        vm.startPrank(user2);
        usdm.approve(address(vault), 3_000e6);
        vault.requestRedeem(3_000e6);
        vm.stopPrank();

        assertEq(vault.getUserRedeemIds(user1).length, 1);
        assertEq(vault.getUserRedeemIds(user2).length, 1);
        assertEq(vault.getUserRedeemIds(user1)[0], 0);
        assertEq(vault.getUserRedeemIds(user2)[0], 1);
    }

    // ═══════════════════════════════════════════════════════════
    //          USER REQUEST TRACKING — sUSDM UNSTAKE
    // ═══════════════════════════════════════════════════════════

    function test_getUserUnstakeIds_empty() public view {
        uint256[] memory ids = susdm.getUserUnstakeIds(user1);
        assertEq(ids.length, 0);
    }

    function test_getUserUnstakeIds_singleRequest_cooldownShares() public {
        _depositAndStake(user1, 10_000e6, 10_000e6);
        uint256 shares = susdm.balanceOf(user1);

        vm.prank(user1);
        uint256 reqId = susdm.cooldownShares(shares);

        uint256[] memory ids = susdm.getUserUnstakeIds(user1);
        assertEq(ids.length, 1);
        assertEq(ids[0], reqId);
    }

    function test_getUserUnstakeRequests_returnsDetails() public {
        _depositAndStake(user1, 10_000e6, 10_000e6);
        uint256 shares = susdm.balanceOf(user1);

        vm.prank(user1);
        susdm.cooldownShares(shares);

        sUSDM.UnstakeRequestDetail[] memory details = susdm.getUserUnstakeRequests(user1);
        assertEq(details.length, 1);
        assertEq(details[0].requestId, 0);
        assertGt(details[0].usdmAmount, 0);
        assertGt(details[0].cooldownEnd, block.timestamp);
    }

    function test_getUserUnstakeIds_cooldownAssets() public {
        _depositAndStake(user1, 10_000e6, 10_000e6);

        vm.prank(user1);
        uint256 reqId = susdm.cooldownAssets(5_000e6);

        uint256[] memory ids = susdm.getUserUnstakeIds(user1);
        assertEq(ids.length, 1);
        assertEq(ids[0], reqId);
    }

    function test_getUserUnstakeIds_multipleRequests() public {
        _depositAndStake(user1, 10_000e6, 10_000e6);

        vm.startPrank(user1);
        uint256 id0 = susdm.cooldownAssets(2_000e6);
        uint256 id1 = susdm.cooldownAssets(3_000e6);
        vm.stopPrank();

        uint256[] memory ids = susdm.getUserUnstakeIds(user1);
        assertEq(ids.length, 2);
        assertEq(ids[0], id0);
        assertEq(ids[1], id1);
    }

    function test_getUserUnstakeIds_removedAfterClaim() public {
        _depositAndStake(user1, 10_000e6, 10_000e6);
        uint256 shares = susdm.balanceOf(user1);

        vm.startPrank(user1);
        uint256 reqId = susdm.cooldownShares(shares);
        vm.warp(block.timestamp + 7 days);
        susdm.claimUnstake(reqId);
        vm.stopPrank();

        uint256[] memory ids = susdm.getUserUnstakeIds(user1);
        assertEq(ids.length, 0);
    }

    function test_getUserUnstakeIds_swapAndPop_middleElement() public {
        _depositAndStake(user1, 10_000e6, 10_000e6);

        vm.startPrank(user1);
        uint256 id0 = susdm.cooldownAssets(2_000e6);
        susdm.cooldownAssets(3_000e6); // id1 — will be claimed
        uint256 id2 = susdm.cooldownAssets(2_000e6);
        vm.warp(block.timestamp + 7 days);
        susdm.claimUnstake(1); // claim middle element
        vm.stopPrank();

        uint256[] memory ids = susdm.getUserUnstakeIds(user1);
        assertEq(ids.length, 2);
        assertEq(ids[0], id0);
        assertEq(ids[1], id2); // id2 swapped into position 1
    }

    function test_getUserUnstakeIds_userIsolation() public {
        _depositAndStake(user1, 10_000e6, 10_000e6);
        _depositAndStake(user2, 10_000e6, 10_000e6);

        vm.prank(user1);
        susdm.cooldownAssets(5_000e6);

        vm.prank(user2);
        susdm.cooldownAssets(3_000e6);

        assertEq(susdm.getUserUnstakeIds(user1).length, 1);
        assertEq(susdm.getUserUnstakeIds(user2).length, 1);
        assertEq(susdm.getUserUnstakeIds(user1)[0], 0);
        assertEq(susdm.getUserUnstakeIds(user2)[0], 1);
    }

    // F-09: sUSDM.injectYield rejects amounts exceeding cap
    function test_injectYield_exceedsMax_reverts() public {
        _depositAndStake(user1, 10_000e6, 10_000e6);
        uint256 overMax = config.maxYieldPerInjection() + 1;

        // Mint excess USDM to vault so it has enough to attempt injection
        vm.startPrank(address(vault));
        usdm.mint(address(vault), overMax);
        usdm.approve(address(susdm), overMax);
        vm.expectRevert("sUSDM: yield exceeds max");
        susdm.injectYield(overMax);
        vm.stopPrank();
    }

    // ─── HLP deposit kill switch ─────────────────────────────

    /// @notice Fresh deployments default to hlpDepositEnabled = true.
    function test_hlpDepositEnabled_defaultTrue() public view {
        assertEq(vault.hlpDepositEnabled(), true);
    }

    /// @notice Operator can flip the switch both ways.
    function test_setHlpDepositEnabled_operatorCanToggle() public {
        vm.prank(operator);
        vault.setHlpDepositEnabled(false);
        assertEq(vault.hlpDepositEnabled(), false);

        vm.prank(operator);
        vault.setHlpDepositEnabled(true);
        assertEq(vault.hlpDepositEnabled(), true);
    }

    /// @notice Only OPERATOR_ROLE can toggle; regular users cannot.
    function test_setHlpDepositEnabled_nonOperator_reverts() public {
        vm.prank(user1);
        vm.expectRevert();
        vault.setHlpDepositEnabled(false);
    }

    /// @notice When frozen, depositToHLP reverts BEFORE touching the accountant
    /// or the L1 action, so a flipped-off switch fully blocks new deposits.
    function test_depositToHLP_whenFrozen_reverts() public {
        _depositAs(user1, 1_000e6);

        vm.prank(operator);
        vault.setHlpDepositEnabled(false);

        vm.prank(operator);
        vm.expectRevert("HLP deposit frozen");
        vault.depositToHLP(500e6);
    }

    /// @notice withdrawFromHLP is NOT affected by the kill switch — deposited
    /// funds must always be retrievable, even after the operator froze new
    /// deposits in preparation for withdraw.
    function test_withdrawFromHLP_worksWhileFrozen() public {
        _depositAs(user1, 1_000e6);

        vm.etch(HyperCoreConstants.CORE_WRITER, address(new MockCoreWriter()).code);

        // Deposit first while enabled
        vm.prank(operator);
        vault.depositToHLP(400e6);

        // Freeze new deposits
        vm.prank(operator);
        vault.setHlpDepositEnabled(false);

        // Simulate HLP equity on the mock precompile
        bytes memory vaultEquityKey = abi.encode(address(vault), HyperCoreConstants.HLP_VAULT);
        bytes memory vaultEquityResp = abi.encode(uint64(400e6), uint64(0));
        MockPrecompile(payable(HyperCoreConstants.PRECOMPILE_VAULT_EQUITY)).setResponse(
            vaultEquityKey, vaultEquityResp
        );

        // Withdraw still succeeds (mark-to-market: no principal bookkeeping)
        vm.prank(operator);
        vault.withdrawFromHLP(400e6);
    }

    /// @notice When enabled (default), depositToHLP works normally.
    function test_depositToHLP_whenEnabled_succeeds() public {
        _depositAs(user1, 1_000e6);
        vm.etch(HyperCoreConstants.CORE_WRITER, address(new MockCoreWriter()).code);

        vm.prank(operator);
        vault.depositToHLP(500e6);
    }

    // ─── Accountant is mandatory for yield operations ────────────────────────────
    //
    // distributeYield and bridgeYieldFromL1 require accountant to guard peg.
    // deposit/requestRedeem/claimRedeem no longer require accountant
    // (they use redeemEscrow for redemption state).

    // Note: `test_deposit_worksWithoutAccountant` was removed. It used
    // `setAccountant(address(0))` to simulate the pre-wired state, but
    // setAccountant now rejects the zero address (no way to un-wire once wired).
    // Fresh-deploy behavior is still validated by the deployment scripts + the
    // explicit zero-address checks on all wiring setters.

    function test_requestRedeem_withoutRedeemEscrow_reverts() public {
        // requestRedeem requires redeemEscrow; setRedeemEscrow blocks zero address.
        // Verify that attempting to set zero redeemEscrow is rejected.
        vm.prank(admin);
        vm.expectRevert("zero address");
        vault.setRedeemEscrow(address(0));
    }

    // Note: `test_unwired_reverts` was removed. It used `setAccountant(address(0))`
    // to simulate the pre-wired state, but setAccountant now rejects zero (wiring
    // is monotonic forward). The requireWired modifier's reverting behavior is
    // implicitly covered by every positive-path test that exercises wired
    // functions — if the modifier silently permitted unwired calls, those tests
    // would fail too.

    function test_depositToHLP_requiresHlpDepositEnabled() public {
        // depositToHLP no longer requires accountant; it requires hlpDepositEnabled
        vm.prank(operator);
        vault.setHlpDepositEnabled(false);

        vm.prank(operator);
        vm.expectRevert("HLP deposit frozen");
        vault.depositToHLP(100e6);
    }

    function test_withdrawFromHLP_exceedsEquity_reverts() public {
        // withdrawFromHLP no longer requires accountant; exceeding equity reverts
        // Set equity to 0 via mock precompile (default returns 0)
        vm.prank(operator);
        vm.expectRevert("exceeds hlp equity");
        vault.withdrawFromHLP(100e6);
    }

    /// @notice HLP enforces a ~4-day lock after deposit. Precompile 0x802 reports
    ///         `lockedUntil` as a ms epoch. Without the guard, withdraw attempts
    ///         during the lock window are silently dropped on L1 — operator
    ///         thinks funds returned, downstream accounting diverges.
    function test_withdrawFromHLP_whileLocked_reverts() public {
        _depositAs(user1, 1_000e6);
        vm.etch(HyperCoreConstants.CORE_WRITER, address(new MockCoreWriter()).code);

        vm.prank(operator);
        vault.depositToHLP(400e6);

        // Mock: 400 USDC equity, locked 1 hour into the future (ms epoch).
        uint64 lockedUntilMs = uint64(block.timestamp * 1000 + 1 hours * 1000);
        MockPrecompile(payable(HyperCoreConstants.PRECOMPILE_VAULT_EQUITY)).setResponse(
            abi.encode(address(vault), HyperCoreConstants.HLP_VAULT),
            abi.encode(uint64(400e6), lockedUntilMs)
        );

        vm.prank(operator);
        vm.expectRevert("HLP still locked");
        vault.withdrawFromHLP(400e6);
    }

    /// @notice Once the lock expires, withdraw succeeds. `lockedUntil=0` (never
    ///         locked) also succeeds — covered in `test_withdrawFromHLP_worksWhileFrozen`.
    function test_withdrawFromHLP_afterLockExpires_succeeds() public {
        _depositAs(user1, 1_000e6);
        vm.etch(HyperCoreConstants.CORE_WRITER, address(new MockCoreWriter()).code);

        vm.prank(operator);
        vault.depositToHLP(400e6);

        // Mock: lock ends 1 second ago (in ms).
        uint64 lockedUntilMs = uint64(block.timestamp * 1000 - 1000);
        MockPrecompile(payable(HyperCoreConstants.PRECOMPILE_VAULT_EQUITY)).setResponse(
            abi.encode(address(vault), HyperCoreConstants.HLP_VAULT),
            abi.encode(uint64(400e6), lockedUntilMs)
        );

        vm.prank(operator);
        vault.withdrawFromHLP(400e6);
    }

    // ─── BLP (Borrow/Lend Pool) ──────────────────────────────

    function test_supplyToBlp_onlyOperator() public {
        vm.etch(HyperCoreConstants.CORE_WRITER, address(new MockCoreWriter()).code);
        vm.prank(user1);
        vm.expectRevert();
        vault.supplyToBlp(0, 1e8);

        vm.prank(operator);
        vault.supplyToBlp(0, 1e8);
    }

    function test_supplyToBlp_zeroAmount_reverts() public {
        vm.etch(HyperCoreConstants.CORE_WRITER, address(new MockCoreWriter()).code);
        vm.prank(operator);
        vm.expectRevert("zero amount");
        vault.supplyToBlp(0, 0);
    }

    function test_supplyToBlp_emitsEvent() public {
        vm.etch(HyperCoreConstants.CORE_WRITER, address(new MockCoreWriter()).code);
        // Whitelist HYPE spot→perp so the Accountant-notify path resolves cleanly.
        vm.prank(admin);
        config.addTradeableAsset(MonetrixConfig.TradeableAsset({perpIndex: 4, spotIndex: 1105, spotPairAssetId: 11105}));
        vm.expectEmit(true, false, false, true);
        emit MonetrixVault.BlpSupplied(1105, 5e8);
        vm.prank(operator);
        vault.supplyToBlp(1105, 5e8);
    }

    function test_supplyToBlp_whenPaused_reverts() public {
        vm.prank(admin);
        vault.pause();
        vm.prank(operator);
        vm.expectRevert();
        vault.supplyToBlp(0, 1e8);
    }

    function test_withdrawFromBlp_onlyOperator() public {
        vm.etch(HyperCoreConstants.CORE_WRITER, address(new MockCoreWriter()).code);
        vm.prank(user1);
        vm.expectRevert();
        vault.withdrawFromBlp(0, 1e8);

        vm.prank(operator);
        vault.withdrawFromBlp(0, 1e8);
    }

    /// @notice withdrawFromBlp allows amount=0 per HL's "0 = max" convention.
    function test_withdrawFromBlp_zeroAmount_allowed() public {
        vm.etch(HyperCoreConstants.CORE_WRITER, address(new MockCoreWriter()).code);
        vm.expectEmit(true, false, false, true);
        emit MonetrixVault.BlpWithdrawn(0, 0);
        vm.prank(operator);
        vault.withdrawFromBlp(0, 0);
    }

    function test_withdrawFromBlp_whenPaused_reverts() public {
        vm.prank(admin);
        vault.pause();
        vm.prank(operator);
        vm.expectRevert();
        vault.withdrawFromBlp(0, 1e8);
    }

    /// Wire-format assertion: supplyToBlp must emit action bytes shaped as
    /// version(1) | kind(15) | abi.encode(uint8 op=0, uint64 token, uint64 amount).
    function test_supplyToBlp_wireFormat() public {
        vm.etch(HyperCoreConstants.CORE_WRITER, address(new CapturingCoreWriter()).code);
        vm.prank(admin);
        config.addTradeableAsset(MonetrixConfig.TradeableAsset({perpIndex: 4, spotIndex: 1105, spotPairAssetId: 11105}));

        vm.prank(operator);
        vault.supplyToBlp(1105, 500_000_000);

        bytes memory action = CapturingCoreWriter(HyperCoreConstants.CORE_WRITER).lastAction();
        assertEq(action.length, 4 + 96, "action = 4-byte header + 96-byte abi-encoded tuple");
        assertEq(uint8(action[0]), 1, "version");
        assertEq(uint8(action[1]) << 16 | uint8(action[2]) << 8 | uint8(action[3]), 15, "kind=BORROW_LEND");

        bytes memory payload = new bytes(96);
        for (uint256 i = 0; i < 96; i++) payload[i] = action[4 + i];
        (uint8 op, uint64 token, uint64 amount) = abi.decode(payload, (uint8, uint64, uint64));
        assertEq(op, 0, "op=0 supply");
        assertEq(token, 1105, "token=HYPE");
        assertEq(amount, 500_000_000, "amount preserved");
    }

    /// Wire-format for withdrawFromBlp: op=1, amount=0 must round-trip cleanly.
    function test_withdrawFromBlp_wireFormat_maxAmount() public {
        vm.etch(HyperCoreConstants.CORE_WRITER, address(new CapturingCoreWriter()).code);

        vm.prank(operator);
        vault.withdrawFromBlp(0, 0);

        bytes memory action = CapturingCoreWriter(HyperCoreConstants.CORE_WRITER).lastAction();
        assertEq(uint8(action[0]), 1);
        assertEq(uint8(action[1]) << 16 | uint8(action[2]) << 8 | uint8(action[3]), 15);

        bytes memory payload = new bytes(96);
        for (uint256 i = 0; i < 96; i++) payload[i] = action[4 + i];
        (uint8 op, uint64 token, uint64 amount) = abi.decode(payload, (uint8, uint64, uint64));
        assertEq(op, 1, "op=1 withdraw");
        assertEq(token, 0, "token=USDC");
        assertEq(amount, 0, "amount=0 preserved for HL max semantic");
    }

    // ─── Token whitelist ─────────────────────────────────────

    function _whitelistEth() internal {
        vm.prank(admin);
        config.addTradeableAsset(MonetrixConfig.TradeableAsset({perpIndex: 4, spotIndex: 221, spotPairAssetId: 10151}));
    }

    function test_addTradeableAsset_admin() public {
        _whitelistEth();
        assertEq(config.tradeableAssetsLength(), 1);
        assertEq(config.isPerpWhitelisted(4), true);
        assertEq(config.isSpotWhitelisted(221), true);              // token_index
        assertEq(config.isSpotPairAssetIdWhitelisted(10151), true); // pair_asset_id
        assertEq(config.perpToSpot(4), 221);
        assertEq(config.spotToPerp(221), 4);
        assertEq(config.perpToSpotPairAssetId(4), 10151);
    }

    function test_addTradeableAssets_batch() public {
        MonetrixConfig.TradeableAsset[] memory assets = new MonetrixConfig.TradeableAsset[](2);
        assets[0] = MonetrixConfig.TradeableAsset({perpIndex: 4, spotIndex: 221, spotPairAssetId: 10151}); // UETH
        assets[1] = MonetrixConfig.TradeableAsset({perpIndex: 0, spotIndex: 197, spotPairAssetId: 10142}); // UBTC
        vm.prank(admin);
        config.addTradeableAssets(assets);
        assertEq(config.tradeableAssetsLength(), 2);
        assertEq(config.isPerpWhitelisted(4), true);
        assertEq(config.isPerpWhitelisted(0), true);
    }

    function test_addTradeableAsset_nonAdmin_reverts() public {
        vm.prank(user1);
        vm.expectRevert();
        config.addTradeableAsset(MonetrixConfig.TradeableAsset({perpIndex: 4, spotIndex: 221, spotPairAssetId: 10151}));
    }

    function test_addTradeableAsset_duplicatePerp_reverts() public {
        _whitelistEth();
        vm.prank(admin);
        vm.expectRevert("Config: perp already listed");
        config.addTradeableAsset(MonetrixConfig.TradeableAsset({perpIndex: 4, spotIndex: 222, spotPairAssetId: 10152}));
    }

    function test_removeTradeableAsset_cleansAll() public {
        _whitelistEth();
        assertEq(config.isPerpWhitelisted(4), true);
        assertTrue(config.isSpotWhitelisted(221));
        assertTrue(config.isSpotPairAssetIdWhitelisted(10151));

        vm.prank(admin);
        config.removeTradeableAsset(4);

        assertFalse(config.isPerpWhitelisted(4));
        assertFalse(config.isSpotWhitelisted(221));
        assertFalse(config.isSpotPairAssetIdWhitelisted(10151));
        assertEq(config.perpToSpotPairAssetId(4), 0);
        assertEq(config.tradeableAssetsLength(), 0);
    }

    function test_removeTradeableAsset_notListed_reverts() public {
        vm.prank(admin);
        vm.expectRevert("Config: perp not listed");
        config.removeTradeableAsset(99);
    }

    // ─── BTC (perpIndex=0) regression ────────────────────────
    // M-02 fix: `isSpotWhitelisted` is the registration sentinel, not
    // `spotToPerp(spot) != 0`. BTC-PERP sits at index 0, which the old code
    // treated as "unregistered" and silently rejected.

    function test_supplyToBlp_btc_doesNotRevert() public {
        vm.etch(HyperCoreConstants.CORE_WRITER, address(new MockCoreWriter()).code);
        vm.prank(admin);
        config.addTradeableAsset(
            MonetrixConfig.TradeableAsset({perpIndex: 0, spotIndex: 197, spotPairAssetId: 10142})
        );

        vm.expectEmit(true, false, false, true);
        emit MonetrixVault.BlpSupplied(197, 5e8);
        vm.prank(operator);
        vault.supplyToBlp(197, 5e8);

        (uint64 spotToken, uint32 perpIndex) = accountant.vaultSupplied(0);
        assertEq(spotToken, 197, "token_index registered (not pair_asset_id)");
        assertEq(perpIndex, 0, "perp=0 preserved (BTC)");
    }

    // ─── token_index ≠ spotPairAssetId regression (HYPE-style) ────────

    function _whitelistHype() internal {
        // HYPE mainnet: token_index=150, spot pair_asset_id=10107, perp_index=159
        vm.prank(admin);
        config.addTradeableAsset(
            MonetrixConfig.TradeableAsset({perpIndex: 159, spotIndex: 150, spotPairAssetId: 10107})
        );
    }

    function test_executeHedge_splitIndexes_mismatchedSpotAsset_reverts() public {
        _whitelistHype();
        vm.etch(HyperCoreConstants.CORE_WRITER, address(new MockCoreWriter()).code);

        ActionEncoder.HedgeParams memory params = ActionEncoder.HedgeParams({
            spotAsset: 150,   // ← WRONG: passed token_index instead of pair_asset_id
            perpAsset: 159,
            size: 1e8, spotPrice: 50e8, perpPrice: 50e8, cloid: 0,
            tif: uint8(3),
            spotReduceOnly: false,
            perpReduceOnly: false
        });

        vm.prank(operator);
        vm.expectRevert("spot/perp mismatch");
        vault.executeHedge(1, params);
    }

    function test_executeHedge_splitIndexes_correctPairAssetId_succeeds() public {
        _whitelistHype();
        vm.etch(HyperCoreConstants.CORE_WRITER, address(new MockCoreWriter()).code);
        vm.prank(admin);
        vault.setPmEnabled(true);

        ActionEncoder.HedgeParams memory params = ActionEncoder.HedgeParams({
            spotAsset: 10107,  // ← correct: pair_asset_id (10000 + 107)
            perpAsset: 159,
            size: 1e8, spotPrice: 50e8, perpPrice: 50e8, cloid: 0,
            tif: uint8(3),
            spotReduceOnly: false,
            perpReduceOnly: false
        });

        vm.prank(operator);
        vault.executeHedge(1, params);

        // Critical: notify must store TOKEN_INDEX (150), not pair_asset_id (10107)
        (uint64 spotToken, uint32 perpIndex) = accountant.vaultSupplied(0);
        assertEq(spotToken, 150, "notify stored token_index from Config, not params.spotAsset");
        assertEq(perpIndex, 159);
    }

    function test_removeTradeableAsset_thenReadd_btc_works() public {
        vm.startPrank(admin);
        config.addTradeableAsset(
            MonetrixConfig.TradeableAsset({perpIndex: 0, spotIndex: 197, spotPairAssetId: 10142})
        );
        assertTrue(config.isPerpWhitelisted(0));
        assertTrue(config.isSpotWhitelisted(197));
        assertTrue(config.isSpotPairAssetIdWhitelisted(10142));

        config.removeTradeableAsset(0);
        assertFalse(config.isPerpWhitelisted(0), "perp cleared");
        assertFalse(config.isSpotWhitelisted(197), "spot token cleared");
        assertFalse(config.isSpotPairAssetIdWhitelisted(10142), "pair cleared");
        assertEq(config.spotToPerp(197), 0);
        assertEq(config.perpToSpot(0), 0);
        assertEq(config.perpToSpotPairAssetId(0), 0);
        assertEq(config.tradeableAssetsLength(), 0);

        config.addTradeableAsset(
            MonetrixConfig.TradeableAsset({perpIndex: 0, spotIndex: 197, spotPairAssetId: 10142})
        );
        assertTrue(config.isPerpWhitelisted(0), "re-add restores perp");
        assertTrue(config.isSpotWhitelisted(197), "re-add restores spot token");
        assertTrue(config.isSpotPairAssetIdWhitelisted(10142), "re-add restores pair");
        assertEq(config.tradeableAssetsLength(), 1);
        vm.stopPrank();
    }

    function test_executeHedge_notWhitelisted_reverts() public {
        vm.etch(HyperCoreConstants.CORE_WRITER, address(new MockCoreWriter()).code);

        ActionEncoder.HedgeParams memory params = ActionEncoder.HedgeParams({
            spotAsset: 10151,
            perpAsset: 4,
            size: 1e8,
            spotPrice: 3000e8,
            perpPrice: 3000e8,
            cloid: 0,
            tif: uint8(3),
            spotReduceOnly: false,
            perpReduceOnly: false
        });

        vm.prank(operator);
        vm.expectRevert("perp not whitelisted");
        vault.executeHedge(1, params);
    }

    function test_executeHedge_whitelisted_succeeds() public {
        _whitelistEth();
        vm.etch(HyperCoreConstants.CORE_WRITER, address(new MockCoreWriter()).code);

        ActionEncoder.HedgeParams memory params = ActionEncoder.HedgeParams({
            spotAsset: 10151,
            perpAsset: 4,
            size: 1e8,
            spotPrice: 3000e8,
            perpPrice: 3000e8,
            cloid: 0,
            tif: uint8(3),
            spotReduceOnly: false,
            perpReduceOnly: false
        });

        vm.prank(operator);
        vault.executeHedge(1, params);
        // No revert = success
    }

    function test_executeHedge_mismatchedPair_reverts() public {
        _whitelistEth();
        vm.etch(HyperCoreConstants.CORE_WRITER, address(new MockCoreWriter()).code);

        // Correct perp but wrong spot
        ActionEncoder.HedgeParams memory params = ActionEncoder.HedgeParams({
            spotAsset: 99999,
            perpAsset: 4,
            size: 1e8,
            spotPrice: 3000e8,
            perpPrice: 3000e8,
            cloid: 0,
            tif: uint8(3),
            spotReduceOnly: false,
            perpReduceOnly: false
        });

        vm.prank(operator);
        vm.expectRevert("spot/perp mismatch");
        vault.executeHedge(1, params);
    }

    function test_closeHedge_notWhitelisted_reverts() public {
        vm.etch(HyperCoreConstants.CORE_WRITER, address(new MockCoreWriter()).code);

        ActionEncoder.CloseParams memory params = ActionEncoder.CloseParams({
            positionId: 1,
            spotAsset: 10151,
            perpAsset: 4,
            size: 1e8,
            spotPrice: 3000e8,
            perpPrice: 3000e8,
            cloid: 0,
            tif: uint8(3),
            spotReduceOnly: false,
            perpReduceOnly: true
        });

        vm.prank(operator);
        vm.expectRevert("perp not whitelisted");
        vault.closeHedge(params);
    }

    function test_repairHedge_perpLeg_whitelisted() public {
        _whitelistEth();
        vm.etch(HyperCoreConstants.CORE_WRITER, address(new MockCoreWriter()).code);

        ActionEncoder.RepairParams memory params = ActionEncoder.RepairParams({
            asset: 4,
            isPerp: true,
            isBuy: true,
            reduceOnly: true,
            size: 1e8,
            price: 3000e8,
            residualBps: 100,
            cloid: 0,
            tif: uint8(3)
        });

        vm.prank(operator);
        vault.repairHedge(1, params);
    }

    function test_repairHedge_spotLeg_whitelisted() public {
        _whitelistEth();
        vm.etch(HyperCoreConstants.CORE_WRITER, address(new MockCoreWriter()).code);

        ActionEncoder.RepairParams memory params = ActionEncoder.RepairParams({
            asset: 10151,
            isPerp: false,
            isBuy: false,
            reduceOnly: true,
            size: 1e8,
            price: 3000e8,
            residualBps: 100,
            cloid: 0,
            tif: uint8(3)
        });

        vm.prank(operator);
        vault.repairHedge(1, params);
    }

    function test_repairHedge_notWhitelisted_reverts() public {
        vm.etch(HyperCoreConstants.CORE_WRITER, address(new MockCoreWriter()).code);

        ActionEncoder.RepairParams memory params = ActionEncoder.RepairParams({
            asset: 4,
            isPerp: true,
            isBuy: true,
            reduceOnly: true,
            size: 1e8,
            price: 3000e8,
            residualBps: 100,
            cloid: 0,
            tif: uint8(3)
        });

        vm.prank(operator);
        vm.expectRevert("perp not whitelisted");
        vault.repairHedge(1, params);
    }

    // ═══════════════════════════════════════════════════════════
    //    WIRE-FORMAT: tif + reduceOnly propagation
    // ═══════════════════════════════════════════════════════════

    /// @dev Decode a LIMIT_ORDER action emitted by ActionEncoder:
    ///      version(1) | kind=1(3) | abi.encode(asset, isBuy, limitPx, size, reduceOnly, tif, cloid)
    function _decodeLimitOrder(bytes memory action)
        internal
        pure
        returns (uint32 asset, bool isBuy, uint64 limitPx, uint64 size, bool reduceOnly, uint8 tif, uint128 cloid)
    {
        require(action.length >= 4, "header");
        require(uint8(action[0]) == 1, "version=1");
        uint24 kind = uint24(uint8(action[1])) << 16 | uint24(uint8(action[2])) << 8 | uint24(uint8(action[3]));
        require(kind == 1, "kind=LIMIT_ORDER");
        bytes memory payload = new bytes(action.length - 4);
        for (uint256 i = 0; i < payload.length; i++) payload[i] = action[4 + i];
        (asset, isBuy, limitPx, size, reduceOnly, tif, cloid) =
            abi.decode(payload, (uint32, bool, uint64, uint64, bool, uint8, uint128));
    }

    function test_executeHedge_forwardsTifAndReduceOnly() public {
        _whitelistEth();
        vm.etch(HyperCoreConstants.CORE_WRITER, address(new CapturingCoreWriter()).code);

        ActionEncoder.HedgeParams memory p = ActionEncoder.HedgeParams({
            spotAsset: 10151,
            perpAsset: 4,
            size: 1e8,
            spotPrice: 3000e8,
            perpPrice: 3000e8,
            cloid: 0,
            tif: uint8(2),
            spotReduceOnly: true,    // non-default, must propagate
            perpReduceOnly: false
        });
        vm.prank(operator);
        vault.executeHedge(1, p);

        CapturingCoreWriter w = CapturingCoreWriter(HyperCoreConstants.CORE_WRITER);
        assertEq(w.actionsLength(), 2, "buySpot + shortPerp");

        (uint32 a0, bool isBuy0, , , bool ro0, uint8 tif0, ) = _decodeLimitOrder(w.actions(0));
        assertEq(a0, 10151, "spot leg asset");
        assertTrue(isBuy0, "spot leg is BUY");
        assertTrue(ro0, "spot leg forwards spotReduceOnly=true");
        assertEq(tif0, uint8(2), "spot leg tif forwarded");

        (uint32 a1, bool isBuy1, , , bool ro1, uint8 tif1, ) = _decodeLimitOrder(w.actions(1));
        assertEq(a1, 4, "perp leg asset");
        assertTrue(!isBuy1, "perp leg is SELL (short)");
        assertTrue(!ro1, "perp leg forwards perpReduceOnly=false");
        assertEq(tif1, uint8(2), "perp leg tif forwarded");
    }

    function test_closeHedge_forwardsTifAndAsymmetricReduceOnly() public {
        _whitelistEth();
        vm.etch(HyperCoreConstants.CORE_WRITER, address(new CapturingCoreWriter()).code);

        // Asymmetric: spot=false (HL silently drops spot+reduceOnly=true on some paths),
        //             perp=true (canonical close-without-flip semantics).
        ActionEncoder.CloseParams memory p = ActionEncoder.CloseParams({
            positionId: 42,
            spotAsset: 10151,
            perpAsset: 4,
            size: 1e8,
            spotPrice: 2900e8,
            perpPrice: 3100e8,
            cloid: 0,
            tif: uint8(1),
            spotReduceOnly: false,
            perpReduceOnly: true
        });
        vm.prank(operator);
        vault.closeHedge(p);

        CapturingCoreWriter w = CapturingCoreWriter(HyperCoreConstants.CORE_WRITER);
        assertEq(w.actionsLength(), 2);

        (uint32 a0, bool isBuy0, , , bool ro0, uint8 tif0, ) = _decodeLimitOrder(w.actions(0));
        assertEq(a0, 10151);
        assertTrue(!isBuy0, "spot close is SELL");
        assertTrue(!ro0, "spot leg honors spotReduceOnly=false");
        assertEq(tif0, uint8(1));

        (uint32 a1, bool isBuy1, , , bool ro1, uint8 tif1, ) = _decodeLimitOrder(w.actions(1));
        assertEq(a1, 4);
        assertTrue(isBuy1, "perp close is BUY");
        assertTrue(ro1, "perp leg honors perpReduceOnly=true");
        assertEq(tif1, uint8(1));
    }

    function test_repairHedge_forwardsTif() public {
        _whitelistEth();
        vm.etch(HyperCoreConstants.CORE_WRITER, address(new CapturingCoreWriter()).code);

        ActionEncoder.RepairParams memory p = ActionEncoder.RepairParams({
            asset: 4,
            isPerp: true,
            isBuy: true,
            reduceOnly: false,
            size: 1e8,
            price: 3000e8,
            residualBps: 0,
            cloid: 0,
            tif: uint8(2)
        });
        vm.prank(operator);
        vault.repairHedge(7, p);

        bytes memory action = CapturingCoreWriter(HyperCoreConstants.CORE_WRITER).lastAction();
        (, , , , bool ro, uint8 tif, ) = _decodeLimitOrder(action);
        assertTrue(!ro, "repair forwards reduceOnly=false");
        assertEq(tif, uint8(2), "repair forwards TIF_GTC");
    }

    // ═══════════════════════════════════════════════════════════
    //    SETTLE GATE INTEGRATION TESTS (V3 refactor)
    // ═══════════════════════════════════════════════════════════

    /// @dev Crank annual yield cap to the hard limit so tests can move
    ///      realistic amounts without hitting the APR floor.
    function _setAnnualCapToMax() internal {
        uint256 cap = config.MAX_ANNUAL_YIELD_BPS_CAP();
        vm.prank(admin);
        config.setMaxAnnualYieldBps(cap);
    }

    /// @notice Vault.settle reverts when EVM USDC is insufficient (all-or-nothing).
    function test_vaultSettle_insufficientEvmUsdc_reverts() public {
        vm.etch(HyperCoreConstants.CORE_WRITER, address(new MockCoreWriter()).code);
        // Deposit 100k → auto-bridges above 50k threshold → Vault EVM drained
        _depositAs(user1, 100_000e6);
        vm.warp(block.timestamp + 6 hours);
        vm.prank(operator);
        vault.keeperBridge(MonetrixVault.BridgeTarget.Vault);
        assertEq(usdc.balanceOf(address(vault)), 0, "vault drained");

        _primeDistributable(500e6);     // surplus=500 on L1
        _setAnnualCapToMax();
        vm.warp(block.timestamp + 30 days);   // loose APR cap

        vm.prank(admin);
        vm.expectRevert("insufficient EVM USDC");
        vault.settle(100e6);
    }

    /// @notice Vault.settle happy path: surplus generated + Vault has EVM USDC
    ///         → YE gets the full proposedYield and totalSettledYield increments.
    function test_vaultSettle_happyPath_routesToYE() public {
        _depositAs(user1, 10_000e6);       // Vault=10k, supply=10k (no auto-bridge)
        _primeDistributable(50e6);         // L1 surplus +50
        _setAnnualCapToMax();
        vm.warp(block.timestamp + 30 days); // loose APR cap

        uint256 yeBefore = usdc.balanceOf(address(yieldEscrow));
        uint256 vaultBefore = usdc.balanceOf(address(vault));

        vm.prank(admin);
        vault.settle(10e6);

        assertEq(usdc.balanceOf(address(yieldEscrow)), yeBefore + 10e6, "YE received");
        assertEq(usdc.balanceOf(address(vault)), vaultBefore - 10e6, "Vault debited");
        assertEq(accountant.totalSettledYield(), 10e6, "cumulative tracked");
        assertEq(accountant.lastSettlementTime(), block.timestamp, "ts updated");
    }

    /// @notice F2-regression: `bridgeRetentionAmount` no longer blocks settle.
    ///         Vault balance can sit at (shortfall + retention) and settle still
    ///         routes up to `vaultBal − shortfall`.
    function test_vaultSettle_atRetentionFloor_stillWorks() public {
        _depositAs(user1, 10_000e6);  // Vault=10k

        // Set retention to 9_990 → if the old `reserved = shortfall + retention`
        // were still in place, available would be 10, and settle(100) would revert.
        vm.prank(admin);
        vault.setBridgeRetentionAmount(9_990e6);

        _primeDistributable(200e6);       // surplus=200
        _setAnnualCapToMax();
        vm.warp(block.timestamp + 30 days);

        // With the F2 fix (reserved = shortfall only), available = 10_000 and
        // settle(100) succeeds even though Vault ends up below the retention floor.
        vm.prank(admin);
        vault.settle(100e6);

        assertEq(usdc.balanceOf(address(yieldEscrow)), 100e6);
        assertEq(usdc.balanceOf(address(vault)), 10_000e6 - 100e6);
    }

    /// @notice F1-regression: settle during a pending redemption window is
    ///         blocked by distributableSurplus. Without the gate, the pending
    ///         redemption USDC would be drained as phantom yield, and claim
    ///         would leave the protocol under-collateralized.
    function test_F1_redemptionWindow_blocksPhantomYieldSettle() public {
        _depositAs(user1, 1_000e6);        // Vault=1k, supply=1k
        _primeDistributable(0);            // initialize settlement (no L1 bump)
        _setAnnualCapToMax();

        // Request redeem 900 → usdm.burn(900), supply=100, shortfall=900
        // Before fix: surplus = 1000 − 100 = 900 (virtual). After fix:
        //   distributable = 900 − 900 = 0 → settle must revert.
        vm.startPrank(user1);
        usdm.approve(address(vault), 900e6);
        uint256 reqId = vault.requestRedeem(900e6);
        vm.stopPrank();

        vm.warp(block.timestamp + 30 days);

        // Keeper tries to grab the phantom 100 → distributable gate blocks.
        vm.prank(admin);
        vm.expectRevert("Accountant: no distributable surplus");
        vault.settle(100e6);

        // Complete the redemption flow; protocol stays solvent.
        vm.prank(operator);
        vault.fundRedemptions(0);
        vm.warp(block.timestamp + 3 days);
        vm.prank(user1);
        vault.claimRedeem(reqId);

        // After claim: Vault=100, supply=100, backing=100 → surplus=0
        assertEq(usdc.balanceOf(address(vault)), 100e6, "residual principal");
        assertEq(usdm.totalSupply(), 100e6, "supply consistent");
        assertGe(accountant.surplus(), int256(0), "no peg violation after F1 gate");
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/tokens/USDM.sol";
import "../src/tokens/sUSDM.sol";
import {sUSDMEscrow} from "../src/tokens/sUSDMEscrow.sol";
import "../src/core/MonetrixConfig.sol";
import "../src/core/MonetrixVault.sol";
import "../src/core/InsuranceFund.sol";

import "../src/core/MonetrixAccountant.sol";
import "../src/core/RedeemEscrow.sol";
import "../src/core/YieldEscrow.sol";
import "../src/governance/MonetrixAccessController.sol";

/// @title MonetrixForkTest - Full integration tests against forked HyperEVM Testnet
/// @dev Run: forge test --fork-url https://hyperliquid-testnet.g.alchemy.com/v2/<KEY> --match-path test/MonetrixFork.t.sol
contract MonetrixForkTest is Test {
    // IMPORTANT: Use inner USDC proxy (0x2B3370...), NOT outer (0x96604e...).
    // CoreDepositWallet.token() returns 0x2B3370... — they have separate storage.
    address constant USDC_ADDR = 0x2B3370eE501B4a559b57D449569354196457D8Ab;
    address constant CORE_DEPOSIT_WALLET = 0x0B80659a4076E9E93C7DbE0f10675A16a3e5C206;

    IERC20 usdc;
    USDM usdm;
    sUSDM susdm;
    sUSDMEscrow unstakeEscrow;
    MonetrixConfig config;
    MonetrixVault vault;
    InsuranceFund insurance;

    MonetrixAccountant accountant;
    RedeemEscrow redeemEscrow;
    YieldEscrow yieldEscrow;
    MonetrixAccessController acl;

    address admin = makeAddr("admin");
    address user1 = makeAddr("user1");
    address user2 = makeAddr("user2");
    address foundation = makeAddr("foundation");
    address operator = makeAddr("operator");

    function setUp() public {
        usdc = IERC20(USDC_ADDR);
        vm.startPrank(admin);

        acl = MonetrixAccessController(
            address(
                new ERC1967Proxy(
                    address(new MonetrixAccessController()),
                    abi.encodeCall(MonetrixAccessController.initialize, (admin))
                )
            )
        );

        usdm = USDM(address(new ERC1967Proxy(address(new USDM()), abi.encodeCall(USDM.initialize, (address(acl))))));
        insurance = InsuranceFund(
            address(
                new ERC1967Proxy(
                    address(new InsuranceFund()),
                    abi.encodeCall(InsuranceFund.initialize, (USDC_ADDR, address(acl)))
                )
            )
        );
        config = MonetrixConfig(
            address(
                new ERC1967Proxy(
                    address(new MonetrixConfig()),
                    abi.encodeCall(MonetrixConfig.initialize, (address(insurance), foundation, address(acl)))
                )
            )
        );
        susdm = sUSDM(
            address(
                new ERC1967Proxy(
                    address(new sUSDM()),
                    abi.encodeCall(sUSDM.initialize, (address(usdm), address(config), address(acl)))
                )
            )
        );
        vault = MonetrixVault(
            address(
                new ERC1967Proxy(
                    address(new MonetrixVault()),
                    abi.encodeCall(
                        MonetrixVault.initialize,
                        (
                            USDC_ADDR,
                            address(usdm),
                            address(susdm),
                            address(config),
                            CORE_DEPOSIT_WALLET,
                            address(acl)
                        )
                    )
                )
            )
        );
        accountant = MonetrixAccountant(
            address(
                new ERC1967Proxy(
                    address(new MonetrixAccountant()),
                    abi.encodeCall(
                        MonetrixAccountant.initialize,
                        (address(vault), USDC_ADDR, address(usdm), address(acl))
                    )
                )
            )
        );

        // Grant roles on the ACL.
        acl.grantRole(acl.GOVERNOR(), admin);
        acl.grantRole(acl.GUARDIAN(), admin);
        acl.grantRole(acl.OPERATOR(), admin);
        acl.grantRole(acl.OPERATOR(), operator);
        acl.grantRole(acl.UPGRADER(), admin);

        // Direct-vault binding replaces former VAULT_CALLER grant.
        usdm.setVault(address(vault));
        susdm.setVault(address(vault));

        // Wire the physically-isolated unstake escrow for sUSDM
        unstakeEscrow = new sUSDMEscrow(address(usdm), address(susdm));
        susdm.setEscrow(address(unstakeEscrow));

        redeemEscrow = RedeemEscrow(
            address(
                new ERC1967Proxy(
                    address(new RedeemEscrow()),
                    abi.encodeCall(RedeemEscrow.initialize, (USDC_ADDR, address(vault), address(acl)))
                )
            )
        );
        yieldEscrow = YieldEscrow(
            address(
                new ERC1967Proxy(
                    address(new YieldEscrow()),
                    abi.encodeCall(YieldEscrow.initialize, (USDC_ADDR, address(vault), address(acl)))
                )
            )
        );

        vault.setAccountant(address(accountant));
        vault.setRedeemEscrow(address(redeemEscrow));
        vault.setYieldEscrow(address(yieldEscrow));
        accountant.setConfig(address(config));
        accountant.initializeSettlement();
        vm.stopPrank();
        deal(USDC_ADDR, user1, 1_000_000e6);
        deal(USDC_ADDR, user2, 1_000_000e6);
    }

    function _depositAs(address user, uint256 amount) internal {
        vm.startPrank(user);
        usdc.approve(address(vault), amount);
        vault.deposit(amount);
        vm.stopPrank();
    }

    function _depositAndStake(address user, uint256 dAmt, uint256 sAmt) internal {
        _depositAs(user, dAmt);
        vm.startPrank(user);
        usdm.approve(address(susdm), sAmt);
        susdm.deposit(sAmt, user);
        vm.stopPrank();
    }

    // ── DEPOSIT ──
    function test_deposit_mintsUSDM() public {
        _depositAs(user1, 10_000e6);
        assertEq(usdm.balanceOf(user1), 10_000e6);
        assertEq(usdc.balanceOf(address(vault)), 10_000e6);
    }

    function test_deposit_belowMinimum_reverts() public {
        vm.startPrank(user1);
        usdc.approve(address(vault), 50e6);
        vm.expectRevert("deposit out of range");
        vault.deposit(50e6);
        vm.stopPrank();
    }

    function test_deposit_aboveMaximum_reverts() public {
        deal(USDC_ADDR, user1, 2_000_000e6);
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

    // ── BRIDGE (real CoreDepositWallet) ──
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

    function test_bridge_reservesPendingRedemptions() public {
        _depositAs(user1, 30_000e6);
        vm.startPrank(user1);
        usdm.approve(address(vault), 10_000e6);
        vault.requestRedeem(10_000e6);
        vm.stopPrank();
        _depositAs(user2, 30_000e6);
        assertGe(usdc.balanceOf(address(vault)), 10_000e6);
    }

    // ── REDEEM ──
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

    // ── sUSDM STAKING (ERC-4626) ──
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
        uint256 before_ = susdm.convertToAssets(susdm.balanceOf(user1));
        vm.startPrank(address(vault));
        usdm.mint(address(vault), 1_000e6);
        usdm.approve(address(susdm), 1_000e6);
        susdm.injectYield(1_000e6);
        vm.stopPrank();
        assertGt(susdm.convertToAssets(susdm.balanceOf(user1)), before_);
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

    function test_unstake_doesNotChangeRate() public {
        _depositAndStake(user1, 10_000e6, 10_000e6);
        _depositAndStake(user2, 10_000e6, 10_000e6);
        uint256 rateBefore = susdm.convertToAssets(1e12);
        uint256 user1Shares = susdm.balanceOf(user1);
        assertGt(user1Shares, 0, "user1 should have shares");
        vm.prank(user1);
        susdm.cooldownShares(user1Shares);
        assertEq(susdm.convertToAssets(1e12), rateBefore);
    }

    function test_withdraw_reverts() public {
        vm.expectRevert();
        susdm.withdraw(100, address(this), address(this));
    }

    function test_redeem_reverts() public {
        vm.expectRevert();
        susdm.redeem(100, address(this), address(this));
    }

    // ── INSURANCE FUND ──
    function test_insuranceFund_anyoneCanDeposit() public {
        deal(USDC_ADDR, admin, 10_000e6);
        vm.startPrank(admin);
        usdc.approve(address(insurance), 10_000e6);
        insurance.deposit(10_000e6);
        vm.stopPrank();
        assertEq(usdc.balanceOf(address(insurance)), 10_000e6);
    }

    function test_insuranceFund_adminWithdraw() public {
        _depositAs(user1, 100_000e6);
        deal(USDC_ADDR, address(yieldEscrow), 1_000e6);
        vm.prank(operator);
        vault.distributeYield();
        uint256 insBal = usdc.balanceOf(address(insurance));
        assertGt(insBal, 0);
        vm.prank(admin);
        insurance.withdraw(admin, insBal, "test");
        assertEq(usdc.balanceOf(address(insurance)), 0);
    }

    // ── CONFIG ──
    function test_config_setYieldBps_exceedReverts() public {
        vm.prank(admin);
        vm.expectRevert("Config: bps exceed 10000");
        config.setYieldBps(9000, 2000);
    }

    function test_config_foundationYieldBps() public {
        assertEq(config.foundationYieldBps(), 2000);
        vm.prank(admin);
        config.setYieldBps(8000, 1000);
        assertEq(config.foundationYieldBps(), 1000);
    }

    function test_config_setDepositLimits() public {
        vm.prank(admin);
        config.setDepositLimits(50e6, 500_000e6);
        assertEq(config.minDepositAmount(), 50e6);
        assertEq(config.maxDepositAmount(), 500_000e6);
    }
}


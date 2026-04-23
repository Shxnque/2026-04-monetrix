// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/governance/TimelockController.sol";
import "@openzeppelin/contracts/access/IAccessControl.sol";

import "../src/tokens/USDM.sol";
import "../src/tokens/sUSDM.sol";
import "../src/core/MonetrixConfig.sol";
import "../src/core/MonetrixVault.sol";
import "../src/core/MonetrixAccountant.sol";
import "../src/core/InsuranceFund.sol";

import "../src/core/RedeemEscrow.sol";
import "../src/core/YieldEscrow.sol";
import "./mocks/MockUSDC.sol";
import "./mocks/MockCoreDepositWallet.sol";
import "../src/governance/MonetrixAccessController.sol";
import "../src/governance/MonetrixGovernedUpgradeable.sol";

/// @title Governance.t.sol
/// @notice End-to-end validation of the 3-tier access model: GUARDIAN (instant
///         pause), GOVERNOR (24h timelock), UPGRADER (48h timelock), OPERATOR
///         (instant hot-path), VAULT_CALLER (contract identity).
contract GovernanceTest is Test {
    uint256 constant GOV_DELAY = 24 hours;
    uint256 constant UPG_DELAY = 48 hours;

    MonetrixAccessController acl;
    TimelockController timelock24h;
    TimelockController timelock48h;

    MockUSDC usdc;
    USDM usdm;
    sUSDM susdm;
    MonetrixConfig config;
    MonetrixVault vault;
    MonetrixAccountant accountant;
    InsuranceFund insurance;
    address deployer = address(this);
    address governorMultisig = address(0x6001);
    address guardianMultisig = address(0x6002);
    address bot = address(0x600B);
    address randomUser = address(0x600F);

    function setUp() public {
        // 1. ACL
        acl = MonetrixAccessController(
            address(
                new ERC1967Proxy(
                    address(new MonetrixAccessController()),
                    abi.encodeCall(MonetrixAccessController.initialize, (deployer))
                )
            )
        );

        // 2. Timelocks (Governor multisig is sole proposer+executor)
        address[] memory prop = new address[](1);
        prop[0] = governorMultisig;
        address[] memory exec = new address[](1);
        exec[0] = governorMultisig;
        timelock24h = new TimelockController(GOV_DELAY, prop, exec, deployer);
        timelock48h = new TimelockController(UPG_DELAY, prop, exec, deployer);

        // 3. Protocol contracts (admin = acl)
        usdc = new MockUSDC();
        usdm = USDM(address(new ERC1967Proxy(address(new USDM()), abi.encodeCall(USDM.initialize, (address(acl))))));
        insurance = InsuranceFund(
            address(
                new ERC1967Proxy(
                    address(new InsuranceFund()),
                    abi.encodeCall(InsuranceFund.initialize, (address(usdc), address(acl)))
                )
            )
        );
        config = MonetrixConfig(
            address(
                new ERC1967Proxy(
                    address(new MonetrixConfig()),
                    abi.encodeCall(MonetrixConfig.initialize, (address(insurance), address(0xF0), address(acl)))
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
        MockCoreDepositWallet depositWallet = new MockCoreDepositWallet(address(usdc));
        vault = MonetrixVault(
            address(
                new ERC1967Proxy(
                    address(new MonetrixVault()),
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
                )
            )
        );
        // 4. Wire roles on the ACL
        acl.grantRole(acl.GOVERNOR(), address(timelock24h));
        acl.grantRole(acl.UPGRADER(), address(timelock48h));
        acl.grantRole(acl.GUARDIAN(), guardianMultisig);
        acl.grantRole(acl.OPERATOR(), bot);

        // Direct-vault binding on USDM/sUSDM (replaces VAULT_CALLER grant).
        // Deployer still holds GOVERNOR at this stage.
        acl.grantRole(acl.GOVERNOR(), address(this));
        usdm.setVault(address(vault));
        susdm.setVault(address(vault));
        acl.revokeRole(acl.GOVERNOR(), address(this));
    }

    // ─── Tier 1: GUARDIAN — no delay ────────────────────────────

    /// Guardian can pause the vault instantly (no schedule/execute).
    function test_Guardian_Pause_NoDelay() public {
        vm.prank(guardianMultisig);
        vault.pause();
        assertTrue(vault.paused());
    }

    /// A non-Guardian address cannot pause.
    function test_Unauthorized_Pause_Reverts() public {
        vm.prank(randomUser);
        vm.expectRevert();
        vault.pause();
    }

    // ─── Tier 2: GOVERNOR — 24h timelock ────────────────────────

    /// Governor multisig cannot call a restricted function directly — must go
    /// through the 24h timelock.
    function test_Multisig_DirectCall_Reverts() public {
        vm.prank(governorMultisig);
        vm.expectRevert();
        config.setYieldBps(7500, 1000);
    }

    /// Full happy path: schedule → wait delay → execute → parameter updated.
    function test_Governor_SetYieldBps_ThroughTimelock() public {
        bytes memory data = abi.encodeCall(config.setYieldBps, (7500, 1000));

        vm.prank(governorMultisig);
        timelock24h.schedule(address(config), 0, data, bytes32(0), bytes32(0), GOV_DELAY);

        vm.warp(block.timestamp + GOV_DELAY);

        vm.prank(governorMultisig);
        timelock24h.execute(address(config), 0, data, bytes32(0), bytes32(0));

        assertEq(config.userYieldBps(), 7500);
        assertEq(config.insuranceYieldBps(), 1000);
    }

    /// Executing before the delay elapses reverts.
    function test_Governor_BeforeDelay_Reverts() public {
        bytes memory data = abi.encodeCall(config.setMaxTVL, (42e6));
        vm.prank(governorMultisig);
        timelock24h.schedule(address(config), 0, data, bytes32(0), bytes32(0), GOV_DELAY);

        // 1 second shy of the delay
        vm.warp(block.timestamp + GOV_DELAY - 1);

        vm.prank(governorMultisig);
        vm.expectRevert();
        timelock24h.execute(address(config), 0, data, bytes32(0), bytes32(0));
    }

    // ─── Tier 2 split: UPGRADER — 48h timelock ───────────────────

    /// Upgrading the vault requires going through the 48h timelock.
    function test_Upgrade_Through48hTimelock() public {
        address newImpl = address(new MonetrixVault());
        bytes memory data = abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (newImpl, ""));

        vm.prank(governorMultisig);
        timelock48h.schedule(address(vault), 0, data, bytes32(0), bytes32(0), UPG_DELAY);

        vm.warp(block.timestamp + UPG_DELAY);

        vm.prank(governorMultisig);
        timelock48h.execute(address(vault), 0, data, bytes32(0), bytes32(0));

        // Post-upgrade the vault is still responsive (no state corruption).
        assertEq(vault.paused(), false);
    }

    /// Upgrade attempt routed through the 24h timelock (which only holds
    /// GOVERNOR, not UPGRADER) must revert — role separation prevents the
    /// shorter queue from being used for upgrades.
    function test_Upgrade_Through24hTimelock_Reverts() public {
        address newImpl = address(new MonetrixVault());
        bytes memory data = abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (newImpl, ""));

        vm.prank(governorMultisig);
        timelock24h.schedule(address(vault), 0, data, bytes32(0), bytes32(0), GOV_DELAY);

        vm.warp(block.timestamp + GOV_DELAY);

        vm.prank(governorMultisig);
        vm.expectRevert(); // _authorizeUpgrade → NotAuthorized(UPGRADER, caller)
        timelock24h.execute(address(vault), 0, data, bytes32(0), bytes32(0));
    }

    // ─── Tier 3: OPERATOR — no delay ────────────────────────────

    /// Operator can call setHlpDepositEnabled instantly.
    function test_Operator_SetHlpDepositEnabled_NoDelay() public {
        vm.prank(bot);
        vault.setHlpDepositEnabled(false);
        assertFalse(vault.hlpDepositEnabled());
    }

    /// Random address cannot impersonate the operator.
    function test_Unauthorized_OperatorCall_Reverts() public {
        vm.prank(randomUser);
        vm.expectRevert();
        vault.setHlpDepositEnabled(false);
    }

    // ─── USDM mint: direct-vault binding ───────────────────────

    /// Vault (bound via setVault) can mint USDM.
    function test_Vault_Mint() public {
        vm.prank(address(vault));
        usdm.mint(randomUser, 1e6);
        assertEq(usdm.balanceOf(randomUser), 1e6);
    }

    /// Non-vault address cannot mint USDM.
    function test_NonVault_CannotMint() public {
        vm.prank(governorMultisig);
        vm.expectRevert(USDM.NotVault.selector);
        usdm.mint(randomUser, 1e6);
    }

    // ─── Role revocation ────────────────────────────────────────

    /// Revoked roles are blocked immediately, no queue.
    function test_RevokedRole_Blocked() public {
        // Bot initially can call operator function.
        vm.prank(bot);
        vault.setHlpDepositEnabled(false);

        // Revoke (deployer still holds DEFAULT_ADMIN_ROLE on ACL in tests)
        acl.revokeRole(acl.OPERATOR(), bot);

        vm.prank(bot);
        vm.expectRevert();
        vault.setHlpDepositEnabled(true);
    }
}

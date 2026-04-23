// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "../../src/tokens/USDM.sol";
import "../../src/tokens/sUSDM.sol";
import {sUSDMEscrow} from "../../src/tokens/sUSDMEscrow.sol";
import "../../src/core/MonetrixConfig.sol";
import "../../src/core/MonetrixVault.sol";
import "../../src/core/MonetrixAccountant.sol";
import "../../src/core/InsuranceFund.sol";
import "../../src/core/RedeemEscrow.sol";
import "../../src/core/YieldEscrow.sol";
import "../../src/governance/MonetrixAccessController.sol";
import "../../src/interfaces/HyperCoreConstants.sol";

import "../mocks/MockUSDC.sol";

import {CoreSimulatorLib} from "@hyper-evm-lib/test/simulation/CoreSimulatorLib.sol";
import {HyperCore} from "@hyper-evm-lib/test/simulation/HyperCore.sol";
import {HLConstants} from "@hyper-evm-lib/src/common/HLConstants.sol";

/// @dev Stub for precompiles not modeled by CoreSimulator (e.g. 0x811 PM
///      supplied balance). Returns 128-byte zero response, which Accountant
///      decodes as "zero supply" — the correct steady-state value for tests
///      that don't exercise portfolio margin. Only used when a supplied slot
///      has been pre-registered on the Accountant (strict reads otherwise
///      revert per design).
contract ZeroPrecompile {
    fallback(bytes calldata) external payable returns (bytes memory) {
        return new bytes(128);
    }
}

/// @notice Shared setUp for simulator-backed tests. Wires the full Monetrix
///         stack at real HyperCore precompile/CoreWriter addresses so actions
///         emitted by the Vault are executed by CoreSimulator on nextBlock().
abstract contract SimulatorBase is Test {
    HyperCore hyperCore;

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
    MonetrixAccessController acl;

    address admin = address(0xAD);
    address operator = address(0xBB);
    address user1 = address(0x1);
    address foundation = address(0xF0);

    address constant HLP = HyperCoreConstants.HLP_VAULT;
    uint64 constant USDC_TOKEN = 0;

    function setUpSimulator() internal {
        // 1. Initialize HyperCore simulator in offline mode.
        hyperCore = CoreSimulatorLib.init();
        hyperCore.setUseRealL1Read(false);
        CoreSimulatorLib.setRevertOnFailure(true);

        vm.startPrank(admin);

        usdc = new MockUSDC();

        // ACL
        MonetrixAccessController aclImpl = new MonetrixAccessController();
        acl = MonetrixAccessController(
            address(new ERC1967Proxy(address(aclImpl), abi.encodeCall(MonetrixAccessController.initialize, (admin))))
        );

        // USDM
        usdm = USDM(
            address(new ERC1967Proxy(address(new USDM()), abi.encodeCall(USDM.initialize, (address(acl)))))
        );

        // Insurance
        insurance = InsuranceFund(
            address(
                new ERC1967Proxy(
                    address(new InsuranceFund()),
                    abi.encodeCall(InsuranceFund.initialize, (address(usdc), address(acl)))
                )
            )
        );

        // Config
        config = MonetrixConfig(
            address(
                new ERC1967Proxy(
                    address(new MonetrixConfig()),
                    abi.encodeCall(MonetrixConfig.initialize, (address(insurance), foundation, address(acl)))
                )
            )
        );

        // sUSDM
        susdm = sUSDM(
            address(
                new ERC1967Proxy(
                    address(new sUSDM()),
                    abi.encodeCall(sUSDM.initialize, (address(usdm), address(config), address(acl)))
                )
            )
        );

        // Vault — coreDepositWallet points at the simulator's etched CORE_DEPOSIT_WALLET
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
                            HLConstants.CORE_DEPOSIT_WALLET,
                            address(acl)
                        )
                    )
                )
            )
        );

        // Accountant
        accountant = MonetrixAccountant(
            address(
                new ERC1967Proxy(
                    address(new MonetrixAccountant()),
                    abi.encodeCall(
                        MonetrixAccountant.initialize, (address(vault), address(usdc), address(usdm), address(acl))
                    )
                )
            )
        );

        redeemEscrow = RedeemEscrow(
            address(
                new ERC1967Proxy(
                    address(new RedeemEscrow()),
                    abi.encodeCall(RedeemEscrow.initialize, (address(usdc), address(vault), address(acl)))
                )
            )
        );
        yieldEscrow = YieldEscrow(
            address(
                new ERC1967Proxy(
                    address(new YieldEscrow()),
                    abi.encodeCall(YieldEscrow.initialize, (address(usdc), address(vault), address(acl)))
                )
            )
        );

        // Roles
        acl.grantRole(acl.GOVERNOR(), admin);
        acl.grantRole(acl.GUARDIAN(), admin);
        acl.grantRole(acl.OPERATOR(), admin);
        acl.grantRole(acl.OPERATOR(), operator);
        acl.grantRole(acl.UPGRADER(), admin);

        usdm.setVault(address(vault));
        susdm.setVault(address(vault));
        unstakeEscrow = new sUSDMEscrow(address(usdm), address(susdm));
        susdm.setEscrow(address(unstakeEscrow));

        config.setCooldowns(3 days, 7 days);

        vault.setAccountant(address(accountant));
        vault.setRedeemEscrow(address(redeemEscrow));
        vault.setYieldEscrow(address(yieldEscrow));
        accountant.setConfig(address(config));

        vm.stopPrank();

        // Activate the vault account on HyperCore so precompile reads/writes work.
        CoreSimulatorLib.forceAccountActivation(address(vault));

        // PM supplied-balance precompile (0x811) is not modeled by CoreSimulator.
        // Etch a zero stub so Accountant's fail-closed read returns `supplied=0`
        // instead of reverting (accurate for non-PM scenarios).
        vm.etch(HyperCoreConstants.PRECOMPILE_SUPPLIED_BALANCE, address(new ZeroPrecompile()).code);

        usdc.mint(user1, 10_000_000e6);
    }

    function _deposit(address user, uint256 amount) internal {
        vm.startPrank(user);
        usdc.approve(address(vault), amount);
        vault.deposit(amount);
        vm.stopPrank();
    }

    function _readVaultEquity() internal view returns (uint64 equity, uint64 lockedUntil) {
        (bool ok, bytes memory res) = HyperCoreConstants.PRECOMPILE_VAULT_EQUITY.staticcall(
            abi.encode(address(vault), HLP)
        );
        require(ok && res.length >= 64, "precompile read failed");
        (equity, lockedUntil) = abi.decode(res, (uint64, uint64));
    }

    function _readSpot(address who, uint64 token) internal view returns (uint64 total) {
        (bool ok, bytes memory res) = HyperCoreConstants.PRECOMPILE_SPOT_BALANCE.staticcall(abi.encode(who, token));
        if (!ok || res.length < 96) return 0;
        (total,,) = abi.decode(res, (uint64, uint64, uint64));
    }
}

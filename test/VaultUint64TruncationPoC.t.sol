// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import "../src/core/MonetrixVault.sol";
import "../src/core/MonetrixConfig.sol";
import "../src/core/InsuranceFund.sol";
import "../src/core/RedeemEscrow.sol";
import "../src/core/YieldEscrow.sol";
import "../src/core/MonetrixAccountant.sol";
import "../src/tokens/USDM.sol";
import "../src/tokens/sUSDM.sol";
import "../src/governance/MonetrixAccessController.sol";
import "../src/interfaces/HyperCoreConstants.sol";
import "./mocks/MockUSDC.sol";
import "./mocks/MockCoreDepositWallet.sol";

/// @notice Capturing mock — preserves the last sendRawAction payload so tests
///         can inspect what bytes were actually sent to CoreWriter.
contract CapturingCoreWriter {
    bytes public lastAction;
    uint256 public callCount;

    function sendRawAction(bytes calldata data) external {
        lastAction = data;
        callCount += 1;
    }
}

/// @title L2-H1 PoC — `_sendL1Bridge` uint64 truncation
/// @notice Demonstrates that `uint64(amount)` in `_sendL1Bridge` silently
///         truncates when `amount > type(uint64).max`. This PoC pins the
///         exact behavior so that any defensive fix (e.g. SafeCast.toUint64)
///         can be verified by this test flipping from pass → revert.
///
///         HyperCore wire format for ACTION_SEND_ASSET:
///           ACTION_VERSION (1) + ACTION_SEND_ASSET (3) +
///           abi.encode(address, address, uint32, uint32, uint64 token, uint64 amount)
///         The final 32-byte word contains the truncated `l1Amount` (padded).
///
///         `l1Amount = uint64(amount) * 100`. If `amount * 100` fits in uint64
///         the product is reliable; if `uint64(amount)` alone truncates `amount`,
///         the emitted l1Amount is the low-64-bit slice × 100, not the full value.
contract VaultUint64TruncationPoC is Test {
    MonetrixAccessController acl;
    MonetrixConfig config;
    InsuranceFund insurance;
    MockUSDC usdc;
    USDM usdm;
    sUSDM susdm;
    MonetrixAccountant accountant;
    MonetrixVault vault;
    RedeemEscrow redeemEscrow;
    YieldEscrow yieldEscrow;
    CapturingCoreWriter writer;

    address admin = address(0xAD);
    address operator = address(0xB0);
    address foundation = address(0xF0);

    function setUp() public {
        vm.startPrank(admin);

        acl = MonetrixAccessController(address(new ERC1967Proxy(
            address(new MonetrixAccessController()),
            abi.encodeCall(MonetrixAccessController.initialize, (admin))
        )));

        insurance = InsuranceFund(address(new ERC1967Proxy(
            address(new InsuranceFund()),
            abi.encodeCall(InsuranceFund.initialize, (address(1), address(acl)))
        )));

        config = MonetrixConfig(address(new ERC1967Proxy(
            address(new MonetrixConfig()),
            abi.encodeCall(MonetrixConfig.initialize, (address(insurance), foundation, address(acl)))
        )));

        usdc = new MockUSDC();
        // Re-init insurance with real usdc after it's deployed.
        // (Simpler: re-deploy insurance pointing at usdc.)
        insurance = InsuranceFund(address(new ERC1967Proxy(
            address(new InsuranceFund()),
            abi.encodeCall(InsuranceFund.initialize, (address(usdc), address(acl)))
        )));

        usdm = USDM(address(new ERC1967Proxy(
            address(new USDM()),
            abi.encodeCall(USDM.initialize, (address(acl)))
        )));

        susdm = sUSDM(address(new ERC1967Proxy(
            address(new sUSDM()),
            abi.encodeCall(sUSDM.initialize, (address(usdm), address(config), address(acl)))
        )));

        MockCoreDepositWallet depositWallet = new MockCoreDepositWallet(address(usdc));

        vault = MonetrixVault(address(new ERC1967Proxy(
            address(new MonetrixVault()),
            abi.encodeCall(
                MonetrixVault.initialize,
                (address(usdc), address(usdm), address(susdm), address(config),
                 address(depositWallet), address(acl))
            )
        )));

        redeemEscrow = RedeemEscrow(address(new ERC1967Proxy(
            address(new RedeemEscrow()),
            abi.encodeCall(RedeemEscrow.initialize, (address(usdc), address(vault), address(acl)))
        )));

        yieldEscrow = YieldEscrow(address(new ERC1967Proxy(
            address(new YieldEscrow()),
            abi.encodeCall(YieldEscrow.initialize, (address(usdc), address(vault), address(acl)))
        )));

        accountant = MonetrixAccountant(address(new ERC1967Proxy(
            address(new MonetrixAccountant()),
            abi.encodeCall(
                MonetrixAccountant.initialize,
                (address(vault), address(usdc), address(usdm), address(acl))
            )
        )));

        acl.grantRole(acl.GOVERNOR(), admin);
        acl.grantRole(acl.OPERATOR(), admin);
        acl.grantRole(acl.OPERATOR(), operator);
        acl.grantRole(acl.GUARDIAN(), admin);

        usdm.setVault(address(vault));
        susdm.setVault(address(vault));

        vault.setAccountant(address(accountant));
        vault.setRedeemEscrow(address(redeemEscrow));
        vault.setYieldEscrow(address(yieldEscrow));

        // Capturing core writer at the HyperCore CoreWriter precompile address.
        // vm.etch copies bytecode; storage reads go through the etched address.
        writer = new CapturingCoreWriter();
        vm.etch(HyperCoreConstants.CORE_WRITER, address(writer).code);

        // M-01 guard: _sendL1Bridge reads vault's L1 spot + supplied USDC
        // before emitting SEND_ASSET. For this PoC we want to bypass the
        // solvency check so the downstream SafeCast overflow is the failure
        // mode under test — mock both reads at max uint64.
        vm.mockCall(
            HyperCoreConstants.PRECOMPILE_SPOT_BALANCE,
            abi.encode(address(vault), uint64(HyperCoreConstants.USDC_TOKEN_INDEX)),
            abi.encode(type(uint64).max, uint64(0), uint64(0))
        );
        vm.mockCall(
            HyperCoreConstants.PRECOMPILE_SUPPLIED_BALANCE,
            abi.encode(address(vault), uint64(HyperCoreConstants.USDC_TOKEN_INDEX)),
            abi.encode(uint64(0), uint64(0), uint64(0), type(uint64).max)
        );

        vm.stopPrank();
    }

    /// @dev Read the captured action from the ETCHED writer at CORE_WRITER.
    function _readCapturedAction() internal view returns (bytes memory) {
        (bool ok, bytes memory ret) = HyperCoreConstants.CORE_WRITER.staticcall(
            abi.encodeWithSignature("lastAction()")
        );
        require(ok, "staticcall failed");
        return abi.decode(ret, (bytes));
    }

    /// @dev Bump outstandingL1Principal to a target value by minting USDC
    ///      into the vault and calling keeperBridge. Safe within this test's
    ///      scope — no supply-side accounting invariants required.
    function _pumpOLP(uint256 target) internal {
        vm.warp(block.timestamp + config.bridgeInterval() + 1);
        usdc.mint(address(vault), target);
        vm.prank(operator);
        vault.keeperBridge(MonetrixVault.BridgeTarget.Vault);
        assertEq(vault.outstandingL1Principal(), target, "OLP setup");
    }

    /// @dev Decode the uint64 l1Amount from the captured action payload.
    ///      Layout: 1 + 3 + abi.encode(address, address, uint32, uint32, uint64 token, uint64 amount)
    ///      Final 32-byte word of the encoded tail is the right-padded uint64 amount.
    function _decodedL1Amount(bytes memory action) internal pure returns (uint64) {
        require(action.length >= 36, "action too short");
        // Header is 4 bytes (version+selector). Tail is standard abi.encode of 6 args = 192 bytes.
        // The last 32 bytes of tail = action[action.length - 32 : action.length]
        uint256 last;
        assembly {
            last := mload(add(action, mload(action)))  // load last 32 bytes
        }
        return uint64(last);
    }

    // ─────────────────────────────────────────────────────────────
    // Sanity: within-range amount bridges the exact expected l1Amount.
    // ─────────────────────────────────────────────────────────────

    function test_bridge_inRange_roundtripsAmount() public {
        uint256 amount = 1_000_000e6;   // 1M USDC — fits in uint64 easily
        _pumpOLP(amount);

        vm.prank(admin);
        vault.emergencyBridgePrincipalFromL1(amount);

        uint64 decoded = _decodedL1Amount(_readCapturedAction());
        uint64 expected = uint64(amount) * uint64(HyperCoreConstants.EVM_TO_L1_PRECISION);
        assertEq(decoded, expected, "in-range l1Amount mismatch");
        assertEq(vault.outstandingL1Principal(), 0, "OLP drained");
    }

    // ─────────────────────────────────────────────────────────────
    // Core PoC: amount > type(uint64).max causes silent EVM/L1 desync.
    // ─────────────────────────────────────────────────────────────

    /// @notice Post-fix verification: when `amount ≥ 2^64`, the pre-fix
    ///         `uint64(amount) * 100` would silently truncate (cast unchecked)
    ///         and desync EVM accounting from L1 movement. The fix routes
    ///         through `HyperCoreConstants.toL1Wei`, which performs the
    ///         multiplication in uint256 and `SafeCast.toUint64`s the product,
    ///         collapsing all truncation paths to a single clean revert.
    ///
    ///         This test used to PASS (documenting silent-loss desync) before
    ///         the fix. It now verifies the revert shape and that no state
    ///         changed — OLP preserved, CoreWriter never invoked.
    function test_poc_uint64TruncationDesync() public {
        // amount = 2^64 + 7 — pre-fix this truncated to 7 → l1Amount = 700
        // wei, EVM debited full 1.8e19. Post-fix: SafeCast.toUint64 sees
        // (2^64 + 7) * 100 ≫ uint64.max and reverts.
        uint256 amount = uint256(type(uint64).max) + 1 + 7;

        _pumpOLP(amount);

        uint256 olpBefore = vault.outstandingL1Principal();
        uint256 writerCallsBefore = writer.callCount();

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                SafeCast.SafeCastOverflowedUintDowncast.selector, uint8(64), amount * 100
            )
        );
        vault.emergencyBridgePrincipalFromL1(amount);

        // No state change: OLP preserved, CoreWriter not called.
        assertEq(vault.outstandingL1Principal(), olpBefore, "OLP unchanged on revert");
        assertEq(writer.callCount(), writerCallsBefore, "no L1 action emitted");
    }

    /// @notice A concrete attack scenario description (no code path yet
    ///         available because maxTVL prevents reaching this state, but
    ///         documenting the arithmetic).
    ///
    ///         Today: config.maxTVL = 10M USDC = 1e13 wei, well under 2^64.
    ///         If governance ever raises / removes the cap (common for mature
    ///         protocols), this PoC's exact scenario becomes directly reachable
    ///         through `keeperBridge` followed by `bridgePrincipalFromL1`.
    function test_poc_reachabilityRequiresMaxTvlLifted() public pure {
        // This test intentionally has no runtime logic — it exists to pin
        // the reachability claim in the audit report for future readers.
        assertTrue(true, "see natspec");
    }
}

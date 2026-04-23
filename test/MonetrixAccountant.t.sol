// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "../src/core/MonetrixAccountant.sol";
import "../src/core/MonetrixConfig.sol";
import "../src/core/PrecompileReader.sol";
import "../src/tokens/USDM.sol";
import "./mocks/MockUSDC.sol";
import "../src/interfaces/HyperCoreConstants.sol";
import "../src/governance/MonetrixAccessController.sol";

/// @notice Controllable mock precompile for testing. Its `staticcall` fallback
/// decodes a selector from the incoming calldata to match the layout the
/// precompile expects, then returns pre-programmed state.
/// @dev Default response is 32 bytes of zeros. This size satisfies the
/// minimum length check in every Accountant reader (perp=32, spot=24, hlp=16,
/// oracle=8), and decodes to "zero balance / zero account value" which the
/// readers interpret as "no position" (short-circuit without error). Tests
/// that want specific non-zero values still call setResponse explicitly.
/// A test that wants to simulate a precompile outage can install a
/// FailingPrecompile via vm.etch on the target address.
contract MockPrecompile {
    mapping(bytes32 => bytes) public responses;

    function setResponse(bytes calldata callData, bytes calldata response) external {
        responses[keccak256(callData)] = response;
    }

    fallback(bytes calldata data) external payable returns (bytes memory) {
        bytes memory r = responses[keccak256(data)];
        if (r.length == 0) {
            // 128 zero bytes — satisfies every reader's min length check
            // (perp=128, spot=96, hlp=64, oracle=32) and decodes to
            // "no position / zero balance" semantics. Tests that want
            // specific non-zero values still call setResponse explicitly.
            return new bytes(128);
        }
        return r;
    }
}

/// @notice Test helper that always reverts. Used with vm.etch to simulate
/// a HyperCore precompile outage and verify fail-closed behavior.
contract FailingPrecompile {
    fallback(bytes calldata) external payable returns (bytes memory) {
        revert("precompile down");
    }
}

/// @notice Test helper that always returns empty bytes. Simulates a malformed
/// precompile response (shorter than the decode length).
contract EmptyPrecompile {
    fallback(bytes calldata) external payable returns (bytes memory) {
        return new bytes(0);
    }
}

/// @notice Minimal stand-in for MonetrixVault exposing just the fields the
/// Accountant reads via IMonetrixVaultReader.
contract MockVault {
    address public multisigVault;
    address public redeemEscrow;

    function setMultisigVault(address _multisig) external {
        multisigVault = _multisig;
    }
    function setRedeemEscrow(address _re) external { redeemEscrow = _re; }
}

contract MonetrixAccountantTest is Test {
    MonetrixAccountant accountant;
    MonetrixConfig config;
    USDM usdm;
    MockUSDC usdc;
    MockVault mockVault;
    MonetrixAccessController acl;
    address vault; // points at mockVault for convenience

    address admin = address(0xAD);
    address keeper = address(0xB01);

    MockPrecompile mockAccountMargin;
    MockPrecompile mockSpotBalance;
    MockPrecompile mockOraclePx;
    MockPrecompile mockVaultEquity;
    MockPrecompile mockSuppliedBalance;
    MockPrecompile mockTokenInfo;
    MockPrecompile mockPerpAssetInfo;

    function setUp() public {
        vm.startPrank(admin);

        usdc = new MockUSDC();
        mockVault = new MockVault();
        vault = address(mockVault);

        // Deploy ACL
        MonetrixAccessController aclImpl = new MonetrixAccessController();
        ERC1967Proxy aclProxy =
            new ERC1967Proxy(address(aclImpl), abi.encodeCall(MonetrixAccessController.initialize, (admin)));
        acl = MonetrixAccessController(address(aclProxy));

        // Deploy USDM proxy
        USDM usdmImpl = new USDM();
        ERC1967Proxy usdmProxy = new ERC1967Proxy(address(usdmImpl), abi.encodeCall(USDM.initialize, (address(acl))));
        usdm = USDM(address(usdmProxy));

        // Deploy MonetrixAccountant proxy
        MonetrixAccountant acctImpl = new MonetrixAccountant();
        ERC1967Proxy acctProxy = new ERC1967Proxy(
            address(acctImpl),
            abi.encodeCall(MonetrixAccountant.initialize, (vault, address(usdc), address(usdm), address(acl)))
        );
        accountant = MonetrixAccountant(address(acctProxy));

        // Deploy Config proxy (needed for tradeableAssets in totalBacking)
        MonetrixConfig configImpl = new MonetrixConfig();
        ERC1967Proxy configProxy = new ERC1967Proxy(
            address(configImpl),
            abi.encodeCall(MonetrixConfig.initialize, (address(0x1), address(0x2), address(acl)))
        );
        config = MonetrixConfig(address(configProxy));

        // Grant roles: keeper plays OPERATOR, admin plays GOVERNOR.
        // Accountant.vault was bound at init to the `vault` mock.
        // USDM.vault is bound to `admin` here (test mints USDM directly via admin).
        acl.grantRole(acl.OPERATOR(), keeper);
        acl.grantRole(acl.GOVERNOR(), admin);

        usdm.setVault(admin);

        // Wire config to accountant (after governor role granted)
        accountant.setConfig(address(config));

        // Install mock precompiles via vm.etch
        vm.etch(HyperCoreConstants.PRECOMPILE_ACCOUNT_MARGIN_SUMMARY, address(new MockPrecompile()).code);
        vm.etch(HyperCoreConstants.PRECOMPILE_SPOT_BALANCE, address(new MockPrecompile()).code);
        vm.etch(HyperCoreConstants.PRECOMPILE_ORACLE_PX, address(new MockPrecompile()).code);
        vm.etch(HyperCoreConstants.PRECOMPILE_VAULT_EQUITY, address(new MockPrecompile()).code);
        vm.etch(HyperCoreConstants.PRECOMPILE_SUPPLIED_BALANCE, address(new MockPrecompile()).code);
        vm.etch(HyperCoreConstants.PRECOMPILE_TOKEN_INFO, address(new MockPrecompile()).code);
        vm.etch(HyperCoreConstants.PRECOMPILE_PERP_ASSET_INFO, address(new MockPrecompile()).code);

        mockAccountMargin = MockPrecompile(payable(HyperCoreConstants.PRECOMPILE_ACCOUNT_MARGIN_SUMMARY));
        mockSpotBalance = MockPrecompile(payable(HyperCoreConstants.PRECOMPILE_SPOT_BALANCE));
        mockOraclePx = MockPrecompile(payable(HyperCoreConstants.PRECOMPILE_ORACLE_PX));
        mockVaultEquity = MockPrecompile(payable(HyperCoreConstants.PRECOMPILE_VAULT_EQUITY));
        mockSuppliedBalance = MockPrecompile(payable(HyperCoreConstants.PRECOMPILE_SUPPLIED_BALANCE));
        mockTokenInfo = MockPrecompile(payable(HyperCoreConstants.PRECOMPILE_TOKEN_INFO));
        mockPerpAssetInfo = MockPrecompile(payable(HyperCoreConstants.PRECOMPILE_PERP_ASSET_INFO));

        vm.stopPrank();
    }

    // ─── Helpers: program mock precompile responses ──────────

    function _setAccountValue(int64 accountValue) internal {
        bytes memory key = abi.encode(uint32(0), vault);
        bytes memory response = abi.encode(accountValue, uint64(0), uint64(0), int64(0));
        mockAccountMargin.setResponse(key, response);
    }

    function _setSpotBalance(uint64 tokenIndex, uint64 total) internal {
        bytes memory key = abi.encode(vault, tokenIndex);
        bytes memory response = abi.encode(total, uint64(0), uint64(0));
        mockSpotBalance.setResponse(key, response);
    }

    function _setOraclePrice(uint16 perpIndex, uint64 price) internal {
        bytes memory key = abi.encode(perpIndex);
        bytes memory response = abi.encode(price);
        mockOraclePx.setResponse(key, response);
    }

    function _setHlpEquity(uint64 equity) internal {
        bytes memory key = abi.encode(vault, HyperCoreConstants.HLP_VAULT);
        bytes memory response = abi.encode(equity, uint64(0));
        mockVaultEquity.setResponse(key, response);
    }

    function _setEvmUsdc(uint256 amount) internal {
        usdc.mint(vault, amount);
    }

    function _mintUsdm(uint256 amount) internal {
        vm.prank(admin);
        usdm.mint(address(this), amount);
    }

    function _setHedgeAsset(uint32 spotToken, uint32 perpIndex) internal {
        vm.prank(admin);
        config.addTradeableAsset(
            MonetrixConfig.TradeableAsset({
                perpIndex: perpIndex,
                spotIndex: spotToken,
                spotPairAssetId: 10000 + spotToken  // synthetic pair_asset_id for tests
            })
        );
    }

    /// @dev Program the TokenInfo precompile (0x80C) for a hedge asset.
    /// Most L1 HIP-1 tokens use weiDecimals=8; szDecimals varies per asset.
    function _setTokenInfo(uint32 spotTokenIndex, uint8 weiDec, uint8 szDec) internal {
        PrecompileReader.TokenInfo memory info = PrecompileReader.TokenInfo({
            name: "MOCK",
            spots: new uint64[](0),
            deployerTradingFeeShare: 0,
            deployer: address(0),
            evmContract: address(0),
            szDecimals: szDec,
            weiDecimals: weiDec,
            evmExtraWeiDecimals: 0
        });
        mockTokenInfo.setResponse(abi.encode(spotTokenIndex), abi.encode(info));
    }

    /// @dev Program the PerpAssetInfo precompile (0x80A) for a hedge perp.
    /// `szDecimals` here drives the oracle price scaling: `rawPx = actualPrice * 10^(6-szDec)`.
    function _setPerpAssetInfo(uint32 perpIndex, uint8 szDec) internal {
        PrecompileReader.PerpAssetInfo memory info = PrecompileReader.PerpAssetInfo({
            coin: "MOCK",
            marginTableId: 0,
            szDecimals: szDec,
            maxLeverage: 50,
            onlyIsolated: false
        });
        mockPerpAssetInfo.setResponse(abi.encode(perpIndex), abi.encode(info));
    }

    /// @dev Convenience: configure a hedge pair + its decimals + balance + price
    /// using Hyperliquid-realistic values. Mirrors the most common test setup.
    /// @param humanPriceCents price expressed in USD cents (e.g. 600000 for $6,000)
    /// @param humanBalBps      balance in basis points of 1 token (e.g. 1000 = 0.1 token)
    function _configureHedge(
        uint32 spotTokenIndex,
        uint32 perpIndex,
        uint8 weiDec,
        uint8 szDec,
        uint256 humanPriceCents,
        uint256 humanBalBps
    ) internal {
        _setHedgeAsset(spotTokenIndex, perpIndex);
        _setTokenInfo(spotTokenIndex, weiDec, szDec);
        _setPerpAssetInfo(perpIndex, szDec);

        uint64 bal = uint64(humanBalBps * (10 ** weiDec) / 10000);
        // rawPx = actualPrice * 10^(6-szDec); actualPrice in 1e2 cents → humanPriceCents/100
        uint64 rawPx = uint64(humanPriceCents * (10 ** (uint256(6) - szDec)) / 100);
        _setSpotBalance(spotTokenIndex, bal);
        _setOraclePrice(uint16(perpIndex), rawPx);
    }

    // ─── Tests: totalBacking ─────────────────────────────────

    function test_totalBacking_sumsAllSources() public {
        _setEvmUsdc(100e6); // 100 USDC in EVM
        _setAccountValue(200e6); // 200 USDC in perp
        _setHlpEquity(50e6); // 50 USDC in HLP
        // 0.1 BTC (weiDecimals=8, szDecimals=5) @ $6,000 (fictitious low price for math).
        // Real Hyperliquid oracle returns `rawPx = actualPrice × 10^(6-szD)`.
        //   → rawPx = 6000 × 10^1 = 60_000
        _configureHedge({
            spotTokenIndex: 197, perpIndex: 0, weiDec: 8, szDec: 5,
            humanPriceCents: 600_000, humanBalBps: 1000
        });

        // spot NAV = 0.1 BTC × $6000 = $600 → 600e6 in 6dp USDC
        // Formula: (bal × rawPx) / 10^(weiDec - szDec) = (1e7 × 60_000) / 10^3 = 6e8 ✓
        // Total = 100 + 200 + 50 (HLP at mark) + 600 = 950 USDC
        assertEq(accountant.totalBacking(), 950e6);
    }

    /// @notice HLP MTM gains are recognized at full mark value (mark-to-market).
    /// Protocol design doc: HLP is the fallback strategy; the InsuranceFund buffers
    /// drawdowns, and unrealized gains flow into surplus / distributable yield.
    function test_totalBacking_hlpMarkToMarketGain() public {
        _setEvmUsdc(0);
        _setAccountValue(0);
        _setHlpEquity(120e6); // HLP mark value 120

        // HLP contribution = 120 (full mark, no cap)
        assertEq(accountant.totalBacking(), 120e6);
    }

    /// @notice HLP losses are recognized immediately at mark value (symmetric
    /// with gains — this drives debt recognition so surplus drops and blocks
    /// distributions until recovered).
    function test_totalBacking_hlpLossReducesBacking() public {
        _setEvmUsdc(0);
        _setAccountValue(0);
        _setHlpEquity(80e6); // HLP dropped to 80

        // HLP contribution = 80 (mark value)
        assertEq(accountant.totalBacking(), 80e6);
    }

    /// @notice Negative perp accountValue (e.g. liquidated position) must
    /// subtract from backing, not be clamped to zero.
    function test_totalBacking_negativeAccountValueReducesBacking() public {
        _setEvmUsdc(100e6);
        _setAccountValue(-30e6); // perp underwater by 30
        _setHlpEquity(50e6);

        // signed total = 100 + (-30) + 50 = 120
        // totalBacking clamps the signed view at 0 but the underlying value is positive
        assertEq(accountant.totalBacking(), 120e6);
    }

    /// @notice When perp liability exceeds all other assets, totalBackingSigned
    /// reports the true negative position. totalBacking() clamps to 0 (view safety).
    function test_totalBackingSigned_deeplyUnderwater() public {
        _setEvmUsdc(10e6);
        _setAccountValue(-50e6); // big liability
        _setHlpEquity(0);

        // signed = 10 + (-50) + 0 = -40
        assertEq(accountant.totalBackingSigned(), -40e6);
        // clamped view returns 0
        assertEq(accountant.totalBacking(), 0);
    }

    function test_totalBacking_noPrecompiles_returnsEvmOnly() public {
        _setEvmUsdc(500e6);
        // No precompile state set → all return 0
        assertEq(accountant.totalBacking(), 500e6);
    }

    // ─── Tests: surplus ──────────────────────────────────────

    function test_surplus_positive() public {
        _setEvmUsdc(1_000e6);
        _mintUsdm(900e6);
        assertEq(accountant.surplus(), int256(100e6));
    }

    function test_surplus_negative() public {
        _setEvmUsdc(800e6);
        _mintUsdm(1_000e6);
        assertEq(accountant.surplus(), -int256(200e6));
    }

    // ─── Tests: settleDailyPnL (new 4-gate model) ────────────

    function test_settleDailyPnL_requiresInitialized() public {
        vm.warp(block.timestamp + 21 hours);
        vm.prank(vault);
        vm.expectRevert("Accountant: not initialized");
        accountant.settleDailyPnL(1e6);
    }

    function test_settleDailyPnL_respectsMinInterval() public {
        _initializeBaseline(1_000e6, 1_000e6);
        _raiseCapForTests();
        // No warp → interval gate should reject
        vm.prank(vault);
        vm.expectRevert("Accountant: settlement too early");
        accountant.settleDailyPnL(1);
    }

    function test_settleDailyPnL_rejectsWhenNoDistributableSurplus() public {
        _initializeBaseline(1_000e6, 1_000e6);  // surplus = 0
        _raiseCapForTests();
        vm.warp(block.timestamp + 21 hours);

        vm.prank(vault);
        vm.expectRevert("Accountant: no distributable surplus");
        accountant.settleDailyPnL(1);
    }

    function test_settleDailyPnL_rejectsProposedAboveDistributable() public {
        _initializeBaseline(1_000e6, 900e6);  // surplus = 100, shortfall=0 → distributable=100
        _raiseCapForTests();
        vm.warp(block.timestamp + 21 hours);

        vm.prank(vault);
        vm.expectRevert("Accountant: exceeds distributable");
        accountant.settleDailyPnL(101e6);
    }

    function test_settleDailyPnL_rejectsAboveAnnualizedCap() public {
        // Large supply makes distributable loose, but APR cap at default 1500bps
        // on 21h elapsed clamps proposedYield tightly.
        _initializeBaseline(10_000_000e6, 9_000_000e6);
        vm.warp(block.timestamp + 21 hours);

        // cap = supply × 1500 × 75600 / (10000 × 365d) ≈ 35_958 × 10 USDC ≈ 359 USDC
        // Proposing 10_000 USDC is well over the APR cap.
        vm.prank(vault);
        vm.expectRevert("Accountant: exceeds annualized cap");
        accountant.settleDailyPnL(10_000e6);
    }

    function test_settleDailyPnL_happyPath_incrementsCumulative() public {
        // Supply 1M so the 5000bps/21h cap (~1200 USDC) comfortably covers 50 USDC
        _initializeBaseline(1_000_000e6, 999_900e6);  // surplus = 100
        _raiseCapForTests();
        vm.warp(block.timestamp + 21 hours);

        vm.prank(vault);
        uint256 distributable = accountant.settleDailyPnL(50e6);
        assertEq(distributable, 100e6, "distributable = 100");
        assertEq(accountant.totalSettledYield(), 50e6, "cumulative += proposed");
        assertEq(accountant.lastSettlementTime(), block.timestamp, "ts updated");
    }

    // ─── Tests: init ────────────────────────────────────────

    function test_initializeSettlement_cannotReinitialize() public {
        _initializeBaseline(1_000e6, 1_000e6);
        vm.prank(admin);
        vm.expectRevert("Accountant: already initialized");
        accountant.initializeSettlement();
    }

    function test_initializeSettlement_requiresConfig() public {
        MonetrixAccountant acctImpl2 = new MonetrixAccountant();
        ERC1967Proxy acctProxy2 = new ERC1967Proxy(
            address(acctImpl2),
            abi.encodeCall(MonetrixAccountant.initialize, (vault, address(usdc), address(usdm), address(acl)))
        );
        MonetrixAccountant fresh = MonetrixAccountant(address(acctProxy2));
        // Config deliberately not wired
        vm.prank(admin);
        vm.expectRevert("Accountant: config unset");
        fresh.initializeSettlement();
    }

    // ─── Tests: precompile fail-closed ───────────────────────
    //
    // These tests prove that a transient HyperCore RPC glitch cannot be
    // silently written into the ledger as a loss. Any critical read failure
    // must bubble up as a revert so the keeper simply retries in the next
    // settlement window.

    /// @notice Perp precompile outage → any backing read (including settle) must
    /// revert, not book a fake loss by treating the missing backing as zero.
    function test_perpReadFailure_settlementReverts() public {
        _setEvmUsdc(1_000e6);
        _setAccountValue(500e6);
        _mintUsdm(1_400e6);

        vm.prank(admin);
        accountant.initializeSettlement();

        // Simulate precompile outage
        vm.etch(HyperCoreConstants.PRECOMPILE_ACCOUNT_MARGIN_SUMMARY, address(new FailingPrecompile()).code);

        vm.warp(block.timestamp + 21 hours);
        vm.prank(vault);
        vm.expectRevert("PrecompileReader: perp account read failed");
        accountant.settleDailyPnL(1e6);
    }

    /// @notice Perp precompile returning malformed short data → revert.
    function test_perpReadMalformed_settlementReverts() public {
        _setEvmUsdc(1_000e6);
        _setAccountValue(500e6);
        _mintUsdm(1_400e6);

        vm.prank(admin);
        accountant.initializeSettlement();

        // Install a stub that returns empty bytes
        vm.etch(HyperCoreConstants.PRECOMPILE_ACCOUNT_MARGIN_SUMMARY, address(new EmptyPrecompile()).code);

        vm.warp(block.timestamp + 21 hours);
        vm.prank(vault);
        vm.expectRevert("PrecompileReader: perp account read failed");
        accountant.settleDailyPnL(1e6);
    }

    /// @notice HLP equity precompile outage → totalBacking revert. Under mark-to-market
    /// there is no short-circuit: the HLP precompile is read unconditionally and any
    /// staticcall failure is propagated (fail-closed).
    function test_hlpReadFailure_reverts() public {
        _setEvmUsdc(500e6);
        _setAccountValue(500e6);
        _setHlpEquity(200e6);

        // Baseline works
        assertEq(accountant.totalBacking(), 1_200e6);

        // Now knock out the HLP precompile
        vm.etch(HyperCoreConstants.PRECOMPILE_VAULT_EQUITY, address(new FailingPrecompile()).code);

        vm.expectRevert("PrecompileReader: vault equity read failed");
        accountant.totalBacking();
    }

    /// @notice Spot precompile outage → revert when tradeableAssets configured.
    function test_spotReadFailure_revertsWhenHedgeConfigured() public {
        _setEvmUsdc(500e6);
        _setAccountValue(500e6);
        _configureHedge({
            spotTokenIndex: 197, perpIndex: 0, weiDec: 8, szDec: 5,
            humanPriceCents: 600_000, humanBalBps: 1000
        });

        // Baseline works
        assertGt(accountant.totalBacking(), 1_000e6);

        vm.etch(HyperCoreConstants.PRECOMPILE_SPOT_BALANCE, address(new FailingPrecompile()).code);
        vm.expectRevert("PrecompileReader: spot balance read failed");
        accountant.totalBacking();
    }

    /// @notice Empty tradeableAssets → broken spot precompile is irrelevant.
    /// @notice No tradeable assets → oracle precompile not read, but spot USDC
    /// balance IS still read (L1 idle cash is always part of backing).
    function test_spotHedgeSkipped_whenNoTradeableAssets() public {
        _setEvmUsdc(1_000e6);
        _setAccountValue(500e6);
        // Do not set hedgeAssets — oracle can be broken, spot USDC still reads
        vm.etch(HyperCoreConstants.PRECOMPILE_ORACLE_PX, address(new FailingPrecompile()).code);

        assertEq(accountant.totalBacking(), 1_500e6);
    }

    /// @notice Oracle precompile outage → revert during totalBacking, even
    /// though the spot balance read succeeded.
    function test_oracleReadFailure_reverts() public {
        _setEvmUsdc(500e6);
        _setAccountValue(500e6);
        _configureHedge({
            spotTokenIndex: 197, perpIndex: 0, weiDec: 8, szDec: 5,
            humanPriceCents: 600_000, humanBalBps: 1000
        });

        // Baseline works
        assertGt(accountant.totalBacking(), 1_000e6);

        vm.etch(HyperCoreConstants.PRECOMPILE_ORACLE_PX, address(new FailingPrecompile()).code);
        vm.expectRevert("PrecompileReader: oracle px read failed");
        accountant.totalBacking();
    }

    /// @notice Oracle returning zero price is rejected as invalid (not silently
    /// multiplied to produce a zero NAV).
    function test_oracleZeroPrice_reverts() public {
        _setEvmUsdc(500e6);
        _setAccountValue(500e6);
        _setHedgeAsset(197, 0);
        _setSpotBalance(197, 1e7);
        _setOraclePrice(0, 0); // explicit zero price

        vm.expectRevert("PrecompileReader: oracle px zero");
        accountant.totalBacking();
    }

    /// @notice Recovery path: once the precompile comes back, surplus reads
    /// pick up correctly and settle() can proceed without booking a fake loss.
    function test_perpReadRecovery_noFakeLossAccumulated() public {
        _setEvmUsdc(1_000e6);
        _setAccountValue(500e6);
        _mintUsdm(1_400e6);  // surplus = (1000 + 500) - 1400 = 100

        vm.prank(admin);
        accountant.initializeSettlement();

        // Simulate outage → settlement attempt reverts
        vm.etch(HyperCoreConstants.PRECOMPILE_ACCOUNT_MARGIN_SUMMARY, address(new FailingPrecompile()).code);
        vm.warp(block.timestamp + 21 hours);
        vm.prank(vault);
        vm.expectRevert("PrecompileReader: perp account read failed");
        accountant.settleDailyPnL(1e6);

        // Recovery: install working mock again, same account value → surplus still 100
        MockPrecompile working = new MockPrecompile();
        vm.etch(HyperCoreConstants.PRECOMPILE_ACCOUNT_MARGIN_SUMMARY, address(working).code);
        _setAccountValue(500e6);
        assertEq(accountant.surplus(), int256(100e6), "surplus read recovers to 100");
    }

    // ─── helpers ─────────────────────────────────────────────

    function _initializeBaseline(uint256 evmAmount, uint256 usdmSupply) internal {
        _setEvmUsdc(evmAmount);
        _mintUsdm(usdmSupply);
        vm.prank(admin);
        accountant.initializeSettlement();
    }

    /// @dev Crank `maxAnnualYieldBps` to the hard cap so small test amounts
    /// don't unintentionally trip the annualized gate. Tests that specifically
    /// verify the APR gate should NOT call this.
    function _raiseCapForTests() internal {
        // Read constant first so the prank is consumed by setMaxAnnualYieldBps,
        // not by the nested constant lookup.
        uint256 cap = config.MAX_ANNUAL_YIELD_BPS_CAP();
        vm.prank(admin);
        config.setMaxAnnualYieldBps(cap);
    }

    // ─── Tests: Config V3 maxAnnualYieldBps ──────────────────

    function test_config_maxAnnualYieldBps_defaultAfterInit() public view {
        // Fresh initialize() sets maxAnnualYieldBps = 1200 (12% APR starting point)
        assertEq(config.maxAnnualYieldBps(), 1200);
    }

    function test_config_setMaxAnnualYieldBps_rejectsZero() public {
        vm.prank(admin);
        vm.expectRevert("Config: zero bps");
        config.setMaxAnnualYieldBps(0);
    }

    function test_config_setMaxAnnualYieldBps_rejectsAboveHardCap() public {
        uint256 cap = config.MAX_ANNUAL_YIELD_BPS_CAP();
        vm.prank(admin);
        vm.expectRevert("Config: exceeds hard cap");
        config.setMaxAnnualYieldBps(cap + 1);
    }

    function test_config_setMaxAnnualYieldBps_atHardCap_allowed() public {
        uint256 cap = config.MAX_ANNUAL_YIELD_BPS_CAP();
        vm.prank(admin);
        config.setMaxAnnualYieldBps(cap);
        assertEq(config.maxAnnualYieldBps(), cap);
    }

    function test_config_setMaxAnnualYieldBps_onlyGovernor() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert();
        config.setMaxAnnualYieldBps(1000);
    }

    // ─── Defensive / regression tests (gaps #1-#4) ───────────

    /// @notice Gap #1: only the bound Vault address may call settleDailyPnL.
    function test_settleDailyPnL_onlyVault_reverts() public {
        _initializeBaseline(1_000_000e6, 999_900e6);
        _raiseCapForTests();
        vm.warp(block.timestamp + 21 hours);

        vm.prank(address(0x9999));
        vm.expectRevert(MonetrixAccountant.NotVault.selector);
        accountant.settleDailyPnL(50e6);
    }

    /// @notice Gap #2: `totalSettledYield` accumulates across calls, not overwrites.
    ///         Without the `+=` semantics, a silent `=` bug would pass single-call tests.
    /// @dev via_ir caches `block.timestamp` across expressions in the same function —
    ///      use absolute timestamps to force each warp to actually advance.
    function test_settleDailyPnL_sequentialCalls_accumulate() public {
        _initializeBaseline(1_000_000e6, 999_700e6);  // surplus ≈ 300, lastSettlement = 1
        _raiseCapForTests();

        uint256 t1 = 1 + 21 hours;
        vm.warp(t1);
        vm.prank(vault);
        accountant.settleDailyPnL(50e6);
        assertEq(accountant.totalSettledYield(), 50e6, "after 1st");

        uint256 t2 = t1 + 21 hours;
        vm.warp(t2);
        vm.prank(vault);
        accountant.settleDailyPnL(30e6);
        assertEq(accountant.totalSettledYield(), 80e6, "after 2nd accumulates");

        uint256 t3 = t2 + 21 hours;
        vm.warp(t3);
        vm.prank(vault);
        accountant.settleDailyPnL(20e6);
        assertEq(accountant.totalSettledYield(), 100e6, "after 3rd continues");
    }

    /// @notice Gap #3a: YieldSettled payload must reflect keeper's proposedYield,
    ///         current distributable surplus, and running cumulative.
    function test_settleDailyPnL_emitsYieldSettled() public {
        _initializeBaseline(1_000_000e6, 999_900e6);  // surplus = 100
        _raiseCapForTests();
        vm.warp(block.timestamp + 21 hours);

        uint256 day = block.timestamp / 1 days;
        vm.expectEmit(true, false, false, true);
        emit MonetrixAccountant.YieldSettled(day, 40e6, 100e6, 40e6);

        vm.prank(vault);
        accountant.settleDailyPnL(40e6);
    }

    /// @notice Gap #3b: SettlementInitialized event fires with the current timestamp.
    function test_initializeSettlement_emitsEvent() public {
        vm.expectEmit(false, false, false, true);
        emit MonetrixAccountant.SettlementInitialized(block.timestamp);

        vm.prank(admin);
        accountant.initializeSettlement();
    }

    /// @notice Gap #3c: setMaxAnnualYieldBps emits event with the new value.
    function test_config_setMaxAnnualYieldBps_emitsEvent() public {
        vm.expectEmit(false, false, false, true);
        emit MonetrixConfig.MaxAnnualYieldBpsUpdated(1000);

        vm.prank(admin);
        config.setMaxAnnualYieldBps(1000);
    }

    /// @notice Gap #4: APR cap boundary — proposedYield exactly at cap passes;
    ///         one wei above reverts. Catches off-by-one in the rounding.
    /// @dev via_ir caches `block.timestamp`, so use absolute warps.
    function test_settleDailyPnL_annualizedCap_boundary() public {
        // Pick numbers so the cap math is exact: supply × 1500 × 75600 / (10000 × 365d).
        // Chose supply = 1_000_000e6 (1M USDM) so the cap is ≈ 359_589_041 wei.
        _initializeBaseline(1_100_000e6, 1_000_000e6);  // surplus = 100_000e6, lastSettlement = 1
        _raiseCapForTests();

        uint256 t1 = 1 + 21 hours;
        vm.warp(t1);

        // Compute the exact cap using the same formula as the contract.
        uint256 supply = usdm.totalSupply();
        uint256 elapsed = 21 hours;
        uint256 bps = config.MAX_ANNUAL_YIELD_BPS_CAP();
        uint256 cap = (supply * bps * elapsed) / (10_000 * 365 days);
        assertGt(cap, 0, "cap sanity");

        // Exactly at cap → passes.
        vm.prank(vault);
        accountant.settleDailyPnL(cap);
        assertEq(accountant.totalSettledYield(), cap, "at-cap accepted");

        // One wei above the fresh cap (same elapsed window) → rejects.
        // Warp another interval so the 20h interval gate passes.
        uint256 t2 = t1 + 21 hours;
        vm.warp(t2);
        uint256 cap2 = (usdm.totalSupply() * bps * 21 hours) / (10_000 * 365 days);
        vm.prank(vault);
        vm.expectRevert("Accountant: exceeds annualized cap");
        accountant.settleDailyPnL(cap2 + 1);
    }

    // ─── BTC (perpIndex=0) regression ────────────────────────

    function test_addMultisigSupplyToken_btc_registersPerpZero() public {
        vm.prank(admin);
        config.addTradeableAsset(
            MonetrixConfig.TradeableAsset({perpIndex: 0, spotIndex: 10003, spotPairAssetId: 20003})
        );

        vm.prank(keeper);
        accountant.addMultisigSupplyToken(10003);

        assertEq(accountant.multisigSuppliedLength(), 1);
        (uint64 spotToken, uint32 perpIndex) = accountant.multisigSupplied(0);
        assertEq(spotToken, 10003);
        assertEq(perpIndex, 0, "BTC perp=0 preserved through _resolvePerp");
    }

    function test_addMultisigSupplyToken_unwhitelisted_reverts() public {
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSignature("SpotNotWhitelisted(uint64)", uint64(10003)));
        accountant.addMultisigSupplyToken(10003);
    }
}

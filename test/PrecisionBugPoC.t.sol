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

/// @notice Mock precompile — returns pre-programmed bytes keyed by calldata.
contract PoCMockPrecompile {
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

contract PoCMockVault {
    address public multisigVault;
    address public redeemEscrow;
}

/// @title PrecisionBugPoC — proves `/1e10` in _readSpotAssetUsdc is wrong on real L1
/// @notice Background:
///         Hyperliquid's `oraclePx` precompile (0x807) returns prices in a
///         `10^(6 - szDecimals)`-scaled integer format, NOT 8-decimal.
///         For BTC-PERP (szDecimals=5), `$96036.0` is returned as `960360`,
///         i.e. `actualPrice × 10^1`. Docs and QuickNode worked example confirm
///         this: https://www.quicknode.com/guides/hyperliquid/read-hypercore-oracle-prices-in-hyperevm
///
///         Spot balances from 0x801 are in `weiDecimals`. For most HIP-1
///         tokens that's 8.
///
///         The correct notional formula:
///             notional_6dp_usdc = bal × rawPx / 10^(weiDecimals - szDecimals)
///
///         Current production code uses a hard-coded `/1e10`, which only
///         matches when `weiDecimals - szDecimals == 10`. No realistic
///         Hyperliquid asset satisfies this (USDC has diff=0, BTC has 3,
///         ETH/SOL 4-6 typically). Existing unit tests passed because they
///         injected a **fabricated** 8-dp oracle price (e.g. `$6000 → 6_000e8`)
///         which happens to cancel with /1e10 — but 8-dp oracle output would
///         require `szDecimals = -2` on L1 (impossible, it's uint8).
///
///         This PoC feeds the reader realistic BTC values as they appear on
///         Hyperliquid mainnet and shows the reader under-counts by ~10^7×.
contract PrecisionBugPoC is Test {
    MonetrixAccountant accountant;
    MonetrixConfig config;
    USDM usdm;
    MockUSDC usdc;
    PoCMockVault mockVault;
    MonetrixAccessController acl;

    PoCMockPrecompile mockSpotBalance;
    PoCMockPrecompile mockOraclePx;

    address admin = address(0xAD);
    address vault;

    // ─── Realistic Hyperliquid BTC constants ─────────────────────
    // (Cross-checked against Hyperliquid docs + QuickNode guide)

    uint32 constant BTC_PERP_INDEX = 0;
    uint32 constant BTC_SPOT_INDEX = 142;         // arbitrary, any HIP-1 token index works
    uint32 constant BTC_PAIR_ASSET_ID = 10142;    // 10000 + pair_index; used by HL spot order path

    uint8 constant BTC_WEI_DECIMALS = 8;    // L1 balance is 8-dp (matches native BTC)
    uint8 constant BTC_SZ_DECIMALS  = 5;    // lot size 10^(8-5) = 1e3 wei = 0.00001 BTC

    // 0.1 BTC on L1, in weiDecimals (8dp):
    uint64 constant BTC_BAL_01 = 1e7; // 0.1 × 10^8

    // $96,036.0 — realistic mainnet BTC price.
    // Format: rawPx = actualPrice × 10^(6 - szDecimals) = 96036 × 10^1 = 960360
    uint64 constant BTC_RAW_PX_96036 = 960360;

    // Correct answer: 0.1 BTC × $96,036 = $9,603.6 USDC
    // In 6-decimal USDC: 9,603.6 × 10^6 = 9_603_600_000
    uint256 constant EXPECTED_NOTIONAL_6DP = 9_603_600_000;

    function setUp() public {
        vm.startPrank(admin);

        usdc = new MockUSDC();
        mockVault = new PoCMockVault();
        vault = address(mockVault);

        acl = MonetrixAccessController(address(new ERC1967Proxy(
            address(new MonetrixAccessController()),
            abi.encodeCall(MonetrixAccessController.initialize, (admin))
        )));

        usdm = USDM(address(new ERC1967Proxy(
            address(new USDM()),
            abi.encodeCall(USDM.initialize, (address(acl)))
        )));

        accountant = MonetrixAccountant(address(new ERC1967Proxy(
            address(new MonetrixAccountant()),
            abi.encodeCall(MonetrixAccountant.initialize, (vault, address(usdc), address(usdm), address(acl)))
        )));

        config = MonetrixConfig(address(new ERC1967Proxy(
            address(new MonetrixConfig()),
            abi.encodeCall(MonetrixConfig.initialize, (address(0x1), address(0x2), address(acl)))
        )));

        acl.grantRole(acl.GOVERNOR(), admin);
        usdm.setVault(admin);
        accountant.setConfig(address(config));

        // Install mock precompiles via vm.etch. After the TokenMath migration,
        // 7 readers are reachable from _readL1Backing (+ tokenInfo + perpAssetInfo
        // for the decimals lookup). Fail-closed readers revert if any responds
        // empty, so all 7 must be etched.
        address[7] memory addrs = [
            HyperCoreConstants.PRECOMPILE_SPOT_BALANCE,
            HyperCoreConstants.PRECOMPILE_ORACLE_PX,
            HyperCoreConstants.PRECOMPILE_ACCOUNT_MARGIN_SUMMARY,
            HyperCoreConstants.PRECOMPILE_VAULT_EQUITY,
            HyperCoreConstants.PRECOMPILE_SUPPLIED_BALANCE,
            HyperCoreConstants.PRECOMPILE_TOKEN_INFO,
            HyperCoreConstants.PRECOMPILE_PERP_ASSET_INFO
        ];
        for (uint256 i = 0; i < addrs.length; i++) {
            vm.etch(addrs[i], address(new PoCMockPrecompile()).code);
        }
        mockSpotBalance = PoCMockPrecompile(payable(HyperCoreConstants.PRECOMPILE_SPOT_BALANCE));
        mockOraclePx = PoCMockPrecompile(payable(HyperCoreConstants.PRECOMPILE_ORACLE_PX));

        // Register BTC as a tradeable hedge asset.
        config.addTradeableAsset(MonetrixConfig.TradeableAsset({
            perpIndex: BTC_PERP_INDEX,
            spotIndex: BTC_SPOT_INDEX,
            spotPairAssetId: BTC_PAIR_ASSET_ID
        }));

        // Seed the mocks with REALISTIC Hyperliquid BTC values:
        //   spotBalance(vault, BTC_SPOT_INDEX) → { total: 1e7, hold: 0, entryNtl: 0 }
        bytes memory sbKey = abi.encode(vault, uint64(BTC_SPOT_INDEX));
        bytes memory sbResp = abi.encode(uint64(BTC_BAL_01), uint64(0), uint64(0));
        mockSpotBalance.setResponse(sbKey, sbResp);

        //   oraclePx(BTC_PERP_INDEX) → 960360 (= $96036 × 10^(6-5))
        bytes memory opKey = abi.encode(uint32(BTC_PERP_INDEX));
        bytes memory opResp = abi.encode(uint64(BTC_RAW_PX_96036));
        mockOraclePx.setResponse(opKey, opResp);

        //   tokenInfo(BTC_SPOT_INDEX) → (weiDecimals=8, szDecimals=5, evmExtra=0, …)
        PrecompileReader.TokenInfo memory ti = PrecompileReader.TokenInfo({
            name: "UBTC",
            spots: new uint64[](0),
            deployerTradingFeeShare: 0,
            deployer: address(0),
            evmContract: address(0),
            szDecimals: BTC_SZ_DECIMALS,
            weiDecimals: BTC_WEI_DECIMALS,
            evmExtraWeiDecimals: 0
        });
        bytes memory tiKey = abi.encode(uint32(BTC_SPOT_INDEX));
        bytes memory tiResp = abi.encode(ti);
        PoCMockPrecompile(payable(HyperCoreConstants.PRECOMPILE_TOKEN_INFO))
            .setResponse(tiKey, tiResp);

        //   perpAssetInfo(BTC_PERP_INDEX) → szDecimals=5 (matches docs BTC price fmt)
        PrecompileReader.PerpAssetInfo memory pi = PrecompileReader.PerpAssetInfo({
            coin: "BTC",
            marginTableId: 0,
            szDecimals: BTC_SZ_DECIMALS,
            maxLeverage: 50,
            onlyIsolated: false
        });
        bytes memory piKey = abi.encode(uint32(BTC_PERP_INDEX));
        bytes memory piResp = abi.encode(pi);
        PoCMockPrecompile(payable(HyperCoreConstants.PRECOMPILE_PERP_ASSET_INFO))
            .setResponse(piKey, piResp);

        vm.stopPrank();
    }

    // ─── Sanity: self-consistency of test inputs ─────────────────

    /// Demonstrate that our BTC input values reproduce the QuickNode worked
    /// example: raw 960360 at szDecimals=5 → $96,036.00.
    function test_sanity_priceFormatMatchesDocs() public pure {
        uint256 rawPx = BTC_RAW_PX_96036;
        uint8 szD = BTC_SZ_DECIMALS;
        uint256 humanPriceCents = (rawPx * 100) / (10 ** (6 - szD));
        assertEq(humanPriceCents, 9_603_600, "BTC@$96036.00 = 9_603_600 cents");
    }

    /// Demonstrate the CORRECT notional formula arrives at 9603.6 USDC.
    function test_sanity_correctFormulaArrivesAtExpected() public pure {
        uint256 bal = BTC_BAL_01;
        uint256 rawPx = BTC_RAW_PX_96036;
        uint8 w = BTC_WEI_DECIMALS;
        uint8 sz = BTC_SZ_DECIMALS;
        // notional_6dp_usdc = bal × rawPx / 10^(w - sz)
        uint256 correct = (bal * rawPx) / (10 ** (uint256(w) - uint256(sz)));
        assertEq(correct, EXPECTED_NOTIONAL_6DP, "correct formula = 9603.6e6");
    }

    // ─── REGRESSION TESTS — pins that the fix matches the correct value ──

    /// @notice Post-fix: totalBacking reports the correct 6-dp USDC value of a
    ///         0.1 BTC spot hedge priced at $96,036.
    ///
    ///         Historical context: pre-fix code used `(bal × rawPx) / 1e10`,
    ///         which assumed `weiDecimals − szDecimals == 10`. Realistic BTC
    ///         has `weiDecimals=8, szDecimals=5 → divisor = 10^3`. The old
    ///         code returned **960** (= $0.00096) for a $9603.60 position —
    ///         an ~10^7 under-count. See commit history + commit message.
    ///
    ///         This test now pins the CORRECT behavior via TokenMath. If the
    ///         pre-fix `/1e10` ever resurfaces, this test turns RED.
    function test_REGRESSION_spotHedgeValuedCorrectly() public view {
        uint256 backing = accountant.totalBacking();
        assertEq(backing, EXPECTED_NOTIONAL_6DP, "backing = 0.1 BTC x $96036 = $9603.60");
    }

    /// @notice Surplus stays healthy when hedge is fully backed: minting 1000
    ///         USDM against a $9603.60 BTC hedge leaves ~$8603.60 of surplus.
    ///
    ///         Under the pre-fix bug this would have been ~-$1000 (hedge read
    ///         as near-zero), blocking every distributeYield call.
    function test_REGRESSION_surplusPositiveWithHedgedObligations() public {
        vm.prank(admin);
        usdm.mint(address(this), 1_000e6); // 1000 USDM obligation
        int256 surplus = accountant.surplus();
        // 9603.60 - 1000 = 8603.60 → 8_603_600_000 in 6dp
        assertEq(surplus, 8_603_600_000, "surplus should be hedgeValue - usdmSupply");
    }

    /// @notice Explicit off-by-factor pin: the old `/1e10` formula returns
    ///         a specific wrong value that we can compute independently.
    ///         Showing these are DIFFERENT proves the fix changed behavior.
    function test_REGRESSION_oldFormulaWouldHaveReturned960() public pure {
        uint256 oldBuggyValue = (uint256(BTC_BAL_01) * uint256(BTC_RAW_PX_96036)) / 1e10;
        assertEq(oldBuggyValue, 960, "pre-fix code would have returned 960 (~$0.00096)");
        assertTrue(oldBuggyValue * 10_000_000 < EXPECTED_NOTIONAL_6DP, "off by >= 10^7x");
    }
}

// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {IEVault, IVault, IERC4626} from "euler-vault-kit/EVault/IEVault.sol";
import {IEVC} from "ethereum-vault-connector/interfaces/IEthereumVaultConnector.sol";
import {AssetZap} from "src/Periphery/AssetZap.sol";
import {IAaveV3ATokenWrapper} from "src/interfaces/IAaveV3ATokenWrapper.sol";
import {IErrors} from "src/interfaces/IErrors.sol";
import {AssetZapFrontendHelper} from "../AssetZapFrontendHelper.sol";

interface IWstETH {
    function getWstETHByStETH(uint256) external view returns (uint256);
}

interface IStandardizedYield {
    function getTokensIn() external view returns (address[] memory);
}

interface IPendleMarket {
    function readTokens() external view returns (address sy, address pt, address yt);
}

// --- Pendle Router V4 types (enums encoded as uint8 so the ABI selector matches Pendle) ---
struct PendleApproxParams {
    uint256 guessMin;
    uint256 guessMax;
    uint256 guessOffchain;
    uint256 maxIteration;
    uint256 eps;
}

struct PendleSwapData {
    uint8 swapType; // 0 = NONE (no external aggregator)
    address extRouter;
    bytes extCalldata;
    bool needScale;
}

struct PendleTokenInput {
    address tokenIn;
    uint256 netTokenIn;
    address tokenMintSy;
    address pendleSwap;
    PendleSwapData swapData;
}

struct PendleOrder {
    uint256 salt;
    uint256 expiry;
    uint256 nonce;
    uint8 orderType;
    address token;
    address YT;
    address maker;
    address receiver;
    uint256 makingAmount;
    uint256 lnImpliedRate;
    uint256 failSafeRate;
    bytes permit;
}

struct PendleFillOrderParams {
    PendleOrder order;
    bytes signature;
    uint256 makingAmount;
}

struct PendleLimitOrderData {
    address limitRouter;
    uint256 epsSkipMarket;
    PendleFillOrderParams[] normalFills;
    PendleFillOrderParams[] flashFills;
    bytes optData;
}

interface IPendleRouter {
    function swapExactTokenForPt(
        address receiver,
        address market,
        uint256 minPtOut,
        PendleApproxParams calldata guessPtOut,
        PendleTokenInput calldata input,
        PendleLimitOrderData calldata limit
    ) external payable returns (uint256 netPtOut, uint256 netSyFee, uint256 netSyInterm);
}

/// @dev Generic-handler target: refunds the input to `refundTo` and pays a pre-funded output to `outTo`.
contract MockSwapTarget {
    function go(address tokenIn, uint256 amountIn, address tokenOut, uint256 amountOut, address refundTo, address outTo)
        external
    {
        IERC20(tokenIn).transferFrom(msg.sender, refundTo, amountIn);
        IERC20(tokenOut).transfer(outTo, amountOut);
    }
}

/// @notice Live-mainnet fork tests for AssetZap against the deployed Twyne intermediate vaults.
/// @dev Runs against a mainnet fork; generic swaps route through the real EVK Swapper.
contract AssetZapTest is Test {
    // Twyne core (public launch, chainId 1)
    address constant EVC = 0xef39D6493884C4C84D38a4bFF879Ce16CEdE702a;
    IEVault constant IV_EULER_WETH = IEVault(0x87b8081A3ace680f35125F469526Ac10f5418Ca7);
    IEVault constant IV_EULER_WSTETH = IEVault(0x7613D202Af490c3d1cE1873b0a7022a34E89815f);
    IEVault constant IV_AAVE_WSTETH = IEVault(0x75029a47f28550C93Ad5A3BbD2d9b5315204B561);
    IEVault constant IV_AAVE_PT_SRUSDE = IEVault(0x79CF33e623555E899d4EE122b9BfA0214fa5A4A1);

    // External protocol addresses
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address constant USDE = 0x4c9EDD5852cd905f086C759E8383e09bff1E68B3;
    address constant PT_SRUSDE = 0x59bC9FaE5D62B19d4f8d07D758047aCb9EE19d34;
    address constant SRUSDE = 0x3d7d6fdf07EE548B939A80edbc9B2256d0cdc003;
    address constant PENDLE_ROUTER = 0x888888888889758F76e7103c6CbF23ABbF58F946;
    address constant PENDLE_MARKET_SRUSDE = 0x66Ec657C59cdcaf171aB43B83da3942758bF8a97;
    // Euler EVK Swapper singleton
    address constant EVK_SWAPPER = 0x2Bba09866b6F1025258542478C39720A09B728bF;
    // USDe whale used to fund test accounts (sUSDe staking contract)
    address constant SUSDE = 0x9D39A5DE30e57443BfF2A8307A4256c8797A3497;
    // Pin the fork so live-AMM (Pendle) swaps are deterministic. PT-srUSDe is active at this block (expiry 2026-10-22).
    uint256 constant MAINNET_FORK_BLOCK = 25702611;

    AssetZap assetZap;
    MockSwapTarget mockTarget;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address attacker = makeAddr("attacker");

    function setUp() public {
        vm.rollFork(MAINNET_FORK_BLOCK);
        assetZap = new AssetZap(EVC, EVK_SWAPPER);
        mockTarget = new MockSwapTarget();

        // On a mainnet fork, makeAddr() can collide with LIVE contracts; force clean EOAs.
        address[3] memory actors = [alice, bob, attacker];
        for (uint256 i; i < actors.length; ++i) {
            vm.etch(actors[i], "");
            vm.deal(actors[i], 0);
        }
        vm.deal(address(assetZap), 0);

        vm.label(address(assetZap), "AssetZap");
        vm.label(EVK_SWAPPER, "EVKSwapper");
        vm.label(WSTETH, "wstETH");
        vm.label(USDE, "USDe");
        vm.label(PT_SRUSDE, "PT-srUSDe");
    }

    // --- helpers ---

    function _fundUSDe(address to, uint256 amount) internal {
        // deal() is unreliable for USDe's storage layout — transfer from the sUSDe contract's balance
        vm.prank(SUSDE);
        IERC20(USDE).transfer(to, amount);
    }

    function _emptyLimit() internal pure returns (PendleLimitOrderData memory limit) {
        // AMM-only fallback; production calldata carries signed order-book fills from the Pendle SDK
    }

    function _defaultGuess() internal pure returns (PendleApproxParams memory) {
        return PendleApproxParams({guessMin: 0, guessMax: type(uint256).max, guessOffchain: 0, maxIteration: 256, eps: 1e14});
    }

    function _assertNoResidue(address token) internal view {
        assertEq(IERC20(token).balanceOf(address(assetZap)), 0, "AssetZap must hold no tokens after a zap");
        assertEq(address(assetZap).balance, 0, "AssetZap must hold no ETH after a zap");
    }

    function _pickTokenMintSy(address sy) internal view returns (address) {
        address[] memory tokensIn = IStandardizedYield(sy).getTokensIn();
        for (uint256 i; i < tokensIn.length; ++i) {
            if (tokensIn[i] == USDE) return USDE;
        }
        return SRUSDE;
    }

    // --- happy paths ---

    function test_wstEthDirect_noSwap() public {
        // Acquire wstETH the honest way (stake), then zap it with no swap
        vm.deal(alice, 2 ether);
        vm.prank(alice);
        (bool ok,) = WSTETH.call{value: 1 ether}("");
        assertTrue(ok);
        uint256 wstEthBal = IERC20(WSTETH).balanceOf(alice);

        vm.startPrank(alice);
        IERC20(WSTETH).approve(address(assetZap), wstEthBal);
        assetZap.zapUnderlying(WSTETH, wstEthBal, address(IV_EULER_WSTETH), IERC4626(IV_EULER_WSTETH.asset()).convertToShares(wstEthBal) * 99 / 100);
        uint256 shares = IV_EULER_WSTETH.skim(type(uint).max, alice);
        vm.stopPrank();

        assertGt(shares, 0);
        assertEq(IV_EULER_WSTETH.balanceOf(alice), shares);

        _assertNoResidue(WSTETH);
    }

    function test_usdeToPt_viaSwapper_aaveIV() public {
        uint256 amountIn = 10_000e18;
        _fundUSDe(alice, amountIn);

        (address sy,,) = IPendleMarket(PENDLE_MARKET_SRUSDE).readTokens();
        address tokenMintSy = _pickTokenMintSy(sy);

        bytes memory pendlePayload = abi.encodeCall(
            IPendleRouter.swapExactTokenForPt,
            (
                IV_AAVE_PT_SRUSDE.asset(), // PT lands directly at the wrapper; next step skims it
                PENDLE_MARKET_SRUSDE,
                0,
                _defaultGuess(),
                PendleTokenInput({
                    tokenIn: USDE,
                    netTokenIn: amountIn,
                    tokenMintSy: tokenMintSy,
                    pendleSwap: address(0),
                    swapData: PendleSwapData({swapType: 0, extRouter: address(0), extCalldata: "", needScale: false})
                }),
                _emptyLimit()
            )
        );
        bytes[] memory step1 = AssetZapFrontendHelper.genericSwap(USDE, PT_SRUSDE, PENDLE_ROUTER, pendlePayload);
        bytes[] memory step2 = AssetZapFrontendHelper.genericSwap(
            PT_SRUSDE, IV_AAVE_PT_SRUSDE.asset(), IV_AAVE_PT_SRUSDE.asset(),
            abi.encodeCall(IAaveV3ATokenWrapper.skim, (address(assetZap)))
        );
        bytes[] memory swapData = new bytes[](2);
        swapData[0] = step1[0];
        swapData[1] = step2[0];

        vm.startPrank(alice);
        IERC20(USDE).approve(address(assetZap), amountIn);
        assetZap.zap(USDE, amountIn, swapData, address(IV_AAVE_PT_SRUSDE), IERC4626(IV_AAVE_PT_SRUSDE.asset()).convertToShares(amountIn * 95 / 100));
        uint256 shares = IV_AAVE_PT_SRUSDE.skim(type(uint).max, alice);
        vm.stopPrank();

        assertGt(shares, 0);
        assertEq(IV_AAVE_PT_SRUSDE.balanceOf(alice), shares);
        address wrapper = IV_AAVE_PT_SRUSDE.asset();
        uint256 ptDeposited = IAaveV3ATokenWrapper(wrapper).convertToAssets(IV_AAVE_PT_SRUSDE.convertToAssets(shares));
        assertGt(ptDeposited, amountIn * 97 / 100, "PT out sane vs USDe in");
        _assertNoResidue(USDE);
        _assertNoResidue(PT_SRUSDE);
    }

    function test_sweep_viaSwapper_residualInputRefunded() public {
        // Fund the mock target's output side with staked wstETH
        vm.deal(address(this), 1 ether);
        (bool ok,) = WSTETH.call{value: 1 ether}("");
        assertTrue(ok);
        uint256 routerWstEth = IERC20(WSTETH).balanceOf(address(this));
        IERC20(WSTETH).transfer(address(mockTarget), routerWstEth);

        uint256 amountIn = 1_000e18;
        _fundUSDe(alice, amountIn);

        // Refund the input back to AssetZap (so zap's sweep returns it to the caller) and route the wstETH
        // output to the Swapper, which sweeps it to the IV's wrapper and skims it into wrapper shares for AssetZap.
        bytes memory payload = abi.encodeCall(
            MockSwapTarget.go, (USDE, amountIn, WSTETH, routerWstEth, address(assetZap), EVK_SWAPPER)
        );
        bytes[] memory step0 = AssetZapFrontendHelper.genericSwap(USDE, WSTETH, address(mockTarget), payload);
        bytes[] memory wrap = AssetZapFrontendHelper.depositViaSkim(WSTETH, IV_EULER_WSTETH.asset(), address(assetZap));
        bytes[] memory swapData = new bytes[](3);
        swapData[0] = step0[0];
        swapData[1] = wrap[0];
        swapData[2] = wrap[1];

        vm.startPrank(alice);
        IERC20(USDE).approve(address(assetZap), amountIn);
        assetZap.zap(USDE, amountIn, swapData, address(IV_EULER_WSTETH), IERC4626(IV_EULER_WSTETH.asset()).convertToShares(routerWstEth) * 99 / 100);
        uint256 shares = IV_EULER_WSTETH.skim(type(uint).max, alice);
        vm.stopPrank();

        assertGt(shares, 0);
        assertEq(IERC20(USDE).balanceOf(alice), amountIn, "input refunded back to caller via the sweep");
        _assertNoResidue(USDE);
        _assertNoResidue(WSTETH);
    }

    function test_zapViaEvcCall() public {
        // EVCUtil._msgSender must unwrap the EVC-routed caller so shares land with the real account.
        // wstETH is delivered to AssetZap ahead of the EVC-routed zap (airdrop mode, no value).
        vm.deal(address(this), 1 ether);
        (bool ok,) = WSTETH.call{value: 1 ether}("");
        assertTrue(ok);
        uint256 delivered = IERC20(WSTETH).balanceOf(address(this));
        IERC20(WSTETH).transfer(address(assetZap), delivered);

        bytes memory data = abi.encodeCall(AssetZap.zapUnderlying, (WSTETH, 0, address(IV_EULER_WSTETH), IERC4626(IV_EULER_WSTETH.asset()).convertToShares(delivered) * 99 / 100));

        vm.prank(alice);
        IEVC(EVC).call(address(assetZap), alice, 0, data);

        IV_EULER_WSTETH.skim(type(uint).max, alice);

        assertGt(IV_EULER_WSTETH.balanceOf(alice), 0, "shares credited to the EVC-routed caller");
        _assertNoResidue(WSTETH);
    }

    // --- reverts & attacks ---

    function test_attack_wstEthWithCalldata_blocked() public {
        // The wstETH contract is only ever called with empty calldata (the direct stake). Attacker-controlled
        // swapData routes to the trusted SWAPPER, never to wstETH — so it cannot drain a third party that approved
        // AssetZap. Bob approves AssetZap for his wstETH, but the attacker (not Bob) is the _msgSender, so AssetZap
        // only ever pulls from the attacker, and the malicious swapData runs in SWAPPER's sandbox.
        vm.deal(bob, 2 ether);
        vm.prank(bob);
        (bool ok,) = WSTETH.call{value: 1 ether}("");
        assertTrue(ok);
        uint256 bobWstEth = IERC20(WSTETH).balanceOf(bob);
        vm.prank(bob);
        IERC20(WSTETH).approve(address(assetZap), type(uint256).max);

        bytes[] memory swapData = new bytes[](1);
        swapData[0] = abi.encodeCall(IERC20.transferFrom, (bob, attacker, bobWstEth));

        vm.prank(attacker);
        // The trusted SWAPPER only routes valid swap calldata, so it rejects the transferFrom selector (observed
        // custom error 0x2082e200 on-chain) — the attacker's call never reaches the wstETH token as a call from
        // AssetZap, so Bob's approval is never spent.
        vm.expectRevert();
        assetZap.zap(WSTETH, 0, swapData, address(IV_EULER_WSTETH), 0);
        assertEq(IERC20(WSTETH).balanceOf(bob), bobWstEth, "victim wstETH untouched by attacker calldata");
        assertEq(IERC20(WSTETH).balanceOf(attacker), 0, "attacker gains nothing");
    }

    function test_revert_minAmountOut() public {
        // Fund AssetZap with the destination's vaultAsset (eulerWETH), then demand one unit more than the
        // zap can transfer: the slippage guard must revert with T_MinAmountOut.
        vm.deal(address(this), 1 ether);
        (bool ok,) = WETH.call{value: 1 ether}("");
        require(ok, "weth wrap failed");
        address vaultAsset = IV_EULER_WETH.asset(); // eulerWETH
        IERC20(WETH).approve(vaultAsset, 1 ether);
        uint256 held = IEVault(vaultAsset).deposit(1 ether, address(assetZap));

        vm.prank(alice);
        vm.expectRevert(IErrors.T_MinAmountOut.selector);
        assetZap.zap(vaultAsset, 0, new bytes[](0), address(IV_EULER_WETH), held + 1);
    }

    function test_revert_inputIsUnderlying() public {
        // Supplying swapData when tokenIn is already the targetAsset is a misuse: no swap is needed, so the zap
        // reverts (T_InputIsUnderlying) before routing anything through the Swapper. Here tokenIn is eulerWETH,
        // the IV's own asset (targetAsset), so any non-empty swapData trips the guard.
        vm.deal(address(this), 1 ether);
        (bool ok,) = WETH.call{value: 1 ether}("");
        require(ok, "weth wrap failed");
        address targetAsset = IV_EULER_WETH.asset(); // eulerWETH
        IERC20(WETH).approve(targetAsset, 1 ether);
        uint256 wrapperShares = IEVault(targetAsset).deposit(1 ether, address(this));
        IERC20(targetAsset).transfer(address(assetZap), wrapperShares);

        bytes[] memory swapData = AssetZapFrontendHelper.depositViaSkim(WETH, targetAsset, address(assetZap));

        vm.prank(alice);
        vm.expectRevert(IErrors.T_InputIsUnderlying.selector);
        assetZap.zap(targetAsset, 0, swapData, address(IV_EULER_WETH), 1);
    }

    // ---------------------------------------------------------------------------------------------
    // zapUnderlying: convenience path for depositing the wrapper's underlying directly (no SWAPPER route).
    // ---------------------------------------------------------------------------------------------

    function test_zapUnderlying_pullMode_eulerWETH() public {
        // Alice wraps ETH -> WETH herself, then zapUnderlying pulls it, deposits into the eulerWETH inner
        // wrapper, and airdrops the wrapper shares to the IV; the skim mints IV shares to alice.
        uint256 amountIn = 1 ether;
        vm.deal(alice, amountIn);
        vm.startPrank(alice);
        (bool ok,) = WETH.call{value: amountIn}("");
        require(ok, "weth wrap failed");
        IERC20(WETH).approve(address(assetZap), amountIn);

        address wrapper = IV_EULER_WETH.asset(); // eulerWETH inner; underlying is WETH
        uint256 minOut = IERC4626(wrapper).convertToShares(amountIn) * 99 / 100;
        assetZap.zapUnderlying(WETH, amountIn, address(IV_EULER_WETH), minOut);
        uint256 shares = IV_EULER_WETH.skim(type(uint).max, alice);
        vm.stopPrank();

        assertGt(shares, 0, "IV shares credited to alice");
        assertEq(IV_EULER_WETH.balanceOf(alice), shares);
        assertEq(IERC20(wrapper).balanceOf(address(assetZap)), 0, "AssetZap holds no wrapper shares");
        _assertNoResidue(WETH);
    }

    function test_zapUnderlying_airdropMode_wstEth() public {
        // wstETH delivered to AssetZap ahead of the call (airdrop mode, amountIn == 0).
        vm.deal(address(this), 1 ether);
        (bool ok,) = WSTETH.call{value: 1 ether}("");
        assertTrue(ok);
        uint256 wstEthBal = IERC20(WSTETH).balanceOf(address(this));
        IERC20(WSTETH).transfer(address(assetZap), wstEthBal);

        address wrapper = IV_EULER_WSTETH.asset(); // eulerWSTETH inner; underlying is wstETH
        uint256 minOut = IERC4626(wrapper).convertToShares(wstEthBal) * 99 / 100;
        vm.prank(alice);
        assetZap.zapUnderlying(WSTETH, 0, address(IV_EULER_WSTETH), minOut);
        uint256 shares = IV_EULER_WSTETH.skim(type(uint).max, alice);

        assertGt(shares, 0, "IV shares credited to caller");
        assertEq(IV_EULER_WSTETH.balanceOf(alice), shares);
        assertEq(IERC20(wrapper).balanceOf(address(assetZap)), 0, "AssetZap holds no wrapper shares");
        _assertNoResidue(WSTETH);
    }

    function test_zapUnderlying_aaveWrapper() public {
        // Aave wstETH IV: wrapper is an AaveV3ATokenWrapper whose underlying is wstETH. The uniform
        // IERC4626.deposit path handles it without any family-specific skim calldata.
        uint256 amountIn = 1 ether;
        vm.deal(address(this), amountIn);
        (bool ok,) = WSTETH.call{value: amountIn}("");
        assertTrue(ok);
        uint256 wstEthBal = IERC20(WSTETH).balanceOf(address(this));
        IERC20(WSTETH).transfer(alice, wstEthBal);

        vm.startPrank(alice);
        IERC20(WSTETH).approve(address(assetZap), wstEthBal);
        address wrapper = IV_AAVE_WSTETH.asset();
        uint256 minOut = IERC4626(wrapper).convertToShares(wstEthBal) * 99 / 100;
        assetZap.zapUnderlying(WSTETH, wstEthBal, address(IV_AAVE_WSTETH), minOut);
        uint256 shares = IV_AAVE_WSTETH.skim(type(uint).max, alice);
        vm.stopPrank();

        assertGt(shares, 0, "IV shares credited to alice");
        assertEq(IV_AAVE_WSTETH.balanceOf(alice), shares);
        assertEq(IERC20(wrapper).balanceOf(address(assetZap)), 0, "AssetZap holds no wrapper shares");
        _assertNoResidue(WSTETH);
    }

    function test_zapUnderlying_revert_notUnderlying() public {
        // tokenIn (USDe) is not the eulerWETH wrapper's underlying (WETH) -> T_NotUnderlying.
        vm.prank(alice);
        vm.expectRevert(IErrors.T_NotUnderlying.selector);
        assetZap.zapUnderlying(USDE, 0, address(IV_EULER_WETH), 0);
    }

    function test_zapUnderlying_revert_minAmountOut() public {
        // Airdrop WETH to AssetZap, then demand one more wrapper share than the deposit mints.
        vm.deal(address(this), 1 ether);
        (bool ok,) = WETH.call{value: 1 ether}("");
        require(ok, "weth wrap failed");
        IERC20(WETH).transfer(address(assetZap), 1 ether);

        address wrapper = IV_EULER_WETH.asset();
        uint256 shares = IERC4626(wrapper).convertToShares(1 ether);
        vm.prank(alice);
        vm.expectRevert(IErrors.T_MinAmountOut.selector);
        assetZap.zapUnderlying(WETH, 0, address(IV_EULER_WETH), shares + 1);
    }
}

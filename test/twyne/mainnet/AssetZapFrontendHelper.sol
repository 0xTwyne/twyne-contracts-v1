// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.28;

import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {IVault} from "euler-vault-kit/EVault/IEVault.sol";
import {WstethHandler} from "src/operators/handlers/WstethHandler.sol";

interface ISwapper {
    struct SwapParams {
        bytes32 handler;
        uint256 mode;
        address account;
        address tokenIn;
        address tokenOut;
        address vaultIn;
        address accountIn;
        address receiver;
        uint256 amountOut;
        bytes data;
    }

    function swap(SwapParams calldata params) external;

    function sweep(address token, uint256 amountMin, address to) external;
}

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

/// @notice Shared types + pure helpers for the Aave / Euler frontend asset-zap reference tests.
/// @dev Mainnet (chainId 1) addresses only. A library (not a base contract) so its constants/helpers are
///      accessed as `AssetZapFrontendHelper.x` and never clash with MainnetBase state vars (WETH, WSTETH, ...).
library AssetZapFrontendHelper {
    // External protocol addresses (Ethereum mainnet)
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address internal constant USDE = 0x4c9EDD5852cd905f086C759E8383e09bff1E68B3;
    address internal constant PT_SRUSDE = 0x59bC9FaE5D62B19d4f8d07D758047aCb9EE19d34;
    // Live Twyne deployment addresses (chainId 1). The PT-srUSDe credit vault is Aave-side on mainnet.
    address internal constant EVC_MAINNET = 0xef39D6493884C4C84D38a4bFF879Ce16CEdE702a;
    address internal constant SWAPPER = 0x2Bba09866b6F1025258542478C39720A09B728bF; // EVK Swapper singleton
    address internal constant IV_AAVE_PT_SRUSDE = 0x79CF33e623555E899d4EE122b9BfA0214fa5A4A1;
    address internal constant CV_AAVE_PT_SRUSDE = 0x70162c6C8FE764C2Be751A39eA69D4335C4bB8cd; // live PT-srUSDe collateral vault
    address internal constant SRUSDE = 0x3d7d6fdf07EE548B939A80edbc9B2256d0cdc003;
    address internal constant PENDLE_ROUTER = 0x888888888889758F76e7103c6CbF23ABbF58F946;
    address internal constant PENDLE_MARKET_SRUSDE = 0x66Ec657C59cdcaf171aB43B83da3942758bF8a97;
    // sUSDe staking contract holds USDe and is used to fund test accounts.
    address internal constant SUSDE = 0x9D39A5DE30e57443BfF2A8307A4256c8797A3497;
    // EVK Swapper handler id; the Generic handler forwards to an arbitrary target with a payload.
    bytes32 internal constant HANDLER_GENERIC = bytes32("Generic");
    // Fork block pinned by the PT-srUSDe asset-zap test: the Aave PT-srUSDe reserve is active here, so the
    // live IV's wrapper accepts raw-PT deposits. rollFork-ing here wipes the test's locally-deployed stack, so
    // the PT flow re-deploys a fresh AssetZap on the live EVC and targets the live vault.
    uint256 internal constant PT_FORK_BLOCK = 25702611;

    /// @dev Builds a SWAPPER.multicall payload that runs one Generic-handler swap to `target` with `payload`.
    function genericSwap(address tokenIn, address tokenOut, address target, bytes memory payload)
        internal
        pure
        returns (bytes[] memory swapData)
    {
        ISwapper.SwapParams memory sp = ISwapper.SwapParams({
            handler: HANDLER_GENERIC,
            mode: 0,
            account: address(0),
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            vaultIn: address(0),
            accountIn: address(0),
            receiver: address(0),
            amountOut: 1,
            data: abi.encode(target, payload)
        });
        swapData = new bytes[](1);
        swapData[0] = abi.encodeCall(ISwapper.swap, (sp));
    }

    /// @dev SWAPPER.multicall payload routing WETH -> wstETH via the handler (Generic target). The handler
    ///      pulls WETH from the Swapper, unwraps to ETH, stakes at the wstETH protocol rate, and forwards
    ///      wstETH to `zap` for the deposit.
    function wstethSwapData(address zap, address handler, uint256 amountIn) internal pure returns (bytes[] memory) {
        bytes memory payload = abi.encodeCall(WstethHandler.wrapWETH, (amountIn, zap));
        return genericSwap(WETH, WSTETH, handler, payload);
    }

    /// @dev Replaces a SWAPPER.deposit with the wrapper's own skim: the Swapper sweeps its full `input`
    ///      balance to `wrapper`, then a Generic-handler step runs `wrapper.skim(receiver)` so the wrapper
    ///      absorbs the underlying and mints shares straight to `receiver` (AssetZap). No deposit path or
    ///      vault-side approval — just transfer + skim, matching the contract's documented airdrop model.
    ///      EVault (Euler) wrappers (skim(uint256, address)); the Aave family uses AssetZap.zapUnderlying.
    function depositViaSkim(address input, address wrapper, address receiver)
        internal
        pure
        returns (bytes[] memory swapData)
    {
        swapData = _sweepAndSkim(input, wrapper, abi.encodeCall(IVault.skim, (type(uint256).max, receiver)));
    }

    function _sweepAndSkim(address input, address wrapper, bytes memory skimCalldata)
        private
        pure
        returns (bytes[] memory swapData)
    {
        swapData = new bytes[](2);
        swapData[0] = abi.encodeCall(ISwapper.sweep, (input, 0, wrapper));
        swapData[1] = genericSwap(input, wrapper, wrapper, skimCalldata)[0];
    }

    /// @dev Two-step Generic-handler route: WstethHandler delivers wstETH directly to `wrapper`, then a
    ///      Generic handler calls `wrapper.skim` with caller-supplied calldata.
    function wstethWrapSwapData(uint256 amountIn, address wrapper, address handler, bytes memory skimCalldata)
        internal
        pure
        returns (bytes[] memory)
    {
        bytes[] memory step1 = genericSwap(WETH, WSTETH, handler, abi.encodeCall(WstethHandler.wrapWETH, (amountIn, wrapper)));
        bytes[] memory step2 = genericSwap(WSTETH, wrapper, wrapper, skimCalldata);
        bytes[] memory swapData = new bytes[](2);
        swapData[0] = step1[0];
        swapData[1] = step2[0];
        return swapData;
    }

    /// @dev AMM-only fallback guess; production calldata carries a tighter off-chain guess from the Pendle SDK.
    function defaultGuess() internal pure returns (PendleApproxParams memory) {
        return PendleApproxParams({guessMin: 0, guessMax: type(uint256).max, guessOffchain: 0, maxIteration: 256, eps: 1e14});
    }

    /// @dev AMM-only fallback; production calldata carries signed order-book fills from the Pendle SDK.
    function emptyLimit() internal pure returns (PendleLimitOrderData memory limit) {}

    /// @dev Prefers USDe (cheaper SY mint) when the SY accepts it, else falls back to srUSDe.
    function pickTokenMintSy(address sy) internal view returns (address) {
        address[] memory tokensIn = IStandardizedYield(sy).getTokensIn();
        for (uint256 i; i < tokensIn.length; ++i) {
            if (tokensIn[i] == USDE) return USDE;
        }
        return SRUSDE;
    }
}

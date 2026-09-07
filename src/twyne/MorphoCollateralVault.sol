// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.28;

import {CollateralVaultBase, SafeERC20, IERC20} from "src/twyne/CollateralVaultBase.sol";
import {PauseState} from "src/TwyneFactory/CollateralVaultFactory.sol";
import {VaultManager} from "src/twyne/VaultManager.sol";
import {IEVault} from "euler-vault-kit/EVault/IEVault.sol";
import {SafeERC20Lib, IERC20 as IERC20_Euler} from "euler-vault-kit/EVault/shared/lib/SafeERC20Lib.sol";
import {Math} from "openzeppelin-contracts/utils/math/Math.sol";
import {IMorpho, MarketParams, Id, Market} from "morpho/interfaces/IMorpho.sol";
import {IOracle} from "morpho/interfaces/IOracle.sol";
import {MorphoBalancesLib} from "morpho/libraries/periphery/MorphoBalancesLib.sol";
import {MorphoLib} from "morpho/libraries/periphery/MorphoLib.sol";
import {MathLib} from "morpho/libraries/MathLib.sol";
import {MarketParamsLib} from "morpho/libraries/MarketParamsLib.sol";
import {ORACLE_PRICE_SCALE} from "morpho/libraries/ConstantsLib.sol";

/// @title MorphoCollateralVault
/// @dev Provides integration logic for Morpho Blue as external protocol.
/// @notice In this contract, the EVC is authenticated before any action that may affect the state of the vault or an
/// account. This is done to ensure that if it's EVC calling, the account is correctly authorized.
contract MorphoCollateralVault is CollateralVaultBase {
    using MathLib for uint;

    address public targetAsset; // like USDC (loan token of the Morpho market)

    // Morpho market specific parameters
    IOracle internal mo_oracle; // price() scaled by ORACLE_PRICE_SCALE (1e36)
    address internal mo_irm;
    uint internal mo_lltv; // Morpho market LLTV (1e18)
    Id public marketId; // hash of the Morpho market params

    uint[50] private __gap;

    /// @param _evc address of EVC deployed by Twyne
    /// @param _targetVault address of the target vault to borrow from in Morpho
    constructor(address _evc, address _targetVault) CollateralVaultBase(_evc, _targetVault) {
        _disableInitializers();
    }

    /// @param __intermediateVault address of the intermediate vault
    /// @param __borrower address of vault owner
    /// @param __liqLTV user-specified target LTV
    /// @param __vaultManager VaultManager contract address
    function initialize(
        address __intermediateVault,
        address __borrower,
        uint __liqLTV,
        VaultManager __vaultManager,
        MarketParams calldata _marketParams
    ) external initializer {
        address _loanToken = _marketParams.loanToken;
        targetAsset = _loanToken;
        mo_oracle = IOracle(_marketParams.oracle);
        mo_irm = _marketParams.irm;
        mo_lltv = _marketParams.lltv;
        marketId = MarketParamsLib.id(_marketParams);

        __CollateralVaultBase_init(__intermediateVault, __borrower, __liqLTV, __vaultManager);
        // intermediate vault's asset (and unit-of-account) must be the Morpho collateral token
        address __asset = asset;
        require(IEVault(__intermediateVault).unitOfAccount() == __asset, UnitOfAccountMismatch());
        require(__asset == _marketParams.collateralToken, AssetMismatch());

        SafeERC20.forceApprove(IERC20(_loanToken), targetVault, type(uint).max); // necessary for repay()
        SafeERC20.forceApprove(IERC20(__asset), targetVault, type(uint).max); // necessary for deposit() and withdraw()
        emit T_CollateralVaultInitialized();
    }

    /// @notice Override for Morpho - collateral is held in Morpho, not in the vault
    function _isNotExternallyLiquidated() internal view override returns (bool) {
        return totalAssetsDepositedOrReserved <= collateralBalance();
    }


    /// @dev increment the version for proxy upgrades
    function version() external override pure returns (uint) {
        return 0;
    }

    /// @notice Returns Morpho's liquidation LTV for the collateral asset (converts 1e18 to 1e4 precision)
    /// @return uint The liquidation threshold in 1e4 precision
    function _getExtLiqLTV() internal view override returns (uint) {
        return mo_lltv / 1e14;
    }

    function __targetAsset() internal view override returns (address) {
        return targetAsset;
    }

    ///
    // Functions defined in CollateralVaultBase requiring custom implementations
    ///

    /// @notice returns the maximum assets that can be repaid to Morpho
    function maxRepay() public view override returns (uint) {
        return __maxRepay(marketParams());
    }

    function __maxRepay(MarketParams memory _mp) internal view returns (uint) {
        return MorphoBalancesLib.expectedBorrowAssets(IMorpho(targetVault), _mp, address(this));
    }

    /// @notice adjust credit reserved from intermediate vault
    function _handleExcessCredit(uint invariantCollateralAmount) internal override {
        IEVault __ivault = intermediateVault;
        uint vaultAssets = totalAssetsDepositedOrReserved;
        unchecked {
            if (vaultAssets > invariantCollateralAmount) {
                uint _release = Math.min(vaultAssets - invariantCollateralAmount, __ivault.debtOf(address(this)));
                __withdrawCollateral(_release, marketParams());
                totalAssetsDepositedOrReserved = vaultAssets - __ivault.repay(_release, address(this));
            } else if (vaultAssets < invariantCollateralAmount) {
                uint _reserve = __ivault.borrow(invariantCollateralAmount - vaultAssets, address(this));
                totalAssetsDepositedOrReserved = vaultAssets + _reserve;
                __supplyCollateral(_reserve, marketParams());
            }
        }
    }

    /// @notice borrows target assets from Morpho
    function _borrow(uint _targetAmount, address _receiver) internal override {
        if (_targetAmount == 0) return;

        IMorpho(targetVault).borrow({
            marketParams: marketParams(),
            assets: _targetAmount,
            shares: 0,
            onBehalf: address(this),
            receiver: _receiver
        });
    }

    /// @notice Converts a collateral-asset amount to target-asset units via Morpho's oracle
    function _convertCollateralToTargetAsset(uint collateralAmount) internal view override returns (uint) {
        return collateralAmount.mulDivDown(mo_oracle.price(), ORACLE_PRICE_SCALE);
    }

    /// @notice sends borrowed target assets to Morpho
    function _repay(uint _amount) internal override {
        uint _morphoShares;
        uint _morphoAssets;
        MarketParams memory _mp = marketParams();
        if (_amount == __maxRepay(_mp)) {
            // Repay by shares to avoid rounding issues
            _morphoShares = MorphoLib.borrowShares(IMorpho(targetVault), marketId, address(this));
        } else {
            _morphoAssets = _amount;
        }

        address _targetAsset = targetAsset;
        address _borrower = borrower;
        SafeERC20Lib.safeTransferFrom(IERC20_Euler(_targetAsset), _borrower, address(this), _amount, permit2);
        uint assetsRepaid = __repay(_morphoAssets, _morphoShares, _mp);

        // Return unused tokens to borrower
        if (_amount > assetsRepaid) {
            unchecked { SafeERC20Lib.safeTransfer(IERC20_Euler(_targetAsset), _borrower, _amount - assetsRepaid); }
        }
    }

    function redeemUnderlying(uint, address) external pure override returns (uint) {
        revert T_MorphoNotImplemented();
    }

    /// @notice Deposits airdropped collateral asset for Morpho integration.
    /// @dev Morpho keeps collateral in the external protocol, so `asset.balanceOf(this)` only tracks unsupplied tokens.
    /// We therefore treat the current local balance as the skim amount and add it to the tracked total.
    function skim() external override onlyBorrowerAndNotExtLiquidated whenNotPaused(PauseState.Frozen) nonReentrant {
        uint skimmed = IERC20(asset).balanceOf(address(this));
        createVaultSnapshot();

        totalAssetsDepositedOrReserved += skimmed;
        __supplyCollateral(skimmed, marketParams());
        _handleExcessCredit(_invariantCollateralAmount());
        evc.requireAccountAndVaultStatusCheck(address(this));
        emit T_Skim(skimmed);
    }

    function _postDeposit(uint _amount) internal virtual override {
        __supplyCollateral(_amount, marketParams());
    }

    function _preWithdraw(uint _amount) internal virtual override {
        __withdrawCollateral(_amount, marketParams());
    }

    ///
    // Twyne Custom Liquidation Logic
    ///

    /// @notice Returns user collateral (C) in loan token terms
    /// @return C = user-owned collateral valued in loan token terms via Morpho oracle
    function _getC() internal view override returns (uint) {
        unchecked {
            uint userCollateralBalance = totalAssetsDepositedOrReserved - maxRelease();
            return userCollateralBalance.mulDivDown(mo_oracle.price(), ORACLE_PRICE_SCALE);
        }
    }

    /// @notice Checks if this vault can be liquidated on Twyne
    /// @dev Two liquidation scenarios:
    /// @dev 1. Morpho position is close to liquidation (borrowed > buffer · maxBorrow at λ̃_e)
    /// @dev 2. Twyne LTV exceeded (borrowed > C · λ̃_t)
    /// @return bool True if the vault can be liquidated
    /// @return uint B = external borrow debt from Morpho (in loan token units)
    function _canLiquidate() internal view override returns (bool, uint) {
        (uint buffer, uint maxTwyneLiqLTV,) = _liqParams();
        uint borrowed = maxRepay();
        uint collateralPrice = mo_oracle.price();

        // Check external protocol liquidation condition (within buffer of Morpho's liq point): borrowed > buffer * maxBorrow
        if (borrowed * MAXFACTOR
                > buffer * collateralBalance().mulDivDown(collateralPrice, ORACLE_PRICE_SCALE).wMulDown(mo_lltv)) {
            return (true, borrowed);
        }

        // C · λ̃_t converted to target asset (1e8 precision on LTV)
        uint collateralValueScaledByLiqLTV =
            _collateralScaledByLiqLTV1e8(false, buffer * _getExtLiqLTV(), maxTwyneLiqLTV, maxRelease()).mulDivDown(collateralPrice, ORACLE_PRICE_SCALE);
        return (borrowed * 1e8 > collateralValueScaledByLiqLTV, borrowed);
    }

    /// @notice Converts collateral value from loan token terms to native collateral asset units
    /// @dev Uses the Morpho oracle price for conversion (inverse of collateral→loan conversion)
    /// @dev Returns the minimum of calculated amount and user-owned collateral
    /// @param collateralValue The collateral value in loan token units
    /// @return collateralAmount The collateral amount in native asset units
    function _convertBaseToCollateral(uint collateralValue) internal view override returns (uint collateralAmount) {
        uint price = mo_oracle.price();
        collateralAmount = collateralValue.mulDivDown(ORACLE_PRICE_SCALE, price);
        unchecked { return Math.min(totalAssetsDepositedOrReserved - maxRelease(), collateralAmount); }
    }

    function balanceOf(address user) external view nonReentrantView override returns (uint) {
        if (user != address(this)) return 0;

        uint _totalAssetsDepositedOrReserved = totalAssetsDepositedOrReserved;
        // return 0 when this vault doesn't have any assets
        if (_totalAssetsDepositedOrReserved == 0) return 0;
        // return 0 if externally liquidated

        if (_totalAssetsDepositedOrReserved > collateralBalance()) return 0;

        unchecked { return _totalAssetsDepositedOrReserved - maxRelease(); }
    }

    /// @notice Splits remaining collateral after external liquidation (whitepaper Section 6.3.1)
    /// @dev After external protocol liquidates the position, remaining collateral is split three ways:
    ///
    /// 1. C_LP (releaseAmount) → returned to intermediate vault for CLP (credit liquidity provider)
    /// 2. borrowerClaim → returned to borrower based on dynamic incentive model
    /// 3. liquidatorReward → goes to liquidator as compensation for handling the liquidation
    ///
    /// The split follows these steps:
    /// Step 1: Calculate user collateral = B_ext / λ̃^max_t (debt at max Twyne LTV)
    ///   - This is the minimum collateral needed to cover the external debt at maximum LTV
    ///   - Capped by actual remaining collateral balance
    ///
    /// Step 2: Calculate C_LP = min(remaining collateral after user portion, maxRelease)
    ///   - CLP gets back their reserved portion, up to what's available
    ///
    /// Step 3: Remaining collateral (C_new = balance - C_LP) is split between borrower and liquidator
    ///   - Uses collateralForBorrower(B, C_new) which applies dynamic incentive i(λ_t)
    ///   - Liquidator gets: C_new - borrowerClaim
    ///
    /// @param _collateralBalance Total remaining collateral after external liquidation
    /// @param _maxRepay Maximum debt that can be repaid (B_ext in target asset units)
    /// @param _maxRelease Maximum collateral that can be released to CLP
    /// @return liquidatorReward Collateral going to liquidator
    /// @return releaseAmount Collateral returning to intermediate vault (C_LP)
    /// @return borrowerClaim Collateral returning to borrower
    function splitCollateralAfterExtLiq(uint _collateralBalance, uint _maxRepay, uint _maxRelease, uint _price) internal view returns (uint liquidatorReward, uint releaseAmount, uint borrowerClaim) {
        if (_maxRepay == 0) {
            unchecked {
                releaseAmount = Math.min(_collateralBalance, _maxRelease);
                borrowerClaim = _collateralBalance - releaseAmount;
                return (0, releaseAmount, borrowerClaim);
            }
        }

        // Step 1: Calculate user's portion of collateral (C_temp)
        // userCollateral = B_ext / λ̃^max_t (converted to collateral asset units)
        // _maxTwyneLiqLTV is always populated here: the only caller, handleExternalLiquidation(),
        // takes the vault snapshot before invoking this split
        uint userCollateral = _maxRepay * MAXFACTOR / _maxTwyneLiqLTV;
        userCollateral = Math.min(_collateralBalance, userCollateral.mulDivDown(ORACLE_PRICE_SCALE, _price));

        // Step 2: Calculate CLP gets min(C_left - C_temp, C_LP^old)
        unchecked { releaseAmount = Math.min(_collateralBalance - userCollateral, _maxRelease); }

        // Step 3: Calculate C_new which is C_left - CLP
        // _collateralBalance >= _collateralBalance - userCollateral >= releaseAmount;
        unchecked { userCollateral = _collateralBalance - releaseAmount; }

        // Convert userCollateral to loan token terms for collateralForBorrower
        uint C_new = userCollateral.mulDivDown(_price, ORACLE_PRICE_SCALE);

        // Apply dynamic incentive model: borrower gets collateralForBorrower(B, C_new)
        // Liquidator gets the remainder as reward for handling external liquidation
        borrowerClaim = collateralForBorrower(_maxRepay, C_new);
        unchecked { liquidatorReward = userCollateral - borrowerClaim; }
    }

    /// @notice to be called if the vault is liquidated by Morpho
    function handleExternalLiquidation() external override callThroughEVC whenNotPaused(PauseState.Paused) nonReentrant {
        createVaultSnapshot();
        uint amount = collateralBalance();
        require(totalAssetsDepositedOrReserved > amount, NotExternallyLiquidated());

        address __asset = asset;
        MarketParams memory _mp = marketParams();
        uint _maxRepay = __maxRepay(_mp);

        uint collateralPrice = mo_oracle.price();
        // Require position is healthy on Morpho before handling
        {
            uint maxBorrow = amount.mulDivDown(collateralPrice, ORACLE_PRICE_SCALE).wMulDown(mo_lltv);
            require(maxBorrow >= _maxRepay, ExternalPositionUnhealthy());
        }

        uint _maxRelease = maxRelease();
        address liquidator = _msgSender();

        if (_maxRelease == 0) {
            require(liquidator == borrower, NoLiquidationForZeroReserve());
        }

        (uint liquidatorReward, uint releaseAmount, uint borrowerClaim) = splitCollateralAfterExtLiq(amount, _maxRepay, _maxRelease, collateralPrice);

        if (_maxRepay > 0) {
            address _targetAsset = targetAsset;
            // step 1: repay all external debt
            SafeERC20Lib.safeTransferFrom(IERC20_Euler(_targetAsset), liquidator, address(this), _maxRepay, permit2);
            uint _assetsRepaid = __repay(0, MorphoLib.borrowShares(IMorpho(targetVault), marketId, address(this)), _mp);

            if (_maxRepay > _assetsRepaid) {
                unchecked { SafeERC20Lib.safeTransfer(IERC20_Euler(_targetAsset), liquidator, _maxRepay - _assetsRepaid); }
            }
        }

        __withdrawCollateral(amount, _mp);

        if (liquidatorReward > 0) {
            // step 2: transfer collateral reward to liquidator
            SafeERC20Lib.safeTransfer(IERC20_Euler(__asset), liquidator, liquidatorReward);
        }

        if (borrowerClaim > 0) {
            // step 3: return some collateral to borrower
            SafeERC20Lib.safeTransfer(IERC20_Euler(__asset), borrower, borrowerClaim);
        }

        if (releaseAmount > 0) {
            // step 4: release remaining assets. Any non-zero bad debt left after this
            // needs to be socialized via intermediateVault.liquidate in the same batch.
            intermediateVault.repay(releaseAmount, address(this));
        }

        // reset the vault
        delete totalAssetsDepositedOrReserved;
        delete borrower;

        evc.requireVaultStatusCheck();
        emit T_HandleExternalLiquidation();
    }

    ///
    // Morpho-specific helpers
    ///

    function marketParams() public view returns (MarketParams memory) {
        return MarketParams({
            loanToken: targetAsset,
            collateralToken: asset,
            oracle: address(mo_oracle),
            irm: mo_irm,
            lltv: mo_lltv
        });
    }

    function collateralBalance() public view returns (uint) {
        return MorphoLib.collateral(IMorpho(targetVault), marketId, address(this));
    }

    function __repay(uint _amount, uint _shares, MarketParams memory _mp) internal returns (uint assetsRepaid) {
        if (_amount == 0 && _shares == 0) return 0;

        (assetsRepaid, ) = IMorpho(targetVault).repay({
            marketParams: _mp,
            assets: _amount,
            shares: _shares,
            onBehalf: address(this),
            data: ""
        });
    }

    function __supplyCollateral(uint _amount, MarketParams memory _mp) internal {
        if (_amount == 0) return;

        IMorpho(targetVault).supplyCollateral({
            marketParams: _mp,
            assets: _amount,
            onBehalf: address(this),
            data: ""
        });
    }

    function __withdrawCollateral(uint _amount, MarketParams memory _mp) internal {
        if (_amount == 0) return;

        IMorpho(targetVault).withdrawCollateral({
            marketParams: _mp,
            assets: _amount,
            onBehalf: address(this),
            receiver: address(this)
        });
    }
}

// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.28;

import {IErrors} from "src/interfaces/IErrors.sol";
import {IEvents} from "src/interfaces/IEvents.sol";
import {PausableUpgradeable} from "openzeppelin-upgradeable/utils/PausableUpgradeable.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "openzeppelin-contracts/utils/Address.sol";
import {IEVault} from "euler-vault-kit/EVault/IEVault.sol";
import {VaultManager} from "src/twyne/VaultManager.sol";
import {CollateralVaultFactory} from "src/TwyneFactory/CollateralVaultFactory.sol";
import {EVCUtil} from "ethereum-vault-connector/utils/EVCUtil.sol";
import {SafeERC20Lib, IERC20 as IERC20_Euler} from "euler-vault-kit/EVault/shared/lib/SafeERC20Lib.sol";
import {Math} from "openzeppelin-contracts/utils/math/Math.sol";
import {ReentrancyGuardUpgradeable} from "openzeppelin-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

/// @title CollateralVaultBase
/// @notice To contact the team regarding security matters, visit https://twyne.xyz/security
/// @notice Provides general vault functionality applicable to any external integration.
/// @dev This isn't a ERC4626 vault, nor does it comply with ERC20 specification.
/// @dev It only supports name, symbol, balanceOf(address) and reverts for all other ERC20 fns.
/// @notice In this contract, the EVC is authenticated before any action that may affect the state of the vault or an account.
/// @notice This is done to ensure that if its EVC calling, the account is correctly authorized.
abstract contract CollateralVaultBase is EVCUtil, ReentrancyGuardUpgradeable, IErrors, IEvents  {
    uint internal constant MAXFACTOR = 1e4;
    address internal constant permit2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    address public immutable targetVault;

    uint private snapshot;
    uint public totalAssetsDepositedOrReserved;

    address public borrower;
    uint public twyneLiqLTV;
    VaultManager public twyneVaultManager;
    CollateralVaultFactory public collateralVaultFactory;
    IEVault public intermediateVault;
    address private _asset;

    string public constant name = "Collateral Vault";
    string public constant symbol = "CV";

    uint[50] private __gap;

    modifier onlyBorrowerAndNotExtLiquidated() {
        _callThroughEVC();
        require(_msgSender() == borrower, ReceiverNotBorrower());
        require(_isNotExternallyLiquidated(), ExternallyLiquidated());
        _;
    }

    function _isNotExternallyLiquidated() internal view virtual returns (bool) {
        return totalAssetsDepositedOrReserved <= IERC20(asset()).balanceOf(address(this));
    }

    modifier whenNotPaused() {
        require(!collateralVaultFactory.paused(), PausableUpgradeable.EnforcedPause());
        _;
    }

    /// @notice Reentrancy guard for view functions
    modifier nonReentrantView() virtual {
        if (_reentrancyGuardEntered()) {
            revert ReentrancyGuardReentrantCall();
        }
        _;
    }

    /// @param _evc address of EVC deployed by Twyne
    /// @param _targetVault address of the target vault to borrow from
    constructor(address _evc, address _targetVault) EVCUtil(_evc) {
        targetVault = _targetVault;
    }

    /// @param __asset address of vault asset
    /// @param __borrower address of vault owner
    /// @param __liqLTV user-specified target LTV
    /// @param __vaultManager VaultManager contract address
    function __CollateralVaultBase_init(
        IERC20 __asset,
        address __borrower,
        uint __liqLTV,
        VaultManager __vaultManager
    ) internal onlyInitializing {
        __ReentrancyGuard_init();

        _asset = address(__asset);
        borrower = __borrower;

        twyneVaultManager = __vaultManager;
        collateralVaultFactory = CollateralVaultFactory(msg.sender);
        address _intermediateVault = twyneVaultManager.getIntermediateVault(address(__asset));
        intermediateVault = IEVault(_intermediateVault);

        // checkLiqLTV must happen after targetVault() and asset() return meaningful values
        _checkLiqLTV(__liqLTV, address(__asset));
        twyneLiqLTV = __liqLTV;
        SafeERC20.forceApprove(IERC20(__asset), _intermediateVault, type(uint).max); // necessary for EVK repay()
        evc.enableController(address(this), _intermediateVault); // necessary for Twyne EVK borrowing
        evc.enableCollateral(address(this), address(this)); // necessary for Twyne EVK borrowing

        require(address(__asset) == IEVault(_intermediateVault).asset(), AssetMismatch());
    }

    /// @notice Returns external lending protocol's liquidation LTV
    /// @param asset The collateral asset address
    /// @return uint The liquidation LTV in 1e4 precision
    function _getExtLiqLTV(address asset) internal view virtual returns (uint);

    /// @notice Returns debt (B) and user collateral (C) in common unit of account (like USD)
    /// @dev Used in liquidation calculations to determine borrower's claim
    /// @return B The total debt value in common unit of account
    /// @return C The user-owned collateral value in common unit of account
    function _getBC() internal view virtual returns (uint B, uint C);

    /// @notice Validates that the provided liqLTV is within acceptable bounds
    /// @dev Ensures: externalLiqLTV * buffer <= liqLTV * MAXFACTOR && liqLTV <= maxLTV
    /// @param liqLTV The liquidation LTV to validate
    /// @param asset The collateral asset address
    function _checkLiqLTV(uint liqLTV, address asset) internal view virtual;

    ///
    // ERC20-compatible functionality
    ///

    /// @dev balanceOf(address(this)) is used by intermediate vault to check the collateral amount.
    /// This vault borrows from intermediate vault using the vault as the collateral asset.
    /// This means balanceOf(borrower-from-intermediate-vault's-perspective) needs to return the amount
    /// of collateral held by borrower-from-intermediate-vault's-perspective.
    /// On first deposit, this value is the deposit amount. Over time, it decreases due to our siphoning mechanism.
    /// Thus, we return borrower owned collateral.
    /// @param user address
    function balanceOf(address user) external view virtual returns (uint);

    /// @dev This is used by intermediate vault to price the collateral (aka collateral vault).
    /// Since CollateralVault.balanceOf(address(this)) [=shares] returns the amount of asset owned by the borrower,
    /// collateral vault token is 1:1 with asset.
    /// @param shares shares
    function convertToAssets(uint shares) external pure returns (uint) {
        return shares;
    }

    /// @dev transfer, transferFrom, allowance, totalSupply, and approve functions aren't supported.
    /// Calling these functions will revert. IF this vault had to be an ERC20 token,
    /// we would only mint the token to this vault itself, and disable any transfer. This makes
    /// approve functionality useless.
    /// How does intermediate vault transfer the collateral during liquidation?
    /// Intermediate vault is liquidated only when this collateral vault has 0 asset.
    /// Thus, the intermediate vault never needs to transfer collateral.
    fallback() external {
        revert T_CV_OperationDisabled();
    }

    //////////////////////////////////////////

    /// @dev returns implementation version
    function version() external virtual pure returns (uint);

    /// @dev returns collateral vault asset (which is the token of another lending protocol, like an aToken, eToken, etc.)
    function asset() public view returns (address) {
        return _asset;
    }

    ///
    // Target asset functions
    ///

    /// @notice Returns the maximum amount of debt that can be repaid to the external lending protocol
    /// @dev This function must be implemented by derived contracts for specific external protocol integrations
    /// @dev The returned value represents the current total debt (principal + interest) owed by this vault
    /// @dev In the protocol mechanics, this corresponds to B in the mathematical formulation
    /// @return The maximum amount of debt that can be repaid, denominated in the target asset's units
    function maxRepay() public view virtual returns (uint);

    /// @dev collateral vault borrows targetAsset from underlying protocol.
    /// Implementation should make sure targetAsset is whitelisted.
    function _borrow(uint _targetAmount, address _receiver) internal virtual;

    /// @dev Implementation should make sure the correct targetAsset is repaid and the repay action is successful.
    /// Revert otherwise.
    function _repay(uint _targetAmount) internal virtual;

    /// @notice Borrows target assets from the external lending protocol
    /// @dev This function calls the internal _borrow function to handle the protocol-specific borrow logic,
    /// then transfers the target asset from the vault to _receiver.
    /// @param _targetAmount The amount of target asset to borrow
    /// @param _receiver The receiver of the borrowed assets
    function borrow(uint _targetAmount, address _receiver)
        external
        onlyBorrowerAndNotExtLiquidated
        whenNotPaused
        nonReentrant
    {
        createVaultSnapshot();
        _borrow(_targetAmount, _receiver);
        _handleExcessCredit(_invariantCollateralAmount());
        evc.requireAccountAndVaultStatusCheck(address(this));
        emit T_Borrow(_targetAmount, _receiver);
    }

    /// @notice Repays debt owed to the external lending protocol
    /// @dev If _amount is set to type(uint).max, the entire debt will be repaid
    /// @dev This function transfers the target asset from the caller to the vault, then
    /// calls the internal _repay function to handle the protocol-specific repayment logic
    /// @dev Reverts if attempting to repay more than the current debt
    /// @param _amount The amount of target asset to repay, or type(uint).max for full repayment
    function repay(uint _amount) external onlyBorrowerAndNotExtLiquidated nonReentrant {
        createVaultSnapshot();
        uint _maxRepay = maxRepay();
        if (_amount == type(uint).max) {
            _amount = _maxRepay;
        } else {
            require(_amount <= _maxRepay, RepayingMoreThanMax());
        }

        _repay(_amount);
        _handleExcessCredit(_invariantCollateralAmount());
        evc.requireVaultStatusCheck();
        emit T_Repay(_amount);
    }

    ///
    // Intermediate vault functions
    ///

    /// @notice Returns the maximum amount of credit that can be released back to the intermediate vault
    /// @dev This represents the total debt (principal + accumulated interest) owed by this vault to the
    /// intermediate vault from which credit was reserved
    /// @dev In the protocol mechanics, this corresponds to C_LP (credit from LPs) in the mathematical formulation
    /// @dev The value is denominated in the collateral asset
    /// @return uint The maximum amount of collateral asset that can be released back to the intermediate vault
    function maxRelease() public view returns (uint) {
        // this math is the same as EVK's getCurrentOwed() used in repay() to find max repay amount
        return Math.min(intermediateVault.debtOf(address(this)), totalAssetsDepositedOrReserved);
    }

    ///
    // Functions from VaultSimple
    // https://github.com/euler-xyz/evc-playground/blob/master/src/vaults/open-zeppelin/VaultSimple.sol
    ///

    /// @notice Creates a snapshot of the vault state
    /// @dev This function is called before any action that may affect the vault's state.
    function createVaultSnapshot() internal {
        // We delete snapshots on `checkVaultStatus`, which can only happen at the end of the EVC batch. Snapshots are
        // taken before any action is taken on the vault that affects the vault asset records and deleted at the end, so
        // that asset calculations are always based on the state before the current batch of actions.
        if (snapshot == 0) {
            snapshot = 1;
        }
    }

    /// @notice Checks the vault status
    /// @dev This function is called after any action that may affect the vault's state.
    /// @dev Executed as a result of requiring vault status check on the EVC.
    function checkVaultStatus() external onlyEVCWithChecksInProgress returns (bytes4) {
        // sanity check in case the snapshot hasn't been taken
        require(snapshot != 0, SnapshotNotTaken());
        require(!_canLiquidate(), VaultStatusLiquidatable());

        // If the vault has been externally liquidated, any bad debt from intermediate vault
        // has to be settled via intermediateVault.liquidate().
        // Bad debt settlement reduces this debt to 0.
        if (borrower == address(0)) {
            require(intermediateVault.debtOf(address(this)) == 0, BadDebtNotSettled());
        }
        delete snapshot;

        return this.checkVaultStatus.selector;
    }

    ///
    // Asset transfer functions
    ///

    /// @notice Deposits a certain amount of assets.
    /// @param assets The assets to deposit.
    function deposit(uint assets)
        external
        onlyBorrowerAndNotExtLiquidated
        whenNotPaused
        nonReentrant
    {
        createVaultSnapshot();

        SafeERC20Lib.safeTransferFrom(IERC20_Euler(asset()), borrower, address(this), assets, permit2);
        totalAssetsDepositedOrReserved += assets;
        _handleExcessCredit(_invariantCollateralAmount());
        evc.requireAccountAndVaultStatusCheck(address(this));
        emit T_Deposit(assets);
    }

    /// @notice Deposits a certain amount of underlying asset.
    /// @param underlying The underlying assets to deposit.
    function depositUnderlying(uint underlying)
        external
        onlyBorrowerAndNotExtLiquidated
        whenNotPaused
        nonReentrant
    {
        createVaultSnapshot();
        totalAssetsDepositedOrReserved += _depositUnderlying(underlying);
        _handleExcessCredit(_invariantCollateralAmount());
        evc.requireAccountAndVaultStatusCheck(address(this));
        emit T_DepositUnderlying(underlying);
    }

    // _depositUnderlying() requires custom implementation per protocol integration
    function _depositUnderlying(uint underlying) internal virtual returns (uint assets);

    /// @notice Deposits airdropped collateral asset.
    /// @dev This is the last step in a 1-click leverage batch.
    function skim() external onlyBorrowerAndNotExtLiquidated whenNotPaused nonReentrant {
        uint balance = IERC20(asset()).balanceOf(address(this));
        uint _totalAssetsDepositedOrReserved = totalAssetsDepositedOrReserved;

        createVaultSnapshot();
        totalAssetsDepositedOrReserved = balance;
        _handleExcessCredit(_invariantCollateralAmount());
        evc.requireAccountAndVaultStatusCheck(address(this));
        emit T_Skim(balance - _totalAssetsDepositedOrReserved);
    }

    /// @notice Withdraws a certain amount of assets for a receiver.
    /// @param assets Amount of collateral assets to withdraw.
    /// @param receiver The receiver of the withdrawal.
    function withdraw(
        uint assets,
        address receiver
    ) public onlyBorrowerAndNotExtLiquidated nonReentrant {
        createVaultSnapshot();

        uint _totalAssetsDepositedOrReserved = totalAssetsDepositedOrReserved;
        uint maxWithdraw = _totalAssetsDepositedOrReserved - maxRelease();
        if (assets == type(uint).max) {
            assets = maxWithdraw;
        } else {
            require(assets <= maxWithdraw, T_WithdrawMoreThanMax());
        }

        totalAssetsDepositedOrReserved = _totalAssetsDepositedOrReserved - assets;


        SafeERC20.safeTransfer(IERC20(asset()), receiver, assets);
        _handleExcessCredit(_invariantCollateralAmount());
        evc.requireAccountAndVaultStatusCheck(address(this));
        emit T_Withdraw(assets, receiver);
    }

    /// @notice Withdraw a certain amount of collateral and transfers collateral asset's underlying asset to receiver.
    /// @param assets Amount of collateral asset to withdraw.
    /// @param receiver The receiver of the redemption.
    /// @return underlying Amount of underlying asset transferred.
    function redeemUnderlying(
        uint assets,
        address receiver
    ) public onlyBorrowerAndNotExtLiquidated nonReentrant returns (uint underlying) {
        createVaultSnapshot();

        uint _totalAssetsDepositedOrReserved = totalAssetsDepositedOrReserved;
        uint maxWithdraw = _totalAssetsDepositedOrReserved - maxRelease();
        if (assets == type(uint).max) {
            assets = maxWithdraw;
        } else {
            require(assets <= maxWithdraw, T_WithdrawMoreThanMax());
        }

        totalAssetsDepositedOrReserved = _totalAssetsDepositedOrReserved - assets;
        _handleExcessCredit(_invariantCollateralAmount());

        // redeem is done after _handleExcessCredit. This is to handle AaveV3 integration.
        // Redeeming wrapped aTokens for underlying tokens and transfer them to the user.
        // However, during high utilization of the intermediate pool, most aTokens may be
        // transferred to collateral vaults and unavailable on the wrapped contract.
        // NOTE: _handleExcessCredit() and _invariantCollateralAmount() should never rely on
        // token balances since we now withdraw collateral asset after rebalancing.
        underlying = IEVault(asset()).redeem(assets, receiver, address(this));

        evc.requireAccountAndVaultStatusCheck(address(this));
        emit T_RedeemUnderlying(assets, receiver);
    }

    ///
    // Twyne Custom Logic, for setting user target LTV, liquidation, rebalancing, teleporting, etc.
    ///

    /// @notice allow the user to set their own vault's LTV
    function setTwyneLiqLTV(uint _ltv) external onlyBorrowerAndNotExtLiquidated whenNotPaused nonReentrant {
        createVaultSnapshot();
        _checkLiqLTV(_ltv, _asset);
        twyneLiqLTV = _ltv;
        _handleExcessCredit(_invariantCollateralAmount());
        evc.requireAccountAndVaultStatusCheck(address(this));
        emit T_SetTwyneLiqLTV(_ltv);
    }

    /// @notice check if a vault can be liquidated
    /// @dev calling canLiquidate() in other functions directly causes a read-only reentrancy issue,
    /// so move the logic to an internal function.
    function canLiquidate() external view nonReentrantView returns (bool) {
        return _canLiquidate();
    }

    // _canLiquidate() requires custom implementation per protocol integration
    function _canLiquidate() internal view virtual returns (bool);

    /// @notice convert collateral from unit of account (like USD) to native asset units
    /// @dev This fn is only used in `collateralForBorrower()` and before returning should
    ///   take a min with `totalAssetsDepositedOrReserved - maxRelease()` since borrower cannot
    ///   receive more than user owned collateral.
    function _convertBaseToCollateral(uint collateralValue) internal view virtual returns (uint);

    /// @notice Calculates the collateral to return to borrower during liquidation/handleExternalLiquidation
    /// @dev Uses Twyne's dynamic liquidation incentive model (whitepaper eq 7.1):
    ///   - Borrower receives: C * [1 - λ_t - i(λ_t)] where λ_t = B/C (Twyne LTV)
    ///   - i(λ_t) is the dynamic liquidation incentive that varies based on health
    ///
    /// Three regimes based on borrower's LTV (λ_t = B/C):
    ///
    /// 1. λ_t >= λ̃^max_t (severely unhealthy): i = 1 - λ_t
    ///    → Borrower gets: C * [1 - λ_t - (1 - λ_t)] = 0
    ///    All remaining equity goes to liquidator as maximum incentive
    ///
    /// 2. λ_t <= β_safe * λ̃_e (healthy, no CLP reservation needed): i = 0
    ///    → Borrower gets: C * [1 - λ_t - 0] = C - B
    ///    No liquidation incentive; borrower keeps full equity
    ///
    /// 3. β_safe * λ̃_e < λ_t < λ̃^max_t (intermediate): linear interpolation
    ///    i = (1 - λ̃^max_t) * (λ_t - β_safe * λ̃_e) / (λ̃^max_t - β_safe * λ̃_e)
    ///    → Borrower gets: C * (1 - β_safe * λ̃_e) * (λ̃^max_t - λ_t) / (λ̃^max_t - β_safe * λ̃_e)
    ///    Incentive grows linearly from 0 to (1 - λ̃^max_t) as LTV increases
    ///
    /// @param B debt in common unit of account (like USD)
    /// @param C user collateral in common unit of account (like USD)
    function collateralForBorrower(uint B, uint C) public view virtual returns (uint) {
        address __asset = asset();
        // liqLTV_e = β_safe * λ̃_e (in 1e8 precision: buffer is 1e4, extLiqLTV is 1e4)
        uint liqLTV_e = uint(twyneVaultManager.externalLiqBuffers(__asset)) * _getExtLiqLTV(__asset); // 1e8 precision
        // maxLTV_t = λ̃^max_t
        uint maxLTV_t = uint(twyneVaultManager.maxTwyneLTVs(__asset)); // 1e4 precision

        if (MAXFACTOR * B >= maxLTV_t * C) {
            // Case 1: λ_t >= λ̃^max_t (MAXFACTOR * B / C >= maxLTV_t / MAXFACTOR)
            // Borrower is severely unhealthy; all equity goes to liquidator
            return 0;
        } else if (MAXFACTOR * MAXFACTOR * B <= liqLTV_e * C) {
            // Case 2: λ_t <= β_safe * λ̃_e (MAXFACTOR² * B / C <= liqLTV_e)
            // Borrower is healthy; no liquidation incentive, keeps full equity (C - B)
            return _convertBaseToCollateral(C - B);
        } else {
            // Case 3: Intermediate regime with linear interpolation
            // Formula: C * (1 - β_safe * λ̃_e) * (λ̃^max_t - λ_t) / (λ̃^max_t - β_safe * λ̃_e)
            // In code precision: (MAXFACTOR² - liqLTV_e) * (maxLTV_t * C - MAXFACTOR * B)
            //                    / (MAXFACTOR * (MAXFACTOR * maxLTV_t - liqLTV_e))
            return _convertBaseToCollateral(
                (MAXFACTOR * MAXFACTOR - liqLTV_e) * (maxLTV_t * C - MAXFACTOR * B) /
                (MAXFACTOR * (MAXFACTOR * maxLTV_t - liqLTV_e))
            );
        }
    }

    /// @notice Begin the liquidation process for this vault.
    /// @dev Liquidation needs to be done in a batch.
    /// @dev Liquidation uses dynamic liquidation incentive model:
    ///   1. Liquidator must first transfer collateral to the borrower as compensation.
    ///   2. The liquidator then becomes the new borrower of this vault.
    ///   3. Liquidator is responsible to make the position healthy before the batch ends.
    ///   4. Liquidator may wind down the position and keep remaining collateral as profit.
    /// @dev The liquidator's profit comes from the difference between the collateral they
    ///   receive (by becoming the vault owner) and the compensation paid to the borrower.
    function liquidate() external callThroughEVC nonReentrant {
        createVaultSnapshot();
        require(_isNotExternallyLiquidated(), ExternallyLiquidated());

        address liquidator = _msgSender();
        require(liquidator != borrower, SelfLiquidation());
        require(_canLiquidate(), HealthyNotLiquidatable());

        (uint B, uint C) = _getBC();
        SafeERC20Lib.safeTransferFrom(IERC20_Euler(asset()), liquidator, borrower, collateralForBorrower(B, C), permit2);

        // liquidator takes over this vault from the current borrower
        borrower = liquidator;

        collateralVaultFactory.setCollateralVaultLiquidated(liquidator);

        evc.requireAccountAndVaultStatusCheck(address(this));
    }

    /// @notice Checks whether the vault has undergone external liquidation
    /// @dev External liquidation occurs when the external lending protocol (e.g., Euler) directly liquidates
    /// collateral from this vault
    /// @dev Detects liquidation by comparing the tracked totalAssetsDepositedOrReserved with the actual
    /// token balance - if actual balance is less, external liquidation has occurred
    /// @return bool True if the vault has been externally liquidated, false otherwise
    function isExternallyLiquidated() external view nonReentrantView returns (bool) {
        return !_isNotExternallyLiquidated();
    }

    /// @notice Handles the aftermath of an external liquidation by the underlying lending protocol
    /// @dev Called when the vault's collateral was liquidated by the external protocol (e.g., Euler)
    /// @dev Steps performed:
    /// 1. Calculate and distribute the remaining collateral in this vault among
    ///  the liquidator, borrower and intermediate vault
    /// 2. Repay remaining external debt using funds from the liquidator
    /// 3. Reset the vault state so that it cannot be used again
    /// @dev Can only be called when the vault is actually in an externally liquidated state
    /// @dev Caller needs to call intermediateVault.liquidate(collateral_vault_address, collateral_vault_address, 0, 0)
    /// in the same EVC batch if there is any bad debt left at the end of this call
    /// @dev Implementation varies depending on the external protocol integration
    function handleExternalLiquidation() external virtual;

    /// @notice Calculates the amount of excess credit that can be released back to the intermediate vault
    /// @dev Excess credit exists when the relationship between borrower collateral and reserved credit becomes unbalanced
    /// @dev The calculation varies depending on the external protocol integration
    /// @return uint The amount of excess credit that can be released, denominated in the collateral asset
    function canRebalance() external view nonReentrantView returns (uint) {
        uint __invariantCollateralAmount = _invariantCollateralAmount();
        require(totalAssetsDepositedOrReserved > __invariantCollateralAmount, CannotRebalance());
        unchecked { return totalAssetsDepositedOrReserved - __invariantCollateralAmount; }
    }

    /// @notice Adjusts credit reserved from intermediate vault to match the invariant collateral amount
    /// @dev If vault has excess credit (vaultAssets > invariant), repays the excess to intermediate vault
    /// @dev If vault needs more credit (vaultAssets < invariant), borrows more from intermediate vault
    /// @param __invariantCollateralAmount The target collateral amount to maintain invariants
    function _handleExcessCredit(uint __invariantCollateralAmount) internal virtual;

    /// @notice Calculates the collateral amount required to maintain protocol invariants
    /// @dev Formula: ceil(userCollateral * twyneLiqLTV * MAXFACTOR / (externalLiqLTV * buffer))
    /// @return uint The amount of collateral assets the vault should hold
    function _invariantCollateralAmount() internal view virtual returns (uint);

    /// @notice Releases excess credit back to the intermediate vault
    /// @dev Excess credit exists when: liqLTV_twyne * C < safety_buffer * liqLTV_external * (C + C_LP)
    /// @dev Anyone can call this function to rebalance a position
    function rebalance() external callThroughEVC nonReentrant {
        uint __invariantCollateralAmount = _invariantCollateralAmount();
        require(totalAssetsDepositedOrReserved > __invariantCollateralAmount, CannotRebalance());
        require(_isNotExternallyLiquidated(), ExternallyLiquidated());
        _handleExcessCredit(__invariantCollateralAmount);
        emit T_Rebalance();
    }
}

// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity ^0.8.19;

import {PausableUpgradeable} from "openzeppelin-upgradeable/utils/PausableUpgradeable.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "openzeppelin-contracts/utils/Address.sol";
import {IEVault} from "euler-vault-kit/EVault/IEVault.sol";
import {VaultBase} from "src/twyne/VaultBase.sol";
import {VaultManager} from "src/twyne/VaultManager.sol";
import {CollateralVaultFactory} from "src/TwyneFactory/CollateralVaultFactory.sol";
import {SafeERC20Lib, IERC20 as IERC20_Euler} from "euler-vault-kit/EVault/shared/lib/SafeERC20Lib.sol";

/// @title CollateralVaultBase
/// @notice Provides general vault functionality applicable to any external integration.
/// @dev This isn't a ERC4626 vault, nor does it comply with ERC20 specification.
/// @dev It only supports name, symbol, balanceOf(address) and reverts for all other ERC20 fns.
/// @notice In this contract, the EVC is authenticated before any action that may affect the state of the vault or an account.
/// @notice This is done to ensure that if its EVC calling, the account is correctly authorized.
abstract contract CollateralVaultBase is VaultBase {
    uint internal constant MAXFACTOR = 1e4;
    address internal constant permit2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    address public immutable targetVault;

    uint public totalAssetsDepositedOrReserved;

    address public borrower;
    uint public twyneLiqLTV;
    VaultManager public twyneVaultManager;
    CollateralVaultFactory public collateralVaultFactory;
    IEVault public intermediateVault;
    address private _asset;

    string public name;
    string public symbol;

    uint[50] private __gap;

    modifier onlyBorrowerAndNotExtLiquidated() {
        _callThroughEVC();
        require(_msgSender() == borrower, ReceiverNotBorrower());
        require(totalAssetsDepositedOrReserved <= IERC20(asset()).balanceOf(address(this)), ExternallyLiquidated());
        _;
    }

    modifier whenNotPaused() {
        require(!collateralVaultFactory.paused(), PausableUpgradeable.EnforcedPause());
        _;
    }

    /// @param _evc address of EVC deployed by Twyne
    /// @param _targetVault address of the target vault to borrow from
    constructor(address _evc, address _targetVault) VaultBase(_evc) {
        targetVault = _targetVault;
        name = "Collateral Vault";
        symbol = "CV";
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
        __VaultBase_init();

        _asset = address(__asset);
        borrower = __borrower;

        twyneVaultManager = __vaultManager;
        collateralVaultFactory = CollateralVaultFactory(msg.sender);
        intermediateVault = IEVault(twyneVaultManager.getIntermediateVault(address(__asset)));

        // checkLiqLTV must happen after targetVault() and asset() return meaningful values
        __vaultManager.checkLiqLTVByCollateralVault(__liqLTV);
        twyneLiqLTV = __liqLTV;
        SafeERC20.forceApprove(IERC20(_asset), address(intermediateVault), type(uint).max); // necessary for EVK repay()
        evc.enableController(address(this), address(intermediateVault)); // necessary for EVK borrowing
        evc.enableCollateral(address(this), address(this)); // necessary for EVK borrowing

        require(address(__asset) == intermediateVault.asset(), AssetMismatch());
    }

    function initialize(
        IERC20 _asset,
        address _borrower,
        uint _liqLTV,
        VaultManager _vaultManager
    ) external virtual;

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

    function borrow(uint _targetAmount, address _receiver)
        external
        onlyBorrowerAndNotExtLiquidated
        whenNotPaused
        nonReentrant
    {
        createVaultSnapshot();
        _borrow(_targetAmount, _receiver);
        evc.requireAccountAndVaultStatusCheck(address(this));
    }

    /// @notice Repays debt owed to the external lending protocol
    /// @dev If _amount is set to type(uint).max, the entire debt will be repaid
    /// @dev This function transfers the target asset from the caller to the vault, then
    /// calls the internal _repay function to handle the protocol-specific repayment logic
    /// @dev Reverts if attempting to repay more than the current debt
    /// @dev Can be called by anyone, not just the borrower
    /// @param _amount The amount of debt to repay, or type(uint).max for full repayment
    function repay(uint _amount) external onlyBorrowerAndNotExtLiquidated nonReentrant {
        createVaultSnapshot();
        uint _maxRepay = maxRepay();
        if (_amount == type(uint).max) {
            _amount = _maxRepay;
        } else {
            require(_amount <= _maxRepay, RepayingMoreThanMax());
        }

        _repay(_amount);
        evc.requireVaultStatusCheck();
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
        return intermediateVault.debtOf(address(this));
    }

    /// @dev This function reserves assets from the intermediate vault.
    /// @param _amount The amount of assets to release back to the intermediate vault.
    function reserve(uint _amount) external onlyBorrowerAndNotExtLiquidated whenNotPaused nonReentrant {
        createVaultSnapshot();
        totalAssetsDepositedOrReserved += intermediateVault.borrow(_amount, address(this));
        evc.requireAccountAndVaultStatusCheck(address(this));
    }

    /// @notice Using an amount of type(uint).max will repay the entire debt.
    /// @dev This function returns principal and accumulated interest to the intermediate vault.
    /// @param _amount The amount of assets to release back to the intermediate vault.
    function release(uint _amount) external onlyBorrowerAndNotExtLiquidated nonReentrant {
        createVaultSnapshot();
        totalAssetsDepositedOrReserved -= intermediateVault.repay(_amount, address(this));
        evc.requireVaultStatusCheck();
    }

    ///
    // Functions from VaultSimple
    // https://github.com/euler-xyz/evc-playground/blob/master/src/vaults/open-zeppelin/VaultSimple.sol
    ///

    /// @notice Creates a snapshot of the vault.
    /// @dev This function is called before any action that may affect the vault's state.
    /// @return A snapshot of the vault's state.
    function doCreateVaultSnapshot() internal pure override returns (uint) {
        return 1;
    }

    /// @notice Checks the vault's status.
    /// @dev This function is called after any action that may affect the vault's state.
    /// @param oldSnapshot The snapshot of the vault's state before the action.
    function doCheckVaultStatus(uint oldSnapshot) internal view override {
        // sanity check in case the snapshot hasn't been taken
        require(oldSnapshot != 0, SnapshotNotTaken());
        require(_hasNonNegativeExcessCredit(), VaultHasNegativeExcessCredit());
        require(!_canLiquidate(), VaultStatusLiquidatable());
    }

    ///
    // Asset transfer functions
    ///

    /// @notice Deposits a certain amount of assets for a receiver.
    /// @param assets The assets to deposit.
    function deposit(uint assets)
        public
        onlyBorrowerAndNotExtLiquidated
        whenNotPaused
        nonReentrant
    {
        createVaultSnapshot();

        SafeERC20Lib.safeTransferFrom(IERC20_Euler(asset()), borrower, address(this), assets, permit2);
        totalAssetsDepositedOrReserved += assets;

        evc.requireVaultStatusCheck();
    }

    /// @notice Deposits a certain amount of underlying asset for a receiver.
    /// @param underlying The underlying assets to deposit.
    function depositUnderlying(uint underlying)
        public
        onlyBorrowerAndNotExtLiquidated
        whenNotPaused
        nonReentrant
    {
        createVaultSnapshot();
        totalAssetsDepositedOrReserved += _depositUnderlying(underlying);
        evc.requireVaultStatusCheck();
    }

    // _depositUnderlying() requires custom implementation per protocol integration
    function _depositUnderlying(uint underlying) internal virtual returns (uint assets);

    /// @notice Withdraws a certain amount of assets for a receiver.
    /// @param assets The assets to withdraw.
    /// @param receiver The receiver of the withdrawal.
    /// @dev owner address param is unnecessary, kept to match IERC4626 interface.
    function withdraw(
        uint assets,
        address receiver
    ) public onlyBorrowerAndNotExtLiquidated nonReentrant {
        createVaultSnapshot();
        totalAssetsDepositedOrReserved -= assets;
        SafeERC20.safeTransfer(IERC20(asset()), receiver, assets);
        evc.requireAccountAndVaultStatusCheck(address(this));
    }

    /// @notice Withdraw a certain amount of collateral and transfers collateral asset's underlying asset to receiver.
    /// @param assets Amount of collateral asset to withdraw.
    /// @param receiver The receiver of the redemption.
    /// @return underlying The assets equivalent to the redeemed shares.
    function redeemUnderlying(
        uint assets,
        address receiver
    ) public onlyBorrowerAndNotExtLiquidated nonReentrant returns (uint underlying) {
        createVaultSnapshot();

        totalAssetsDepositedOrReserved -= assets;
        underlying = IEVault(asset()).redeem(assets, receiver, address(this));

        evc.requireAccountAndVaultStatusCheck(address(this));
    }

    ///
    // Twyne Custom Logic, for setting user target LTV, liquidation, rebalancing, teleporting, etc.
    ///

    /// @notice allow the user to set their own vault's LTV
    function setTwyneLiqLTV(uint _ltv) external onlyBorrowerAndNotExtLiquidated whenNotPaused nonReentrant {
        createVaultSnapshot();
        twyneVaultManager.checkLiqLTVByCollateralVault(_ltv);
        twyneLiqLTV = _ltv;
        evc.requireAccountAndVaultStatusCheck(address(this));
    }

    /// @notice check if a vault can be liquidated
    /// @dev calling canLiquidate() in other functions directly causes a read-only reentrancy issue,
    /// so move the logic to an internal function.
    function canLiquidate() external view nonReentrantRO returns (bool) {
        return _canLiquidate();
    }

    // _canLiquidate() requires custom implementation per protocol integration
    function _canLiquidate() internal view virtual returns (bool);

    /// @notice Begin the liquidation process for this vault.
    /// @dev Liquidation needs to be done in a batch.
    /// If the vault is liquidatable, this fn makes liquidator the new borrower.
    /// Liquidator is then responsible to make this collateral healthy.
    /// Liquidator may choose to wind down the position and take collateral as profit.
    function liquidate() external callThroughEVC nonReentrant {
        createVaultSnapshot();
        require(totalAssetsDepositedOrReserved <= IERC20(asset()).balanceOf(address(this)), ExternallyLiquidated());
        address liquidator = _msgSender();
        require(liquidator != borrower, SelfLiquidation());
        require(_canLiquidate(), HealthyNotLiquidatable());

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
    function isExternallyLiquidated() external view nonReentrantRO returns (bool) {
        return totalAssetsDepositedOrReserved > IERC20(asset()).balanceOf(address(this));
    }

    /// @notice Handles the aftermath of an external liquidation by the underlying lending protocol
    /// @dev Called when the vault's collateral was liquidated by the external protocol (e.g., Euler)
    /// @dev Steps performed:
    /// 1. Repay remaining external debt using funds from the liquidator
    /// 2. Calculate and provide a reward from remaining collateral to the liquidator
    /// 3. Calculate and return some collateral to the borrower
    /// 4. Release remaining collateral to the intermediate vault
    /// 5. Reset the vault state so that it cannot be used again
    /// @dev Can only be called when the vault is actually in an externally liquidated state
    /// @dev Caller needs to call intermediateVault.liquidate(collateral_vault_address, collateral_vault_address, 0, 0)
    /// in the same EVC batch if there is any bad debt left at the end of this call
    /// @dev Implementation varies depending on the external protocol integration
    function handleExternalLiquidation() external virtual;

    /// @notice Calculates the amount of excess credit that can be released back to the intermediate vault
    /// @dev Excess credit exists when the relationship between borrower collateral and reserved credit becomes unbalanced
    /// @dev This is a public wrapper for the internal _canRebalance() function, protected against reentrancy
    /// @dev The calculation varies depending on the external protocol integration
    /// @return uint The amount of excess credit that can be released, denominated in the collateral asset
    function canRebalance() external view nonReentrantRO returns (uint) {
        return _canRebalance();
    }

    function _canRebalance() internal view virtual returns (uint);

    /// @notice Releases excess credit back to the intermediate vault
    /// @dev Excess credit exists when: liqLTV_twyne * C < safety_buffer * liqLTV_external * (C + C_LP)
    /// @dev Anyone can call this function to rebalance a position
    function rebalance() external callThroughEVC nonReentrant {
        require(totalAssetsDepositedOrReserved <= IERC20(asset()).balanceOf(address(this)), ExternallyLiquidated());
        totalAssetsDepositedOrReserved -= intermediateVault.repay(_canRebalance(), address(this));
    }

    function _hasNonNegativeExcessCredit() internal view virtual returns (bool);

    function teleport(uint toDeposit, uint toReserve, uint toBorrow) external virtual;
}

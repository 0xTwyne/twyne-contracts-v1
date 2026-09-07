// SPDX-License-Identifier: MIT

pragma solidity ^0.8.28;

import {MorphoTestBase, console2} from "./MorphoTestBase.t.sol";
import {IEVault} from "euler-vault-kit/EVault/IEVault.sol";
import {IEVC} from "ethereum-vault-connector/interfaces/IEthereumVaultConnector.sol";
import {MorphoCollateralVault} from "src/twyne/MorphoCollateralVault.sol";
import {IErrors as TwyneErrors} from "src/interfaces/IErrors.sol";
import {IMorpho, MarketParams, Id} from "morpho/interfaces/IMorpho.sol";
import {IOracle} from "morpho/interfaces/IOracle.sol";
import {MathLib} from "morpho/libraries/MathLib.sol";
import {ORACLE_PRICE_SCALE} from "morpho/libraries/ConstantsLib.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";

/// @title MorphoTestTwyneGovernance
/// @notice Governance / onboarding tests for Morpho, mirroring EulerTestTwyneGovernance.
/// @dev Simulates the runtime asset-pair onboarding flow (cf. the TwyneAddMorphoMarket
///      deployment script): deploy a new self-denominated intermediate vault, configure
///      VaultManager params, whitelist the Morpho market, and verify the pair is functional.
contract MorphoTestTwyneGovernance is MorphoTestBase {
    using MathLib for uint;

    function setUp() public override {
        super.setUp();
    }

    /// @notice Governance onboards a brand-new intermediate vault for an existing Morpho market
    ///         and the pair is usable end-to-end (credit LP supply → deposit → borrow).
    function test_morpho_addNewPair() public noGasMetering {
        // 1. Governance deploys a new self-denominated intermediate vault for WSTETH and
        //    configures VaultManager params (maxLTV, externalLiqBuffer) + whitelists the market.
        vm.startPrank(admin);
        IEVault newIntermediate =
            newIntermediateVaultForMorpho(MO_COLLATERAL_TOKEN, address(oracleRouter), MO_COLLATERAL_TOKEN);
        twyneVaultManager.setMaxLiquidationLTV(address(newIntermediate), MO_LOAN_TOKEN, maxLTVInitial, 0);
        twyneVaultManager.setExternalLiqBuffer(address(newIntermediate), MO_LOAN_TOKEN, externalLiqBufferInitial, 0);
        twyneVaultManager.setAllowedMorphoMarket(morpho, address(newIntermediate), morphoMarketId, true);
        vm.stopPrank();

        // The new vault is registered as an intermediate vault
        assertTrue(twyneVaultManager.isIntermediateVault(address(newIntermediate)), "new intermediate vault not registered");

        // 2. Credit LP supplies liquidity to the new intermediate vault
        vm.startPrank(bob);
        IERC20(MO_COLLATERAL_TOKEN).approve(address(newIntermediate), type(uint256).max);
        newIntermediate.deposit(CREDIT_LP_AMOUNT, bob);
        vm.stopPrank();
        assertEq(newIntermediate.balanceOf(bob), CREDIT_LP_AMOUNT, "Credit LP deposit failed");
        assertEq(IERC20(MO_COLLATERAL_TOKEN).balanceOf(address(newIntermediate)), CREDIT_LP_AMOUNT, "Intermediate vault should hold collateral");

        // 3. Alice creates a collateral vault against the new intermediate vault + the Morpho market
        vm.startPrank(alice);
        collateralVaultFactory.createMorphoCollateralVault({
            _intermediateVault: address(newIntermediate),
            _targetVault: morpho,
            _marketParams: morphoMarketParams,
            _liqLTV: twyneLiqLTV
        });
        address[] memory vaults = collateralVaultFactory.getCollateralVaults(alice);
        MorphoCollateralVault newVault = MorphoCollateralVault(vaults[vaults.length - 1]);
        vm.stopPrank();
        assertEq(address(newVault.intermediateVault()), address(newIntermediate), "Vault wired to wrong intermediate vault");

        // 4. Deposit collateral via EVC
        vm.startPrank(alice);
        IERC20(MO_COLLATERAL_TOKEN).approve(address(newVault), type(uint256).max);
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        items[0] = IEVC.BatchItem({
            targetContract: address(newVault),
            onBehalfOfAccount: alice,
            value: 0,
            data: abi.encodeCall(newVault.deposit, (COLLATERAL_AMOUNT))
        });
        evc.batch(items);

        // 5. Borrow against the new pair — exercises the Morpho oracle + LTV paths end-to-end
        uint256 collateralPrice = IOracle(MO_ORACLE).price();
        uint256 borrowAmount =
            COLLATERAL_AMOUNT.mulDivDown(collateralPrice, ORACLE_PRICE_SCALE).wMulDown(MO_LLTV) * 95 / 100;
        newVault.borrow(borrowAmount, alice);
        vm.stopPrank();

        assertApproxEqAbs(newVault.maxRepay(), borrowAmount, 1, "Borrow against new pair failed");
        assertGt(newVault.maxRelease(), 0, "New pair should reserve credit from the new intermediate vault");
        assertEq(newVault.collateralBalance(), COLLATERAL_AMOUNT + newVault.maxRelease(), "Morpho collateral mismatch");
    }

    /// @notice Only governance (admin) can whitelist a Morpho market.
    function test_morpho_addNewPair_reverts_nonAdmin() public noGasMetering {
        vm.startPrank(alice);
        vm.expectRevert();
        twyneVaultManager.setAllowedMorphoMarket(morpho, address(morpho_intermediate_vault), morphoMarketId, true);
        vm.stopPrank();
    }
}

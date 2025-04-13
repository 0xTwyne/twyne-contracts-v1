// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.13;

import {Test, console2} from "forge-std/Test.sol";

import {GenericFactory} from "euler-vault-kit/GenericFactory/GenericFactory.sol";
import {CollateralVaultFactory} from "src/TwyneFactory/CollateralVaultFactory.sol";

import {EVault} from "euler-vault-kit/EVault/EVault.sol";
import {ProtocolConfig} from "euler-vault-kit/ProtocolConfig/ProtocolConfig.sol";

import {Dispatch} from "euler-vault-kit/EVault/Dispatch.sol";

import {Initialize} from "euler-vault-kit/EVault/modules/Initialize.sol";
import {Token} from "euler-vault-kit/EVault/modules/Token.sol";
import {Vault} from "euler-vault-kit/EVault/modules/Vault.sol";
import {Borrowing} from "euler-vault-kit/EVault/modules/Borrowing.sol";
import {Liquidation} from "euler-vault-kit/EVault/modules/Liquidation.sol";
import {BalanceForwarder} from "euler-vault-kit/EVault/modules/BalanceForwarder.sol";
import {Governance} from "euler-vault-kit/EVault/modules/Governance.sol";
import {RiskManager} from "euler-vault-kit/EVault/modules/RiskManager.sol";

import {IEVault} from "euler-vault-kit/EVault/IEVault.sol";
import {Base} from "euler-vault-kit/EVault/shared/Base.sol";
import {EulerRouter} from "euler-price-oracle/src/EulerRouter.sol";

import {EthereumVaultConnector} from "ethereum-vault-connector/EthereumVaultConnector.sol";

import {TestERC20} from "euler-vault-kit/../test/mocks/TestERC20.sol";
import {MockBalanceTracker} from "euler-vault-kit/../test/mocks/MockBalanceTracker.sol";
import {MockPriceOracle} from "euler-vault-kit/../test/mocks/MockPriceOracle.sol";
import {IRMTestDefault} from "euler-vault-kit/../test/mocks/IRMTestDefault.sol";
import {IHookTarget} from "euler-vault-kit/interfaces/IHookTarget.sol";
import {SequenceRegistry} from "euler-vault-kit/SequenceRegistry/SequenceRegistry.sol";

import {AssertionsCustomTypes} from "euler-vault-kit/../test/helpers/AssertionsCustomTypes.sol";

import "euler-vault-kit/EVault/shared/Constants.sol";
import {EulerCollateralVault} from "src/twyne/EulerCollateralVault.sol";
import {UpgradeableBeacon} from "openzeppelin-contracts/proxy/beacon/UpgradeableBeacon.sol";

contract TwyneVaultTestBase is AssertionsCustomTypes, Test {
    EthereumVaultConnector public evc;
    address admin;
    address feeReceiver;
    address protocolFeeReceiver;
    ProtocolConfig protocolConfig;
    address balanceTracker;
    MockPriceOracle oracle;
    address unitOfAccount;
    address permit2;
    address sequenceRegistry;
    GenericFactory public factory;
    CollateralVaultFactory public collateralVaultFactory;

    Base.Integrations integrations;
    Dispatch.DeployedModules modules;

    TestERC20 assetTST;
    TestERC20 assetTST2;

    IEVault public eTST;
    IEVault public eTST2;

    address initializeModule;
    address tokenModule;
    address vaultModule;
    address borrowingModule;
    address liquidationModule;
    address riskManagerModule;
    address balanceForwarderModule;
    address governanceModule;

    // addresses shared in every test file, set based on chainId AKA FOUNDRY_PROFILE
    address aavePool;
    address eulerWETH;
    // address eulerCBBTC;
    address eulerWSTETH;
    address eulerUSDC;
    address eulerUSDS;
    address USDC;
    address WETH;
    address WSTETH;
    address USDS;
    address constant USD = address(840);
    uint256 ethPrice;
    EulerRouter eulerOnChain;

    error UnknownProfile();

    function setUp() public virtual {
        string memory foundryProfile = vm.envString("FOUNDRY_PROFILE");
        if (keccak256(abi.encodePacked((foundryProfile))) == keccak256(abi.encodePacked(("base")))) {
            aavePool = 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5;
            eulerWETH = 0x859160DB5841E5cfB8D3f144C6b3381A85A4b410;
            // eulerCBBTC = 0x882018411Bc4A020A879CEE183441fC9fa5D7f8B;
            eulerWSTETH = 0x7b181d6509DEabfbd1A23aF1E65fD46E89572609;
            eulerUSDC = 0x0A1a3b5f2041F33522C4efc754a7D096f880eE16;
            eulerUSDS = 0x556d518FDFDCC4027A3A1388699c5E11AC201D8b;
            eulerOnChain = EulerRouter(0x6E183458600e66047A0f4D356d9DAa480DA1CA59);
        } else if (keccak256(abi.encodePacked((foundryProfile))) == keccak256(abi.encodePacked(("sonic")))) {
            aavePool = 0x5362dBb1e601abF3a4c14c22ffEdA64042E5eAA3;
            eulerWETH = 0xa5cd24d9792F4F131f5976Af935A505D19c8Db2b;
            // eulerCBBTC = address(0); // no BTC pool on Sonic Euler yet
            eulerWSTETH = 0x05d57366B862022F76Fe93316e81E9f24218bBfC;
            eulerUSDC = 0x196F3C7443E940911EE2Bb88e019Fd71400349D9;
            eulerUSDS = 0xB38D431e932fEa77d1dF0AE0dFE4400c97e597B8; // actually this is scUSD
            eulerOnChain = EulerRouter(0x231811a9574dDE19e49f72F7c1cAC3085De6971a);
        }  else if (keccak256(abi.encodePacked((foundryProfile))) == keccak256(abi.encodePacked(("mainnet")))) {
            aavePool = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
            eulerWETH = 0xD8b27CF359b7D15710a5BE299AF6e7Bf904984C2;
            // eulerCBBTC = 0x056f3a2E41d2778D3a0c0714439c53af2987718E;
            eulerWSTETH = 0xbC4B4AC47582c3E38Ce5940B80Da65401F4628f1;
            eulerUSDC = 0x797DD80692c3b2dAdabCe8e30C07fDE5307D48a9;
            eulerUSDS = 0x000000000000000000000000000000000000DdDD;
            eulerOnChain = EulerRouter(0x83B3b76873D36A28440cF53371dF404c42497136);
        } else {
            revert UnknownProfile();
        }

        USDC = IEVault(eulerUSDC).asset();
        WETH = IEVault(eulerWETH).asset();
        WSTETH = IEVault(eulerWSTETH).asset();
        USDS = IEVault(eulerUSDS).asset();
        vm.label(USDC, "USDC");
        vm.label(WETH, "WETH");
        vm.label(WSTETH, "WSTETH");
        vm.label(USDS, "USDS");

        admin = makeAddr("admin");
        feeReceiver = makeAddr("feeReceiver");
        protocolFeeReceiver = makeAddr("protocolFeeReceiver");
        evc = new EthereumVaultConnector();
        factory = new GenericFactory(admin);
        collateralVaultFactory = new CollateralVaultFactory(admin, address(evc));

        protocolConfig = new ProtocolConfig(admin, protocolFeeReceiver);
        balanceTracker = address(new MockBalanceTracker());
        oracle = new MockPriceOracle();
        unitOfAccount = address(1);
        permit2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
        sequenceRegistry = address(new SequenceRegistry());
        integrations =
            Base.Integrations(address(evc), address(protocolConfig), sequenceRegistry, balanceTracker, permit2);

        initializeModule = address(new Initialize(integrations));
        tokenModule = address(new Token(integrations));
        vaultModule = address(new Vault(integrations));
        borrowingModule = address(new Borrowing(integrations));
        liquidationModule = address(new Liquidation(integrations));
        riskManagerModule = address(new RiskManager(integrations));
        balanceForwarderModule = address(new BalanceForwarder(integrations));
        governanceModule = address(new Governance(integrations));

        modules = Dispatch.DeployedModules({
            initialize: initializeModule,
            token: tokenModule,
            vault: vaultModule,
            borrowing: borrowingModule,
            liquidation: liquidationModule,
            riskManager: riskManagerModule,
            balanceForwarder: balanceForwarderModule,
            governance: governanceModule
        });

        address evaultImpl = address(new EVault(integrations, modules));

        address eulerUSDCCollateralVaultImpl = address(new EulerCollateralVault(address(evc), eulerUSDC));
        address eulerWETHCollateralVaultImpl = address(new EulerCollateralVault(address(evc), eulerWETH));

        vm.startPrank(admin);
        protocolConfig.setInterestFeeRange(0, 0); // set fee range to zero
        protocolConfig.setProtocolFeeShare(0); // set protocol fee to zero
        factory.setImplementation(evaultImpl);
        collateralVaultFactory.setBeacon(eulerUSDC, address(new UpgradeableBeacon(eulerUSDCCollateralVaultImpl, admin)));
        collateralVaultFactory.setBeacon(eulerWETH, address(new UpgradeableBeacon(eulerWETHCollateralVaultImpl, admin)));
        vm.stopPrank();

        assetTST = new TestERC20("Test Token", "TST", 18, false);
        assetTST2 = new TestERC20("Test Token 2", "TST2", 18, false);

        vm.startPrank(admin);
        eTST = IEVault(
            factory.createProxy(address(0), true, abi.encodePacked(address(assetTST), address(oracle), unitOfAccount))
        );
        eTST.setHookConfig(address(0), 0);
        eTST.setInterestRateModel(address(new IRMTestDefault()));
        eTST.setMaxLiquidationDiscount(0.2e4);
        eTST.setFeeReceiver(feeReceiver);

        eTST2 = IEVault(
            factory.createProxy(address(0), true, abi.encodePacked(address(assetTST2), address(oracle), unitOfAccount))
        );
        eTST2.setHookConfig(address(0), 0);
        eTST2.setInterestRateModel(address(new IRMTestDefault()));
        eTST2.setMaxLiquidationDiscount(0.2e4);
        eTST2.setFeeReceiver(feeReceiver);
        vm.stopPrank();
    }

    function getSubAccount(address primary, uint8 subAccountId) internal pure returns (address) {
        require(subAccountId <= 256, "invalid subAccountId");
        return address(uint160(uint160(primary) ^ subAccountId));
    }
}

contract MockHook is IHookTarget {
    error E_OnlyAssetCanDeposit();
    error E_OperationDisabled();

    function isHookTarget() external pure override returns (bytes4) {
        return this.isHookTarget.selector;
    }

    // deposit is only allowed for the asset
    function deposit(uint256, address) external view {
        address asset = IEVault(msg.sender).asset();

        // these calls are just to test if there's no RO-reentrancy for the hook target
        IEVault(msg.sender).totalBorrows();
        IEVault(msg.sender).balanceOf(address(this));

        if (asset != caller()) revert E_OnlyAssetCanDeposit();
    }

    // all the other hooked ops are disabled
    fallback() external {
        revert E_OperationDisabled();
    }

    function caller() internal pure returns (address _caller) {
        assembly {
            _caller := shr(96, calldataload(sub(calldatasize(), 20)))
        }
    }
}

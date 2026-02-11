// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.4;

library IERC4626StataToken {
    struct SignatureParams {
        uint8 v;
        bytes32 r;
        bytes32 s;
    }
}

interface IAaveV3ATokenWrapper {
    error AddressEmptyCode(address target);
    error ControllerDisabled();
    error ECDSAInvalidSignature();
    error ECDSAInvalidSignatureLength(uint256 length);
    error ECDSAInvalidSignatureS(bytes32 s);
    error ERC1967InvalidImplementation(address implementation);
    error ERC1967NonPayable();
    error ERC20InsufficientAllowance(address spender, uint256 allowance, uint256 needed);
    error ERC20InsufficientBalance(address sender, uint256 balance, uint256 needed);
    error ERC20InvalidApprover(address approver);
    error ERC20InvalidReceiver(address receiver);
    error ERC20InvalidSender(address sender);
    error ERC20InvalidSpender(address spender);
    error ERC2612ExpiredSignature(uint256 deadline);
    error ERC2612InvalidSigner(address signer, address owner);
    error ERC4626ExceededMaxDeposit(address receiver, uint256 assets, uint256 max);
    error ERC4626ExceededMaxMint(address receiver, uint256 shares, uint256 max);
    error ERC4626ExceededMaxRedeem(address owner, uint256 shares, uint256 max);
    error ERC4626ExceededMaxWithdraw(address owner, uint256 assets, uint256 max);
    error EVC_InvalidAddress();
    error EnforcedPause();
    error ExpectedPause();
    error FailedCall();
    error IncorrectEVC();
    error InvalidAccountNonce(address account, uint256 currentNonce);
    error InvalidInitialization();
    error NotAuthorized();
    error NotCollateralVault();
    error NotInitializing();
    error OnlyPauseGuardian(address caller);
    error OwnableInvalidOwner(address owner);
    error OwnableUnauthorizedAccount(address account);
    error PoolAddressMismatch(address pool);
    error SafeERC20FailedOperation(address token);
    error StaticATokenInvalidZeroShares();
    error UUPSUnauthorizedCallContext();
    error UUPSUnsupportedProxiableUUID(bytes32 slot);
    error ZeroIncentivesControllerIsForbidden();

    event Approval(address indexed owner, address indexed spender, uint256 value);
    event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares);
    event EIP712DomainChanged();
    event Initialized(uint64 version);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event Paused(address account);
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Unpaused(address account);
    event Upgraded(address indexed implementation);
    event Withdraw(
        address indexed sender, address indexed receiver, address indexed owner, uint256 assets, uint256 shares
    );

    function DOMAIN_SEPARATOR() external view returns (bytes32);
    function EVC() external view returns (address);
    function INCENTIVES_CONTROLLER() external view returns (address);
    function POOL() external view returns (address);
    function POOL_ADDRESSES_PROVIDER() external view returns (address);
    function RAY() external view returns (uint256);
    function UPGRADE_INTERFACE_VERSION() external view returns (string memory);
    function aToken() external view returns (address);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 value) external returns (bool);
    function asset() external view returns (address);
    function balanceOf(address account) external view returns (uint256);
    function burnShares_CV(uint256 shares) external;
    function claimReward(address to, address reward) external returns (uint256);
    function collateralVaultFactory() external view returns (address);
    function convertToAssets(uint256 shares) external view returns (uint256);
    function convertToShares(uint256 assets) external view returns (uint256);
    function decimals() external view returns (uint8);
    function deposit(uint256 assets, address receiver) external returns (uint256);
    function depositATokens(uint256 assets, address receiver) external returns (uint256);
    function depositWithPermit(
        uint256 assets,
        address receiver,
        uint256 deadline,
        IERC4626StataToken.SignatureParams memory sig,
        bool depositToAave
    ) external returns (uint256);
    function eip712Domain()
        external
        view
        returns (
            bytes1 fields,
            string memory name,
            string memory version,
            uint256 chainId,
            address verifyingContract,
            bytes32 salt,
            uint256[] memory extensions
        );
    function initialize(address aToken, address owner, string memory staticATokenName, string memory staticATokenSymbol)
        external;
    function latestAnswer() external view returns (int256);
    function maxDeposit(address) external pure returns (uint256);
    function maxMint(address) external pure returns (uint256);
    function maxRedeem(address) external pure returns (uint256);
    function maxWithdraw(address) external pure returns (uint256);
    function mint(uint256 shares, address receiver) external returns (uint256);
    function name() external view returns (string memory);
    function nonces(address owner) external view returns (uint256);
    function owner() external view returns (address);
    function paused() external view returns (bool);
    function permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external;
    function previewDeposit(uint256 assets) external view returns (uint256);
    function previewMint(uint256 shares) external view returns (uint256);
    function previewRedeem(uint256 shares) external view returns (uint256);
    function previewWithdraw(uint256 assets) external view returns (uint256);
    function proxiableUUID() external view returns (bytes32);
    function rebalanceATokens_CV(uint256 shares) external;
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256);
    function redeemATokens(uint256 shares, address receiver, address owner) external returns (uint256);
    function renounceOwnership() external;
    function setPaused(bool paused) external;
    function skim(address receiver) external;
    function symbol() external view returns (string memory);
    function totalAssets() external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
    function transferOwnership(address newOwner) external;
    function upgradeToAndCall(address newImplementation, bytes memory data) external payable;
    function version() external pure returns (uint256);
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256);
}

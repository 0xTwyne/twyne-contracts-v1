# Twyne Contracts v1

Full details of the Twyne protocol are found at [https://twyne.gitbook.io/](https://twyne.gitbook.io/)

The Twyne protocol builds on Euler Finance's [EVC](https://github.com/euler-xyz/ethereum-vault-connector) and [EVK](https://github.com/euler-xyz/euler-vault-kit) to offer lender extra yield and borrowers extra borrowing power. As of the release on June 16, the Twyne codebase contains 667 lines of custom code in the src/twyne and src/TwyneFactory directories.

## Running tests

Remember to use `forge install` to install all dependencies before running tests. If you are setting up your `.env` for the first time: `cp .env.example .env`

### To run all tests

```sh
forge test -vv
```

### Running a single test

```sh
forge test --match-test "test_e_second_creditDeposit" -vv
```

### To run tests in certain test files

```sh
forge test --match-contract "EulerTestEdgeCases|EulerLiquidationTest" -vv
```

Note: using llama RPCs like https://eth.llamarpc.com can result in errors due to rate limiting. [Blutgang](https://github.com/rainshowerLabs/blutgang) is recommended to avoid this.

### To run differential tests

Assuming you have cloned `py-fuzz` repo in the same directory as this repo, and you have installed all dependencies in `py-fuzz`:

```sh
source ../py-fuzz/venv/bin/activate
forge test --match-contract "testFuzz_e_IRMTwyneCurve" -vv
```

### To check test coverage

```sh
forge coverage --no-match-coverage "test|script"
```

And if you want a lcov file to use with a VSCode extension such as [Coverage Gutters](https://marketplace.visualstudio.com/items?itemName=ryanluker.vscode-coverage-gutters), add the `--report lcov` argument to the above.

### Gas snapshot

To save a gas-snapshot of tests:

```sh
forge snapshot --match-path "test/twyne/*"
```

To compare the gas consumption with the saved gas-snapshot:

```sh
forge snapshot --match-path "test/twyne/*" --diff
```

To view the gas consumption of contract functions:

```sh
forge test --match-path "test/twyne/EulerTestNormalActions.t.sol" --gas-report
```

## Deployment to Base mainnet

Note: If you will reuse an existing EVK deployment instead of spending gas on a fresh EVK deployment, keep in mind that a new GenericFactory should be deployed (and address updated in the Base deployment script) if you do NOT want the old intermediate vaults showing up on the frontend.

1. Clone evk-periphery and checkout the `deployment-scripts` branch. Run `forge install`. You need to have the [euler-interfaces](https://github.com/euler-xyz/euler-interfaces) repository cloned to the same parent directory where evk-periphery is located. Edit the script at scripts/50_CoreAndPeriphery.s.sol to remove logic related to "Deploying EUL" and "Deploying rEUL" because these are not needed. You should make sure to delete the euler-interfaces/address/8453 directory (or whichever chain you are deploying to) and evk-periphery/script/deployments/* directories.
2. Set .env to specify the values `DEPLOYMENT_RPC_URL` and `DEPLOYER_KEY`, then run Euler's deploy script with `FORCE_MULTISIG_ADDRESSES=true ./script/interactiveDeployment.sh` and choose option 50. Choose "No" for the OFT Adapter question and enter the deployer address for any address prompts and press enter to use the default value for Uniswap and other prompts.
3. Copy the output files with deployed addresses at evk-periphery/script/deployments/onchain/8453/output to the tech-notes/ repo in a new directory for this specific deployment to store the addresses in a shared place.
4. Now back in the twyne-contracts repo, make sure the .env file has the production private keys with gas to deploy to Base. Also edit script/TwyneDeployEulerIntegration.s.sol so `productionSetup()` contains the addresses of the contracts just deployed by the EVK deploy script. Finally, edit script/TwyneDeployEulerIntegration.s.sol to comment out everything in `run()` except `productionSetup()` and `twyneStuff()`.
5. Run the Twyne deploy script:
`forge script script/TwyneDeployEulerIntegration.s.sol:TwyneDeployEulerIntegration --broadcast -vv --verify --verifier etherscan --verifier-url https://api.basescan.org/api --etherscan-api-key <YOUR_ETHERSCAN_API_KEY>`
6. Copy the TwyneAddresses_output.json output file to the tech-notes repo to store the addresses in a shared place and push the commit.

## Verify contracts after deployment

Use [forge to verify contracts](https://docs.etherscan.io/etherscan-v2/contract-verification/verify-with-foundry#verify-an-existing-contract) after deploying.

1. Verify `EulerRouter`

    Use `cast abi-encode "constructor(address,address)"` to generate the constructor calldata needed for verification:

    ```sh
    forge verify-contract --watch --chain base 0xb18e8F37F51A5C5ccA92aF0B926aA25E7B4Bda77 lib/euler-price-oracle/src/EulerRouter.sol:EulerRouter --verifier etherscan --etherscan-api-key <YOUR_ETHERSCAN_API_KEY> --constructor-args 0x000000000000000000000000c36aed7b7816aa21b660a33a637a8f9b9b70ad6c000000000000000000000000224b9735166658a049bc8813be062dca65a3a949
    ```

2. Verify intermediate vault's proxy contract:

   ```sh
   forge verify-contract  --chain base --num-of-optimizations 20000 --watch --constructor-args $(cast abi-encode "constructor(bytes)" $(cast abi-encode --packed "(bytes4,bytes)" 00000000 $(cast abi-encode --packed "(address,address,address)" <COLLATERAL_ADDRESS> <ORACLE_ADDRESS> <UNIT_OF_ACCOUNT>))) --verifier etherscan --etherscan-api-key <YOUR_ETHERSCAN_API_KEY> --compiler-version 0.8.24+commit.e11b9ed9 0xB49414341e06986FE83f17c971cCA14bD4362aF0  lib/euler-vault-kit/src/GenericFactory/BeaconProxy.sol:BeaconProxy
   ```

## Post-deployment scripts

### Admin ownership transfer

1. Update TwyneAdminTransfer.s.sol script to include the correct multisig address that will become the new owner of the Twyne protocol. Also make sure that TwyneAddresses_output.json exists in the main directory with the on-chain addresses that you wish to change ownership for.
2. Update the .env file to set `DEPLOYER_PRIVATE_KEY` to the deployer EOA's private key. Test the deploy script without the broadcast flag to verify it works: `forge script script/TwyneAdminTransfer.s.sol:TwyneAdminTransfer -vv`
3. Run the same script command with the `--broadcast` flag

## Deploying EulerWrapper periphery contract

1. Make sure the proper commit hash of the codebase is checked out
2. Make sure that TwyneAddresses_output.json exists in the main directory with the on-chain addresses that you wish to verify.
3. Update the .env file to set `DEPLOYER_ADDRESS` and `DEPLOYER_PRIVATE_KEY` with the deployer EOA info.
4. Test the periphery deployment script runs without errors: `forge script script/TwynePeriphery.s.sol:TwynePeriphery -vv`
5. To run the periphery deployment script on-chain: `forge script script/TwynePeriphery.s.sol:TwynePeriphery --broadcast -vv --verify --verifier etherscan --verifier-url https://api.basescan.org/api --etherscan-api-key <YOUR_ETHERSCAN_API_KEY>`
6. Add the new contract address to the tech-notes repo in the appropriate JSON file

## Testing deployment

1. Make sure that TwyneAddresses_output.json exists in the main directory with the on-chain addresses that you wish to verify.
2. Run the post deployment checks script: `forge script script/PostDeploymentCheck.s.sol:PostDeploymentCheck -vv`

### Add new vault pair

Note: After the first deployment on a chain, a Gnosis Safe address is `TwyneVaultManager`'s owner. To add new assets, `TwyneAddVaultPair.s.sol` publishes the required transactions to Gnosis Safe UI.

1. Update TwyneAddVaultPair.s.sol script to include the correct asset addresses that will be added to the Twyne protocol. Also make sure that TwyneAddresses_output.json exists in the main directory with the on-chain addresses that you wish to change ownership for.
2. Update the .env file to set `DEPLOYER_PRIVATE_KEY` to the deployer EOA's private key. For each `PHASE = [0,1]`, (update PHASE, SEND, SAFE vars in the script, and the following env vars), execute the following command. In Phase 0, the deployer EOA is executing the actions. In Phase 1, the Safe will be executing the on-chain actions, which is when the hardware wallet args are needed in Phase 1. In order to find the correct MNEMONIC_INDEX, you need to find the index of your address in your wallet using Rabby or another wallet that displays all of your addresses.

```bash
CHAIN=base WALLET_TYPE=ledger MNEMONIC_INDEX=3 forge script script/TwyneAddVaultPair.s.sol --verify --verifier etherscan --verifier-url https://api.basescan.org/api --etherscan-api-key <YOUR_ETHERSCAN_API_KEY>
```

3. Run the same script command from step 2 with the `--broadcast` flag to execute on-chain. Do this for Phase 0 and then Phase 1.

### Change the supply/deposit caps (testing only, need to use multisig for on-chain change)

1. Update TwyneSetCaps.s.sol script to include the correct cap values. These values are acquired from the euler_supply_cap.py script found at twyne-frontend/scripts/euler_supply_cap.py. After updating the cap values, also make sure that vaultManager is set properly in the script.
2. (NOTE: This step doesn't work on-chain because the vaultManager owner is the multisig). Update the .env file to set `DEPLOYER_PRIVATE_KEY` to the deployer EOA's private key. Test the deploy script without the broadcast flag to verify it works: `forge script script/TwyneSetCaps.s.sol:TwyneSetCaps -vv`
3. Run the same script command with the `--broadcast` flag

### Post-deployment check script

1. Make sure that TwyneAddresses_output.json exists in the main directory with the on-chain addresses that you wish to check for correctness.
2. Test the deploy script without the broadcast flag to verify it works: `forge script script/PostDeploymentCheck.s.sol:PostDeploymentCheck -vv`

### Collateral vault proxy upgrade

These steps cover testing and performing a proxy (beacon) upgrade for collateral vaults (e.g., upgrading to v1 where `teleport` supports Euler subaccounts).

#### Tests
1. Create a test file under `test/upgrades` to validate the specific contract changes using onchain addresses and a simulated proxy upgrade (e.g., `test_e_teleportSubAccountProxyUpgrade`).
2. Add another test that performs a simulated proxy upgrade and verifies basic functions (deposit, borrow, withdraw, repay) work before and after the upgrade (e.g., `test_e_postUpgradeCollateralVault`).
3. Add a test that is intended to run after the real onchain upgrade to verify the basic functions continue to work (e.g., `test_e_postRealUpgradeCollateralVault`).

#### Onchain upgrade
1. Update `script/TwyneUpgradeBeacon.s.sol`:
    - Set `SAFE` to your protocol Gnosis Safe address.
    - Set `PHASE` to `0` to deploy the new collateral vault implementation. Phase 0 writes `UpgradeBeaconPhase0_<chainid>.json` for Phase 1 to consume.
    - Ensure `TwyneAddresses_output.json` exists at the repo root and includes `.collateralVaultFactory` and `.deployerExampleCollateralVault`.

2. Run Phase 0 (dry run first):

    ```sh
    FORGE_PROFILE=base CHAIN=base WALLET_TYPE=ledger MNEMONIC_INDEX=3 forge script script/TwyneUpgradeBeacon.s.sol --verify --verifier etherscan --verifier-url https://api.basescan.org/api --etherscan-api-key <YOUR_ETHERSCAN_API_KEY>
    ```

3. Run Phase 0 with broadcast:

    ```sh
    FORGE_PROFILE=base CHAIN=base WALLET_TYPE=ledger MNEMONIC_INDEX=3 forge script script/TwyneUpgradeBeacon.s.sol --verify --verifier etherscan --verifier-url https://api.basescan.org/api --etherscan-api-key <YOUR_ETHERSCAN_API_KEY> --broadcast
    ```

4. Update `PHASE` to `1` in `script/TwyneUpgradeBeacon.s.sol` and run Phase 1 to upgrade the `UpgradeableBeacon` that backs collateral vault proxies:

    ```sh
    FORGE_PROFILE=base CHAIN=base WALLET_TYPE=ledger MNEMONIC_INDEX=3 SENDER=<ADDRESS> forge script script/TwyneUpgradeBeacon.s.sol --ffi
    ```
   Only `WALLET_TYPE=ledger` is currently supported.

5. Validate the upgrade:
  - Confirm `collateralVaultFactory.collateralVaultBeacon(<TARGET_VAULT>)` now points to the new implementation (visible on the block explorer), and the version increments on a sample vault.
  - Optionally run the post-deployment checks script: `forge script script/PostDeploymentCheck.s.sol:PostDeploymentCheck -vv`.
  - Run the post-upgrade validation test:

    ```sh
    forge test --match-contract EulerTestEdgeCases --match-test test_e_postRealUpgradeCollateralVault -vv
    ```
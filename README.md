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

# DashEVM Genesis Contracts

The system contracts installed in the DashEVM genesis block: validator set, staking,
slashing, governance and fee handling. This repository is a fork of
[bnb-chain/bsc-genesis-contract](https://github.com/bnb-chain/bsc-genesis-contract) at master
commit `8464181`. All DashEVM changes are on top of it:

```
git diff 8464181 main
```

The node that calls these contracts is
[DashEVM/dashevm-node](https://github.com/DashEVM/dashevm-node). The live genesis file and the
script that compiles these contracts into it (`make_genesis.py`) are in
[DashEVM/dashevm-bridge](https://github.com/DashEVM/dashevm-bridge) under `chain/`.

## What DashEVM changes

- **Post quantum validators.** `StakeHub` registers validators by ML-DSA-87 consensus key and
  proof of possession instead of BLS. Key rotation is checked against the working validator
  set.
- **Permissioned launch.** While `StakeHub.permissioned` is on, only allowlisted operators can
  create validators, stake per pool is capped (`launchStakeCap`), and governance votes are
  capped with it (`GovToken`).
- **Conflicting seal evidence.** `SlashIndicator.submitConflictingSealEvidence` jails a
  validator that sealed two conflicting blocks, verified through precompile `0x0f02`.
- **No fee burn.** The native coin is bridged DASH, so gas fees are never burned. The upstream
  burn share goes to the `FeeVault` predeploy (`bridgechain/FeeVault.sol`), which pays the
  community share to validators and their delegators (`bridgechain/ValidatorRewards.sol`) and
  the treasury. No staking inflation.
- **Fee currencies.** `finallayer/FeeCurrencyDirectory.sol` and the rate oracles list the
  ERC-20 tokens that can pay gas.

## Build and test

Install [Foundry](https://book.getfoundry.sh), the npm dependencies (OpenZeppelin) and
forge-std v1.7.3:

```shell
npm install
forge install --no-git foundry-rs/forge-std@v1.7.3
forge build
forge test --match-path 'test/{BridgeChain,DashEVM,ConflictingSealEvidence,FinalLayer}*'
```

The original BSC test suite (`forge test --fork-url <archive node>`) runs against BSC and
does not cover the DashEVM changes.

## Security

See [SECURITY.md](SECURITY.md) for how to report a vulnerability.

## License

Apache License 2.0, see [LICENCE](LICENCE).

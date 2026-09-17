# @quevra/contracts

Foundry package for Quevra protocol contracts on Monad.

`ValidatorRegistry` is deployed with a single `authAddress`, `amount`, and `commission`. The owner can update those values; proposers read them (or `stakingPayload(secp, bls)`) and sign the Monad `addValidator` payload. Anyone can later **execute** a proposal by paying `amount`; the contract forwards the stored signatures to `addValidator` at `0x1000`.

## Usage

```shell
forge build
forge test
forge fmt
anvil --network monad
forge script script/DeployValidatorRegistry.s.sol:DeployValidatorRegistry --account monad-deployer --broadcast
```

# @quevra/contracts

Foundry package for Quevra protocol contracts on Monad.

`ValidatorRegistry` accepts operator **proposals** of consensus keys plus signatures proving those keys. The operator does not set `authAddress`, stake, or commission. Anyone can later **execute** a proposal by supplying those values; the contract forwards the stored signatures to `addValidator` at `0x1000`.

## Usage

```shell
forge build
forge test
forge fmt
anvil --network monad
forge script script/DeployValidatorRegistry.s.sol:DeployValidatorRegistry --account monad-deployer --broadcast
```

# @quevra/contracts

Foundry package for Quevra protocol contracts on Monad.

`ValidatorRegistry` is deployed with a single `authAddress`, `amount`, and `commission`. The owner can update those values; proposers read them (or `stakingPayload(secp, bls)`) and sign the Monad `addValidator` payload. Anyone can later **execute** a proposal by paying `amount`; the contract forwards the stored signatures to `addValidator` at `0x1000`.

Access control, pause, and reentrancy protection come from OpenZeppelin Contracts v5:

- `Ownable2Step` for two-step ownership transfer (`transferOwnership` then `acceptOwnership`)
- `Pausable` so the owner can halt propose/execute (cancel remains available)
- `ReentrancyGuardTransient` on `execute` (EIP-1153, Cancun)

The staking precompile interface is the official Monad `IMonadStaking` ABI.

## Usage

```shell
forge build
forge test
forge fmt
anvil --network monad
forge script script/DeployValidatorRegistry.s.sol:DeployValidatorRegistry --account monad-deployer --broadcast
```

# Quevra Contracts

## Test Architecture

Use inheritance-based fixtures for all Solidity tests.

- `BaseTest` is the only global harness: shared actors, Monad handles, funding, assertions, and generic helpers only. Never deploy protocol contracts here.
- Every contract has a dedicated `<Contract>Fixture` that deploys only that contract and its direct dependencies.
- Tests live in `test/<Contract>.t.sol` as `<Contract>Test` and inherit from the matching fixture.
- Fixture inheritance should mirror real contract dependencies (e.g. `StakingVaultFixture -> ValidatorRegistryFixture`) and remain shallow.
- Cross-contract flows belong in `test/integration`; invariants in `test/invariant`; fork tests in `test/fork`.
- Avoid duplicated deployments, hidden setup, circular inheritance, and helpers that perform the behavior under test.

Example:

```solidity
abstract contract BaseTest is Test {}

abstract contract ValidatorRegistryFixture is BaseTest {
    ValidatorRegistry registry;
}

abstract contract StakingVaultFixture is ValidatorRegistryFixture {
    StakingVault vault;
}

contract StakingVaultTest is StakingVaultFixture {}
```

## Checks

Before finishing:

- Contract changes: `pnpm --filter @quevra/contracts check`
- Workspace-wide changes: `pnpm check`

## Protocol Time Model

**Monad epoch is the atomic unit of protocol time. Quevra cycle is the economic accounting boundary.**

| Tigris | Quevra |
|---|---|
| `block.timestamp` | Monad epoch |
| Epoch | Cycle |
| Timestamp-based accounting | Cycle-based accounting |

Rules:

- Never use `block.timestamp` or block numbers for protocol economics.
- All cycle-scoped state (veMON voting power, voting, validator selection, gauges, rewards, refunds, checkpoints) must transition on **cycle boundaries**.
- Use the shared protocol epoch/cycle abstraction; do not reimplement cycle calculations per contract.
- When adapting Tigris code, preserve the economic behavior but translate its timestamp/epoch logic into Monad epoch/cycle semantics.

Tests must model **Monad epoch progression and cycle rollover**, not timestamp progression, for economic behavior.
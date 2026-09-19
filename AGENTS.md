# Quevra Contracts

## Solidity test structure

Solidity tests use an inheritance-based fixture model. New tests must follow the existing hierarchy instead of adding ad hoc setup directly to test contracts.

- `test/fixtures/BaseTest.sol` is the only global harness. It may contain Foundry/Monad handles, common actors, chain configuration, reusable funding, shared assertions, and small helper functions that are truly useful across contract suites. It must not deploy protocol contracts, mutate contract-specific state, or hide scenario setup.
- Every tested contract must have a dedicated fixture named `<ContractName>Fixture` under `test/fixtures`. That fixture deploys and configures only that contract and its direct dependencies.
- Unit tests live in `test/<ContractName>.t.sol`, are named `<ContractName>Test`, and inherit from the matching fixture. Test cases stay in the test file; deployment and reusable setup stay in the fixture.
- Fixture inheritance is appropriate only when the contract exposes behavior through an upstream dependency path. For example, `StakingVaultFixture` inherits `ValidatorRegistryFixture` because the vault executes a registry request, and `ValidatorVoterFixture` inherits `StakingControllerFixture` because voter creation routes through the controller. Keep inheritance shallow and aligned with real contract dependencies.
- Avoid circular inheritance, duplicated deployments, oversized base harnesses, hidden state mutation, and fixture helpers that silently perform the behavior under test. Helpers should be explicit about actors, funding, and state changes.
- Actors shared across suites belong in `BaseTest`; actors that exist only for one contract belong in that contract fixture or test. Reusable mocks belong in `BaseTest` only when broadly shared; otherwise keep mocks beside the fixture that needs them.
- Unit tests cover one contract boundary and its direct dependencies. Cross-component behavior belongs under `test/integration`. Invariant tests belong under an `invariant` suite, and fork-specific behavioral tests belong under a `fork` suite with clear RPC assumptions.
- New tests must extend the established fixture hierarchy. If a new contract dependency would require a deep or awkward chain, create a narrow fixture or move the scenario to integration tests instead.

Repo-specific fixture pattern:

```solidity
abstract contract BaseTest is Test {
    // Global actors, Monad handles, funding, and shared assertions only.
}

abstract contract ValidatorRegistryFixture is BaseTest {
    ValidatorRegistry internal registry;

    function setUp() public virtual override {
        super.setUp();
        registry = new ValidatorRegistry();
    }
}

abstract contract StakingVaultFixture is ValidatorRegistryFixture {
    StakingVault internal vault;

    function setUp() public virtual override {
        super.setUp();
        uint256 requestId = _requestValidator();
        vault = _deployVault(requestId);
    }
}

contract StakingVaultTest is StakingVaultFixture {
    // StakingVault unit tests only.
}
```

## Before finishing

Run `pnpm --filter @quevra/contracts check` from the workspace root for contract-only changes. Run the root `pnpm check` when changes can affect other workspace packages.

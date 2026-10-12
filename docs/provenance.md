# Provenance and attribution

This record maps every `src/**/*.sol` file to its license, origin, and adaptation notes. File-level `SPDX-License-Identifier` comments remain authoritative. Package license texts live in [`LICENSE`](../LICENSE), [`LICENSE-MIT`](../LICENSE-MIT), and [`LICENSE-BUSL-1.1.txt`](../LICENSE-BUSL-1.1.txt).

## Upstream references consulted

| Reference | Revision | Role |
| --- | --- | --- |
| Local Mezo ABI / Tigris extract submodule [`tigris/`](../tigris/) (`newtmex/mezo-abi`) | `fa9ba83d93d4ee362b0699e7bcd13d32e150afda` | Primary tree used when adapting or comparing Solidity sources under `tigris/solidity/contracts/` |
| Public [mezo-org/tigris](https://github.com/mezo-org/tigris) | `0a3b5e840ac8e187cc705fbeddcf00f88b09247e` (main as of 2025-09-16) | Cross-check for files that exist on the public repository; root `LICENSE` there is GPL-3.0 while individual Solidity files carry their own SPDX |
| Design lineage named in source notices | Solidly, Curve, Velodrome / Tigris contributors (`velodrome.finance`, `@figs999`, `@pegahcarter`) | Historical attribution retained in file headers where present |

The `tigris/` submodule is an extract/reference tree (`license: UNLICENSED` in its `package.json`). It is **not** redistributed as Quevra protocol source. Quevra runtime sources live only under `src/`.

Upstream SPDX observed in the extract at `fa9ba83` (and on mezo-org/tigris where the path exists):

| Upstream path (under `solidity/contracts/`) | Upstream SPDX |
| --- | --- |
| `VotingEscrow.sol` | BUSL-1.1 |
| `ValidatorsVoter.sol` | BUSL-1.1 (present in local extract; not on mezo-org/tigris `main` at the cross-check commit) |
| `NonStakingVoter.sol` | BUSL-1.1 (present in local extract; not on mezo-org/tigris `main` at the cross-check commit) |
| `rewards/VotingReward.sol` | BUSL-1.1 |
| `rewards/BribeVotingReward.sol` | BUSL-1.1 |
| `rewards/Reward.sol` | MIT |
| `libraries/SafeCastLibrary.sol` | BUSL-1.1 |
| `libraries/ProtocolTimeLibrary.sol` | MIT |
| `libraries/BoostLibrary.sol` | MIT |
| `gauges/Gauge.sol` | MIT |
| `gauges/NonStakingGauge.sol` | MIT |
| `interfaces/IVotingEscrow.sol`, `IVotingEscrowBooster.sol`, `IBaseVoter.sol`, `IGauge.sol`, `INonStakingGauge.sol`, `INonStakingVoter.sol`, `IReward.sol` | MIT |

## Per-file record (`src/`)

### BUSL-1.1 adaptations (not MIT)

| Quevra file | SPDX | Upstream source | Adaptation summary |
| --- | --- | --- | --- |
| [`src/VotingEscrow.sol`](../src/VotingEscrow.sol) | BUSL-1.1 | `tigris/solidity/contracts/VotingEscrow.sol` @ `fa9ba83`; also [mezo-org/tigris VotingEscrow.sol](https://github.com/mezo-org/tigris/blob/0a3b5e840ac8e187cc705fbeddcf00f88b09247e/solidity/contracts/VotingEscrow.sol) | Abstract veNFT escrow; Monad epoch/cycle locks; native MON principal sync with `StakingController`; UUPS/OZ upgradeable bases; retains Solidly/Curve/Tigris notices |
| [`src/voting/NonStakingVoter.sol`](../src/voting/NonStakingVoter.sol) | BUSL-1.1 | `tigris/solidity/contracts/NonStakingVoter.sol` @ `fa9ba83` | Token whitelist and reward-funding base; ERC-7201 namespaced storage; OZ upgradeable/ownable patterns |
| [`src/voting/ValidatorsVoter.sol`](../src/voting/ValidatorsVoter.sol) | BUSL-1.1 | `tigris/solidity/contracts/ValidatorsVoter.sol` @ `fa9ba83` | Validator-gauge voting tied to physical MON allocation; bribe balance sync; beacon proxies for gauges/bribes; UUPS |
| [`src/rewards/VotingReward.sol`](../src/rewards/VotingReward.sol) | BUSL-1.1 | `tigris/solidity/contracts/rewards/VotingReward.sol` @ `fa9ba83`; [mezo-org path](https://github.com/mezo-org/tigris/blob/0a3b5e840ac8e187cc705fbeddcf00f88b09247e/solidity/contracts/rewards/VotingReward.sol) | Vote-balance reward base; Quevra cycle checkpoints; voter-authorized deposit/withdraw |
| [`src/libraries/SafeCastLibrary.sol`](../src/libraries/SafeCastLibrary.sol) | BUSL-1.1 | `tigris/solidity/contracts/libraries/SafeCastLibrary.sol` @ `fa9ba83`; [mezo-org path](https://github.com/mezo-org/tigris/blob/0a3b5e840ac8e187cc705fbeddcf00f88b09247e/solidity/contracts/libraries/SafeCastLibrary.sol) | Checked `uint256`/`int128` casts for lock amounts |

### MIT adaptations of Tigris MIT sources

| Quevra file | SPDX | Upstream source | Adaptation summary |
| --- | --- | --- | --- |
| [`src/rewards/Reward.sol`](../src/rewards/Reward.sol) | MIT | `tigris/solidity/contracts/rewards/Reward.sol` @ `fa9ba83`; [mezo-org path](https://github.com/mezo-org/tigris/blob/0a3b5e840ac8e187cc705fbeddcf00f88b09247e/solidity/contracts/rewards/Reward.sol) | Cycle-scoped reward escrow; claim from cycle `c+1` for notifications in `c`; ERC-7201 storage |
| [`src/gauges/Gauge.sol`](../src/gauges/Gauge.sol) | MIT | `tigris/solidity/contracts/gauges/Gauge.sol` @ `fa9ba83` | Gauge accounting on Monad cycles via `ProtocolTimeLibrary` |
| [`src/gauges/NonStakingGauge.sol`](../src/gauges/NonStakingGauge.sol) | MIT | `tigris/solidity/contracts/gauges/NonStakingGauge.sol` @ `fa9ba83` | Non-staking validator gauge; beneficiary switch settles rewards first |
| [`src/libraries/ProtocolTimeLibrary.sol`](../src/libraries/ProtocolTimeLibrary.sol) | MIT | `tigris/solidity/contracts/libraries/ProtocolTimeLibrary.sol` @ `fa9ba83` | Rebuilt around Monad staking epochs at `0x1000` (`EPOCHS_PER_CYCLE = 5`) |
| [`src/libraries/BoostLibrary.sol`](../src/libraries/BoostLibrary.sol) | MIT | `tigris/solidity/contracts/libraries/BoostLibrary.sol` @ `fa9ba83` | Boost math helpers for validator-boosted voting power |
| [`src/interfaces/IVotingEscrow.sol`](../src/interfaces/IVotingEscrow.sol) | MIT | `tigris/solidity/contracts/interfaces/IVotingEscrow.sol` @ `fa9ba83` | Interface shaped for Quevra escrow / controller hooks |
| [`src/interfaces/IVotingEscrowBooster.sol`](../src/interfaces/IVotingEscrowBooster.sol) | MIT | `tigris/solidity/contracts/interfaces/IVotingEscrowBooster.sol` @ `fa9ba83` | Booster poke interface |
| [`src/interfaces/IBaseVoter.sol`](../src/interfaces/IBaseVoter.sol) | MIT | `tigris/solidity/contracts/interfaces/IBaseVoter.sol` @ `fa9ba83` | Omits Tigris governor / emergency-council hooks |
| [`src/interfaces/INonStakingVoter.sol`](../src/interfaces/INonStakingVoter.sol) | MIT | `tigris/solidity/contracts/interfaces/INonStakingVoter.sol` @ `fa9ba83` | Non-staking voter surface |
| [`src/interfaces/IGauge.sol`](../src/interfaces/IGauge.sol) | MIT | `tigris/solidity/contracts/interfaces/IGauge.sol` @ `fa9ba83` | Gauge interface |
| [`src/interfaces/INonStakingGauge.sol`](../src/interfaces/INonStakingGauge.sol) | MIT | `tigris/solidity/contracts/interfaces/INonStakingGauge.sol` @ `fa9ba83` | Non-staking gauge interface |
| [`src/interfaces/IReward.sol`](../src/interfaces/IReward.sol) | MIT | `tigris/solidity/contracts/interfaces/IReward.sol` @ `fa9ba83` | Reward / bribe interface |

### Quevra-authored MIT sources (no Tigris implementation copy)

These files are Quevra protocol code for Monad native staking coordination. Some **compose** BUSL parents (for example `BribeVotingRewards` extends `VotingReward`); the wrapper file itself is MIT, while the inherited BUSL sources stay BUSL-1.1.

| Quevra file | SPDX | Notes |
| --- | --- | --- |
| [`src/VeMON.sol`](../src/VeMON.sol) | MIT | Concrete MON voting escrow; extends BUSL `VotingEscrow` |
| [`src/VeValidator.sol`](../src/VeValidator.sol) | MIT | Validator identity NFT / boostable escrow |
| [`src/rewards/BribeVotingRewards.sol`](../src/rewards/BribeVotingRewards.sol) | MIT | Thin initializer wrapper over BUSL `VotingReward` (upstream `BribeVotingReward.sol` is BUSL-1.1; this file is a Quevra-authored beacon implementation shell) |
| [`src/staking/StakingController.sol`](../src/staking/StakingController.sol) | MIT | Native stake intent, vault/agent factory, settlement |
| [`src/staking/StakingAdmin.sol`](../src/staking/StakingAdmin.sol) | MIT | Admin / commission / binding helpers |
| [`src/staking/controlled/StakeControlled.sol`](../src/staking/controlled/StakeControlled.sol) | MIT | Precompile-facing staking primitive |
| [`src/staking/controlled/StakingVault.sol`](../src/staking/controlled/StakingVault.sol) | MIT | Validator registration vault |
| [`src/staking/controlled/StakingAgent.sol`](../src/staking/controlled/StakingAgent.sol) | MIT | Per-position delegation agent |
| [`src/libraries/StakingControllerRewardsLibrary.sol`](../src/libraries/StakingControllerRewardsLibrary.sol) | MIT | Native reward share helpers |
| [`src/libraries/ValidatorPayloadLibrary.sol`](../src/libraries/ValidatorPayloadLibrary.sol) | MIT | Monad `addValidator` payload field readers |
| [`src/libraries/VotingPower.sol`](../src/libraries/VotingPower.sol) | MIT | Voting-power helpers |
| [`src/interfaces/IStakingController.sol`](../src/interfaces/IStakingController.sol) | MIT | Controller API |
| [`src/interfaces/IValidatorsVoter.sol`](../src/interfaces/IValidatorsVoter.sol) | MIT | Validator voter API |
| [`src/interfaces/IVeMON.sol`](../src/interfaces/IVeMON.sol) | MIT | veMON API |
| [`src/interfaces/IVeValidator.sol`](../src/interfaces/IVeValidator.sol) | MIT | veValidator API |

## Dependencies (not Quevra SPDX)

| Dependency | License | Pin / location |
| --- | --- | --- |
| OpenZeppelin Contracts | MIT | npm / `lib` `5.7.0` |
| OpenZeppelin Contracts Upgradeable | MIT | npm `5.7.0` |
| forge-std | MIT / Apache-2.0 (upstream dual) | `lib/forge-std` |
| monad-std | Upstream license in that repository | `lib/monad-std` |

## Package license statement

- **Default for new Quevra-authored files:** MIT (`LICENSE-MIT`).
- **Submitted package license:** multi-licensed — MIT and BUSL-1.1 by file, as listed above.
- **Not claimed:** that the combined work is uniformly MIT, uniformly GPL, or OSI “open source” in its entirety. BUSL-covered files remain source-available under BUSL-1.1 until an applicable upstream Change Date converts them.

When adding or adapting further Tigris material, update this table, preserve upstream SPDX and notices, and do not relicense BUSL or GPL-family implementation code as MIT.

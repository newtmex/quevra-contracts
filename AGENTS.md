# Quevra Contracts

## Purpose and MVP Definition

Quevra is a validator-capital and liquidity-coordination protocol for Monad. Users lock native MON into veMON positions, direct their positions toward validators through cycle-based voting, and earn native MON staking rewards alongside additional incentives (bribes) offered by validators and protocols to attract delegations. Pooled capital can help register new validators or delegate to existing validators. The same MON can be reallocated between validators in later cycles without requiring users to unlock and deposit it again, enabling users to optimize their staking rewards and incentives while supporting validator decentralization.

**MVP success is a real, end-to-end lifecycle on Monad staking, not a collection of individually deployable contracts.** A user must be able to lock MON, support a validator, have the controller execute real staking operations, change allocations in a later cycle, earn and claim or compound attributable native staking rewards, receive and claim funded validator/protocol incentives for eligible votes starting in the next cycle, and ultimately withdraw after both the veMON lock and Monad withdrawal conditions are satisfied.

Treat this document as a **behavioral specification and acceptance contract**, not as proof that the current code already meets it. When code and this specification disagree, identify the gap; do not quietly weaken the specification or write tests that merely match broken behavior. Prefer minimal, auditable changes to the existing architecture.

### MVP scope

- Native MON custody, veMON locks and voting-power accounting.

- Validator identity/onboarding for both new and existing Monad validators.

- Validator gauges and veMON vote-to-MON-stake allocation.

- **Validator/protocol incentives (bribes):** Funding/notification to a validator-linked reward contract, proportional distribution to veMON positions based on their cycle-`c` recorded votes, and claiming starting in cycle `c+1` for incentives notified in `c`.

- StakingController, validator-bound StakingVaults, and per-position StakingAgents.

- Actual Monad staking precompile calls, epoch-based delays, permissionless settlement, and rebalancing.

- Native MON staking-reward attribution, claiming, and compounding.

- User exit after lock expiry, withdrawal maturity, and full settlement.

- The existing veValidator backing and validator-boost mechanism, insofar as required for consistent validator voting and identity accounting.

- Focused unit, integration, invariant, and representative fork/e2e coverage.

### Explicitly outside the MVP acceptance gate

- QUE token issuance and veQUE governance; veQUE-funded boosts or emissions.

- Liquidity-pool gauges, DEX integration, liquidity mining, and a liquid ERC-20 staking derivative.

- A full external bribe marketplace, permissionless onboarding of arbitrary incentive tokens, or bribe refund economics. Demonstrate at least one supported, whitelisted incentive token; existing additional-token support may remain.

- Production-grade autonomous validator selection, optimal active-set bidding, and the full future capital auction/allocation algorithm.

- Frontend, indexer, tokenomics, multisig/timelock rollout, or mainnet launch operations.

Existing interfaces or contracts for future features may remain, but **do not block MVP completion on their full implementation**. Do not imply veMON NFTs are instantly redeemable for MON, or that a validator is in Monad's active set merely because its registration succeeded.

## Canonical MVP User Journey

The protocol must demonstrate this sequence against the actual Monad staking state machine:

1. **Register a validator.** An operator creates a Quevra validator identity linked to either a new signed Monad validator-registration payload or an existing validator ID. The identity has an associated vault, gauge, and bribe reward contract; its owner/operator, staking identifier, and backing remain coherent.
2. **Lock MON.** A user deposits real MON and receives a veMON NFT whose locked principal equals the MON credited to the controller. The selected finite lock expires at a cycle boundary, or a supported permanent lock remains non-expiring until explicitly converted back to a finite lock.
3. **Vote for validators.** The veMON holder votes for valid validator gauges. Gauge voting weights derive from veMON voting power; the MON allocation derives from **locked principal**, not decaying voting power. A vote produces an authoritative per-validator staking intent and the corresponding cycle-scoped voting-reward balance.
4. **Fund validator incentives.** A validator, protocol, or other permitted sponsor posts an actual, supported incentive token to the bribe rewards contract for the target validator gauge in cycle `c`. Reward funding is associated with the correct gauge and cycle and cannot be fabricated by a notification alone.
5. **Deploy capital.** The controller progresses the intent. Where a new validator can be registered, capital first fills its vault's required registration backing; additional delegations use the token-specific staking agent. Existing validators receive delegated MON through the native precompile. Capital lacking a valid executable path stays accounted for rather than disappearing.
6. **Progress epochs.** Monad delegation and undelegation do not necessarily take effect immediately. The protocol must respect precompile epoch-effective rules and withdrawal delays, with later permissionless `poke`/settlement calls completing work.
7. **Earn and use native rewards.** Native MON earned by supported validator positions is attributable to the correct veMON token. Its holder can **claim** MON into their wallet or **compound** it into the position, increasing backing and locked principal consistently.
8. **Claim voting incentives.** Starting in cycle `c+1`, eligible veMON holders can claim their proportional share of the bribes notified for a gauge in cycle `c` using that cycle's recorded voting weights. These are separately funded incentive tokens, not native MON staking rewards or newly minted locked principal.
9. **Rebalance in a later cycle.** The holder changes validator choices and amounts, including increasing, reducing, removing, and adding validators using the **same already-locked MON**. Rebalancing handles pending undelegations without a second deposit or double use of capital; it must not rewrite the holder's earned incentives for completed cycles.
10. **Exit.** After the finite lock expires and all staking withdrawal obligations mature, a holder can redeem the actual MON owed and burn/close the veMON position. Previously earned bribes must be claimable or safely settled before the NFT burn can orphan the entitlement. Early exit, permanent-lock exit, or premature NFT burn must not bypass those conditions.

A passing demonstration must show state changes in the Monad precompile **and** real incentive-token transfers, funded balances, cycle-c snapshots, cycle-`c+1` claims, and conserved assets—not only emitted events, intent mappings, mocked return values, or zero-value reward paths.

## Protocol Actors and Authority

- **veMON holder:** controls eligible locks, votes, permitted stake-intent changes, native MON claims/compounding, cycle-matured bribe claims, and exit. Enforce ownership/approval semantics appropriate to each action; incentive, reward, and principal payments must not be redirectable by unauthorized callers.

- **Validator operator:** submits a validator identity and the correct signed consensus payload or existing validator ID. May fund incentives to attract votes/delegations but does not acquire custody of arbitrary users' veMON principal.

- **Incentive sponsor (validator, protocol, or other permitted funder):** deposits an approved reward token into the correct validator-linked bribe contract and cannot change another user's vote balance or seize deposited funds.
- **BribeVotingRewards/VotingReward/Reward:** escrow notified incentives, record per-cycle vote entitlements, and permit legitimate claims only when the earning cycle is complete.

- **ValidatorsVoter:** is the authorized vote-to-intent and vote-to-bribe-accounting bridge. It cannot create MON or reward tokens and should not permit invalid gauges, duplicate choices, or arbitrary third-party changes to another position's allocation or recorded reward shares.

- **StakingController:** is the custody and settlement authority over validator vaults and per-token agents. It owns the accounting for each token's liquid balance, target allocation, actual allocation, and pending withdrawal.

- **Permissionless keeper:** may advance a publicly callable rebalance/withdrawal state machine where permitted, but may not change a holder's chosen allocation or become the recipient of principal/rewards.

- **Protocol owner/admin:** may configure tightly scoped parameters and one-time bindings; cannot arbitrarily bypass veMON ownership, account for nonexistent deposits, or confiscate user stake. Commission scheduling must observe its defined cycle delay.

## Required Protocol Behavior

### 1. Monad time and cycles

**Monad epoch is the atomic unit of protocol time. Quevra cycle is the economic accounting boundary.**

| Tigris | Quevra |

|---|---|

| `block.timestamp` | Monad epoch |

| Epoch | Cycle |

| Timestamp-based accounting | Cycle-based accounting |

Rules:

- Never use `block.timestamp` or block numbers for **protocol economics**. A block-number same-block transfer safety guard is not an economic clock.

- Use `ProtocolTimeLibrary` as the sole source of epoch/cycle conversions, cycle starts, and precompile delay-period semantics; do not reimplement them per contract.

- Economic vote eligibility, lock expiration, cycle-scoped accounting, native staking rewards, incentive notification/claiming, checkpoints, and scheduled administrative changes must respect the appropriate epoch/cycle boundaries. **Bribes notified in cycle `c` first become claimable in `c+1`, never in `c` or delayed to `c+2`.**

- Monad changes made before and during the staking delay period may have different effective epochs. An epoch transition does **not** automatically mean a pending undelegation is withdrawable.

- Test actual Monad epoch progression, delay periods, cycle rollover, and withdrawal maturity, not simulated wall-clock progression.

- Keep cycle length configurable in its intended shared abstraction; do not scatter assumptions about five epochs or a mainnet cycle length throughout production logic and tests.

- When adapting Tigris code, preserve relevant economics while translating time to Monad epochs/cycles. Do not mechanically copy timestamp-based reward or checkpoint behavior.

### 2. veMON lock and accounting

- A veMON NFT represents a particular user's **locked MON principal**, not transferable ERC-20 MON supply and not a claim on a validator's assets independent of the controller.

- Deposit accounting and native MON payment must be atomic and exact. Zero, malformed, overflowing, or unauthorized changes must revert.

- Support bounded finite cycle locks, linear epoch-based voting-power decay with correct historical checkpoints, and permanent locks with nondecaying voting power where implemented.

- Lock durations and unlock epochs must follow the shared protocol time model; expired locks cannot cast new votes with nonexistent voting power.

- Controller-authorized compounding increases principal and checkpoints voting power. No other caller can increase or decrease a lock without the corresponding economically valid staking/accounting action.

- **Voting power and staked MON are distinct:** voting power may decay while the actual principal continues to back the validator. Do not reduce delegated MON merely because voting power decays.

- Do not burn a veMON position until its underlying claim has actually been settled. A permanent position must first become eligible for finite-lock exit under the protocol's rules.

### 3. Validator identities and registration

- Support **new-validator registration** using an unchanged, fully specified signed Monad registration payload and its native consensus signatures, and **existing-validator association** using a real validator ID.

- Use the canonical Monad precompile ABI/semantics. The precompile is the ultimate source of validator existence, delegation, withdrawability, and effective stake.

- Bind each validator identity to the correct operator, validator-bound vault, gauge, and native validator ID once known; reject duplicate or contradictory identities where they violate uniqueness assumptions.

- A new validator's auth address and economics must match the payload, deterministic vault setup, and signing configuration. Do not silently rewrite or synthesize signatures.

- Preserve the distinction between the native minimum required to **register** a validator and the stake needed to be selected into the **active validator set**; registration does not promise active-set inclusion or reward production.

- Validator identity (veValidator) is non-transferable/permanent in the current design. Its tracked backing must rise or fall only with actual controller-recognized validator backing, not votes alone.

- Retain the current ability to associate a vault/gauge with a new or already-existing validator without introducing a redundant parallel registry unless required by the implementation.

### 4. Validator votes and stake intent

- A veMON holder can vote for registered, eligible validator gauges with a bounded, validated allocation array. Enforce the defined voting window/cycle restrictions and clear old vote weights correctly on reset or vote replacement.

- Calculate **gauge weight** using the veMON position's current applicable voting power. Calculate **staking amount** by distributing its locked principal pro rata over the selected gauges. The sum of computed amounts must be exactly the allocatable principal; handle truncation/dust deterministically without minting capital.

- Connect the voter to `StakingController` as the canonical vote-to-intent path. A successful vote must write the corresponding target allocations and initiate/progress settlement (or explicitly expose the deferred continuation), not only update a vote mapping.

- Vote reset or a zero-allocation choice must remove obsolete intent and initiate the necessary unstake flow without erasing still-delegated or pending capital.

- If direct holder-controlled staking APIs are retained, their targets, authorization, cycle guards, and vote-driven paths must be internally consistent. Never allow two contradictory authoritative allocation sources or let a direct call bypass the voter’s security boundaries.

- Maintain per-position, per-gauge and total weights without stale votes, double voting, ghost gauges, or overflow; use checkpointing appropriate to power decay. Maintain the associated bribe-reward vote balances/checkpoints in the same coherent vote/reset transition so rewards from completed cycles survive later vote changes.

- Validator boosts may affect **voting power**, with a bounded multiplier and checkpoint/refresh behavior, but must not fabricate native MON, alter a user's principal, or be treated as staking rewards. The existing boost machinery should remain coherent without making veQUE or a separate liquidity-gauge incentive system an MVP dependency. Validator bribes **are** in scope and use recorded eligible veMON gauge vote weights, not delegated MON principal or a fictional separate boost balance.

### 5. Staking execution and rebalancing

- The controller must distinguish for every veMON token: available MON, target allocations, actual delegated/validator-vault backing, pending undelegations, and matured withdrawals. Never conflate intent with settled stake.

- Registration vaults are **bound to one validator**. New-validator backing is placed into the vault first up to the required amount; excess or subsequent delegations are routed through a token-specific staking agent as appropriate.

- A per-token staking agent may service multiple validator IDs but may not commingle ownership/accounting between veMON token IDs. For an existing validator, use native delegation rather than attempting to add the validator again.

- A new validator can only be added when the exact precompile registration requirements are met. If funds are insufficient or the operation is not executable, keep the user’s funds credited and available for later settlement; do not mark a validator active prematurely.

- The controller should reuse liquid amounts from the same token, then mature pending withdrawals and shift stake through undelegation/withdrawal/delegation where necessary. Reduce positions through the agent before disturbing validator-registration backing when practical and correct.

- Replacing an allocation in a later cycle must **not** require a new MON deposit; it must allow changing proportions, moving from A to B, withdrawing entirely from C, and adding D.

- Pending undelegations must not be counted simultaneously as spendable and delegated; no accelerated withdrawal before the native waiting period. Repeated permissionless pokes must be safe and idempotent in effect.

- Failure to finish settlement immediately is not necessarily failure: report pending state accurately, continue in later valid epochs, and ensure there is an eventual path to completion if the native precompile permits it.

- Avoid unbounded iteration over **all users or token IDs** in ordinary staking, rewards, and keeper methods; iterate only the relevant position's bounded vault/validator set.

### 6. Validator and protocol incentives (bribes)

- A registered validator gauge must have a correctly associated `BribeVotingRewards`/`VotingReward` accounting path. A validator or protocol (and any otherwise permitted funder) may notify an **approved/whitelisted** incentive token to attract veMON votes and corresponding MON stake allocation. The MVP must support at least one real ERC-20 incentive asset.
- **Funding is real:** `notifyRewardAmount` (or the established equivalent) must escrow/transfer the supported token and credit precisely the funded reward amount to the correct validator gauge and **notification cycle `c`**. Reject zero/invalid notifications, unsupported tokens, and unfunded reward accounting. Validate behavior of nonstandard transfer-fee tokens instead of crediting imaginary balances.
- **Eligibility is vote-based:** veMON token IDs that allocated eligible voting weight to a validator gauge in cycle `c` share that gauge's cycle-`c` incentives **pro rata to the recorded voting weight for that cycle**. Staking intent maps determine MON deployment separately; do not calculate bribes from locked MON principal, actual native staking rewards, or another validator's vote weight.
- Use cycle-scoped vote-balance and supply checkpoints so changes to locks, voting power, boosts, resets, or validator allocations in a later cycle do not rewrite past entitlements. A vote removal within a cycle must follow the protocol's established cycle snapshot rules; never pay rewards to positions lacking the required eligible cycle-`c` voting balance.
- **Claim boundary:** incentives notified in cycle `c` are not claimable during `c`; eligible claims begin at the **start of cycle `c+1`**. Never carry forward an obsolete `c+2` waiting period. A late claim must be able to settle past eligible cycles without losing earlier unpaid amounts.
- The NFT owner or permitted approved caller may initiate a claim only for that NFT; payout goes to the rightful owner. Claims must debit only that token ID's accrued entitlement and must not pay twice, leak rewards between positions/gauges/cycles, or grant the funder control over recipient funds.
- Bribes are **independent of native MON staking rewards**. Claims pay the funded incentive token to the holder and do not automatically compound into MON, mutate a veMON lock, or increase validator backing.
- Treat empty-vote cycles and rounding dust explicitly, without division by zero or fabricated entitlements. Do not invent a refund or redistribution rule: general refund economics remain deferred; unallocated incentives must be accounted for safely under the existing mechanism.
- Reward eligibility already earned in a completed cycle must survive a subsequent reset/revote/reallocation and must remain claimable (or explicitly settled) before a position is burned. Preserve accounting without unbounded iteration over all veMON positions.

### 7. Native MON rewards

- The **native staking-reward channel** distributes MON actually earned from validator staking, not hypothetical gauge emissions, deposited principal, or voting weight. Keep it explicitly separate from funded vote-based validator/protocol bribes, which are also part of the MVP.

- Rewards from a shared validator vault must be attributed to participating token IDs with checkpointed, share-based accounting (for example, accumulated reward-per-share). A token-specific agent may track rewards directly, but must still attribute only that token's earned amount.

- Snapshot/update accrued rewards **before** stake/share changes, undelegation, withdrawal, or other updates that change attribution. Former participants retain already-earned rewards without receiving later rewards they did not support.

- Claiming transfers only the caller's position's accrued, claimable MON to its rightful owner. Claiming twice without newly accrued rewards must not pay twice or drain reserves backing other positions.

- Compounding claims attributable rewards, increases that token's locked principal through the authorized escrow path, and routes the added MON through the existing staking/intent machinery. It must update backing, shares, voting-power checkpoints, and reward debt without treating claimed principal as new external deposits.

- Claim and compound operations must be mutually consistent across multiple validators and cycles; claiming for one position must not change another position's pending reward or principal.

- Native reward reserves, principal balances, precompile-reported amounts, and all native payouts must remain economically reconciled. Bribe escrow balances and payouts require their own conservation accounting, not commingled MON accounting. Explicitly handle rounding dust and zero-reward epochs.

- **A zero-reward test proves that the zero-reward path does not fail, not that rewards work.** Verify a strictly positive native reward from a real active validator in a suitable fork/e2e environment where possible. If the harness cannot accrue positive rewards, document that limitation as an outstanding MVP verification gap.

### 8. Withdrawal, lock expiry, and safety

- Exit requires both an expired/eligible veMON lock **and** a fully settled position under the Monad staking precompile. Maturity of the lock alone is insufficient.

- Undelegation, native withdrawal request, and final withdrawal are distinct steps when required by Monad. Tokens must retain enough bookkeeping to complete pending exits across epoch and cycle boundaries.

- Final MON payout goes to the legitimate veMON owner and is bounded by the real principal/withdrawn amount available to that token, plus independently claimable native rewards according to the accounting model. Funded bribes are settled separately in their reward asset.

- Do not pay out another token's principal or incentives, withdraw native reward reserves as principal, burn before final settlement or before outstanding earned bribes are safely claimable/settled, or allow an unauthorized caller to redirect funds.

- Check external/native transfers and precompile results; guard appropriate entry points against reentrancy. Avoid owner-only liveness bottlenecks for routine settlement.

- Any stuck-state handling must preserve the conservation invariants and leave an auditable recovery path rather than writing accounting values to simulate success.

## MVP Invariants (Non-negotiable)

1. **No created MON:** total principal credited/withdrawn/reinvested is reconcilable to actual deposits, native delegated/undelegated balances, and genuinely accrued rewards. Voting and boost cannot increase MON balances.

2. **No double allocation:** a token's actual liquid + delegated + pending principal cannot exceed its backed principal (subject only to explicitly separated, real rewards and accounting dust).

3. **Ownership isolation:** holder A cannot redirect, claim, compound, unstake, or withdraw holder B's assets; keeper progression cannot change ownership or intended recipients.

4. **Native reward conservation:** claimed + compounded + reserved/unclaimed native rewards do not exceed rewards actually accrued and received; rewards cannot be claimed twice.
5. **Bribe conservation:** cumulative paid + reserved/unclaimed + any explicitly supported residuals cannot exceed the actual amount of each incentive token funded to its corresponding reward contract. No claim may exceed a token ID's eligible per-cycle share or pay twice.

6. **Intent/settlement separation:** updates to targets do not falsely mark precompile operations completed; repeated `poke` calls converge without duplicating transfers.

7. **Validator linkage:** validator IDs, operator identity, vault, gauge, and veValidator NFT cannot become mismatched; only valid native operations count as backing.

8. **Temporal correctness:** no vote, native staking reward, incentive claim, commission change, or principal exit bypasses the applicable cycle/epoch, lock, effective-stake, or precompile withdrawal timing; a cycle-`c` bribe cannot be claimed earlier than `c+1`.

9. **Accounting isolation:** mutations to one token ID's allocation, staking reward debt, or bribe checkpoint cannot silently mutate another token ID's economic entitlement.
10. **Historical bribe entitlement:** a later-cycle vote change, removal, stake settlement, or NFT exit cannot retroactively reassign already accrued cycle-`c` bribes to new voters or a different gauge.

## MVP Acceptance Tests

Write an end-to-end happy-path suite **and** negative/edge-path suites that collectively demonstrate:

- New signed validator onboarding and existing validator onboarding, including correct identity/vault/gauge association and native validator IDs.

- Creation of multiple veMON locks with exact deposited MON, finite/permanent locks, linear decay, and historical voting power checkpoints.

- Vote -> per-gauge weights -> proportional allocation of locked principal -> actual add-validator/delegate calls; assert native precompile state rather than events alone.

- A holder allocating to multiple validators and, in a later cycle, increasing one allocation, reducing another, completely removing a third, and adding a fourth, **without depositing new MON**.

- Rebalancing when one or more undelegations cannot yet be withdrawn; correct pending balances, later epoch maturation, and repeated third-party `poke` calls.

- Validator/protocol incentive notification into the correct gauge-linked bribe contract with a **positive, observable ERC-20 transfer**, verified escrow balance and cycle-`c` reward accounting. Reject zero funding, unwhitelisted token, invalid gauge, and funding that was not actually received.
- Two veMON token IDs voting different weights for the same validator gauge in cycle `c` receive correct proportional incentive claims **starting in cycle `c+1`**. Assert no claim during `c`, exact boundary behavior at `c+1`, correct rounding, retained unpaid historical rewards, and no required `c+2` delay.
- Bribe payouts after vote resets, revotes or MON reallocation in later cycles; no retroactive redistribution, double claim, cross-user/cross-gauge leakage, unauthorized redirect, or reward orphaning on withdrawal/NFT burn. Test an empty-vote cycle and an incentive funded with zero eligible votes.

- Actual native MON reward accrual/distribution for two token IDs in the same vault and a token with exposure to multiple validators, including stake-share changes between cycles. Include a positive-reward e2e/fork case where technically supported.

- Claim -> claim again, compound -> revised locked principal and staking intent, alternating claim/compound across cycles, and no cross-user reward leakage.

- Partial and full unstake, finite lock expiry, pending native withdrawal, final owner payout, and burning the veMON NFT only after settlement.

- Unauthorized votes/intents, malformed arrays, duplicates, nonexistent gauges, invalid validator submissions, invalid payout recipients, repeated calls, premature exits, and boundary conditions for epochs and cycle rollovers.

- Conservation across the complete lifecycle, including accrued native rewards, **separately escrowed/claimed bribes**, vault backing, agent positions, controller-held funds, and pending withdrawal amounts.

For each critical test, assert **inputs, on-chain state transitions, final balances, precompile state, and unchanged unrelated-user state**. Prefer behaviorally distinct scenarios over shallow tests of emitted events. A failing test is a protocol gap, not a reason to mock the relevant precompile transition or relax the assertion.

### MVP completion gate

Mark MVP ready **only when** all of the following hold:

- A single coherent e2e path traverses registration, locking, voting, **real bribe notification and claim from `c+1`**, actual staking, reallocation, native staking reward claim/compound, and exit.

- No material loss/double-credit, access-control, native reward attribution, **bribe funding/entitlement/claiming**, or withdrawal-liveness issue remains unresolved.

- The Monad epoch and withdrawal delay behaviors are exercised, and production methods do not depend on Foundry-only state mutations.

- The relevant checks and test suites pass; **positive funded incentive notification and positive incentive claim are demonstrated**. Unsupported positive native MON staking-reward harness coverage is explicitly disclosed and validated separately before making production native-reward claims.

- Any feature outside scope is clearly labeled deferred and is not silently presented as working MVP functionality.

## Test Architecture

Use inheritance-based fixtures for all Solidity tests.

- `BaseTest` is the only global harness: shared actors, Monad handles, funding, assertions, and generic helpers only. Never deploy protocol contracts here.

- Every contract has a dedicated `<Contract>Fixture` that deploys only that contract and its direct dependencies.

- Tests live in `test/<Contract>.t.sol` as `<Contract>Test` and inherit from the matching fixture.

- Fixture inheritance should mirror real contract dependencies (e.g. `StakingControllerFixture -> VeValidatorFixture`) and remain shallow.

- Cross-contract flows belong in `test/integration`; invariants in `test/invariant`; fork tests in `test/fork`.

- Avoid duplicated deployments, hidden setup, circular inheritance, and helpers that perform the behavior under test.

- Don't mock calls to the staking precompile; always transition state in the precompile to meet the test's needs.

- Use `monad-std`/Monad epoch controls for test advancement. Mocking an entire native staking response is not an acceptable substitute for testing the integration.

- Keep positive native staking-reward tests distinguishable from harness environments that cannot produce consensus-earned rewards. **Bribe tests must fund a real test ERC-20 and demonstrate a nonzero transfer/claim**, regardless of whether the native staking test harness can generate validator rewards.

Example:

```solidity

abstract contract BaseTest is Test {}

abstract contract VeValidatorFixture is BaseTest {

    // Validator identity and its direct dependencies.

}

abstract contract StakingControllerFixture is VeValidatorFixture {

    StakingController controller;

}

contract StakingControllerTest is StakingControllerFixture {}

```

## Engineering Guidance for Agents

- **First inspect the current branch** and map each MVP requirement to contract entry points and tests. Report implemented, partially implemented, missing, and blocked behavior separately.

- Prefer extending and fixing existing `VeMON`, `VotingEscrow`, `VeValidator`, `ValidatorsVoter`, `StakingController`, `StakingVault`, `StakingAgent`, `BribeVotingRewards`, `VotingReward`, `Reward`, and native staking reward accounting over adding new parallel systems.

- Preserve working ABI, fixture architecture, shared cycle library, and existing asset accounting unless a change is necessary to satisfy an explicit invariant. State deliberate interface changes.

- Avoid mocks, magical balances, invented validator IDs, synthetic successful precompile results, or tests that skip the real staking delays.

- Do not substitute voting weight for native MON amounts, treat intent as delegated funds, or treat a successful validator registration as active-set inclusion. **Use recorded voting weight for bribe entitlement and actual delegated MON for native staking rewards**; never confuse or compound the two reward streams.

- Implement bounded and gas-conscious per-position iteration. Prefer pull-based per-token native rewards, cycle-checkpointed bribe claims, and permissionless settlement to global user loops.

- Maintain clear authorization boundaries and events for important state changes. Use established OpenZeppelin and Monad integration patterns; flag trust assumptions and reentrancy risks.

- Before calling a requirement complete, demonstrate the concrete call path and a test asserting the economic consequence. Distinguish supported behavior from plans or inferred intent.

- If the task requests a narrower subsystem, work within that subsystem; **do not opportunistically build deferred MVP features**.

## Tigris / Mezo Earn Reference and Source Licensing

Use the Mezo Earn **Tigris** vote-escrow and gauge system as the principal *design reference*, not as an assumed drop-in dependency. When the full workspace includes `packages/contracts/tigris/solidity`, inspect its `contracts/` directory first; otherwise locate the reference at [mezo-org/tigris](https://github.com/mezo-org/tigris), under `solidity/contracts/`. If a local copy has a different commit, record its path and revision and verify the applicable license there before reusing code.

### What to learn from Tigris

- `VotingEscrow.sol`, `VeBTC.sol`, `VeMEZO.sol`, and `ve/`: vote-escrow state, finite/permanent locks, decaying voting-power checkpoints, lock ownership, and veNFT behavior. Adapt **concepts** to native MON custody and Monad epochs rather than copying Mezo-specific token/time logic.
- `Voter.sol`, validator/gauge voting components when present, `gauges/Gauge.sol`, and `interfaces/`: vote replacement/reset, gauge association, per-gauge weights, checkpoint coordination, and boost accounting. Translate Mezo's vote/emissions system into Quevra's validator gauge → locked-MON stake intent; do not import liquidity-gauge logic as MVP requirements.
- `rewards/Reward.sol`, `rewards/VotingReward.sol`, and `rewards/BribeVotingReward.sol`: cycle-bounded incentive notification, gauge-linked reward escrow, vote/supply checkpoints, historical accrual, and veNFT-level claiming. Specifically implement **notification in cycle `c` and first claim in `c+1`** under `ProtocolTimeLibrary`; do not copy any Mezo claim delay mechanically.
- Contrast implementations against Quevra's existing code before refactoring. Prefer targeted corrections and tests to replacing entire working modules. Keep native MON validator staking rewards separate from bribes distributed by voting weight.

### Mandatory licensing and provenance rules

- **Quevra's default license for newly authored, independently implemented files is MIT.** Use `// SPDX-License-Identifier: MIT` in such Solidity files, and keep an appropriate root `LICENSE` for the original MIT-licensed Quevra work.
- **Never assume Tigris is uniformly MIT.** At the checked `mezo-org/tigris` main-branch sources, `solidity/contracts/VotingEscrow.sol` and `solidity/contracts/Voter.sol` carry `BUSL-1.1`; `solidity/contracts/VeBTC.sol` carries `GPL-3.0-or-later`; `solidity/contracts/rewards/Reward.sol`, `VotingReward.sol`, and `BribeVotingReward.sol` carry `MIT`. The Tigris repository root `LICENSE` is GPL-3.0. Other Tigris files and earlier revisions may differ. **Check both each actual source file's SPDX/copyright notices and the repository/upstream licenses for the exact revision used.**
- For any legally permissible copying/adaptation of MIT-licensed Tigris material, preserve its **original SPDX, copyright/author notices, upstream attribution, and applicable license text**. Document the exact source URL, commit/revision, adapted functions or files, and changes to the behavior (especially Monad epoch/cycle and bribe claim timing). Do not strip Velodrome, Solidly, Curve, or other upstream notices carried by that file.
- **Do not copy or adapt BUSL-1.1 or GPL-family licensed implementation code and then label it MIT.** A conceptual rewrite must be genuinely independently authored, not a superficial rename or line-by-line translation. BUSL usage may require separate permission under its terms; GPL-derived/combined code may impose obligations incompatible with the intended MIT-only distribution. When the licensing position is uncertain, stop the copying step, document the provenance concern, and ask for an explicit licensing decision rather than silently changing an SPDX header.
- A third-party source file's license is **not** overridden by the Quevra root MIT default. If permission is granted to use code under another license, preserve the original license conditions, source notices, and any required distribution of license/source text; isolate it and document the exception. Do not claim the entire combined work is MIT unless the license audit supports that conclusion.
- Review existing Quevra files whose comments say "ported from Tigris" and files structurally derived from a Tigris `BUSL-1.1` implementation (especially vote escrow or voter modules). An existing `MIT` header is not proof that an adaptation can be relicensed; record whether each file is independently authored or a permitted adaptation before changing or distributing it.
- For every newly imported or adapted source file, include provenance in code comments or a repository-level attribution record. An acceptable pattern for an **MIT-compatible** adaptation is:

  ```solidity
  // SPDX-License-Identifier: MIT
  // Adapted from: https://github.com/mezo-org/tigris/blob/<commit>/solidity/contracts/rewards/Reward.sol
  // Original copyright and author notices retained from the source.
  // Changes: cycle-boundary accounting, Monad epoch timing, and Quevra reward semantics.
  ```

  Replace `<commit>` with a real immutable commit; the shown attribution lines do **not** substitute for carrying the actual original notices and MIT license text where required.
- Before completing a change involving any Tigris-inspired implementation, list which source files were consulted, which (if any) code was actually reused, the verified license of each reused file, the required notices, and the adaptations made. **Treat legal uncertainty as a blocker to copying, not a reason to relax the MVP functional tests.**

## Checks

Before finishing:

- Contract changes: `pnpm --filter @quevra/contracts check`

- Workspace-wide changes: `pnpm check`

- Run the focused Foundry unit/integration tests for every changed behavior, including positive bribe notification/claiming across a `c → c+1` boundary, and report the exact commands and failures.

- For claims about true Monad compatibility, run the relevant Solonet or fork/e2e path and state any environment limitations. For Tigris-inspired changes, perform and report the source SPDX/provenance review described above.

A clean build is necessary but **not sufficient** for MVP readiness.

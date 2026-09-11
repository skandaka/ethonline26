# CCAExitLens

**The missing settlement layer for Uniswap Continuous Clearing Auctions.**

Built for ETHOnline 2026 · Uniswap Foundation track

---

## The problem

Uniswap's [Continuous Clearing Auction](https://github.com/Uniswap/continuous-clearing-auction) (CCA)
is the protocol behind token launches in the Uniswap web app. When you are outbid in a CCA, your
unspent currency is not stuck until the auction ends — the protocol deliberately lets you exit
early and recover your capital.

Except, in practice, you often can't. Getting your money out means calling:

```solidity
function exitPartiallyFilledBid(
    uint256 bidId,
    uint64  lastFullyFilledCheckpointBlock, // hint #1
    uint64  outbidBlock                     // hint #2
) external;
```

Those two hints are **checkpoint block numbers that you have to compute yourself**. Pass the wrong
pair and the call reverts with `InvalidLastFullyFilledCheckpointHint()` or
`InvalidOutbidBlockCheckpointHint()` — no indication of what the right answer was.

They are genuinely awkward to compute. Checkpoints live in a *sparse mapping* from block number
to `Checkpoint`, threaded by `prev`/`next` pointers:

```solidity
mapping(uint64 blockNumber => Checkpoint) private $_checkpoints;
```

Reading `checkpoints(n)` for a block with no checkpoint returns a zeroed struct, so absence tells
you nothing about which direction to search. **The list cannot be binary searched — it can only be
walked one pointer at a time, and each hop needs the result of the previous hop.** Offchain, that is
one sequential JSON-RPC round trip per checkpoint. On a busy auction that is hundreds of serial
calls before a user can press "withdraw".

## How this is solved today

Uniswap ships [`cca-indexer`](https://github.com/Uniswap/cca-indexer), a Ponder indexer that tracks
`lastFullyFilledCheckpointBlock` and `outbidCheckpointBlock` per bid. **It computes the hints
correctly** — this project is not filling a hole in Uniswap's understanding of the problem, it is
offering a different shape of answer.

The indexer's shape has costs. It needs Postgres, an RPC endpoint and a running server; it
backfills from the auction's deployment block; and it is configured with a single
`AUCTION_CONTRACT_ADDRESS`, so supporting *n* auctions means *n* deployments. Its README calls it
"not production-ready and intended for development and testing purposes only."

|  | `cca-indexer` | `CCAExitLens` |
|---|---|---|
| Infrastructure | Postgres + RPC + server | none — one `eth_call` |
| Auctions per deployment | one | every auction on the chain |
| New auction | backfill from deploy block | works immediately |
| Trust | the indexer operator's database | chain state, read directly |
| Callable from a contract | **no** | **yes** |
| Sees the *pending* checkpoint | **no** (see below) | **yes** |

The last two rows are the ones that aren't just convenience. An offchain indexer fundamentally
cannot be called by a smart contract, which rules out atomic settlement, keepers, and vaults that
manage CCA positions. And event-driven resolution has a correctness window, below.

## The pending-checkpoint window

A CCA checkpoints *lazily*. `submitBid` checkpoints **before** it books the new demand, so a
price-moving bid never moves the clearing price of its own block — the raised price is only written
when something checkpoints again.

So there is a window where every *committed* checkpoint still shows a bid winning, while the next
checkpoint — the one `exitPartiallyFilledBid` itself creates when called — shows it outbid. Anything
deriving hints from emitted `CheckpointUpdated` events can only see committed checkpoints, so in
this window it reports "not outbid" and its hints **revert**:

```
vm.expectRevert(CannotPartiallyExitBidBeforeEndBlock.selector);
auction.exitPartiallyFilledBid(bidId, indexerLastFullyFilled, indexerOutbidBlock); // 0 == never outbid
```

`CCAExitLens` calls `checkpoint()` first, exactly as the exit path does, so it observes the same
state the exit call will — and its hints settle in that same window. This is demonstrated in
`test/PendingCheckpoint.t.sol`, which also bounds the claim honestly: the window closes as soon as
anyone checkpoints, and a 256-run fuzz test asserts the two approaches agree everywhere else.

## What this does

`CCAExitLens` performs the checkpoint walk *inside the EVM*, so the entire search costs **one
`eth_call`**.

It returns a complete `ExitPlan`: which function to call, the exact hints to pass, whether the bid
is settleable at this block, and why not if it isn't.

`CCAExitRouter` goes one step further and removes hints from the user's world entirely — it resolves
the plan and forwards the correct exit call in the same transaction:

```solidity
router.exit(auction, bidId); // no hints, no indexer, one transaction
```

## The insight that makes it work

The auction documents an invariant in its own source:

> *"the clearing price can never decrease between checkpoints"*
> — `ContinuousClearingAuction.sol`

So a bid's lifetime splits into three **contiguous, monotonically ordered** regions:

```
   [ clearingPrice < maxPrice ] [ clearingPrice == maxPrice ] [ clearingPrice > maxPrice ]
          fully filled                partially filled                  outbid
                     ^                                          ^
     lastFullyFilledCheckpointBlock                        outbidBlock
```

Those two boundaries are precisely the hints `exitPartiallyFilledBid` validates. A single forward
walk finds both, and monotonicity lets it stop at the first checkpoint above the bid.

## Results

All figures below are produced by the test suite in this repo, run against the **unmodified**
Uniswap contracts vendored in `lib/continuous-clearing-auction` (pinned at `6c9e559`).

| | |
|---|---|
| Tests passing | **17 / 17** |
| Checkpoints resolved in one `eth_call` | **99** |
| Gas for that call | **254,872** (~2.6k per checkpoint) |
| Offchain RPC round trips replaced | **99 → 1** |
| Fuzz runs passing | **2,000** (settlement) + **256** (indexer agreement) |

At ~2.6k gas per checkpoint, a standard 50M-gas `eth_call` resolves roughly 19,000 checkpoints,
which is why `DEFAULT_MAX_HOPS` is 20,000. Auctions beyond that are still resolvable through the
paged entrypoint.

### Correctness

These are **differential tests, not assertions about a reimplementation**. Every test that produces
hints then *spends* them on a real `ContinuousClearingAuction`. A hint the protocol rejects fails
the test.

```
[PASS] testFuzz_everySettleablePlanSettles(uint256,uint8) (runs: 2000)
[PASS] test_outbidMidAuction_settlesEarlyWithLensHints()
[PASS] test_partialFillWindowThenOutbid()
[PASS] test_fullyFilledBid_routesToExitBid()
[PASS] test_finalClearingEqualsMaxPrice_routesToPartialWithZeroOutbidHint()
[PASS] test_notGraduated_routesToFullRefund()
[PASS] test_liveAuctionNotGraduated_isNotExitable()
[PASS] test_stillWinningMidAuction_isNotExitable()
[PASS] test_alreadyExited()
[PASS] test_wrongHints_areRejectedByTheAuction()
[PASS] test_pagedWalk_convergesToUnpagedAnswer()
[PASS] test_resolveExitPlansForOwner()
[PASS] test_router_settlesOutbidBidWithoutHints()

[PASS] test_lensSeesPendingCheckpointThatAnIndexerCannot()
[PASS] test_onceCheckpointedBothViewsAgree()
[PASS] testFuzz_lensAgreesWithCommittedIndexerView(uint256) (runs: 256)
```

Two of these carry most of the weight:

- **`test_wrongHints_areRejectedByTheAuction`** shows the lens is doing real work: it feeds the
  auction three plausible *neighbouring* values, shows each is rejected, then settles with the
  lens's answer.
- **`testFuzz_lensAgreesWithCommittedIndexerView`** is a differential test between *two independent
  implementations* of the same search — the lens walking live state inside the EVM, and a
  reimplementation of `cca-indexer`'s event-driven bookkeeping — asserting they agree wherever the
  event-driven one is not stale.

## Usage

### Read a settlement plan

```solidity
ExitPlan memory plan = lens.resolveExitPlan(auction, bidId);

if (plan.route == ExitRoute.EXIT_BID) {
    auction.exitBid(bidId);
} else if (plan.route == ExitRoute.EXIT_PARTIALLY_FILLED) {
    auction.exitPartiallyFilledBid(
        bidId,
        plan.lastFullyFilledCheckpointBlock,
        plan.outbidBlock
    );
}
```

`resolveExitPlan` is intentionally **not** `view`: it calls `auction.checkpoint()` first, exactly as
`exitPartiallyFilledBid` does, so the hints are validated against the same state the exit call will
observe. Use `eth_call`.

### Settle without touching hints at all

```solidity
router.exit(auction, bidId);                       // one bid
router.exitBatch(auction, bidIds);                 // several, all-or-nothing
router.exitSkippingFailures(auction, bidIds);      // settle whatever is ready
router.exitAndClaim(auction, bidId);               // settle, then claim tokens if claimable
```

Safe to call on anyone's behalf, because of two properties of the auction itself: exits have **no
caller restriction**, and `_processExit` always pays the refund to `bid.owner`, never to
`msg.sender`. The router cannot redirect value.

### Scan a wallet's bids

Bids are stored in a flat, append-only mapping with no per-owner index, so finding a wallet's bids
means scanning ids. This does the whole scan — and every hint walk it implies — in one call:

```solidity
ExitPlan[] memory plans = lens.resolveExitPlansForOwner(
    auction, wallet, 0, auction.nextBidId(), lens.DEFAULT_MAX_HOPS()
);
```

### Very long auctions

If a walk exceeds its hop budget, `hintsResolved` comes back `false` with a resumable `cursor`:

```solidity
HintCursor memory cursor;
ExitPlan memory plan;
do {
    plan = lens.resolveExitPlanPaged(auction, bidId, cursor, 5_000);
    cursor = plan.cursor;
} while (!plan.hintsResolved);
```

## SDK

A wallet integrating this writes TypeScript, not Solidity, so `sdk/` ships a viem-based client and a
CLI:

```js
import { resolveExitPlansForOwner, isSettleable, buildRouterExitCall } from 'cca-exit-sdk';

// One eth_call: every position this wallet holds in the auction, with hints resolved.
const plans = await resolveExitPlansForOwner(client, { lens, auction, owner });

for (const plan of plans.filter(isSettleable)) {
  await wallet.writeContract(buildRouterExitCall({ router, auction, bidId: plan.bidId }));
}
```

```console
$ cca-exit plan --lens 0x5FbD.. --auction 0xCf7E.. --bid 0
bid 0  owner 0x70997970C51812dc3A010C7d01b50e0d17dc79C8
  route                          : EXIT_PARTIALLY_FILLED
  lastFullyFilledCheckpointBlock : 16
  outbidBlock                    : 17
  checkpoints walked             : 3
  graduated / over               : true / false

settleable now: yes
```

`cca-exit scan --owner <addr>` lists a wallet's positions; `cca-exit settle --bid <id>` simulates and
then settles through the router. Run the whole thing against a local chain with
`./demo/run-sdk-demo.sh`.

## Demo

```bash
./demo/run-demo.sh
```

Starts a local anvil node, deploys a **real** `ContinuousClearingAuction` plus the lens and router,
and plays out the case the project exists for: Alice bids 0.05 ETH, Bob outbids her ten blocks later,
and Alice recovers **0.044 ETH mid-auction in one transaction** — after the naive hint guess is shown
to revert. Full transcript and commentary in [DEMO.md](./DEMO.md).

## Layout

```
src/
  CCAExitLens.sol         Stateless hint resolver. One eth_call per bid.
  CCAExitRouter.sol       Resolve + settle atomically. Holds no funds.
script/
  Deploy.s.sol            Deploys both.
  DemoSetup.s.sol         Deploys a demo-sized auction alongside them.
demo/
  run-demo.sh             End-to-end scenario against a local anvil node.
  run-sdk-demo.sh         The same scenario driven through the SDK and CLI.
sdk/
  src/index.js            viem client: resolve plans, build settlement calls.
  bin/cca-exit.js         CLI: plan / scan / settle.
test/
  CCAExitLens.t.sol       13 differential tests against real auctions, incl. fuzz.
  PendingCheckpoint.t.sol Lens vs. event-driven resolution, incl. a 256-run agreement fuzz.
  Benchmark.t.sol         Cost of resolving across a long checkpoint list.
  utils/                  Auction harness built on the real contracts.
```

Both contracts are stateless and hold no funds, so a single deployment per chain is safe to share
across every auction — the same deployment model as Uniswap's own `CCALens`.

## Build

```bash
git clone --recurse-submodules <this repo>
cd ethonline26
forge test
```

Requires Foundry and solc 0.8.26. The submodule pulls in Uniswap's CCA contracts and their
dependencies (~500MB); `git submodule update --init --recursive` if you cloned without
`--recurse-submodules`.

## Feedback to the Uniswap Foundation

See [FEEDBACK.md](./FEEDBACK.md) — seven concrete findings from building against CCA, including a
documentation bug where the deployment guide documents a factory function that does not exist in
the deployed contract.

## License

MIT. The vendored Uniswap contracts under `lib/` are MIT and belong to Uniswap.

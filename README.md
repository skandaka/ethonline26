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
`InvalidOutbidBlockCheckpointHint()` — no indication of what the right answer was. Uniswap's own
`CCALens` reads auction state and tick data, but **nothing in the official tooling computes these
hints.**

And they are genuinely awkward to compute. Checkpoints live in a *sparse mapping* from block number
to `Checkpoint`, threaded by `prev`/`next` pointers:

```solidity
mapping(uint64 blockNumber => Checkpoint) private $_checkpoints;
```

Reading `checkpoints(n)` for a block with no checkpoint returns a zeroed struct, so absence tells
you nothing about which direction to search. **The list cannot be binary searched — it can only be
walked one pointer at a time, and each hop needs the result of the previous hop.** Offchain, that is
one sequential JSON-RPC round trip per checkpoint. On a busy auction that is hundreds of serial
calls before a user can press "withdraw".

## What this does

`CCAExitLens` performs that walk *inside the EVM*, so the entire search costs **one `eth_call`**.

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
| Checkpoints resolved in one `eth_call` | **99** |
| Gas for that call | **254,872** (~2.6k per checkpoint) |
| Offchain RPC round trips replaced | **99 → 1** |
| Fuzz runs passing | **2,000** |

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
```

`test_wrongHints_areRejectedByTheAuction` is the one that shows the lens is doing real work: it
feeds the auction three plausible *neighbouring* values and shows each is rejected, then settles
with the lens's answer.

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

## Layout

```
src/
  CCAExitLens.sol      Stateless hint resolver. One eth_call per bid.
  CCAExitRouter.sol    Resolve + settle atomically. Holds no funds.
script/
  Deploy.s.sol         Deploys both.
test/
  CCAExitLens.t.sol    13 differential tests against real auctions, incl. fuzz.
  Benchmark.t.sol      Cost of resolving across a long checkpoint list.
  utils/               Auction harness built on the real factory + contracts.
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

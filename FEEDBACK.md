# Developer feedback — building against Uniswap Continuous Clearing Auctions

Submitted for the Uniswap Foundation track at ETHOnline 2026.

Context: I built [`CCAExitLens`](./src/CCAExitLens.sol), a periphery contract that resolves the
checkpoint hints required by `ContinuousClearingAuction.exitPartiallyFilledBid`. Everything below
came out of actually integrating against the contracts in
[`Uniswap/continuous-clearing-auction`](https://github.com/Uniswap/continuous-clearing-auction)
at commit `6c9e559`, not from reading the docs alone.

Overall: the mechanism is elegant and the code is unusually pleasant to read — the accounting
libraries are well factored, the BTT test layout made the invariants easy to discover, and the
inline comments explaining *why* (rather than what) repeatedly saved me time. The friction is
almost entirely in the **integration surface for bidders**, not the mechanism.

---

## 1. `exitPartiallyFilledBid` has no hint resolver anywhere in the official tooling

This is the big one, and it is the reason this project exists.

```solidity
function exitPartiallyFilledBid(
    uint256 bidId,
    uint64  lastFullyFilledCheckpointBlock,
    uint64  outbidBlock
) external;
```

Both hints must be derived by walking the checkpoint list. `CCALens` ships `AuctionStateLens` (latest
checkpoint, currency raised, graduation) and `TickDataLens` (initialized tick walk) — but there is no
equivalent for the one computation a *bidder* actually needs in order to get their money back.

The result is that the protocol's early-exit capability, which is a genuinely nice piece of design,
is effectively gated behind writing your own indexer.

**Suggestion:** add a `resolveExitHints(auction, bidId)` view to `CCALens`. It is ~40 lines given
the monotonicity invariant. I'd be glad to upstream this repo's implementation.

## 2. The checkpoint list cannot be binary searched, which makes offchain resolution O(n) *sequential*

Checkpoints are a sparse mapping keyed by block number:

```solidity
mapping(uint64 blockNumber => Checkpoint) private $_checkpoints;
```

`checkpoints(n)` for an un-checkpointed block returns a zeroed struct. Because absence carries no
direction information, an offchain integrator cannot binary search the range — they must follow
`next` pointers one at a time, and each hop depends on the previous response. That is one JSON-RPC
round trip per checkpoint, strictly serialized, so it cannot be batched or multicalled either.

Walking 99 checkpoints costs ~255k gas in a single `eth_call`. The same walk offchain is 99
sequential round trips.

**Suggestion:** this is inherent to the storage layout and probably not worth changing — but it is
exactly why a lens-side resolver (point 1) matters so much. Worth an explicit note in the docs that
bidder-side hint resolution should be done onchain via a lens rather than offchain.

## 3. A bid never moves the clearing price of its own block, and this is not documented

This cost me the most debugging time, and I think it will surprise most integrators.

`submitBid` calls `checkpoint()` **before** booking the new demand. So the checkpoint written at
block *N* reflects the clearing price *before* any bid submitted in block *N*. The raised price only
becomes observable at the next checkpoint.

The practical consequence for bidders: **you cannot exit in the block you are outbid.** Your exit
becomes available one checkpoint later. A UI that offers "withdraw" the instant it sees a higher bid
land will produce a reverting transaction.

**Suggestion:** call this out in the technical documentation next to the exit functions. It is a
one-sentence addition that would save integrators real time.

## 4. Hint validation errors carry no data

```solidity
error InvalidLastFullyFilledCheckpointHint();
error InvalidOutbidBlockCheckpointHint();
```

When a hint is wrong you learn only *which* hint, never what was expected or what the contract saw.
During development I repeatedly had to re-walk the list by hand to work out whether I was off by one
checkpoint or had the wrong region entirely.

**Suggestion:** include the offending value and the checkpoint's clearing price, e.g.
`InvalidLastFullyFilledCheckpointHint(uint64 provided, uint256 clearingPriceAtHint)`. Cheap, and it
turns a guessing game into a one-shot fix.

## 5. `next == type(uint64).max` is a sharp edge for integrators

The newest checkpoint stores `next = MAX_BLOCK_NUMBER` as a sentinel. If an integrator follows that
pointer naively, `checkpoints(type(uint64).max)` returns a **zeroed** struct — and a `clearingPrice`
of `0` compares as *below* every bid price. A walk that does not special-case the sentinel will
silently conclude "this bid was fully filled forever" instead of terminating.

The auction itself relies on this behaviour deliberately (a zero-price sentinel makes
`_getCheckpoint(lff.next).clearingPrice < bidMaxPrice` correctly reject an unterminated hint), so it
is not a bug — but it is an easy way for a third-party integration to be quietly wrong rather than
loudly broken.

**Suggestion:** document the sentinel explicitly in the checkpoint section of the technical docs.

## 6. Documentation bug: the factory function documented does not exist

`docs/DeploymentGuide.md` and `docs/TechnicalDocumentation.md` both document the auction factory
entrypoint as:

```solidity
function initializeDistribution(address token, uint256 amount, bytes calldata configData, bytes32 salt)
```

The deployed `ContinuousClearingAuctionFactory` implements `IDistributorFactory` and exposes:

```solidity
function create(address token, uint256 amount, bytes calldata configData, bytes32 salt)
    external returns (IDistributor distributor);
```

There is no `initializeDistribution` anywhere in `src/`. The stale name also appears in the
generated reference at
`docs/autogen/src/src/ContinuousClearingAuctionFactory.sol/contract.ContinuousClearingAuctionFactory.md`,
which suggests the autogen output has drifted rather than being regenerated.

Following the deployment guide verbatim will not compile. This is the first thing a new integrator
does, so it is worth a quick fix.

## 7. Finding a wallet's bids requires a full id scan

Bids live in a flat append-only mapping with no per-owner index:

```solidity
mapping(uint256 bidId => Bid bid) private $_bids;
```

To show "your bids" a wallet must scan `0..nextBidId()` and filter on `bid.owner`. On a popular
launch that is a lot of reads for a simple portfolio view. The `BidSubmitted` event makes this
tractable via logs, but anything wanting current state still has to scan.

**Suggestion:** either an `ownerOf`-style index, or a lens helper that does the scan onchain. I
implemented the latter as `resolveExitPlansForOwner`; it works well and is cheap enough, but it
feels like something that belongs in `CCALens`.

---

## What worked well

- **The monotonic clearing price invariant is the whole ballgame**, and the codebase states it
  plainly in a comment right where it matters, in `exitPartiallyFilledBid`. That single comment is
  what made a correct one-pass resolver possible. More invariants surfaced like this, please.
- **Exits are permissionless and always pay `bid.owner`.** That is a deliberate, well-chosen
  property — it is what makes a third-party router safe to build, and it means anyone can settle a
  stuck bidder's position for them. It deserves to be advertised more loudly, because it enables a
  whole class of helpful tooling.
- **`address(0)` as a fee controller** cleanly disables protocol fees and made test setup trivial.
- **The BTT test structure** under `test/btt/` made it fast to find the exact semantics of
  `accountPartiallyFilledCheckpoints` without reading the whole accounting library.
- **Audit coverage** (Spearbit, OpenZeppelin, ABDK) being linked directly from the README is a good
  signal and saved me asking.

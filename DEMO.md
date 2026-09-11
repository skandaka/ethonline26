# Demo — a bidder recovers capital mid-auction

Run it yourself:

```bash
./demo/run-demo.sh
```

It starts a local anvil node, deploys the lens, the router and a **real**
`ContinuousClearingAuction`, and plays out the case the whole project exists for: a bidder is outbid
while the auction is still running and wants their money back. Nothing is mocked — every step is a
real transaction against the unmodified Uniswap contracts.

## The scenario

| | |
|---|---|
| Auction | 1,000 tokens, 1% released per block over 100 blocks, floor 0.001 ETH/token |
| Alice | bids **0.05 ETH** at 0.0011 ETH/token |
| Bob | 10 blocks later, floods the book at 0.0017 ETH/token |
| Result | the clearing price moves above Alice — she is outbid, mid-auction |

## Transcript

Captured from an actual run. CI executes this same script on every commit, so the behaviour below
is verified rather than remembered — though the exact block numbers and gas-adjusted balances shift
with the run.

```
0. Starting a local chain
  anvil up at http://127.0.0.1:8545

1. Deploying the lens, the router, and a real Continuous Clearing Auction
  auction  0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9
  lens     0x5FbDB2315678afecb367f032d93F642f64180aa3
  router   0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512

2. Alice bids 0.05 ETH at 0.0011 ETH/token
  bid 0 submitted by alice
  alice balance: 9999.949759205150841440 ETH

3. Bob floods the book at 0.0017 ETH/token, outbidding Alice
  bid 1 submitted by bob — the clearing price will move above alice

4. Alice's position, according to the lens (one eth_call)
  raw plan: (0, 0x7099...79C8, 3, 16, 17, true, (0, 0), 3,
             87150978765690771352898345, 134687876274249373909024715, true, false)
  route                          : EXIT_PARTIALLY_FILLED
  lastFullyFilledCheckpointBlock : 16
  outbidBlock                    : 17

5. What happens without the hints
  calling exitPartiallyFilledBid(0, 0, 0) — the naive guess:
  reverted, as expected — the hints are load-bearing

6. Settling through the router, with no hints supplied by the caller
  router.exit(auction, 0) succeeded

Result
  alice before : 9999.949759205150841440 ETH
  alice after  : 9999.993940530599803513 ETH
  recovered    : 0.044181325448962073 ETH  (net of gas)

  bid struct after exit: (5, 500000, 18, 8715..., 0x7099...79C8, 3.961e45, 5789473684210526315)
  (non-zero exitedBlock == settled)

Alice recovered her capital mid-auction, in one transaction, with no indexer.
```

## Reading the output

**Step 4** is the whole contribution in one line. A single `eth_call` returns
`route = EXIT_PARTIALLY_FILLED` with hints `(16, 17)` — the last checkpoint below Alice's price and
the first one above it. `hops = 3` says it walked three checkpoints to find them. No database, no
backfill, no indexer; the auction was deployed seconds earlier.

**Step 5** shows the hints are load-bearing rather than decorative. `(0, 0)` is the obvious naive
guess and the auction rejects it.

**Step 6** settles through the router, which resolves the hints internally — the caller passes only
the auction address and the bid id.

**The result** shows Alice recovering **0.044 ETH** of her 0.05 ETH, net of gas, while the auction is
still live. The remainder is not lost: `tokensFilled = 5789473684210526315` in the bid struct is the
~5.79 tokens she actually bought during the blocks when her bid was clearing, claimable after the
auction's claim block. And `exitedBlock = 18` confirms settlement.

## Why the mid-auction part matters

Alice did not have to wait for the auction to end. CCA deliberately allows an outbid bidder to exit
early, and on a 100-block auction that is the difference between capital being locked and being
redeployable. The catch is that early exit is the *only* path that requires the `outbidBlock` hint —
which is exactly the one an event-driven indexer cannot supply during the pending-checkpoint window
described in [README.md](./README.md#the-pending-checkpoint-window).

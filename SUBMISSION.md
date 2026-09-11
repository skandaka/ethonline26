# Submission checklist

Things only you can do. The repository side is done; these are the gates that need a human.

## 1. Demo video — 2–4 minutes, **required**

ETHGlobal requires a 2–4 minute demo video. Without it the submission is incomplete regardless of
the code. A suggested run of show, which maps onto `./demo/run-demo.sh`:

| Time | Beat |
|---|---|
| 0:00–0:30 | The problem. A CCA bidder who gets outbid can withdraw *before* the auction ends — but only by passing two checkpoint block numbers they have to compute themselves. Pass the wrong pair and it reverts. |
| 0:30–1:00 | Why it's hard. Show `CheckpointStorage.sol`: a sparse mapping threaded by `prev`/`next`. Un-checkpointed blocks read back as zeros, so it can't be binary searched — only walked, one sequential RPC round trip per hop. |
| 1:00–1:30 | Today's answer: `Uniswap/cca-indexer` — correct, but Postgres + RPC + a server, one deployment per auction. Show the comparison table in the README. |
| 1:30–2:30 | Run `./demo/run-demo.sh` live. The naive hint guess reverts; the router recovers 0.044 ETH mid-auction in one transaction. |
| 2:30–3:15 | The finding: the pending-checkpoint window. Event-driven hints *revert* where the lens's settle. Show `test/PendingCheckpoint.t.sol` passing. |
| 3:15–4:00 | `forge test` green, the benchmark (99 checkpoints, one `eth_call`, 255k gas), and `FEEDBACK.md`. |

Record with `./demo/run-sdk-demo.sh` if you'd rather show the CLI than raw `cast`.

## 2. Uniswap Developer Feedback Form — **track qualification gate**

The Uniswap Foundation track requires a public open-source repo, a `FEEDBACK.md`, **and** a
completed submission to the Uniswap Developer Feedback Form linking to that file. Two of the three
are done; the form is not, and I can't submit web forms.

Link it to `FEEDBACK.md` on the default branch once this is merged.

## 3. Hacker Dashboard submission

- Select **Uniswap Foundation** as a partner prize (you get up to 3).
- For each partner prize you must explain how you used their tools, give feedback, and add comments.
  `FEEDBACK.md` is the source material for all three.
- Paste the description below, or your own edit of it.

### Ready-to-paste description

> **CCAExitLens — the missing settlement layer for Uniswap Continuous Clearing Auctions.**
>
> A CCA lets an outbid bidder recover unspent capital before the auction ends, but only by calling
> `exitPartiallyFilledBid` with two checkpoint block-number hints the caller must compute. Checkpoints
> live in a sparse mapping threaded by pointers, where un-checkpointed blocks read back as zeros — so
> the list can't be binary searched, only walked one hop at a time, each hop depending on the last.
> Offchain that's one sequential RPC round trip per checkpoint.
>
> Uniswap's `cca-indexer` resolves these hints correctly, but needs Postgres, an RPC endpoint and a
> running server, backfills from the auction's deploy block, and takes one auction per deployment.
>
> CCAExitLens does the walk inside the EVM: **one `eth_call`, no infrastructure, every auction on the
> chain, and callable from a smart contract** — which an offchain indexer fundamentally cannot be.
> CCAExitRouter resolves and settles atomically, so users never touch a hint.
>
> Tracing the indexer's algorithm surfaced a correctness gap. A CCA checkpoints lazily: `submitBid`
> checkpoints *before* booking demand, so a price-moving bid never moves the clearing price of its own
> block. That leaves a window where every committed checkpoint shows a bid winning while the next one —
> the one the exit call itself creates — shows it outbid. Event-driven hints don't just go stale there,
> they **revert**. The lens checkpoints first and settles in that same window. Proven, and honestly
> bounded, in `test/PendingCheckpoint.t.sol`.
>
> 17 tests, all differential against the unmodified Uniswap contracts: every test that produces hints
> then spends them on a live auction, so a hint the protocol rejects fails the test. 2,000-run
> settlement fuzz, plus a 256-run differential fuzz against a reimplementation of the indexer's
> bookkeeping. 99 checkpoints resolved in one call for 254,872 gas. Live demo on anvil, plus a viem
> SDK and CLI.

## 4. AI disclosure — **required by the rules**

This project was built by Claude Code. ETHGlobal requires disclosing AI assistance in writing and
including prompts and planning artifacts in the repo. [`AI-DISCLOSURE.md`](./AI-DISCLOSURE.md) does
that — all four prompts verbatim, how the problem was found, the false claim that was caught and
retracted before submission, and the known limits.

**Repeat the disclosure in the submission form itself**, and point it at that file. The rules ask for
disclosure "in writing to the ETHGlobal team" plus "full details in your submission (repo history,
video, and description)" — a file in the repo alone may not satisfy the form requirement.

## 5. Before you submit

- [ ] Merge [PR #1](https://github.com/skandaka/ethonline26/pull/1) so the default branch carries the work
- [ ] Repository is **public** (track requirement)
- [ ] Demo video recorded and linked
- [ ] Uniswap Developer Feedback Form submitted, linking to `FEEDBACK.md`
- [ ] AI assistance disclosed in the submission form
- [ ] Uniswap Foundation selected as a partner prize
- [ ] Submitted before the deadline — late submissions are not accepted

## Worth doing if you have time

The one substantive gap: **fork tests against the live deployments.** All public RPC endpoints were
blocked in the build environment, so nothing here has run against a real chain. Pointing the test
suite at the deployed factory `0x000000001F26a0044BaA66024e7b6599c61963F8` on Ethereum, Base,
Arbitrum or Unichain — and resolving hints for a real historical bid — would be the strongest single
addition:

```bash
forge test --fork-url $RPC_URL --match-contract CCAExitLensTest
```

Deploying the lens to a testnet and putting the verified address in the README would also let judges
click through to it.

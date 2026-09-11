# AI disclosure and planning artifacts

ETHGlobal's rules require that projects built with AI assistance disclose it, and that spec files,
prompts and planning artifacts be included in the submission repository so judges can see how the
AI was directed rather than only the generated output. This file is that record.

## Summary

**This project was built by Claude (Anthropic's Claude Code agent), directed by the repository
owner.** There is no pre-existing work: the repository was empty at the start of the session, and
every commit is from that session. The commit history is the full provenance.

The vendored Uniswap contracts under `lib/continuous-clearing-auction` are not this project's work —
they are the unmodified upstream repository, pinned as a git submodule at commit `6c9e559`, included
so the tests run against the real protocol rather than a reimplementation.

## The prompts

The entire project came from four instructions. They are reproduced verbatim.

**1 — the opening instruction:**

> do extensive research on ethonline26. make sure you are learning absolutely eveyrthing there is to
> know about this hackathon, and then do something in the uniswap track prize. make sure you are do
> extensive extensive web research and you are thinking extremely hard.

**2 — after the first working version:**

> continue improving this further, and do extensive research on the most optimal next steps to take.
> do extensive research online in various places, and make sure you are doing an in depth planning
> stage before you start creating again.

**3 — a security review**, invoked as the `/security-review` slash command (a Claude Code skill that
reviews the branch diff for exploitable vulnerabilities).

**4 — a self-paced improvement loop:**

> continue improving this further, and do extensive research on the most optimal next steps to take.
> do extensive research online in various places, and make sure you are doing an in depth planning
> stage before you start creating again. keep improving until we have a great amazing chance of
> winning this hackathon.

Note what is *not* in those prompts: the idea. "Build a lens that resolves CCA exit hints" was not
specified by the human. The choice of the CCA track over v4 hooks, the identification of the exit
hint problem, the algorithm, and the pending-checkpoint finding all came out of the research
described below. The human set direction and quality bar; the technical decisions are the agent's,
and the agent is responsible for their correctness.

## How the problem was found

The research path is worth recording because the result depends on it.

1. **Hackathon research.** Established ETHOnline 2026's dates, the Uniswap Foundation's $5,000
   track, and — importantly — the track's hard qualification gates: a public open-source repo, a
   `FEEDBACK.md`, and a submission to the Uniswap Developer Feedback Form.

2. **Track selection.** The track scope covers "the Uniswap API, the Uniswap AMM (v2, v3, or v4),
   CCA, or any other Uniswap protocol." v4 hooks are saturated — 90k+ hook addresses initialized.
   Continuous Clearing Auction, live since February 2026, was named in scope and barely tooled. That
   ratio of relevance to crowding is why CCA was chosen.

3. **Reading the source, not the docs.** The contracts were cloned and read directly. This mattered
   immediately: the official `TechnicalDocumentation.md` and `DeploymentGuide.md` document a factory
   entrypoint `initializeDistribution(...)` that does not exist — the deployed factory exposes
   `create(...)`. Following the deployment guide verbatim will not compile. That became finding #6
   in `FEEDBACK.md`.

4. **Finding the gap.** `exitPartiallyFilledBid` requires two checkpoint block-number hints from the
   caller. Reading `CheckpointStorage.sol` showed checkpoints are a *sparse mapping* threaded by
   `prev`/`next` pointers, where an un-checkpointed block reads back as zeros — so the list cannot be
   binary searched, only walked pointer by pointer, each hop depending on the previous response.

5. **Finding the invariant.** A comment inside `exitPartiallyFilledBid` states that "the clearing
   price can never decrease between checkpoints." That makes a bid's lifetime three contiguous
   ordered regions whose boundaries are exactly the two hints — which is what makes a single forward
   walk correct.

## The correction that matters most

Partway through, research turned up [`Uniswap/cca-indexer`](https://github.com/Uniswap/cca-indexer),
a Ponder indexer that **already resolves these hints**. The README and `FEEDBACK.md` at that point
both claimed nothing in the official tooling computed them. That claim was false.

The agent traced the indexer's algorithm line by line expecting to find an off-by-one — initially
believing `lastFullyFilledCheckpointBlock` was only written at `BidSubmitted` and never updated. It
then found the batch `UPDATE` that does rewrite it on every fully-filled checkpoint, and concluded
**the indexer is correct**. The false claim was retracted in commit `6b8f23f`, in the docs and in the
pull request body, before any of it was submitted.

This is recorded deliberately. An unverified accusation of a bug in a sponsor's codebase, published
in a feedback document that sponsor reads, would have been worse than useless. The lesson applied
throughout: every claim in `FEEDBACK.md` is either verified against source or stated as uncertain.

That investigation is also what produced the project's strongest technical result — tracing the
event-driven algorithm is what exposed the pending-checkpoint window, which is now proven in
`test/PendingCheckpoint.t.sol`.

## Verification approach

The agent's own output is not evidence. The project is therefore structured so the *protocol*
adjudicates every claim:

- Tests run against the real, unmodified Uniswap contracts, not mocks.
- Every test that produces hints then **spends** them on a live auction. A hint the protocol rejects
  fails the test, so the lens cannot be "correct" only in its author's opinion.
- `test_wrongHints_areRejectedByTheAuction` feeds three plausible *neighbouring* values and shows
  each is rejected, establishing the hints are load-bearing rather than incidental.
- `testFuzz_lensAgreesWithCommittedIndexerView` is a differential test between two independent
  implementations — the lens, and a reimplementation of the indexer's event-driven bookkeeping.
- `demo/run-demo.sh` and `demo/run-sdk-demo.sh` execute the full scenario against a real auction on
  a local node, and CI runs both, so the transcript in `DEMO.md` cannot silently rot.

Two defects in the agent's own code were found this way and fixed: hints that reverted because the
test scenario misunderstood lazy checkpointing, and an early return that reported a graduated
auction as not graduated for already-settled bids.

## Known limits

Stated plainly, because a submission that hides these is worth less than one that doesn't:

- **No live-network deployment or fork tests.** All public RPC endpoints were blocked by the build
  environment's egress policy, so the contracts have never run against a real chain — only against
  real contracts on a local node. Fork tests against the deployed factory
  (`0x000000001F26a0044BaA66024e7b6599c61963F8`) are the obvious next step and are not done.
- **Not audited.** The contracts are stateless and hold no funds, which bounds the risk, but no
  external review has happened beyond the `/security-review` pass recorded in the session.
- **The pending-checkpoint finding is a freshness gap, not a permanent divergence.** The window
  closes as soon as anyone checkpoints the auction. `test_onceCheckpointedBothViewsAgree` exists
  specifically to bound that claim.
- **The demo runs on anvil**, with a scaled-down auction sized to fit default account balances.

## Tooling

Claude Code (agent), Foundry (forge/cast/anvil) for contracts and tests, viem for the SDK. Model
identity and session metadata are in the commit trailers.

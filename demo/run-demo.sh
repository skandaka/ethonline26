#!/usr/bin/env bash
# End-to-end demo: a bidder is outbid mid-auction and recovers their capital in one transaction.
#
# Runs a real ContinuousClearingAuction on a local anvil node. Nothing is mocked — every step below
# is a real transaction against the unmodified Uniswap contracts.
#
#   ./demo/run-demo.sh
set -euo pipefail

RPC=http://127.0.0.1:8545
# anvil's default accounts
DEPLOYER_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
ALICE_KEY=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d
BOB_KEY=0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a
ALICE=0x70997970C51812dc3A010C7d01b50e0d17dc79C8
BOB=0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC

cd "$(dirname "$0")/.."

hr() { printf '\n\033[1m%s\033[0m\n' "$*"; }
note() { printf '  %s\n' "$*"; }

cleanup() { [[ -n "${ANVIL_PID:-}" ]] && kill "$ANVIL_PID" 2>/dev/null || true; }
trap cleanup EXIT

hr "0. Starting a local chain"
anvil --silent --port 8545 &
ANVIL_PID=$!
for _ in $(seq 1 50); do
  cast block-number --rpc-url $RPC >/dev/null 2>&1 && break
  sleep 0.2
done
note "anvil up at $RPC"

hr "1. Deploying the lens, the router, and a real Continuous Clearing Auction"
# Capture the output to parse addresses out of it, but surface it if the deploy fails — under
# `set -e` a bare `OUT=$(...)` aborts the script with the error swallowed into the variable.
if ! OUT=$(forge script script/DemoSetup.s.sol:DemoSetup \
    --rpc-url $RPC --private-key $DEPLOYER_KEY --broadcast 2>&1); then
  echo "forge script failed:" >&2
  echo "$OUT" >&2
  exit 1
fi

AUCTION=$(grep -oE 'AUCTION=0x[0-9a-fA-F]{40}' <<<"$OUT" | tail -1 | cut -d= -f2)
LENS=$(grep -oE 'LENS=0x[0-9a-fA-F]{40}' <<<"$OUT" | tail -1 | cut -d= -f2)
ROUTER=$(grep -oE 'ROUTER=0x[0-9a-fA-F]{40}' <<<"$OUT" | tail -1 | cut -d= -f2)
TICK2=$(grep -oE 'TICK2=[0-9]+' <<<"$OUT" | tail -1 | cut -d= -f2)
TICK8=$(grep -oE 'TICK8=[0-9]+' <<<"$OUT" | tail -1 | cut -d= -f2)

if [[ -z "$AUCTION" || -z "$LENS" || -z "$ROUTER" ]]; then
  echo "deployment failed:"; echo "$OUT"; exit 1
fi
note "auction  $AUCTION"
note "lens     $LENS"
note "router   $ROUTER"

mine() { cast rpc anvil_mine "$1" --rpc-url $RPC >/dev/null; }

hr "2. Alice bids 0.05 ETH at 0.0011 ETH/token"
cast send "$AUCTION" \
  'submitBid(uint256,uint128,address,bytes)(uint256)' \
  "$TICK2" 50000000000000000 "$ALICE" 0x \
  --value 0.05ether --private-key $ALICE_KEY --rpc-url $RPC >/dev/null
note "bid 0 submitted by alice"

ALICE_BEFORE=$(cast balance $ALICE --rpc-url $RPC)
note "alice balance: $(cast from-wei "$ALICE_BEFORE") ETH"

mine 10

hr "3. Bob floods the book at 0.0017 ETH/token, outbidding Alice"
cast send "$AUCTION" \
  'submitBid(uint256,uint128,address,bytes)(uint256)' \
  "$TICK8" 5100000000000000000 "$BOB" 0x \
  --value 5.1ether --private-key $BOB_KEY --rpc-url $RPC >/dev/null
note "bid 1 submitted by bob — the clearing price will move above alice"

mine 1

hr "4. Alice's position, according to the lens (one eth_call)"
PLAN=$(cast call "$LENS" \
  'resolveExitPlan(address,uint256)((uint256,address,uint8,uint64,uint64,bool,(uint64,uint64),uint32,uint256,uint256,bool,bool))' \
  "$AUCTION" 0 --rpc-url $RPC)
note "raw plan: $PLAN"

# `cast call` already returns a decoded tuple. Fields 3-5 all sit before the nested cursor tuple,
# so a plain comma split is safe here.
FIELDS=$(sed 's/^(//' <<<"$PLAN")
ROUTE=$(cut -d, -f3 <<<"$FIELDS" | tr -d ' ')
LFF=$(cut -d, -f4 <<<"$FIELDS" | tr -d ' ')
OUTBID=$(cut -d, -f5 <<<"$FIELDS" | tr -d ' ')

case "$ROUTE" in
  0) ROUTE_NAME="ALREADY_EXITED" ;;
  1) ROUTE_NAME="NOT_YET_EXITABLE" ;;
  2) ROUTE_NAME="EXIT_BID" ;;
  3) ROUTE_NAME="EXIT_PARTIALLY_FILLED" ;;
  *) ROUTE_NAME="unknown($ROUTE)" ;;
esac
note "route                          : $ROUTE_NAME"
note "lastFullyFilledCheckpointBlock : $LFF"
note "outbidBlock                    : $OUTBID"

hr "5. What happens without the hints"
note "calling exitPartiallyFilledBid(0, 0, 0) — the naive guess:"
if cast send "$AUCTION" 'exitPartiallyFilledBid(uint256,uint64,uint64)' 0 0 0 \
     --private-key $ALICE_KEY --rpc-url $RPC >/dev/null 2>&1; then
  note "unexpectedly succeeded"
else
  note "reverted, as expected — the hints are load-bearing"
fi

hr "6. Settling through the router, with no hints supplied by the caller"
cast send "$ROUTER" 'exit(address,uint256)(uint8)' "$AUCTION" 0 \
  --private-key $ALICE_KEY --rpc-url $RPC >/dev/null
note "router.exit(auction, 0) succeeded"

ALICE_AFTER=$(cast balance $ALICE --rpc-url $RPC)
EXITED=$(cast call "$AUCTION" 'bids(uint256)((uint64,uint24,uint64,uint256,address,uint256,uint256))' 0 --rpc-url $RPC)

hr "Result"
note "alice before : $(cast from-wei "$ALICE_BEFORE") ETH"
note "alice after  : $(cast from-wei "$ALICE_AFTER") ETH"
# Wei balances exceed bash's 64-bit arithmetic, so do the subtraction in python.
RECOVERED=$(python3 -c "print($ALICE_AFTER - $ALICE_BEFORE)")
note "recovered    : $(cast from-wei "$RECOVERED") ETH  (net of gas)"
note ""
note "bid struct after exit: $EXITED"
note "(non-zero exitedBlock == settled)"
printf '\n\033[1mAlice recovered her capital mid-auction, in one transaction, with no indexer.\033[0m\n\n'

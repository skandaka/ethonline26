#!/usr/bin/env bash
# Same scenario as run-demo.sh, driven through the TypeScript/viem SDK instead of `cast`.
# Shows what a wallet integrating this would actually call.
#
#   (cd sdk && npm install) && ./demo/run-sdk-demo.sh
set -euo pipefail

RPC=http://127.0.0.1:8545
DEPLOYER_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
ALICE_KEY=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d
BOB_KEY=0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a
ALICE=0x70997970C51812dc3A010C7d01b50e0d17dc79C8
BOB=0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC

cd "$(dirname "$0")/.."
CLI="node sdk/bin/cca-exit.js"

hr() { printf '\n\033[1m%s\033[0m\n' "$*"; }

if [[ ! -d sdk/node_modules ]]; then
  echo "sdk dependencies missing — run: (cd sdk && npm install)" >&2
  exit 1
fi

cleanup() { [[ -n "${ANVIL_PID:-}" ]] && kill "$ANVIL_PID" 2>/dev/null || true; }
trap cleanup EXIT

anvil --silent --port 8545 &
ANVIL_PID=$!
for _ in $(seq 1 50); do
  cast block-number --rpc-url $RPC >/dev/null 2>&1 && break
  sleep 0.2
done

hr "Deploying lens, router and a real Continuous Clearing Auction"
OUT=$(forge script script/DemoSetup.s.sol:DemoSetup \
  --rpc-url $RPC --private-key $DEPLOYER_KEY --broadcast --offline 2>&1)
AUCTION=$(grep -oE 'AUCTION=0x[0-9a-fA-F]{40}' <<<"$OUT" | tail -1 | cut -d= -f2)
LENS=$(grep -oE 'LENS=0x[0-9a-fA-F]{40}' <<<"$OUT" | tail -1 | cut -d= -f2)
ROUTER=$(grep -oE 'ROUTER=0x[0-9a-fA-F]{40}' <<<"$OUT" | tail -1 | cut -d= -f2)
TICK2=$(grep -oE 'TICK2=[0-9]+' <<<"$OUT" | tail -1 | cut -d= -f2)
TICK8=$(grep -oE 'TICK8=[0-9]+' <<<"$OUT" | tail -1 | cut -d= -f2)
echo "  auction $AUCTION"
echo "  lens    $LENS"
echo "  router  $ROUTER"

mine() { cast rpc anvil_mine "$1" --rpc-url $RPC >/dev/null; }

hr "Alice bids, then Bob outbids her"
cast send "$AUCTION" 'submitBid(uint256,uint128,address,bytes)(uint256)' \
  "$TICK2" 50000000000000000 "$ALICE" 0x \
  --value 0.05ether --private-key $ALICE_KEY --rpc-url $RPC >/dev/null
mine 10
cast send "$AUCTION" 'submitBid(uint256,uint128,address,bytes)(uint256)' \
  "$TICK8" 5100000000000000000 "$BOB" 0x \
  --value 5.1ether --private-key $BOB_KEY --rpc-url $RPC >/dev/null
mine 1
echo "  done"

hr "\$ cca-exit plan --auction .. --bid 0"
$CLI plan --rpc $RPC --lens "$LENS" --auction "$AUCTION" --bid 0

hr "\$ cca-exit scan --owner alice"
$CLI scan --rpc $RPC --lens "$LENS" --auction "$AUCTION" --owner "$ALICE"

BEFORE=$(cast balance $ALICE --rpc-url $RPC)

hr "\$ cca-exit settle --bid 0"
$CLI settle --rpc $RPC --router "$ROUTER" --auction "$AUCTION" --bid 0 --key $ALICE_KEY

AFTER=$(cast balance $ALICE --rpc-url $RPC)
hr "Result"
echo "  recovered: $(cast from-wei "$(python3 -c "print($AFTER - $BEFORE)")") ETH (net of gas)"

hr "\$ cca-exit plan --bid 0   (after settling)"
$CLI plan --rpc $RPC --lens "$LENS" --auction "$AUCTION" --bid 0
echo

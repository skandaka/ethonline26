#!/usr/bin/env node
/**
 * cca-exit — inspect and settle Continuous Clearing Auction positions from the command line.
 *
 *   cca-exit plan  --lens 0x.. --auction 0x.. --bid 0
 *   cca-exit scan  --lens 0x.. --auction 0x.. --owner 0x..
 *   cca-exit settle --router 0x.. --auction 0x.. --bid 0 --key 0x..
 *
 * All commands take --rpc (default http://127.0.0.1:8545).
 */

import { createPublicClient, createWalletClient, http } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import {
  buildRouterExitCall,
  formatPlan,
  isSettleable,
  resolveExitPlan,
  resolveExitPlansForOwner,
  routeName,
} from '../src/index.js';

function parseArgs(argv) {
  const out = { _: [] };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a.startsWith('--')) out[a.slice(2)] = argv[++i];
    else out._.push(a);
  }
  return out;
}

function need(args, ...keys) {
  const missing = keys.filter((k) => !args[k]);
  if (missing.length) {
    console.error(`missing required option(s): ${missing.map((k) => `--${k}`).join(', ')}`);
    process.exit(1);
  }
}

const USAGE = `cca-exit — Uniswap CCA position tooling

  plan    --lens <addr> --auction <addr> --bid <id>
          Resolve one bid's settlement plan (one eth_call).

  scan    --lens <addr> --auction <addr> --owner <addr>
          Resolve every plan for a wallet across the auction (one eth_call).

  settle  --router <addr> --auction <addr> --bid <id>
          Resolve hints on chain and settle atomically.
          Signing key from CCA_EXIT_PRIVATE_KEY (preferred) or --key <privkey>.

  Common: --rpc <url>   (default http://127.0.0.1:8545)
`;

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const cmd = args._[0];
  const rpc = args.rpc ?? 'http://127.0.0.1:8545';
  const transport = http(rpc);
  const client = createPublicClient({ transport });

  if (cmd === 'plan') {
    need(args, 'lens', 'auction', 'bid');
    const plan = await resolveExitPlan(client, {
      lens: args.lens,
      auction: args.auction,
      bidId: BigInt(args.bid),
    });
    console.log(formatPlan(plan));
    console.log(`\nsettleable now: ${isSettleable(plan) ? 'yes' : 'no'}`);
    return;
  }

  if (cmd === 'scan') {
    need(args, 'lens', 'auction', 'owner');
    const plans = await resolveExitPlansForOwner(client, {
      lens: args.lens,
      auction: args.auction,
      owner: args.owner,
    });
    if (plans.length === 0) {
      console.log(`no bids for ${args.owner} in ${args.auction}`);
      return;
    }
    console.log(`${plans.length} position(s) for ${args.owner}:\n`);
    for (const plan of plans) console.log(formatPlan(plan), '\n');
    const ready = plans.filter(isSettleable);
    console.log(`${ready.length} of ${plans.length} settleable now.`);
    return;
  }

  if (cmd === 'settle') {
    need(args, 'router', 'auction', 'bid');

    // Prefer the environment variable: process arguments are visible to other users via `ps` and
    // land in shell history, so --key is kept only as a convenience for local test keys.
    const key = process.env.CCA_EXIT_PRIVATE_KEY ?? args.key;
    if (!key) {
      console.error('no signing key: set CCA_EXIT_PRIVATE_KEY, or pass --key for local test keys');
      process.exit(1);
    }
    if (!process.env.CCA_EXIT_PRIVATE_KEY) {
      console.warn('warning: --key is visible in `ps` and shell history; prefer CCA_EXIT_PRIVATE_KEY');
    }
    const account = privateKeyToAccount(key);
    const wallet = createWalletClient({ account, transport });
    const call = buildRouterExitCall({
      router: args.router,
      auction: args.auction,
      bidId: BigInt(args.bid),
    });

    // Simulate first so a non-settleable bid fails loudly instead of burning gas.
    const { result } = await client.simulateContract({ ...call, account });
    console.log(`simulated route: ${routeName(Number(result))}`);

    const hash = await wallet.writeContract(call);
    const receipt = await client.waitForTransactionReceipt({ hash });
    console.log(`settled in ${hash} (block ${receipt.blockNumber}, status ${receipt.status})`);
    return;
  }

  console.log(USAGE);
  process.exit(cmd ? 1 : 0);
}

main().catch((err) => {
  console.error(err.shortMessage ?? err.message ?? err);
  process.exit(1);
});

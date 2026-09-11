// Minimal ABIs for CCAExitLens and CCAExitRouter.

/** The `ExitPlan` tuple returned by the lens, in declaration order. */
const EXIT_PLAN = {
  type: 'tuple',
  components: [
    { name: 'bidId', type: 'uint256' },
    { name: 'owner', type: 'address' },
    { name: 'route', type: 'uint8' },
    { name: 'lastFullyFilledCheckpointBlock', type: 'uint64' },
    { name: 'outbidBlock', type: 'uint64' },
    { name: 'hintsResolved', type: 'bool' },
    {
      name: 'cursor',
      type: 'tuple',
      components: [
        { name: 'nextBlock', type: 'uint64' },
        { name: 'lastFullyFilledCheckpointBlock', type: 'uint64' },
      ],
    },
    { name: 'hops', type: 'uint32' },
    { name: 'bidMaxPrice', type: 'uint256' },
    { name: 'clearingPrice', type: 'uint256' },
    { name: 'graduated', type: 'bool' },
    { name: 'auctionOver', type: 'bool' },
  ],
};

export const lensAbi = [
  {
    type: 'function',
    name: 'resolveExitPlan',
    stateMutability: 'nonpayable',
    inputs: [
      { name: 'auction', type: 'address' },
      { name: 'bidId', type: 'uint256' },
    ],
    outputs: [{ ...EXIT_PLAN, name: 'plan' }],
  },
  {
    type: 'function',
    name: 'resolveExitPlansForOwner',
    stateMutability: 'nonpayable',
    inputs: [
      { name: 'auction', type: 'address' },
      { name: 'owner', type: 'address' },
      { name: 'fromBidId', type: 'uint256' },
      { name: 'toBidId', type: 'uint256' },
      { name: 'maxHopsPerBid', type: 'uint32' },
    ],
    outputs: [{ type: 'tuple[]', name: 'plans', components: EXIT_PLAN.components }],
  },
  {
    type: 'function',
    name: 'DEFAULT_MAX_HOPS',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ type: 'uint32' }],
  },
];

export const routerAbi = [
  {
    type: 'function',
    name: 'exit',
    stateMutability: 'nonpayable',
    inputs: [
      { name: 'auction', type: 'address' },
      { name: 'bidId', type: 'uint256' },
    ],
    outputs: [{ type: 'uint8' }],
  },
  {
    type: 'function',
    name: 'exitSkippingFailures',
    stateMutability: 'nonpayable',
    inputs: [
      { name: 'auction', type: 'address' },
      { name: 'bidIds', type: 'uint256[]' },
    ],
    outputs: [{ type: 'bool[]' }],
  },
];

export const auctionAbi = [
  {
    type: 'function',
    name: 'nextBidId',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ type: 'uint256' }],
  },
  {
    type: 'function',
    name: 'exitBid',
    stateMutability: 'nonpayable',
    inputs: [{ name: 'bidId', type: 'uint256' }],
    outputs: [],
  },
  {
    type: 'function',
    name: 'exitPartiallyFilledBid',
    stateMutability: 'nonpayable',
    inputs: [
      { name: 'bidId', type: 'uint256' },
      { name: 'lastFullyFilledCheckpointBlock', type: 'uint64' },
      { name: 'outbidBlock', type: 'uint64' },
    ],
    outputs: [],
  },
];

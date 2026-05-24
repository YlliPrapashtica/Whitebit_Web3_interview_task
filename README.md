# WorldCupBetting — Assessment Solution

Implementation of `contracts/contracts/WorldCupBetting.sol` for the on-chain betting assessment. The contract supports binary and multi-outcome markets backed by ETH or ERC20 collateral, an AMM share pricing curve, a secondary market for selling open positions, a 2% platform fee, and a reputation hook on every claim.

## What's in this repo

- `contracts/contracts/WorldCupBetting.sol` — the implementation.
- `contracts/test/WorldCupBetting.assessment.test.ts` — the provided assessment suite, untouched, nine scenarios A–I.
- `contracts/test/WorldCupBetting.extra.test.ts` — additional unit tests covering validation paths the assessment doesn't.
- `contracts/scripts/deploy-worldcup.ts` — Sepolia deployment + Etherscan verification.
- `contracts/deployments/sepolia.json` — recorded addresses and metadata from the live deployment.

## Setup

```bash
cd contracts
npm install --legacy-peer-deps
npx hardhat compile
```

## Tests

```bash
cd contracts
npx hardhat test
```

Expected: assessment scenarios A–I pass plus the extra suite.

## Sepolia deployment

| Contract | Address |
|----------|---------|
| WorldCupBetting | [`0xe5E3FcC69e9AB860Fb62eB31F24C63a9145f12a5`](https://sepolia.etherscan.io/address/0xe5E3FcC69e9AB860Fb62eB31F24C63a9145f12a5) |
| ReputationSystem | [`0x61353fB38857E8C3842Cf76de4e9CC63e7e96f70`](https://sepolia.etherscan.io/address/0x61353fB38857E8C3842Cf76de4e9CC63e7e96f70) |
| MockERC20 (mUSDC) | [`0xE2422d5281aF5c01f8954cAB2d661e73C713981A`](https://sepolia.etherscan.io/address/0xE2422d5281aF5c01f8954cAB2d661e73C713981A) |

Source verified on Etherscan for all three.

To redeploy, populate `contracts/.env` (see `contracts/.env.example`) and run:

```bash
cd contracts
npx hardhat run scripts/deploy-worldcup.ts --network sepolia
```

## Design notes

A few deliberate departures from the in-repo reference `PredictionMarket.sol`:

1. `SafeERC20` is used for all ERC20 transfers. Raw `IERC20.transfer/transferFrom` silently breaks with tokens (e.g., USDT) that don't return a bool.
2. `reputationSystem` is `immutable`. Pinned at construction; can't be repointed.
3. `createMarket` enforces an upper bound (`MAX_OUTCOMES = 10`). The reference only enforces `>= 2`, leaving the outcomes array unbounded — `getTotalPool` loops over it.
4. `createMarket` requires non-empty outcome labels.
5. `placeBet` rejects ETH sent alongside an ERC20 bet (`require(msg.value == 0)`), preventing accidental ETH being locked.

Fee is expressed as basis points (`PLATFORM_FEE_BPS = 200`, `BPS_DENOMINATOR = 10_000`) — standard DeFi convention.

## Scenario B walkthrough (the fee path)

- 1 ETH on YES, 1 ETH on NO → `totalPool = 2 ETH`.
- YES wins; fanFrance is the only YES bettor → `totalWinningShares == fanFrance.shares`.
- `gross = fanFrance.shares * 2 ETH / fanFrance.shares = 2 ETH`.
- `fee = 2 ETH * 200 / 10_000 = 0.04 ETH` accrues to `collectedFees[address(0)]`.
- `net = 1.96 ETH` transferred to fanFrance.
- Owner calls `withdrawFees(address(0))` → 0.04 ETH to owner.

## Scenario G walkthrough (the ownership transfer)

- fanBrazil places a 0.5 ETH bet → `bets[X].bettor = fanBrazil`.
- `listPosition(X, 0.55 ETH)` flips `positionsForSale[X]` and records the price.
- neutralFan calls `buyPosition(X, {value: 0.55 ETH})`:
  - 0.55 ETH is paid to fanBrazil.
  - `bets[X].bettor` flips to neutralFan.
  - `userBets[neutralFan]` gets `X` appended.
  - Listing is cleared.
- After resolution, only neutralFan passes the `msg.sender == bet.bettor` check in `claimWinnings(X)`. They receive the gross payout net of the 2% fee.

## Known trade-offs

- `userBets` on the seller side is not pruned when a position is sold. `getUserBets(seller)` will still list a sold `betId`. The source of truth for ownership is `bets[betId].bettor`, which is correctly updated. Pruning the seller's array requires O(n) iteration; left as documented behavior.

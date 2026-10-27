# Contract interface specification (v1 draft)

Interface source: [`contracts/src/interfaces/IDime.sol`](../contracts/src/interfaces/IDime.sol)
— implemented in `contracts/src/DimeProtocol.sol` with `lib/DimeMath.sol` (settlement arithmetic) and
`lib/DimeRights.sol` (rights ledger), both external libraries linked at deploy. Tests: `forge test`
(28 tests incl. two 256-run fuzz tests of the balance-conservation invariant).
Reference maths: [`src/domain/math.ts`](../src/domain/math.ts) and
[`src/domain/rights.ts`](../src/domain/rights.ts), with unit tests in `src/domain/domain.test.ts`.
The contract implementation should port these and pass equivalent tests.

The contract is authoritative for collateral, signatures, nonces, capacity, settlement
and withdrawals. Backend checks only improve UX.

## Modules

v1 may deploy as a single contract that exposes all of these interfaces. The frontend
uses one `NEXT_PUBLIC_VAULT_ADDRESS`. If the modules are split later, add an address
registry; only the adapter changes.

| Interface | Responsibility |
|---|---|
| `IDimeVault` | Customer USDC: deposit (with the per-wallet funding cap), withdraw, free/locked balances |
| `IDimePositions` | Open HOUSE / MATCHED positions from signed intents, close, liquidate, reserve protection, nonces |
| `IDimeHouse` | House reserve accounting, `houseStats()`, protocol state |
| `IPriceVerifier` | Verifies a `PriceProof` → (price, ts). **The adapter is undecided (blocker).** |
| `IDimeRights` | Non-transferable rights: issuance, epochs, funding, claims |
| `IDimeConfig` | Versioned parameters; intents are signed against `version` |

## Units and rounding

- Collateral: token base units. USDC is expected to have 6 decimals. The deploy script
  and the frontend both check `decimals()` against the canonical address for the
  selected network, and the frontend blocks trading on a mismatch.
- Price: 8-decimal fixed point. Bps: 1e4. Reward index: 1e18.
- **Amounts owed to a trader round toward −∞. Amounts owed by a trader, and fees, round
  up.** Dust (less than 1 base unit per operation) accrues to the house reserve. In
  matched pairs each leg is floored independently, so `loserLoss ≥ winnerGross`; the
  difference is dust that goes to the house.
- Rights per-index accrual floors. Index dust stays in the claims pool and never
  becomes house capital.

## Balances that must stay distinct

| Bucket | Owner | Can back house risk? |
|---|---|---|
| Free customer funds | trader | **No** |
| Position collateral (house or matched) | trader, locked | No |
| House reserve | house | Yes, up to `houseMaxUtilisationBps` |
| House reservations | earmarked house reserve | Already committed |
| Matched gap backstop | earmarked house reserve | Only for its pair |
| Funded distribution claims | rights holders | **No.** Moved out of the reserve at funding. |
| Unfunded liabilities | owed but uncovered | Should be 0. If > 0, state → INSOLVENT. |

Invariant: `token.balanceOf(this) == Σ free + Σ locked + reserve + fundedUnclaimed`
(± dust bounded by operation count). Test this after every state transition.

## Signed messages (EIP-712)

Domain: `{name, version, chainId, verifyingContract}`, exposed via EIP-5267 `eip712Domain()`.

```
OrderIntent(address user,bytes32 market,uint8 side,uint128 collateral,uint16 leverage,
            uint8 routeMask,uint64 matchDeadline,uint128 priceLimit,uint32 configVersion,
            uint64 expiry,uint256 nonce)
CloseRequest(address user,bytes32 positionId,uint64 expiry,uint256 nonce)
WithdrawRequest(address user,uint256 amount,uint64 expiry,uint256 nonce)
```

`WithdrawRequest` (`withdrawBySig`) is a gasless withdrawal: anyone may submit it, it may be signed by the wallet or a
live session key, and the contract pays `user` only, so a session key can move funds out of DIME but never away from
their owner. It works in every protocol state, like `withdraw`. Its use: converting wins (for example into Robinhood
Stock Tokens) without a wallet prompt. Withdrawals don't reduce the lifetime deposit cap (`depositedTotal`).

This binds chain, contract, user, market, side, size, leverage, permitted routes,
fee/config version, expiry and nonce. Nonces are **unordered 256-bit random values**,
consumed on use or via `cancelNonce`, so concurrent devices can't race. `priceLimit`
is the worst acceptable entry.

`routeMask`: bit0 means matched is allowed; bit1 means house is allowed. If both are set,
`openHouse` must revert unless `block.timestamp > matchDeadline` (fallback only after
the user's match window). The frontend caps the price tolerance at ¼ of the
liquidation distance. (No extra on-chain check is needed: the entry IS the verified price at open, and the
liquidation price is derived from it.)

## Flows

**House open (`openHouse`, relayer only):** verify signature, nonce, expiry and config
version; check `routeMask` and the deadline rule; `verify(price)` must be fresh with
entry within `priceLimit`; move collateral free → locked; admission check (below);
reserve `collateral × houseReservationMultiple` from the reserve; emit `PositionOpened`.

**Matched open (`openMatched`, relayer only):** both intents valid; opposite sides;
equal `collateral × leverage`; `longUser != shortUser`; both have bit0; one verified
price within both limits. Lock both collaterals atomically, reserve
`matchedGapBackstop` (v1: 0) from the house, and set the same `pairId`. Whole-ticket
only, with no partial fills. **Address inequality doesn't prevent one person trading
both sides from two wallets**, and the docs and UI say so.

**Close:** `close(req, sig, price)` via the relayer or `closeOwn(id, price)` directly.
For matched positions, either leg's close **settles both legs** at one price.

**Liquidation (`liquidate`, permissionless):** the adverse move reaches `10,000 / leverage − liqBufferBps` bp
(4 bp buffer: a 6 bp move at 1000×, 46 bp at 200×) at a verified price. The buffer is validated so
`liqBufferBps × maxLeverage < 10,000`. The Monad contract of 2026-10-13 still uses the older rule,
`equity ≤ maintenanceBps × collateral`, and a flat `profitFeeBps`. For house positions the loser forfeits full collateral to the reserve.
For matched pairs the loser forfeits full collateral; the winner receives it as gross
(the win cut is then taken) plus any gap from the backstop.

**Reserve protection (`protect`, keeper):** when house-position gross P&L reaches
`protectionTriggerBps × reservation`, extend the reservation by another
`collateral × multiple` if free capacity allows; otherwise close at the verified price
with reason `RESERVE_PROTECTION`. This is the disclosed early-close rule. There is no
fixed dollar ceiling, but finite reserves can't guarantee every payout.

### Settlement maths

```
rawGross   = floor(dir × notional × (exit − entry) / entry)
house:     gross = clamp(rawGross, −collateral, houseReservation)   (LIQUIDATION ⇒ −collateral)
k          = closed within shortHoldSeconds of opening ? shortHoldK : curveK   (stored per position at open; alpha: shortHoldSeconds 0, so always curveK)
m          = floor(|exit − entry| × 1e6 / entry)                     (move, hundredths of a bp)
cut        = gross > 0 ? min(gross, ceil(gross × k / (m + k))) : 0   (a win of m bp pays m × m / (m + k))
net        = gross − cut ;  returned = collateral + net
house P&L  = −net        (the cut is NOT added again: it's the part of the win not paid out)
matched:   loss = min(−loserRaw, loserCollateral)  (LIQUIDATION ⇒ loserCollateral)
           winnerGross = min(winnerRaw, loss) + min(max(0, winnerRaw − loss), backstop)
           house gets cut + (loss − base) − gapPaid
```

### Gap policy (OPEN DECISION, required before mainnet)

If the price gaps through liquidation, a matched winner's gross is capped at the
loser's collateral plus the reserved backstop. v1 sets the backstop to 0, so the
winner absorbs the gap. The UI discloses this ("your win is capped at their margin").
Options for the decision:
(a) keep 0 and disclose it (current);
(b) reserve a small per-pair backstop from the house at open, which counts against
    matched-exposure limits;
(c) a socialised insurance pool funded by matched fees.
Do not improvise this in the frontend.

## Markets

- A market is `keccak256(symbol)`, e.g. `keccak256("BTC-USD")`, `keccak256("NVDA-USD")`. Every `OrderIntent` names
  one and every `Position` stores it (`Position.market`, indexed in `PositionOpened`).
- New positions open only on enabled markets (`marketEnabled`). BTC-USD is enabled in the constructor; the admin
  enables others (`setMarketEnabled`). The guardian may disable a market but never enable one. Disabling stops
  opens; that market's open positions still close, liquidate and settle.
- Prices are verified for the position's own market: the verifier's signed message includes the market, so one
  market's price can't open or settle another. A matched pair must share a market. `windDownSettle` batches must
  hold one market.
- NVDA-USD is priced from Hyperliquid's `xyz:NVDA` perp (trade.xyz), which trades 24/7. Opening guards for weekend
  pricing, the reopen, thin books and fast moves are enforced off-chain (they gate new positions only).

## Admission and risk limits (separate, all enforced on-chain)

- House-backed exposure: `reservation ≤ reserve × utilisation − Σ reservations`. The reservation is
  `margin × houseReservationMultiple`, set at deploy and changeable by config.
- Directional concentration, per market: `|net house notional in that market| ≤ reserve × houseMaxNetNotionalMultiple`
  (`netDirectionalOf(market)`; risk-reducing trades are always admitted).
- Matched exposure and backstop: `maxConcurrentMatchedPairs`, and Σ backstops ≤ cap.
- Concurrent positions: `maxConcurrentHousePositions`, one active position per wallet.
- Request throughput and sponsored gas: enforced by the backend and relayer, not the
  contract. The contract still caps per-block opens to bound keeper load.
- Financial capacity scales with house equity automatically. Operational ceilings
  (position counts, rates) change only through a new config version after measurement.

## Protocol states

| State | New opens | Closes / liquidations | Withdrawals | Notes |
|---|---|---|---|---|
| OPEN | ✓ | ✓ | ✓ | |
| CLOSE_ONLY | ✗ | ✓ | ✓ | |
| ORACLE_HOLD | ✗ | held until a verified price | ✓ (free funds) | Auto-entered when the verifier fails freshness or agreement checks |
| WIND_DOWN | ✗ | keeper settles in **bounded batches** by position id cursor | ✓ | Deterministic and never iterates all wallets in one tx |
| INSOLVENT | ✗ | pro-rata by published shortfall rule | free funds ✓ | Entered when unfunded liabilities > 0 |

Pausing new trades does not settle existing liabilities.

## Rights (`IDimeRights`)

- Only **house** settlements call `recordHouseResult`. Matched rewards stay disabled
  (`matchedRewardsEnabled = false`) until a fee-funded policy has been specified and tested.
- Issuance comes from the increase in the user's cumulative net house loss above their
  high-water mark × `rightsPerLossUnitE6` (UNVALIDATED). Rights stay pending until
  epoch E+1.
- `fundAndAdvance()`: eligible = house cumulative earnings − earnings HWM (prior house
  losses are recovered first); target = eligible × `distributionShareBps` (UNVALIDATED,
  illustrative 20%); funded = min(target, reserve − reservations − floor). Fund
  **before** advancing, so newly activated rights don't share earlier earnings. The
  earnings HWM advances even when nothing is funded, so earnings are never queued.
- Non-transferable (no `transfer` or `approve`), no staking, no principal claim, no
  guaranteed yield.

## Events (Envio)

See `IDime.sol`. The schema sketch is in [`envio/schema.graphql`](../envio/schema.graphql).
Every event carries enough data to rebuild positions, house ledger totals and rights
balances without contract reads.

## Required tests before mainnet

Stale or conflicting price, cancel versus fill races, signature replay across chain,
contract, nonce and config version, simultaneous matches on one intent,
counterparty-triggered closure, liquidation of each leg, gaps beyond collateral
(each gap-policy option), reserve exhaustion during protection, epoch funding with a
floor, claims across many epochs, balance-conservation invariant fuzzing, and
WIND_DOWN batching gas bounds.


## Implementation notes (v1 as built)

- **Size:** `DimeProtocol` is ~27.5 KB, above Ethereum's 24 KB limit and within Monad's 128 KB limit
  (docs.monad.xyz, "differences"). Local tests use `anvil --code-size-limit 131072`.
- **Matched compatibility:** pairs need equal collateral **and** equal leverage (equal notional and equal
  liquidation distance), opposite sides, distinct addresses, both signing for matched, and both inside their
  match windows (`block.timestamp <= matchDeadline`).
- **House fallback:** `openHouse` with both route bits set requires `block.timestamp > matchDeadline`.
- **Claims** credit the free balance (withdrawable at any time) rather than transferring, so the claim path
  makes no external call.
- **Admin reserve withdrawal** (`withdrawExcessReserve`) is limited to capital above the open-risk utilisation
  ceiling and the distribution floor. It is disclosed, and forbidden in INSOLVENT.
- **Guardian** may move the protocol to CLOSE_ONLY, ORACLE_HOLD or WIND_DOWN. Only the admin may reopen or leave
  WIND_DOWN. INSOLVENT is set only by the contract.
- **Allow-list** (founder-only commissioning): when enabled, deposits and opens need `allowlisted[user]`.
  Withdrawals are always allowed.
- **Position id** = `keccak256(abi.encode(chainid, protocol, user, nonce))`, which the backend can derive.
- **Price timestamps** are in ms. They are rejected if older than `maxPriceAgeMs + 1000` (block timestamps have
  1 s granularity), more than 2 s in the future, or older than the position's open.
- **Operator verifier:** `OperatorPriceVerifier.isIndependentOracle()` returns `false`. It is for testnet and
  commissioning only.

## DIME token, emission and staking (v1.1)

- **`DimeToken`** (ERC-20 "DIME", 18 decimals) is minted only by the protocol: no pre-mint and no team or
  investor allocation. After `setProtocol` the minter role is **locked**: nobody, including the admin, can
  add or remove minters.
- **Transferability:** DIME is **non-transferable until a publicly scheduled date.** Until then it can only
  be staked, unstaked or held; it can't be sent to another wallet, sold or listed.
  - The admin may call `scheduleTransfers(at)` with at least **14 days' notice** (`MIN_NOTICE`, emitted on-chain).
  - The schedule can be cancelled only before `at`. Once open, it stays open permanently.
  - Schedule it only after legal review.
- **Issuance:** for each new net loss on a *house* trade above the user's high-water mark, issue
  `loss × emissionRate() × weight` DIME, minted into the protocol as the user's **pending stake**. It activates
  next epoch.
  - `weight = leverage / 1000 × phase boost × (liquidated ? liquidation boost : 1)`. `issuancePhase()` reads cumulative
    house-route trader losses (`collectedLosses`): below $10k 4× (liquidations 2× more), below $50k 2× (1.5×), below
    $200k 1.5× (1.25×), then 1×. After that the base rate is the weekly lever. `DimeIssued.rateE18` is the effective rate.
  - `emissionRate() = dimePerUsdE18` (deploy default 11 DIME per $1) while the house reserve is at or below
    `emissionDecayTvl` (default $1M). Above that it is `dimePerUsdE18 × (emissionDecayTvl / reserve)³`, rounded
    down at each step: 1/8 of the base at $2M, 1/125 at $5M, 1/1000 at $10M.
  - Hard cap: `maxMintPerEpoch` (the high-water mark still advances when the cap binds).
  - Matched trades never issue DIME.
- **Minimum stake:** a manual `stake` must leave the holder with at least `minStake` staked (default
  0.1 DIME, UNVALIDATED). DIME auto-issued on losses is always staked, even below the minimum.
- **Staking:** `stake(amount)` (after approve) adds pending stake that activates next epoch, so stake
  can't be added just before funding. `unstake(amount)` takes from pending first, then active, and
  returns DIME to the wallet. Accrued USDC stays claimable.
- **Rewards:** `fundAndAdvance()` funds active stake with up to `distributionShareBps` of new eligible
  house earnings, after loss recovery and the reserve floor, through the same reward index as before.
  `claim()` credits USDC to the free balance.
- **Farming bound** (design input, not enforced): with paired house trades across two wallets, $1 of
  "loss" costs about $0.25 (the profit fee), and that $0.25 is house earnings, of which stakers get only
  `distributionShareBps` back. So farmers can't recover their spend from their own flow; they profit only by
  taking a share of real traders' losses from real stakers. The lifetime deposit cap bounds each wallet to about
  cap ÷ fee of eligible loss ($40 at $10 and 25%), and the exposure cap ($5,000 per position) bounds daily churn per pair.
  Model it at `/lab` on the dev server (`src/app/lab/model.ts`).
- Events: `DimeIssued`, `Staked`, `Unstaked` (Envio-indexed).

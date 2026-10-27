# Backend API (v1 draft)

The live frontend adapter ([`src/adapters/live/index.ts`](../src/adapters/live/index.ts))
is written against this spec. Nothing here is implemented yet.

**Conventions:** amounts are decimal strings of token base units (`"100000"` = $0.10
USDC); prices are decimal strings with 8 decimals; times are ms since the epoch unless
marked as unix seconds. Auth is `Authorization: Bearer <Privy access token>`, verified
server-side against Privy's JWKS, and the wallet address is taken from the verified
token's linked wallets, never from the request body. Errors look like
`{ "error": { "code": "CAPACITY_UNAVAILABLE", "message": "…" } }`.

## Services (separate deployables)

| Service | Owns |
|---|---|
| **pricing** | One process per market. BTC-USD ingests ≥ 3 independent sources (timestamp + sequence id); NVDA-USD reads Hyperliquid's `xyz:NVDA` perp and adds opening guards (weekend reopen, thin book, fast move). Produces the model estimate and quality metrics, and compares them with the contract-verifiable reference. Rejects stale, conflicting or insufficient input. |
| **admission/matching** | Auth, rate limits, eligibility, quotes, intent intake (idempotent), whole-ticket matching, expiry, cancel, authorised house fallback. |
| **execution** | Restricted relayer (allow-listed selectors only: `openHouse`, `openMatched`, `close`, `liquidate`, `protect`, `fundAndAdvance`). Receipt tracking and retry with no duplicate positions (keyed by intent nonce). |
| **keepers + watchdog** | Liquidation, protection, epoch funding, WIND_DOWN batching. An independent watchdog alerts on lag, reserve breaches and verifier failures, and can trigger CLOSE_ONLY. |
| **stream** | WebSocket fan-out of prices, intent states, settlements and tx progress, reconciled against contract state. |
| **Envio** | Durable event history and aggregates (read layer only, **not** an oracle). |

## REST

### `POST /v1/quotes`
Request: `{ market: "BTC-USD" | "NVDA-USD", side, collateral, leverage, routes: {matched, houseFallback}, matchWindowMs, slippageBps }`

Response:
```json
{ "id": "q_…", "indicativeEntry": "10008012000000", "priceLimit": "…", "liquidationPrice": "…",
  "feeBps": 2500, "exampleMovePct": 0.05, "exampleNetProfit": "37500", "exampleFee": "12500",
  "capacity": { "houseAvailable": true, "houseReason": null, "houseReservationRequired": "2000000",
                "houseCapacityRemaining": "9750000", "housePositionsRemaining": 9,
                "matchedPairsRemaining": 24, "matchedOppositeWaiting": 1 },
  "configVersion": 1, "expiresAt": 1760000000000 }
```
Capacity is an **estimate**; the contract decides. Quotes are rejected with
`PRICE_UNAVAILABLE` when price quality is not `OK`.

### `POST /v1/intents`
Headers: `Idempotency-Key: <address>:<nonce>`.
Body: `{ quoteId, message: OrderIntent (decimal strings), signature }`.
Server checks: signature recovers `message.user` == the authenticated wallet;
`configVersion` is current; no other live intent or position for the wallet; rate
limits; free balance ≥ collateral (read from chain). Response: `IntentState`
(see `src/domain/types.ts`). A repeated idempotency key returns the original result.

### `POST /v1/intents/:id/cancel`
Allowed while `SIGNING`/`MATCHING`. If the intent is already `SUBMITTED`, it returns
`409 TOO_LATE`. Users can always invalidate on-chain with `cancelNonce(nonce)`.

### `POST /v1/close`
Body: `{ message: CloseRequest, signature }` with an idempotency key. Response: `{ txHash }`.

### `POST /v1/withdrawals`
Body: `{ message: WithdrawRequest {user, amount, expiry, nonce}, signature }` (wallet or session key) with an
idempotency key. The relayer submits `withdrawBySig` on the close lane; funds go to `user` only. No terms or invite
check. Response: `{ txHash, status }`.

### `GET /v1/markets`
`{ markets: [{ symbol, hash, base, name, priceSource, enabled }] }`.

### `GET /v1/markets/:symbol/history?limit=600`
`{ points: [{ t, price }] }`: indicative estimates for charting only.

### `GET /v1/metrics`
Server-side measurements with sample counts and p50/p95/p99 for each load profile:
quote latency, match wait, acceptance rate, submission→inclusion, inclusion→verified
state, Envio event→indexed, plus failure, expiry and stale-price rejection rates.

## Matching policy (v1)

- FIFO within compatible buckets: same market, opposite side, equal `collateral × leverage`.
- Notional size is **not** a priority. There's a bounded queue per bucket and a
  per-wallet limit of one live intent.
- No self-match: `user` addresses must differ. This doesn't prevent coordinated
  multi-wallet trading, and that limitation is disclosed.
- If the window ends unmatched, the intent goes to house admission when bit1 is set;
  otherwise it ends `EXPIRED`. Nothing is queued past `expiry`.
- Dedicated capacity is reserved for risk-reducing actions (close, liquidate, protect)
  and emergency processing, separate from the open queue.

## WebSocket `NEXT_PUBLIC_STREAM_URL`

Client → `{op:"auth", token}`, `{op:"subscribe", channel}`.
Server → `{channel, data}`.

| Channel | Data |
|---|---|
| `price:BTC-USD` | `PriceSnapshot`: estimate, reference {price, ts, verifier}, sources[{id,name,price,ts,seq}], ageMs, disagreementBps, referenceDeviationBps, quality |
| `intents:<address>` | `IntentState` on every transition, with timeline |
| `settlements:<address>` | `Settlement`, including counterparty-triggered and keeper closes |
| `tx:<address>` | `TxProgress` for relayed transactions |

The stream is indicative. The frontend reads balances, positions, house stats and
rights from the contract (`CONFIRMED`) and history from Envio (`INDEXED`), and labels
each source.

## Envio GraphQL (`NEXT_PUBLIC_ENVIO_GRAPHQL_URL`)

The frontend queries:
```graphql
Activity(where:{user:{_eq:$user}}, order_by:{timestamp:desc}, limit:100) { id kind title amount txHash blockNumber timestamp }
chain_metadata { chain_id latest_processed_block block_height }
```
Aggregates for the House (`HouseDaily`, `EpochFunding`) are in `envio/schema.graphql`.
Envio lag is shown as blocks and as the wall-clock gap between the head block and the
indexed block.

## As built (backend/, v1)

| Process | Port (bind) | Notes |
|---|---|---|
| `pricing` | 8710 (localhost) | 6 public feeds: Coinbase, Kraken, Bitstamp (USD) and Binance, OKX, Bybit (USDT, basis-adjusted). Median fair value with stale, conflict and insufficient flags. Signs the operator reference every 250 ms when quality is OK. `/health`, `/metrics`, `/snapshot`, `/proof/latest`, WS `/internal` |
| `api` | 8720 (localhost, behind nginx `/api`) | Routes below, plus the matcher, the relayer executor and the event watcher |
| `keeper` | 8730 (localhost) | Liquidate, protect, `fundAndAdvance` (on chain time), WIND_DOWN batches |
| `watchdog` | none | Health and gas probes. The guardian sets ORACLE_HOLD if the reference stays stale. Alerts go to structured logs and an optional webhook |

Differences from the draft above:
- `POST /v1/intents/:id/cancel` needs `{ signature }`, a `personal_sign` of `DIME cancel request <id>` by the
  requesting wallet. After `SUBMITTED` it returns `409 TOO_LATE`; use `cancelNonce` on-chain instead.
- `POST /v1/intents` also accepts `matchWindowMs` and `slippageBps` (for display) and requires `Idempotency-Key`.
  A replay returns the original response. A reused nonce under a new key returns `409`.
- `GET /v1/manifest` returns the deployment manifest (addresses, collateral identity, oracle kind, stage).
- `GET /v1/intents/:id` returns the current `IntentState`.
- `GET /health` reports price quality, proof age, chain-state age, indexed and head block, relayer queue depth
  and protocol state.
- `GET /v1/metrics` returns server-side p50/p95/p99 with sample counts:
  - quote, admission, match wait, admit→opened, relayer send→inclusion, close;
  - outcome counters;
  - the pricing service's internal and venue latencies.
- Auth: `AUTH_MODE=privy` verifies the Privy JWT against Privy's JWKS. `AUTH_MODE=none` is for local tests only
  and is refused in production. The wallet binding comes from the EIP-712 signature itself.
- Persistence: SQLite (WAL) holds intents, transactions, idempotency keys, the event cursor and the positions index.
  Contract state remains authoritative.
- Executor: a single signer runs one transaction at a time. Each tx is recorded before sending, simulated first,
  given a +30% gas margin, and confirmed by receipt. A timeout marks it `UNKNOWN` for reconciliation and never
  triggers a blind resubmission.

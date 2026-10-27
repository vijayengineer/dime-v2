# Build on DIME

DIME is a house-backed trading protocol for BTC and tokenised stocks (Nvidia first): long or short up to 1000×, zero trading fees, wins paid
the moment you close. Everything a trader can do in the app, code can do too. This page is for people building
bots, AI agents, terminals, dashboards and copy-trading tools.

| You want to… | Use |
|---|---|
| Write a bot or strategy in TypeScript | [SDK](#sdk) (`sdk/`) |
| Let Claude, Cursor or another AI agent read or trade | [MCP server](#mcp-server) (`mcp/`) |
| Build a terminal or dashboard in any language | [REST + WebSocket](#rest-and-websocket) |
| Trade without a wallet prompt per order | [Session keys](#session-keys) |
| See a complete bot | `backend/src/agents/example.ts` |

## How trading works

1. You **quote** a trade (`market`, `side`, `margin`, `leverage`; `market` is `BTC-USD` by default, `GET /v1/markets`
   lists what's enabled). The server picks the route: the house takes the other side
   straight away when it can back the trade; otherwise you're matched with another trader.
2. Your **wallet or session key signs an order** (EIP-712 `OrderIntent`). The signature is the authority: the API
   and the contract both check it.
3. The relayer submits it with the next signed price. The order fills only within your price limit.
4. To exit, sign a `CloseRequest`. Closes and liquidations skip the queue.

Rules that matter for code:

- **One open position per account.** Margin × leverage ≤ **$5,000** ($5 at 1000×, $50 at 100×). When the house is
  full, orders wait in its queue.
- **NVDA-USD** follows Hyperliquid's `xyz:NVDA` perp around the clock. New NVDA positions pause around the weekend
  reopen (15 min before to 30 min after) and when the book is thin or moving fast; quotes then return `409
  MARKET_PAUSED` with the reasons. Closes always work.
- **Wins:** a move of `m` bp in your favour pays `m × m / (m + 3)` bp. No fee to open, close or lose, and no charge
  for holding time (`shortHoldSeconds` is 0 in `activeConfig()`).
- **No stop-loss or take-profit orders.** Close positions from your own code (`dime.close`).
- **Liquidation** 4 bp before margin runs out. Anyone may liquidate; the protocol's keeper does it at once.
- **Units:** collateral (USDC on Monad, USDG on Robinhood Chain) has 6 decimals; prices have 8.
- **Escape hatch:** `closeOwn(positionId, priceProof)` lets the wallet close on-chain without the API.

## Access

| | How | What it can do |
|---|---|---|
| Public | nothing | prices, house state, any account's position and activity |
| **API key** | wallet signs one message → `x-api-key: dime_…` | call quote / order / close endpoints (rate limits per key) |
| **Wallet** | the account's own key | sign orders and closes, withdraw, stake, create keys |
| **Session key** | wallet signs once, gasless, ≤ 30 days | sign orders and closes **only**: never withdraw, stake or renew itself |

Before the first key, the wallet accepts the Terms of Use (`POST /v1/terms`). DIME is not available in the US, UK
or EU. During the invite-only waves, the wallet also needs an invite.

## Session keys

A session key is an ordinary private key that your app or bot holds. The wallet authorises it once with an EIP-712
signature:

```
SessionKey(address user, address key, uint64 expiry, uint256 nonce)
```

`POST /v1/session-keys` submits it on-chain for you (no gas). Or call `setSessionKey(key, expiry)` on the protocol
from the wallet. Up to **5 live keys per account** (each bot or paired browser has its own); setting a key
again renews it, `expiry = 0` revokes that key and `key = 0x0` revokes them all. `sessionKeysOf(user)` lists them.

Why it's safe to hand to a bot or a browser tab: the contract accepts it only for opens and closes of that one
account. Withdrawals, staking, cancelling nonces and changing keys all need the wallet itself. If a key leaks, the
worst it can do is trade inside the limits above until it expires or you revoke it.

## SDK

```ts
import { DimeClient } from "@rndm/dime-sdk";            // in this repo: sdk/src/index.ts
import { privateKeyToAccount } from "viem/accounts";

const dime = new DimeClient({ api: "https://api-dime.rndm.io" });
const wallet = privateKeyToAccount(WALLET_KEY);          // or wrap a browser wallet: { address, signTypedData, signMessage }

// one-time setup (three wallet signatures, no gas)
await dime.acceptTerms(wallet, termsText);               // termsText: the exact text from /terms
await dime.createApiKey(wallet, "my bot");               // stored on the client; save key.key
const session = await dime.createSessionKey(wallet, 7 * 86400);   // save session.privateKey

// trading: session key only
const order = await dime.open({ account: wallet.address, signer: session.account, side: "LONG", margin: 0.1, leverage: 1000 });
const result = await dime.waitForIntent(order.id);       // OPENED | REJECTED | EXPIRED | CAPACITY_UNAVAILABLE | CANCELLED
const { position } = await dime.positions(wallet.address);
await dime.close({ account: wallet.address, signer: session.account, positionId: position!.id });

// live data
const stop = dime.subscribe(["price:BTC-USD", `settlements:${wallet.address.toLowerCase()}`], (channel, data) => { /* … */ });
```

Also: `quote`, `price`, `history`, `house`, `activity`, `sessionKeysOf`, `cancel`, `revokeSessionKey` (one key, or all), and helpers
`usd`, `fromUsd`, `fromPrice`, `maxLeverageFor`. Errors throw `DimeError` with the HTTP status and code.

## MCP server

Gives any MCP client tools to read DIME and, optionally, trade:

| Tool | |
|---|---|
| `dime_price`, `dime_price_history` | BTC reference price |
| `dime_house` | protocol state, reserve, free capacity, open interest, live limits |
| `dime_quote` | entry, liquidation price and whether the house can take a trade |
| `dime_account`, `dime_activity` | balance, open position, DIME, history for any wallet |
| `dime_open`, `dime_close` | **only when a session key is configured** |

Claude Desktop / Claude Code config:

```json
{
  "mcpServers": {
    "dime": {
      "command": "npx",
      "args": ["tsx", "/path/to/dime/mcp/src/server.ts"],
      "env": {
        "DIME_API": "https://api-dime.rndm.io",
        "DIME_ACCOUNT": "0xYourWallet",
        "DIME_API_KEY": "dime_…",
        "DIME_SESSION_KEY_FILE": "/path/to/session.key",
        "DIME_MCP_MAX_MARGIN_USD": "1",
        "DIME_MCP_MAX_LEVERAGE": "1000"
      }
    }
  }
}
```

Leave out the last four to run read-only. The agent's own limits (`DIME_MCP_MAX_*`) apply on top of the protocol's.

## REST and WebSocket

Base URL `https://api-dime.rndm.io`. JSON; big numbers are decimal strings. Authenticated routes take
`x-api-key` (or a Privy `Authorization: Bearer`). Order and close posts need an `Idempotency-Key` header.

| Method | Path | Auth | |
|---|---|---|---|
| GET | `/health` | – | price freshness, chain lag, protocol state |
| GET | `/v1/manifest` | – | chain id, contract addresses, EIP-712 domain |
| GET | `/v1/house` | – | state, house stats, live config |
| GET | `/v1/markets` | – | markets and whether each is open |
| GET | `/v1/markets/:symbol/history?limit=600` | – | 1 s price points (`BTC-USD`, `NVDA-USD`) |
| GET | `/v1/positions/:address` | – | free balance, open position, DIME rights |
| GET | `/v1/activity/:address` | – | indexed on-chain history |
| POST | `/v1/quotes` | key | `{side, collateral, leverage}` → price limit, liquidation, capacity, auto route |
| POST | `/v1/intents` | key | `{message: OrderIntent, signature}` |
| GET | `/v1/intents/:id` | – | status and timeline |
| POST | `/v1/intents/:id/cancel` | key | wallet `personal_sign` of `DIME cancel request <id>` |
| POST | `/v1/close` | key | `{message: CloseRequest, signature}` |
| POST | `/v1/withdrawals` | key | `{message: WithdrawRequest, signature}`: gasless, paid to the account's own wallet only (SDK `dime.withdraw`) |
| POST | `/v1/stops` | key | **not enabled** (`AUTO_CLOSE_ENABLED=0`; returns 404) · auto-close: `{message: CloseRequest (expiry ≤ 30 days), signature, triggerPrice}` (8 decimals) |
| GET | `/v1/stops/:address` | – | auto-closes and their status (`ACTIVE`, `FIRING`, `DONE`, `CANCELLED`, `FAILED`) |
| POST | `/v1/stops/:id/cancel` | key | `personal_sign` of `DIME cancel auto-close <id>` by the wallet or its session key |
| POST | `/v1/session-keys` | key | `{user, key, expiry, nonce, signature}` (gasless) |
| GET | `/v1/session-keys/:address` | – | `{keys: [{key, expiresAt, active}], active}` |
| POST | `/v1/terms` | – | `{address, signature}` over the terms text |
| POST | `/v1/api-keys` | – | `{address, issuedAt, label, signature}` → key, shown once |
| GET | `/v1/api-keys/:address` | – | list (no secrets) |
| POST | `/v1/api-keys/:id/revoke` | – | wallet signature of `DIME revoke API key <id> for <address>` |

Rate limits per key: 120 quotes, 20 orders, 30 closes, 10 session-key changes a minute.

WebSocket `wss://api-dime.rndm.io/v1/stream`: send `{"op":"subscribe","channel":"…"}` for `price:BTC-USD` or `price:NVDA-USD`,
`intents:<address>`, `settlements:<address>`, `stops:<address>` (lowercase address, up to 8 channels per socket).

Auto-close (TP/SL) is built but **not offered**: the API runs with `AUTO_CLOSE_ENABLED=0` and the app hides it. If it is
ever enabled: an auto-close fires the first time the signed reference price crosses the trigger (below the current price at creation:
fires at or below; above: at or above). It then settles like any close at the next fresh price, so it is not a
guaranteed exit price, and liquidation wins if the price reaches the liquidation line first. SDK:
`dime.autoClose({ account, signer, positionId, triggerPrice })`, `dime.autoCloses(account)`, `dime.cancelAutoClose(id, signer)`.

EIP-712 domain: `{ name: "DIME", version: "1", chainId, verifyingContract: protocol }` from `/v1/manifest`.
Type strings are in `sdk/src/index.ts` and `contracts/src/DimeProtocol.sol`.

## Building a terminal

Everything a pro terminal needs is public: the price stream, positions, activity, house capacity and the quote
endpoint. A good terminal:

- creates a session key on connect, so trades are one tap with no wallet prompt, and shows its expiry;
- shows entry and liquidation lines (`/v1/positions`) on the chart (`/v1/markets/BTC-USD/history` or the stream);
- quotes before every order and shows `capacity.houseReason` when the house can't take it;
- never asks for the wallet's private key, and keeps the session key in memory or encrypted storage.

Multi-venue terminals are welcome to add DIME next to other venues: costs, payouts and the house reserve are all
public and checkable on-chain.

## Guardrails

- Trading at up to 1000× can lose the whole margin in seconds. Bots should cap their own size and losses.
- Never publish a key in a repo or a client bundle. Session keys expire; API keys can be revoked any time.
- Don't present DIME as an investment or promise a token value or return.

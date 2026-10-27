# DIME v2

DIME is a 1000× trading protocol for BTC and tokenised stocks (Nvidia first). Traders open small, isolated
positions against an on-chain house reserve. There's no fee to open, close or hold. A win of `m` bp pays
`m × m / (m + 3)` bp, so the contract keeps at most 3 bp of any win, and a liquidation loses the whole margin to the
house. Every settlement is enforced by the contract. Losses on the house route earn DIME, which is staked for a share
of house earnings.

- Live on Monad mainnet: [dime.rndm.io](https://dime.rndm.io)
- Robinhood Chain alpha (invite-only, BTC and NVDA): alpha-dime.rndm.io

This repository holds the contracts, the TypeScript SDK and the protocol docs. The web app and backend services
(pricing, matching, relayer, keeper) live in a private repository.

## Contents

| Path | What |
|---|---|
| `contracts/src/DimeProtocol.sol` | Vault, positions, house reserve, settlement, DIME issuance and staking, session keys, markets |
| `contracts/src/DimeToken.sol` | DIME: minted only by the protocol, non-transferable until transfers are scheduled with 14 days' notice |
| `contracts/src/oracle/OperatorPriceVerifier.sol` | Verifies operator-signed prices; each signature binds chain, verifier, market, price and time |
| `contracts/src/lib/` | Settlement maths (`DimeMath`) and DIME rights accounting (`DimeRights`) |
| `contracts/test/` | Foundry tests: settlement and conservation fuzzing, liquidation, reserve protection, signatures and replay, session keys, markets, issuance limits |
| `contracts/script/Deploy.s.sol` | Deployment (testnet, commissioning and alpha stages) |
| `sdk/` | `@rndm/dime-sdk`: quotes, orders, closes, gasless session keys, API keys, live streams |
| `docs/CONTRACTS.md` | Contract specification: units, signed messages, flows, settlement maths, limits, states |
| `docs/DEVELOPERS.md` | Building bots, agents and terminals on DIME |
| `docs/API.md` | Backend REST and WebSocket API |
| `docs/DEPLOYMENTS.md` | Deployed addresses and setup transactions |

## Design in brief

- **Markets.** A market is `keccak256(symbol)`, for example `BTC-USD` or `NVDA-USD`. The admin enables markets, and
  the guardian can only disable one. Prices are verified for each position's own market. NVDA-USD is priced from
  Hyperliquid's `xyz:NVDA` perp, which trades 24/7. New NVDA positions pause around the weekend reopen and when its
  book is thin or moving fast.
- **House capacity.** Each house position reserves `margin × houseReservationMultiple` of the reserve, within a
  utilisation ceiling and a per-market net-directional limit. When the house is full, orders wait in a queue rather
  than failing.
- **Gasless withdrawals.** `withdrawBySig` lets the wallet or a session key sign a withdrawal that anyone can submit.
  It pays the account's own wallet only. The app uses it to turn wins into Robinhood Stock Tokens without a prompt.
- **Limits on the operator.** DIME issuance can only be lowered after deployment. The stakers' share has a 5% floor.
  The reserve floor can't be raised. Excess-reserve withdrawals can't touch what stakers have accrued.
- **Price trust.** The price verifier is operator-signed, not an independent oracle: a signature proves who signed
  a price, not that it was fair. `isIndependentOracle()` returns false, and the app labels it. Signed prices and
  their inputs are published for audit.

## Build and test

```sh
git clone --recurse-submodules https://github.com/vijayengineer/dime-v2
cd dime-v2
forge build
forge test
```

The SDK:

```sh
cd sdk && npm install viem && npx tsc --noEmit
```

## Status

The alpha is invite-only and geoblocked: it isn't offered in the US, the UK or other restricted jurisdictions.
Leverage up to 1000× means a small move can lose the whole margin.

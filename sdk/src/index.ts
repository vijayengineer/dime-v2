/**
 * DIME SDK: trade the 1000× house (BTC, and Nvidia where enabled) from code. For bots, AI agents, terminals and dashboards.
 *
 *   const dime = new DimeClient({ api: "https://api-dime.rndm.io", apiKey: process.env.DIME_API_KEY });
 *   const session = await dime.createSessionKey(wallet);              // once: a trading-only key, no prompts after
 *   const order = await dime.open({ account: wallet.address, signer: session.account, side: "LONG", margin: 0.1, leverage: 1000 });
 *   await dime.waitForIntent(order.id);
 *   const { position } = await dime.positions(wallet.address);
 *   await dime.close({ account: wallet.address, signer: session.account, positionId: position!.id });
 *
 * Money: collateral (USDC/USDG) has 6 decimals; prices have 8. Helpers below convert.
 * Every order and close is signed by the account's wallet or its session key and checked on-chain. An API key
 * only identifies the caller for rate limits; it can never move funds.
 */
import { keccak256, toHex, type Address, type Hex } from "viem";
import { generatePrivateKey, privateKeyToAccount, type PrivateKeyAccount } from "viem/accounts";
import { dimeAbi } from "./abi";

export { dimeAbi };

/* ------------------------------------------------------------------ units */
export const COLLATERAL_DECIMALS = 6;
export const PRICE_DECIMALS = 8;
export const usd = (x: number) => BigInt(Math.round(x * 1e6));
export const fromUsd = (x: bigint | string) => Number(BigInt(x)) / 1e6;
export const fromPrice = (x: bigint | string) => Number(BigInt(x)) / 1e8;
/** margin × leverage may not exceed $100 at launch; this is the most leverage a margin allows. */
export const MAX_NOTIONAL = 5_000_000_000n;
export const maxLeverageFor = (margin: bigint, protocolMax = 1000) =>
  margin <= 0n ? protocolMax : Math.max(1, Math.min(protocolMax, Number(MAX_NOTIONAL / margin)));

/* ------------------------------------------------------------------ EIP-712 */
export type MarketSymbol = "BTC-USD" | "NVDA-USD";
/** On-chain market id: keccak256 of the symbol. A deployment trades the markets its admin has enabled (GET /v1/markets). */
export const marketId = (symbol: MarketSymbol) => keccak256(toHex(symbol));
export const BTC_MARKET = marketId("BTC-USD");
export const NVDA_MARKET = marketId("NVDA-USD");
export const ORDER_TYPES = {
  OrderIntent: [
    { name: "user", type: "address" }, { name: "market", type: "bytes32" }, { name: "side", type: "uint8" },
    { name: "collateral", type: "uint128" }, { name: "leverage", type: "uint16" }, { name: "routeMask", type: "uint8" },
    { name: "matchDeadline", type: "uint64" }, { name: "priceLimit", type: "uint128" }, { name: "configVersion", type: "uint32" },
    { name: "expiry", type: "uint64" }, { name: "nonce", type: "uint256" },
  ],
} as const;
export const WITHDRAW_TYPES = {
  WithdrawRequest: [
    { name: "user", type: "address" }, { name: "amount", type: "uint256" }, { name: "expiry", type: "uint64" }, { name: "nonce", type: "uint256" },
  ],
} as const;
export const CLOSE_TYPES = {
  CloseRequest: [{ name: "user", type: "address" }, { name: "positionId", type: "bytes32" }, { name: "expiry", type: "uint64" }, { name: "nonce", type: "uint256" }],
} as const;
export const SESSION_TYPES = {
  SessionKey: [{ name: "user", type: "address" }, { name: "key", type: "address" }, { name: "expiry", type: "uint64" }, { name: "nonce", type: "uint256" }],
} as const;

/** Anything that can sign: a viem LocalAccount, or a wrapper around a wallet client. */
export interface Signer {
  address: Address;
  signTypedData: (args: any) => Promise<Hex>;
  signMessage: (args: { message: string }) => Promise<Hex>;
}

export interface Manifest {
  chainId: number; protocol: Address; collateral: Address; collateralSymbol: string; eip712Name: string; eip712Version: string;
  stage: string; [k: string]: unknown;
}
export interface Quote {
  id: string; indicativeEntry: string; priceLimit: string; liquidationPrice: string; configVersion: number; expiresAt: number;
  capacity: { houseAvailable: boolean; houseReason?: string; houseWouldWait: boolean; houseQueueLength: number; [k: string]: unknown };
  auto: { routes: { matched: boolean; houseFallback: boolean }; matchWindowMs: number; slippageBps: number; summary: string };
}
export interface AutoClose {
  id: string; positionId: Hex; triggerPrice: string; direction: "BELOW" | "ABOVE";
  status: "ACTIVE" | "FIRING" | "DONE" | "CANCELLED" | "FAILED"; attempts: number; txHash?: Hex; reason?: string;
  expiresAt: number; createdAt: number; updatedAt: number;
}
export type IntentStatus = "MATCHING" | "QUEUED" | "SUBMITTED" | "OPENED" | "CAPACITY_UNAVAILABLE" | "EXPIRED" | "REJECTED" | "CANCELLED";
export const TERMINAL: IntentStatus[] = ["OPENED", "CAPACITY_UNAVAILABLE", "EXPIRED", "REJECTED", "CANCELLED"];
export interface Intent {
  id: string; status: IntentStatus; route?: "MATCHED" | "HOUSE"; reason?: string; positionId?: Hex; txHash?: Hex;
  matchDeadline: number; expiresAt: number; updatedAt: number; timeline: { status: string; at: number; note?: string }[];
}
export interface Position {
  id: Hex; user: Address; route: number; side: number; collateral: string; leverage: number; entryPrice: string;
  liquidationPrice: string; houseReservation: string; openedAtMs: string; [k: string]: unknown;
}
export interface Account { address: string; freeBalance: string; position: Position | null; dime: Record<string, string> }

export class DimeError extends Error {
  constructor(readonly status: number, readonly code: string, message: string, readonly body?: unknown) { super(message); }
}

export interface DimeClientOptions {
  /** e.g. https://api-dime.rndm.io */
  api: string;
  /** From createApiKey(). Not needed for public reads. */
  apiKey?: string;
  /** Privy session token, for browser apps that already sign users in. */
  bearer?: string;
  fetch?: typeof fetch;
}

const randomNonce = () => {
  const b = new Uint8Array(32);
  crypto.getRandomValues(b);
  return BigInt(toHex(b));
};
const json = (v: unknown) => JSON.stringify(v, (_, x) => (typeof x === "bigint" ? x.toString() : x));
const nowS = () => BigInt(Math.floor(Date.now() / 1000));

export class DimeClient {
  readonly api: string;
  private apiKey?: string;
  private bearer?: string;
  private f: typeof fetch;
  private manifestP?: Promise<Manifest>;

  constructor(o: DimeClientOptions) {
    this.api = o.api.replace(/\/$/, "");
    this.apiKey = o.apiKey;
    this.bearer = o.bearer;
    this.f = o.fetch ?? fetch;
  }

  setApiKey(k: string) { this.apiKey = k; }

  async request<T = any>(path: string, init: { method?: string; body?: unknown; headers?: Record<string, string> } = {}): Promise<T> {
    const headers: Record<string, string> = { ...init.headers };
    if (init.body !== undefined) headers["content-type"] = "application/json";
    if (this.apiKey) headers["x-api-key"] = this.apiKey;
    if (this.bearer) headers.authorization = `Bearer ${this.bearer}`;
    const r = await this.f(`${this.api}${path}`, { method: init.method ?? (init.body !== undefined ? "POST" : "GET"), headers, body: init.body !== undefined ? json(init.body) : undefined });
    const body = (await r.json().catch(() => ({}))) as any;
    if (!r.ok) throw new DimeError(r.status, body?.error?.code ?? "HTTP", body?.error?.message ?? `HTTP ${r.status}`, body);
    return body as T;
  }

  /* ---------------------------------------------------------------- public reads */
  manifest() { return (this.manifestP ??= this.request<Manifest>("/v1/manifest")); }
  health() { return this.request("/health"); }
  /** Protocol state, house reserve and capacity, live config. */
  house() { return this.request<{ state: string; house: Record<string, string>; config: Record<string, unknown>; allowlist: boolean; at: number }>("/v1/house"); }
  /** One point per second, newest last; price has 8 decimals. */
  history(limit = 600, market: MarketSymbol = "BTC-USD") { return this.request<{ points: { t: number; price: string }[] }>(`/v1/markets/${market}/history?limit=${limit}`).then((r) => r.points); }
  async price(market: MarketSymbol = "BTC-USD") { const [p] = (await this.history(1, market)).slice(-1); return p ? { t: p.t, price: fromPrice(p.price) } : null; }
  /** Markets this deployment knows, and whether each is open for new positions. */
  markets() { return this.request<{ markets: { symbol: MarketSymbol; hash: Hex; base: string; name: string; priceSource: string; enabled: boolean }[] }>("/v1/markets").then((r) => r.markets); }
  positions(address: string) { return this.request<Account>(`/v1/positions/${address}`); }
  activity(address: string) { return this.request(`/v1/activity/${address}`); }
  intent(id: string) { return this.request<Intent>(`/v1/intents/${id}`); }
  /** The account's session keys (up to 5: paired browsers, bots), each with its expiry. */
  sessionKeysOf(address: string) { return this.request<{ keys: { key: Address; expiresAt: number; active: boolean }[]; active: boolean }>(`/v1/session-keys/${address}`); }

  async waitForIntent(id: string, timeoutMs = 20_000, pollMs = 200): Promise<Intent> {
    const t0 = Date.now();
    for (;;) {
      const i = await this.intent(id);
      if (TERMINAL.includes(i.status) || Date.now() - t0 > timeoutMs) return i;
      await new Promise((r) => setTimeout(r, pollMs));
    }
  }

  /* ---------------------------------------------------------------- onboarding (wallet signatures) */
  async termsText(address: string) { return this.request<{ version: string; accepted: boolean }>(`/v1/terms/${address}`); }
  /** Signs the current terms with the wallet. `text` comes from the app's terms page (shared/terms.ts termsMessage). */
  acceptTerms(wallet: Signer, text: string) {
    return wallet.signMessage({ message: text }).then((signature) => this.request("/v1/terms", { body: { address: wallet.address, signature } }));
  }

  /** Creates an API key for this wallet (shown once) and uses it for this client. */
  async createApiKey(wallet: Signer, label = "") {
    const issuedAt = Date.now();
    const message = ["DIME API key", "", "Create an API key that can submit my signed DIME orders.", "", `Wallet: ${wallet.address.toLowerCase()}`, `Issued: ${issuedAt}`].join("\n");
    const signature = await wallet.signMessage({ message });
    const r = await this.request<{ id: string; key: string }>("/v1/api-keys", { body: { address: wallet.address, issuedAt, label, signature } });
    this.apiKey = r.key;
    return r;
  }

  /**
   * Creates a trading-only session key: it can open and close for `wallet`, never withdraw. An account can hold
   * up to 5 at once (one per bot or browser); creating more fails until one is revoked or expires.
   * One wallet signature, no gas (the relayer submits it). Keep the returned private key safe; it expires after `ttlSeconds` (max 30 days).
   */
  async createSessionKey(wallet: Signer, ttlSeconds = 7 * 86400, privateKey: Hex = generatePrivateKey()) {
    const account = privateKeyToAccount(privateKey);
    const expiry = nowS() + BigInt(ttlSeconds);
    const message = { user: wallet.address, key: account.address, expiry, nonce: randomNonce() };
    const signature = await wallet.signTypedData({ domain: await this.domain(), types: SESSION_TYPES, primaryType: "SessionKey", message });
    await this.request("/v1/session-keys", { body: { ...message, signature } });
    return { account, privateKey, address: account.address, expiresAt: Number(expiry) * 1000 };
  }

  /** Revokes one session key, or every key when `key` is omitted (a wallet signature; gasless). */
  async revokeSessionKey(wallet: Signer, key: Address = "0x0000000000000000000000000000000000000000") {
    const message = { user: wallet.address, key, expiry: 0n, nonce: randomNonce() };
    const signature = await wallet.signTypedData({ domain: await this.domain(), types: SESSION_TYPES, primaryType: "SessionKey", message });
    return this.request("/v1/session-keys", { body: { ...message, signature } });
  }

  /* ---------------------------------------------------------------- trading */
  async domain() {
    const m = await this.manifest();
    return { name: m.eip712Name, version: m.eip712Version, chainId: m.chainId, verifyingContract: m.protocol };
  }

  /** margin in dollars (e.g. 0.1) or base units (bigint). */
  quote(q: { side: "LONG" | "SHORT"; margin: number | bigint; leverage: number; market?: MarketSymbol }) {
    const collateral = typeof q.margin === "bigint" ? q.margin : usd(q.margin);
    return this.request<Quote>("/v1/quotes", { body: { market: q.market ?? "BTC-USD", side: q.side, collateral: collateral.toString(), leverage: q.leverage } });
  }

  /**
   * Quote, sign and submit an order. Routing, match window and price tolerance follow the server's auto policy
   * (the same as the app). `account` is the trading account; `signer` is its wallet or its session key.
   */
  async open(o: { account: Address; signer: Signer; side: "LONG" | "SHORT"; margin: number | bigint; leverage: number; market?: MarketSymbol; ttlSeconds?: number }) {
    const collateral = typeof o.margin === "bigint" ? o.margin : usd(o.margin);
    const market = o.market ?? "BTC-USD";
    const q = await this.quote({ side: o.side, margin: collateral, leverage: o.leverage, market });
    const routeMask = (q.auto.routes.matched ? 1 : 0) | (q.auto.routes.houseFallback ? 2 : 0);
    const now = nowS();
    const message = {
      user: o.account, market: marketId(market), side: o.side === "LONG" ? 0 : 1, collateral, leverage: o.leverage, routeMask,
      matchDeadline: now + BigInt(Math.ceil(q.auto.matchWindowMs / 1000)), priceLimit: BigInt(q.priceLimit),
      configVersion: q.configVersion, expiry: now + BigInt(o.ttlSeconds ?? 30), nonce: randomNonce(),
    };
    const signature = await o.signer.signTypedData({ domain: await this.domain(), types: ORDER_TYPES, primaryType: "OrderIntent", message });
    const intent = await this.request<Intent>("/v1/intents", {
      body: { quoteId: q.id, message, signature, matchWindowMs: q.auto.matchWindowMs, slippageBps: q.auto.slippageBps },
      headers: { "idempotency-key": `${o.account}:${message.nonce}` },
    });
    return { ...intent, quote: q, nonce: message.nonce };
  }

  /** Cancel a request that hasn't been submitted yet. Must be signed by the wallet (not a session key). */
  async cancel(id: string, wallet: Signer) {
    const signature = await wallet.signMessage({ message: `DIME cancel request ${id}` });
    return this.request<Intent>(`/v1/intents/${id}/cancel`, { body: { signature } });
  }

  async close(o: { account: Address; signer: Signer; positionId: Hex }) {
    const message = { user: o.account, positionId: o.positionId, expiry: nowS() + 30n, nonce: randomNonce() };
    const signature = await o.signer.signTypedData({ domain: await this.domain(), types: CLOSE_TYPES, primaryType: "CloseRequest", message });
    return this.request<{ txHash: Hex; status: string; block?: number }>("/v1/close", { body: { message, signature }, headers: { "idempotency-key": `close:${message.nonce}` } });
  }

  /**
   * Gasless withdrawal of free balance to the account's own wallet (the contract pays nowhere else). `signer` may be the
   * wallet or one of its session keys. `amount` in dollars or base units.
   */
  async withdraw(o: { account: Address; signer: Signer; amount: number | bigint; ttlSeconds?: number }) {
    const amount = typeof o.amount === "bigint" ? o.amount : usd(o.amount);
    const message = { user: o.account, amount, expiry: nowS() + BigInt(o.ttlSeconds ?? 60), nonce: randomNonce() };
    const signature = await o.signer.signTypedData({ domain: await this.domain(), types: WITHDRAW_TYPES, primaryType: "WithdrawRequest", message });
    return this.request<{ txHash: Hex; status: string; block?: number }>("/v1/withdrawals", { body: { message, signature }, headers: { "idempotency-key": `withdraw:${message.nonce}` } });
  }

  /**
   * Auto-close (stop-loss or take-profit). Not offered: the public API returns 404 NOT_ENABLED. Kept for an API that
   * enables it (AUTO_CLOSE_ENABLED=1). Signs a close now; the API submits it the first time the signed reference
   * price crosses `triggerPrice` (dollars, or 8-decimal bigint). It settles at the next price like any close, so it is
   * not a guaranteed exit price, and liquidation still wins if the price gets there first. Max 2 per position.
   * `validForS` defaults to 7 days (max 30). A session key can sign it.
   */
  async autoClose(o: { account: Address; signer: Signer; positionId: Hex; triggerPrice: number | bigint; validForS?: number }) {
    const message = { user: o.account, positionId: o.positionId, expiry: nowS() + BigInt(o.validForS ?? 7 * 86_400), nonce: randomNonce() };
    const signature = await o.signer.signTypedData({ domain: await this.domain(), types: CLOSE_TYPES, primaryType: "CloseRequest", message });
    const triggerPrice = typeof o.triggerPrice === "bigint" ? o.triggerPrice : BigInt(Math.round(o.triggerPrice * 1e8));
    return this.request<AutoClose>("/v1/stops", { body: { message, signature, triggerPrice: triggerPrice.toString() } });
  }

  autoCloses(account: Address) { return this.request<AutoClose[]>(`/v1/stops/${account}`); }

  /** Cancels an auto-close. Signed by the wallet or its session key. */
  async cancelAutoClose(id: string, signer: Signer) {
    const signature = await signer.signMessage({ message: `DIME cancel auto-close ${id}` });
    return this.request<AutoClose>(`/v1/stops/${id}/cancel`, { body: { signature } });
  }

  /* ---------------------------------------------------------------- streaming */
  /**
   * Live updates over WebSocket: "price:BTC-USD" (or "price:NVDA-USD"), "intents:<address>", "settlements:<address>", "stops:<address>" (max 8 channels per socket).
   * Uses the global WebSocket (browsers, Node 22+). Returns an unsubscribe function.
   */
  subscribe(channels: string[], onMessage: (channel: string, data: any) => void, onError?: (e: unknown) => void): () => void {
    const url = this.api.replace(/^http/, "ws") + "/v1/stream";
    let ws: WebSocket | null = null;
    let closed = false;
    const connect = () => {
      ws = new WebSocket(url);
      ws.onopen = () => channels.forEach((channel) => ws!.send(JSON.stringify({ op: "subscribe", channel })));
      ws.onmessage = (ev) => {
        try { const m = JSON.parse(String(ev.data)); onMessage(m.channel, m.data); } catch (e) { onError?.(e); }
      };
      ws.onerror = (e) => onError?.(e);
      ws.onclose = () => { if (!closed) setTimeout(connect, 1000); };
    };
    connect();
    return () => { closed = true; ws?.close(); };
  }
}

/** Session keys are plain private keys: load one saved earlier. */
export const sessionAccount = (privateKey: Hex): PrivateKeyAccount => privateKeyToAccount(privateKey);

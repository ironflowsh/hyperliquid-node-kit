// InfoClient talks to the node's local info server (--serve-info).
// It only sends request types the local server answers. Requests the local
// server rejects with 422 (allMids, l2Book, userFills, portfolio,
// metaAndAssetCtxs) are left out on purpose: use the public API for those.

export const DEFAULT_INFO_URL = "http://localhost:3001/info";
const REQUEST_TIMEOUT_MS = 5_000;
const ADDRESS_RE = /^0x[0-9a-fA-F]{40}$/;
const DEX_RE = /^[a-z0-9]{1,16}$/;

export type FetchFn = typeof fetch;

export class InfoError extends Error {}

/** Throws unless `user` is a 0x-prefixed 20-byte hex address. */
export function assertAddress(user: string): string {
  if (!ADDRESS_RE.test(user)) {
    throw new InfoError(`not an address: ${JSON.stringify(user)} (expected 0x followed by 40 hex characters)`);
  }
  return user.toLowerCase();
}

/** Throws unless `dex` looks like a builder dex name (lowercase letters and digits). */
export function assertDex(dex: string): string {
  if (!DEX_RE.test(dex)) {
    throw new InfoError(`not a dex name: ${JSON.stringify(dex)}`);
  }
  return dex;
}

export class InfoClient {
  constructor(
    private readonly url: string = DEFAULT_INFO_URL,
    private readonly fetchFn: FetchFn = fetch,
  ) {}

  /** POSTs one info request and returns the parsed JSON body. */
  async post(body: Record<string, unknown>): Promise<unknown> {
    let res: Response;
    try {
      res = await this.fetchFn(this.url, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body),
        signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
      });
    } catch (err) {
      const reason = err instanceof Error ? err.message : String(err);
      throw new InfoError(`local info server at ${this.url} did not answer (${reason}). Is the node running with --serve-info?`);
    }
    const text = await res.text();
    if (!res.ok) {
      throw new InfoError(`local info server answered ${res.status} for ${String(body.type)}: ${text.slice(0, 200)}`);
    }
    try {
      return JSON.parse(text);
    } catch {
      throw new InfoError(`local info server returned non-JSON for ${String(body.type)}`);
    }
  }

  /** L1 time of the node's local state and how far it trails wall clock. */
  async health(nowMs: number = Date.now()): Promise<{ l1_time: string; lag_seconds: number }> {
    const body = (await this.post({ type: "exchangeStatus" })) as { time?: unknown };
    if (typeof body?.time !== "number") {
      throw new InfoError("exchangeStatus response has no numeric time field");
    }
    return {
      l1_time: new Date(body.time).toISOString(),
      lag_seconds: Math.max(0, Math.round((nowMs - body.time) / 1000)),
    };
  }
}

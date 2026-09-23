import { describe, expect, it, vi } from "vitest";
import { InfoClient, InfoError, assertAddress } from "../src/client.js";
import { runTool, tools } from "../src/tools.js";

const ADDR = "0x1234567890abcdef1234567890ABCDEF12345678";

function mockFetch(status: number, body: unknown) {
  return vi.fn(async (_url: string | URL | Request, _init?: RequestInit) =>
    new Response(typeof body === "string" ? body : JSON.stringify(body), { status }),
  );
}

describe("assertAddress", () => {
  it("accepts a 40-hex address and lowercases it", () => {
    expect(assertAddress(ADDR)).toBe(ADDR.toLowerCase());
  });
  it("rejects anything else", () => {
    expect(() => assertAddress("0x123")).toThrow(InfoError);
    expect(() => assertAddress("1234567890abcdef1234567890abcdef12345678")).toThrow(InfoError);
  });
});

describe("tool requests", () => {
  it("builds clearinghouseState with and without dex", () => {
    expect(tools.get_clearinghouse_state.request({ user: ADDR })).toEqual({
      type: "clearinghouseState",
      user: ADDR.toLowerCase(),
    });
    expect(tools.get_clearinghouse_state.request({ user: ADDR, dex: "xyz" })).toEqual({
      type: "clearinghouseState",
      user: ADDR.toLowerCase(),
      dex: "xyz",
    });
  });
  it("rejects a malformed dex", () => {
    expect(() => tools.get_meta.request({ dex: "../x" })).toThrow(InfoError);
  });
  it("only uses request types the local info server answers", () => {
    const types = [
      tools.get_clearinghouse_state.request({ user: ADDR }).type,
      tools.get_spot_state.request({ user: ADDR }).type,
      tools.get_open_orders.request({ user: ADDR }).type,
      tools.get_frontend_open_orders.request({ user: ADDR }).type,
      tools.get_meta.request({}).type,
      tools.get_user_abstraction.request({ user: ADDR }).type,
    ];
    expect(types).toEqual([
      "clearinghouseState",
      "spotClearinghouseState",
      "openOrders",
      "frontendOpenOrders",
      "meta",
      "userAbstraction",
    ]);
  });
});

describe("InfoClient", () => {
  it("posts JSON to the configured URL and parses the answer", async () => {
    const f = mockFetch(200, { marginSummary: { accountValue: "12.5" } });
    const client = new InfoClient("http://node:3001/info", f as unknown as typeof fetch);
    const out = await runTool(client, "get_clearinghouse_state", { user: ADDR });
    expect(out).toEqual({ marginSummary: { accountValue: "12.5" } });
    const [url, init] = f.mock.calls[0];
    expect(url).toBe("http://node:3001/info");
    expect(JSON.parse(String(init?.body))).toEqual({ type: "clearinghouseState", user: ADDR.toLowerCase() });
  });

  it("turns a 422 into a readable error", async () => {
    const client = new InfoClient("http://node:3001/info", mockFetch(422, "Failed to deserialize") as unknown as typeof fetch);
    await expect(client.post({ type: "meta" })).rejects.toThrow(/answered 422 for meta/);
  });

  it("explains a connection failure", async () => {
    const f = vi.fn(async () => {
      throw new TypeError("fetch failed");
    });
    const client = new InfoClient("http://node:3001/info", f as unknown as typeof fetch);
    await expect(client.post({ type: "meta" })).rejects.toThrow(/--serve-info/);
  });

  it("computes lag from exchangeStatus", async () => {
    const now = 1_790_157_752_170;
    const client = new InfoClient("http://node:3001/info", mockFetch(200, { specialStatuses: null, time: now - 8_000 }) as unknown as typeof fetch);
    const h = await client.health(now);
    expect(h.lag_seconds).toBe(8);
    expect(h.l1_time).toBe(new Date(now - 8_000).toISOString());
  });
});

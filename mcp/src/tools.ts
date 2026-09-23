// Tool definitions: one entry per read-only request type the local info
// server answers. Kept as data so the tests can check every request body
// without starting an MCP transport.

import { z } from "zod";
import { assertAddress, assertDex, type InfoClient } from "./client.js";

const user = z.string().describe("Wallet address, 0x followed by 40 hex characters");
const dex = z
  .string()
  .optional()
  .describe("Builder dex name for HIP-3 markets, for example xyz. Omit for the main perp dex.");

/** Adds `dex` to a request body when it was given. */
function withDex(body: Record<string, unknown>, d?: string): Record<string, unknown> {
  return d ? { ...body, dex: assertDex(d) } : body;
}

export const tools = {
  get_clearinghouse_state: {
    description: "Perp account state for a wallet: margin summary, positions, withdrawable balance.",
    inputSchema: { user, dex },
    request: (a: { user: string; dex?: string }) =>
      withDex({ type: "clearinghouseState", user: assertAddress(a.user) }, a.dex),
  },
  get_spot_state: {
    description: "Spot balances for a wallet.",
    inputSchema: { user },
    request: (a: { user: string }) => ({ type: "spotClearinghouseState", user: assertAddress(a.user) }),
  },
  get_open_orders: {
    description: "Resting orders for a wallet.",
    inputSchema: { user, dex },
    request: (a: { user: string; dex?: string }) =>
      withDex({ type: "openOrders", user: assertAddress(a.user) }, a.dex),
  },
  get_frontend_open_orders: {
    description: "Resting orders for a wallet with trigger and TP/SL details.",
    inputSchema: { user, dex },
    request: (a: { user: string; dex?: string }) =>
      withDex({ type: "frontendOpenOrders", user: assertAddress(a.user) }, a.dex),
  },
  get_meta: {
    description: "Perp market metadata: asset names, size decimals, max leverage.",
    inputSchema: { dex },
    request: (a: { dex?: string }) => withDex({ type: "meta" }, a.dex),
  },
  get_user_abstraction: {
    description: "Account mode of a wallet (for example unifiedAccount, portfolioMargin or default).",
    inputSchema: { user },
    request: (a: { user: string }) => ({ type: "userAbstraction", user: assertAddress(a.user) }),
  },
} as const;

export type ToolName = keyof typeof tools;

/** Runs one tool against the client and returns the JSON body. */
export async function runTool(client: InfoClient, name: ToolName, args: Record<string, unknown>): Promise<unknown> {
  const def = tools[name];
  // Each request builder validates its own arguments.
  const body = (def.request as (a: Record<string, unknown>) => Record<string, unknown>)(args);
  return client.post(body);
}

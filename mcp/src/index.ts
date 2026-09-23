#!/usr/bin/env node
// hlnode-mcp: a read-only MCP server for the local info server of a
// Hyperliquid node. It never signs or sends orders.
//
// Env:
//   HL_INFO_URL            local info server (default http://localhost:3001/info)
//   HL_MAX_LAG_SECONDS     node_health reports stale above this (default 60)

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { DEFAULT_INFO_URL, InfoClient } from "./client.js";
import { runTool, tools, type ToolName } from "./tools.js";

const DEFAULT_MAX_LAG_SECONDS = 60;

const client = new InfoClient(process.env.HL_INFO_URL || DEFAULT_INFO_URL);
const maxLag = Number(process.env.HL_MAX_LAG_SECONDS) || DEFAULT_MAX_LAG_SECONDS;
const server = new McpServer({ name: "hlnode-mcp", version: "0.1.0" });

function asText(value: unknown) {
  return { content: [{ type: "text" as const, text: JSON.stringify(value, null, 2) }] };
}

function asError(err: unknown) {
  return {
    isError: true,
    content: [{ type: "text" as const, text: err instanceof Error ? err.message : String(err) }],
  };
}

for (const name of Object.keys(tools) as ToolName[]) {
  const def = tools[name];
  server.registerTool(
    name,
    {
      description: `${def.description} Read from your own node, no public rate limit. Check node_health first if freshness matters.`,
      inputSchema: def.inputSchema,
      annotations: { readOnlyHint: true, openWorldHint: false },
    },
    async (args: Record<string, unknown>) => {
      try {
        return asText(await runTool(client, name, args));
      } catch (err) {
        return asError(err);
      }
    },
  );
}

server.registerTool(
  "node_health",
  {
    description:
      "How far the node's local state trails the chain. stale=true means answers from the other tools are old.",
    annotations: { readOnlyHint: true, openWorldHint: false },
  },
  async () => {
    try {
      const h = await client.health();
      return asText({ ...h, stale: h.lag_seconds > maxLag, max_lag_seconds: maxLag });
    } catch (err) {
      return asError(err);
    }
  },
);

await server.connect(new StdioServerTransport());

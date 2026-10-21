// A minimal MCP stdio server: newline-delimited JSON-RPC 2.0, protocol 2024-11-05.
//
// Deliberately dependency-free. These servers sit *inside* the security boundary
// `MCPApprovalProxy` defends — whatever they expose, the proxy can only filter by
// name. That makes "can a person read this file and know everything it can do"
// a security property, and a node_modules tree is not something anyone audits at
// a glance. The whole protocol surface needed here is four methods.
//
// Framing matches what `MCPApprovalProxy.Downstream` speaks: one JSON object per
// line on stdout, requests read the same way from stdin.
//
// **Nothing may ever be written to stdout except a protocol message.** A stray
// console.log corrupts the stream and presents as the server failing to start with
// no reason given — the same hazard `qwen_tts_server.py` dodges by moving fd 1 out
// of the way. Use `log()` below, which goes to stderr and lands in the app log.

import { createInterface } from "node:readline";

export function log(...parts) {
  process.stderr.write(parts.join(" ") + "\n");
}

const PROTOCOL_VERSION = "2024-11-05";

/// Wrap a plain string as MCP text content.
export function text(value) {
  return { content: [{ type: "text", text: String(value) }] };
}

/// Wrap raw bytes as MCP image content.
///
/// The spec is explicit that screenshots reach the model as image content and never
/// as a readable file path: a path is a second capability — anything that can read
/// it can read its siblings — handed over without passing the tool gate.
export function image(buffer, mimeType) {
  return { content: [{ type: "image", data: buffer.toString("base64"), mimeType }] };
}

/// A tool failure the model should see and can act on, rather than a dead connection.
export function failure(message) {
  return { content: [{ type: "text", text: String(message) }], isError: true };
}

export function serve({ name, version, tools }) {
  const byName = new Map(tools.map((tool) => [tool.name, tool]));

  const send = (message) => {
    process.stdout.write(JSON.stringify(message) + "\n");
  };

  const reply = (id, result) => send({ jsonrpc: "2.0", id, result });
  const fail = (id, code, message) =>
    send({ jsonrpc: "2.0", id, error: { code, message } });

  const handle = async (message) => {
    const { id, method, params } = message;
    // A notification carries no id and must never be answered — a reply to one is a
    // response the peer has no request for, and it desynchronises the stream.
    const isNotification = id === undefined || id === null;

    switch (method) {
      case "initialize":
        return reply(id, {
          protocolVersion: PROTOCOL_VERSION,
          capabilities: { tools: {} },
          serverInfo: { name, version },
        });

      case "notifications/initialized":
        return;

      case "ping":
        return isNotification ? undefined : reply(id, {});

      case "tools/list":
        return reply(id, {
          tools: tools.map(({ name, description, inputSchema }) => ({
            name,
            description,
            inputSchema,
          })),
        });

      case "tools/call": {
        const tool = byName.get(params?.name);
        // Unknown names are refused here as well as at the proxy. The proxy is the
        // boundary; this is the reminder that a server which only *happens* to be
        // behind one is not a design.
        if (!tool) return fail(id, -32602, `Unknown tool: ${params?.name}`);
        try {
          return reply(id, await tool.handler(params?.arguments ?? {}));
        } catch (error) {
          // Returned as a tool result, not a JSON-RPC error: a failed action is
          // something the model should read and reconsider, not a transport fault
          // that tears down the session and loses the conversation.
          return reply(id, failure(error?.message ?? String(error)));
        }
      }

      default:
        if (isNotification) return;
        return fail(id, -32601, `Unknown method: ${method}`);
    }
  };

  createInterface({ input: process.stdin }).on("line", async (line) => {
    const trimmed = line.trim();
    if (!trimmed) return;
    let message;
    try {
      message = JSON.parse(trimmed);
    } catch {
      // Unparseable input is dropped rather than answered: with no id there is
      // nothing to answer, and guessing one would invent a reply the peer never
      // asked for.
      return log(`[${name}] dropped unparseable line`);
    }
    try {
      await handle(message);
    } catch (error) {
      log(`[${name}] handler threw: ${error?.stack ?? error}`);
      if (message?.id !== undefined && message?.id !== null) {
        fail(message.id, -32603, "Internal error");
      }
    }
  });

  log(`[${name}] ready`);
}

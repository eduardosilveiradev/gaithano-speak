#!/usr/bin/env node
// SmartThings control for Agent Mode, wrapping the official `smartthings` CLI.
//
// There is no such package as `smartthings-mcp`; this adapter is the thing
// `MCPServerConfig` was always pointing at.
//
// **The CLI is never addressable from the model's side.** No tool here takes a
// command string. `send_device_command` takes a device, a capability, a command and
// a list of arguments as separate fields, and *this file* composes the
// `capability:command(args)` string the CLI expects. That is what makes the
// SmartThings surface "every device command the account has" without it also being
// a way to run `smartthings apps:delete` — or anything else the CLI can do.
//
// It is also what makes the approval gate work. `ActionRiskPolicy` classifies a
// SmartThings action by its *capability* — `lock` is `.security` however the user
// named the device — and it can only do that because the capability arrives as its
// own field. A single opaque string would have to be parsed by the gate, and a gate
// that parses is a gate that can be fooled by spacing.
//
// As everywhere in this feature: `execFile` with an argument array, never a shell.

import { execFile } from "node:child_process";
import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { serve, text, failure, log } from "./lib/mcp.js";

// MARK: - Finding the CLI
//
// The app passes `GAITHANO_SMARTTHINGS_CLI`; the search is the fallback for running
// this server by hand. Same bargain as `ClaudeCLIFormatter.resolveExecutable` — a
// GUI app's PATH does not have any of this.
const CANDIDATES = [
  process.env.GAITHANO_SMARTTHINGS_CLI,
  `${homedir()}/.npm-global/bin/smartthings`,
  `${homedir()}/.local/bin/smartthings`,
  `${homedir()}/.bun/bin/smartthings`,
  "/opt/homebrew/bin/smartthings",
  "/usr/local/bin/smartthings",
].filter(Boolean);

const CLI = CANDIDATES.find((path) => existsSync(path));

/// Run the CLI. Long timeout because these are network round trips to Samsung's
/// cloud, not local reads.
function cli(args, timeout = 30000) {
  return new Promise((resolve, reject) => {
    if (!CLI) {
      return reject(new Error(
        "The SmartThings CLI isn't installed. Install it with " +
        "`npm install -g @smartthings/cli`, then sign in with `smartthings login`."));
    }
    execFile(CLI, args, { timeout, encoding: "utf8", maxBuffer: 16 * 1024 * 1024 },
      (error, stdout, stderr) => {
        const output = `${stdout ?? ""}${stderr ?? ""}`;
        if (error) {
          // A CLI that wants credentials will try to open a browser. The spec is
          // explicit that reauthentication is a setup action the user takes in the
          // app, never something a tool call sets off, so this is reported as an
          // error to act on rather than retried.
          if (/token|login|unauthor|authenticat/i.test(output)) {
            return reject(new Error(
              "SmartThings isn't signed in. Run `smartthings login` in Terminal, then try again."));
          }
          return reject(new Error(output.trim() || "the SmartThings CLI failed"));
        }
        resolve(stdout.trim());
      });
  });
}

/// Ask for JSON and hand back what came out.
///
/// Returned as text rather than parsed and reformatted: the model reads this, and
/// the CLI's own field names are the ones the SmartThings docs use.
async function json(args, timeout) {
  const output = await cli([...args, "--json"], timeout);
  return text(output || "[]");
}

// MARK: - Validation
//
// Capability and command names go into a string this file composes, so they are
// checked against the shape SmartThings actually uses. Nothing here reaches a
// shell, so this is not escaping — it is refusing to build a command that means
// something other than what the gate was shown.
const IDENTIFIER = /^[A-Za-z][A-Za-z0-9]*$/;
const UUID = /^[0-9a-fA-F-]{8,64}$/;

function requireIdentifier(value, field) {
  if (typeof value !== "string" || !IDENTIFIER.test(value)) {
    throw new Error(`\`${field}\` must be a capability-style name, letters and digits only.`);
  }
  return value;
}

function requireID(value, field) {
  if (typeof value !== "string" || !UUID.test(value)) {
    throw new Error(`\`${field}\` must be a SmartThings id.`);
  }
  return value;
}

/// Render one command argument the way the CLI's mini-language expects.
function renderArgument(value) {
  if (typeof value === "number" && Number.isFinite(value)) return String(value);
  if (typeof value === "boolean") return String(value);
  if (typeof value === "string") {
    if (!/^[A-Za-z0-9 _.:%+-]{0,64}$/.test(value)) {
      throw new Error(`Unsupported argument "${value}".`);
    }
    return /^[0-9.]+$/.test(value) ? value : JSON.stringify(value);
  }
  throw new Error("Command arguments must be strings, numbers, or booleans.");
}

// MARK: - Tools

const tools = [
  {
    name: "list_locations",
    description: "List the SmartThings locations on the account, e.g. \"Home\".",
    inputSchema: { type: "object", properties: {} },
    handler: () => json(["locations"]),
  },

  {
    name: "list_rooms",
    description: "List the rooms in a location.",
    inputSchema: {
      type: "object",
      properties: { location_id: { type: "string", description: "Location id from list_locations." } },
    },
    handler: ({ location_id }) =>
      json(["locations:rooms", ...(location_id ? [requireID(location_id, "location_id")] : [])]),
  },

  {
    name: "list_devices",
    description:
      "List every device on the account, with its id, label, and the capabilities it supports. " +
      "Use the id with device_status and send_device_command.",
    inputSchema: { type: "object", properties: {} },
    handler: () => json(["devices", "--verbose"]),
  },

  {
    name: "device_status",
    description: "Get the current state of one device — whether it is on, its level, its temperature.",
    inputSchema: {
      type: "object",
      properties: { device_id: { type: "string", description: "Device id from list_devices." } },
      required: ["device_id"],
    },
    handler: ({ device_id }) => json(["devices:status", requireID(device_id, "device_id")]),
  },

  {
    name: "device_capabilities",
    description:
      "Get the components and capabilities of one device, which is what says which commands it accepts.",
    inputSchema: {
      type: "object",
      properties: { device_id: { type: "string", description: "Device id from list_devices." } },
      required: ["device_id"],
    },
    handler: ({ device_id }) => json(["devices", requireID(device_id, "device_id")]),
  },

  {
    name: "refresh_inventory",
    description:
      "Re-read the device list from SmartThings. Use after adding or renaming a device so the " +
      "ids and labels are current.",
    inputSchema: { type: "object", properties: {} },
    // Nothing is cached here, so a refresh *is* a re-read. Kept as its own tool
    // because the model has no way to know that, and would otherwise have no answer
    // to a user who just added a device.
    handler: () => json(["devices", "--verbose"]),
  },

  {
    name: "send_device_command",
    description:
      "Send a command to a device — turn a switch on, set a level, lock a lock. Give the " +
      "capability and command as separate fields, e.g. capability \"switch\" and command \"on\", " +
      "or capability \"switchLevel\", command \"setLevel\", arguments [50].",
    inputSchema: {
      type: "object",
      properties: {
        device_id: { type: "string", description: "Device id from list_devices." },
        capability: { type: "string", description: "Capability name, e.g. \"switch\", \"switchLevel\", \"lock\"." },
        command: { type: "string", description: "Command name, e.g. \"on\", \"off\", \"setLevel\", \"lock\"." },
        arguments: {
          type: "array",
          description: "Command arguments, if the command takes any. e.g. [50] for setLevel.",
          items: {},
        },
        component: { type: "string", description: "Component, default \"main\"." },
      },
      required: ["device_id", "capability", "command"],
    },
    async handler({ device_id, capability, command, arguments: args, component }) {
      const id = requireID(device_id, "device_id");
      const capabilityName = requireIdentifier(capability, "capability");
      const commandName = requireIdentifier(command, "command");
      const componentName = component === undefined
        ? "main"
        : requireIdentifier(component, "component");

      const list = args === undefined ? [] : args;
      if (!Array.isArray(list)) throw new Error("`arguments` must be an array.");
      const rendered = list.map(renderArgument);

      // Composed here, from fields the gate already saw separately — never taken
      // from the model as one string.
      const spec = `${componentName}:${capabilityName}:${commandName}` +
        (rendered.length ? `(${rendered.join(",")})` : "");
      await cli(["devices:commands", id, spec]);
      return text(`Sent ${spec} to ${id}`);
    },
  },

  {
    name: "list_scenes",
    description: "List the scenes on the account.",
    inputSchema: { type: "object", properties: {} },
    handler: () => json(["scenes"]),
  },

  {
    name: "run_scene",
    description:
      "Run a scene. A scene is a stored list of actions this app cannot see, so what it " +
      "changes is not knowable in advance.",
    inputSchema: {
      type: "object",
      properties: { scene_id: { type: "string", description: "Scene id from list_scenes." } },
      required: ["scene_id"],
    },
    // `ActionRiskPolicy` classifies this `.unknown`, which means it always asks.
    // That is the correct answer and not a gap: a scene may contain a lock, and the
    // contents are not visible from here to rule it out.
    async handler({ scene_id }) {
      const id = requireID(scene_id, "scene_id");
      await cli(["scenes:execute", id]);
      return text(`Ran scene ${id}`);
    },
  },
];

if (!CLI) log("[gaithano-smartthings] no smartthings CLI found; every tool will report how to install it");

serve({ name: "gaithano-smartthings", version: "1.0.0", tools });

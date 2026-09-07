#!/usr/bin/env node
// macOS desktop control for Agent Mode.
//
// Written for this app rather than taken off the shelf, for two reasons found by
// reading the alternative. `mcp-macos-cua@1.2.0` names almost none of the tools
// `AgentToolAllowlist` lists, so the gate would have filtered it down to nothing;
// and its `type_text` builds a shell command by interpolating the model's own text
// between single quotes, escaping `\` and `"` but not `'`. That is a shell, reached
// through the one tool most likely to carry text the assistant read off a web page.
//
// So the rules here are structural, not stylistic:
//
//   1. **No shell, anywhere.** `execFile` with an argument array. Nothing in this
//      file builds a command string, so there is no quoting to get right and no
//      escaping bug to introduce later.
//   2. **No model-supplied value is ever interpolated into an AppleScript.** Every
//      script is a fixed literal with `on run argv`, and values arrive as arguments.
//      A name containing quotes, newlines, or `do shell script` is inert data. The
//      only things built into script text are role and modifier keywords, which are
//      AppleScript *syntax* rather than data, and each is checked against a fixed
//      map first — an unrecognised one is refused, never passed through.
//   3. **The tool list is exactly `AgentToolAllowlist.macosTools`.** A tool the
//      allowlist doesn't name is unreachable, so shipping one is only a way to be
//      wrong later.
//
// There is deliberately no run-a-script tool. That is the capability this whole
// feature is built to not have.

import { execFile } from "node:child_process";
import { readFile, unlink } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { serve, text, image, failure, log } from "./lib/mcp.js";

const DEFAULT_TIMEOUT = 15000;

function run(file, args, timeout = DEFAULT_TIMEOUT) {
  return new Promise((resolve, reject) => {
    execFile(file, args, { timeout, encoding: "utf8", maxBuffer: 8 * 1024 * 1024 },
      (error, stdout, stderr) => {
        if (error) {
          // -1712 is an Apple Event timeout, which in practice means macOS is
          // waiting on an Automation permission decision that nothing can present.
          // Saying so beats "Command failed", which sends the model looking for a
          // bug in its own arguments.
          const detail = (stderr || error.message || "").trim();
          if (detail.includes("-1712") || error.killed) {
            return reject(new Error(
              "macOS did not respond. Grant Gaithano Speak permission to control " +
              "your Mac under System Settings → Privacy & Security → Automation " +
              "(and Accessibility), then try again."));
          }
          return reject(new Error(detail || "command failed"));
        }
        resolve(stdout.trim());
      });
  });
}

/// Run a fixed AppleScript, passing every value as an argument.
///
/// The `--` matters: without it `osascript` reads a leading-dash value as one of its
/// own flags. With it, everything after is `argv` and nothing is parsed.
const osa = (script, args = []) =>
  run("osascript", ["-e", script, "--", ...args.map(String)]);

// MARK: - Validated vocabularies
//
// These are the only values that ever reach a script as *syntax*. Each lookup fails
// closed, so a role or key this file doesn't know is an error rather than a string
// spliced into a script.

const KEY_CODES = {
  return: 36, enter: 36, escape: 53, esc: 53, tab: 48, space: 49,
  delete: 51, backspace: 51, forwarddelete: 117,
  up: 126, down: 125, left: 123, right: 124,
  pageup: 116, pagedown: 121, home: 115, end: 119,
  f1: 122, f2: 120, f3: 99, f4: 118, f5: 96, f6: 97, f7: 98, f8: 100,
  f9: 101, f10: 109, f11: 103, f12: 111,
};

const MODIFIERS = {
  cmd: "command down", command: "command down",
  shift: "shift down",
  alt: "option down", option: "option down",
  ctrl: "control down", control: "control down",
  fn: "function down",
};

// AppleScript element classes. Two words stay two words — `menu item`, not
// `menu_item` — because this text becomes syntax.
const ROLES = new Set([
  "button", "menu item", "menu button", "checkbox", "radio button",
  "text field", "text area", "pop up button", "static text", "image",
  "group", "tab group", "scroll area", "table", "row", "list", "link",
  "slider", "combo box", "outline", "splitter group", "toolbar", "window",
]);

function requireString(value, field) {
  if (typeof value !== "string" || value.trim() === "") {
    throw new Error(`\`${field}\` is required and must be a non-empty string.`);
  }
  return value;
}

function requireNumber(value, field) {
  const number = Number(value);
  if (!Number.isFinite(number)) throw new Error(`\`${field}\` must be a number.`);
  return number;
}

// MARK: - Tools

const tools = [
  {
    name: "capture_screen",
    description:
      "Take a screenshot of the whole screen and return it as an image. Use this to see " +
      "what is currently on screen before deciding where to click.",
    inputSchema: { type: "object", properties: {} },
    async handler() {
      // Written to the private temp directory and deleted before returning, so the
      // path never leaves this process. The spec's rule is that screenshots reach
      // the model as image content and never as a readable path — a path would be a
      // second capability handed over without passing the tool gate.
      const path = join(tmpdir(), `gs-agent-shot-${process.pid}-${Date.now()}.png`);
      try {
        // -x: no shutter sound. A capture the user can hear is one they can notice,
        // but this fires often enough that it would become noise rather than signal.
        await run("screencapture", ["-x", "-t", "png", path], 20000);
        return image(await readFile(path), "image/png");
      } finally {
        await unlink(path).catch(() => {});
      }
    },
  },

  {
    name: "list_applications",
    description: "List the names of applications that are currently running and visible.",
    inputSchema: { type: "object", properties: {} },
    async handler() {
      const names = await osa(
        'tell application "System Events" to get name of every process whose background only is false');
      return text(names || "(nothing running)");
    },
  },

  {
    name: "list_windows",
    description: "List the window titles of one running application.",
    inputSchema: {
      type: "object",
      properties: { app: { type: "string", description: "Application name, e.g. \"Safari\"." } },
      required: ["app"],
    },
    async handler({ app }) {
      const titles = await osa(`on run argv
  tell application "System Events" to tell process (item 1 of argv)
    return name of every window
  end tell
end run`, [requireString(app, "app")]);
      return text(titles || "(no windows)");
    },
  },

  {
    name: "open_application",
    description: "Launch an application, or bring it forward if it is already running.",
    inputSchema: {
      type: "object",
      properties: { app: { type: "string", description: "Application name, e.g. \"Mail\"." } },
      required: ["app"],
    },
    async handler({ app }) {
      // `open -a` rather than an Apple Event: launching is the one thing that does
      // not need Automation permission, and not needing it is worth more than
      // symmetry with `activate_application`.
      await run("open", ["-a", requireString(app, "app")]);
      return text(`Opened ${app}`);
    },
  },

  {
    name: "activate_application",
    description: "Bring an already-running application to the front so it receives input.",
    inputSchema: {
      type: "object",
      properties: { app: { type: "string", description: "Application name." } },
      required: ["app"],
    },
    async handler({ app }) {
      await osa(`on run argv
  tell application "System Events" to tell process (item 1 of argv) to set frontmost to true
end run`, [requireString(app, "app")]);
      return text(`Activated ${app}`);
    },
  },

  {
    name: "accessibility_tree",
    description:
      "List the interactive elements of an application's front window, with their role and " +
      "name. Prefer this over a screenshot when deciding what to click: it gives exact " +
      "names for click_element, where a screenshot only gives coordinates that shift.",
    inputSchema: {
      type: "object",
      properties: {
        app: { type: "string", description: "Application name." },
        depth: {
          type: "string",
          enum: ["shallow", "deep"],
          description: "\"shallow\" lists top-level elements; \"deep\" walks the whole window and can be slow.",
        },
      },
      required: ["app"],
    },
    async handler({ app, depth }) {
      const name = requireString(app, "app");
      const script = depth === "deep"
        ? `on run argv
  tell application "System Events" to tell process (item 1 of argv)
    return entire contents of window 1
  end tell
end run`
        : `on run argv
  tell application "System Events" to tell process (item 1 of argv)
    return {role, name, description} of every UI element of window 1
  end tell
end run`;
      // A deep walk on a big window genuinely takes tens of seconds; the default
      // timeout would report a permission problem for what is only a slow tree.
      const result = await run("osascript", ["-e", script, "--", name],
                               depth === "deep" ? 45000 : DEFAULT_TIMEOUT);
      return text(result || "(no elements)");
    },
  },

  {
    name: "click_element",
    description:
      "Click a named element in an application's front window, found through accessibility. " +
      "More reliable than clicking coordinates, which move when a window moves.",
    inputSchema: {
      type: "object",
      properties: {
        app: { type: "string", description: "Application name." },
        role: { type: "string", description: "Element role, e.g. \"button\", \"checkbox\", \"menu item\"." },
        name: { type: "string", description: "The element's visible name or title." },
      },
      required: ["app", "role", "name"],
    },
    async handler({ app, role, name }) {
      const application = requireString(app, "app");
      const label = requireString(name, "name");
      const kind = requireString(role, "role").trim().toLowerCase();
      if (!ROLES.has(kind)) {
        throw new Error(`Unsupported role "${role}". Known roles: ${[...ROLES].sort().join(", ")}.`);
      }
      // `kind` is syntax and comes from the set above; `application` and `label` are
      // data and arrive as arguments. That split is the reason a window titled
      // `" of window 1` is a title and not a script.
      await osa(`on run argv
  tell application "System Events" to tell process (item 1 of argv)
    click ${kind} (item 2 of argv) of window 1
  end tell
end run`, [application, label]);
      return text(`Clicked ${kind} "${label}" in ${application}`);
    },
  },

  {
    name: "click_coordinate",
    description:
      "Click at a screen position, in points from the top-left of the main display. Use only " +
      "when the target has no accessible name — take a screenshot first to find the position.",
    inputSchema: {
      type: "object",
      properties: {
        x: { type: "number", description: "X position in points." },
        y: { type: "number", description: "Y position in points." },
      },
      required: ["x", "y"],
    },
    async handler({ x, y }) {
      const px = requireNumber(x, "x");
      const py = requireNumber(y, "y");
      await osa(`on run argv
  tell application "System Events" to click at {(item 1 of argv) as number, (item 2 of argv) as number}
end run`, [px, py]);
      return text(`Clicked at (${px}, ${py})`);
    },
  },

  {
    name: "scroll",
    description: "Scroll the frontmost window. Scrolls whatever currently has keyboard focus.",
    inputSchema: {
      type: "object",
      properties: {
        direction: { type: "string", enum: ["up", "down"], description: "Scroll direction." },
        amount: { type: "number", description: "Number of steps, default 3. One step is roughly a wheel notch." },
      },
      required: ["direction"],
    },
    async handler({ direction, amount }) {
      // Arrow keys rather than a wheel event. Synthesizing a real scroll wheel needs
      // CGEventCreateScrollWheelEvent, which means either pyobjc or a compiled
      // helper — neither is present, and a scroll that works everywhere beats a
      // smoother one that needs a dependency the user has to install.
      const key = direction === "up" ? KEY_CODES.up : KEY_CODES.down;
      if (direction !== "up" && direction !== "down") {
        throw new Error('`direction` must be "up" or "down".');
      }
      const steps = Math.min(Math.max(Math.round(Number(amount) || 3), 1), 50);
      await osa(`on run argv
  tell application "System Events"
    repeat (item 1 of argv) as integer times
      key code ${key}
    end repeat
  end tell
end run`, [steps * 3]);
      return text(`Scrolled ${direction} ${steps} steps`);
    },
  },

  {
    name: "press_key",
    description:
      "Press a key or key combination, e.g. \"return\", \"escape\", \"cmd+c\", \"cmd+shift+t\". " +
      "The frontmost application receives it.",
    inputSchema: {
      type: "object",
      properties: {
        keys: { type: "string", description: "Key combination, modifiers joined with \"+\"." },
      },
      required: ["keys"],
    },
    async handler({ keys }) {
      const combo = requireString(keys, "keys").toLowerCase().split("+").map((p) => p.trim());
      const key = combo.pop();
      const modifiers = combo.map((name) => {
        const modifier = MODIFIERS[name];
        if (!modifier) throw new Error(`Unknown modifier "${name}".`);
        return modifier;
      });
      // Built from the validated map only — never from `keys` itself.
      const using = modifiers.length ? ` using {${modifiers.join(", ")}}` : "";

      if (KEY_CODES[key] !== undefined) {
        await osa(`tell application "System Events" to key code ${KEY_CODES[key]}${using}`);
      } else if ([...key].length === 1) {
        // A single character is data, so it goes through argv like everything else.
        await osa(`on run argv
  tell application "System Events" to keystroke (item 1 of argv)${using}
end run`, [key]);
      } else {
        throw new Error(
          `Unknown key "${key}". Use a single character, or one of: ${Object.keys(KEY_CODES).join(", ")}.`);
      }
      return text(`Pressed ${keys}`);
    },
  },

  {
    name: "type_text",
    description: "Type text into the frontmost application, as if typed on the keyboard.",
    inputSchema: {
      type: "object",
      properties: { text: { type: "string", description: "The text to type." } },
      required: ["text"],
    },
    async handler({ text: value }) {
      if (typeof value !== "string" || value === "") {
        throw new Error("`text` is required and must be a non-empty string.");
      }
      // The tool that made the off-the-shelf server unusable. Here the text is an
      // argument to a fixed script, so quotes, newlines and semicolons in it are
      // characters to type and cannot become syntax in a script or a shell.
      await osa(`on run argv
  tell application "System Events" to keystroke (item 1 of argv)
end run`, [value], 30000);
      return text(`Typed ${value.length} characters`);
    },
  },

  {
    name: "close_window",
    description: "Close the front window of an application, with ⌘W.",
    inputSchema: {
      type: "object",
      properties: { app: { type: "string", description: "Application name." } },
      required: ["app"],
    },
    async handler({ app }) {
      const name = requireString(app, "app");
      await osa(`on run argv
  tell application "System Events"
    tell process (item 1 of argv) to set frontmost to true
    keystroke "w" using {command down}
  end tell
end run`, [name]);
      return text(`Closed the front window of ${name}`);
    },
  },

  {
    name: "quit_application",
    description: "Quit an application. Unsaved work may prompt the app's own save dialog.",
    inputSchema: {
      type: "object",
      properties: { app: { type: "string", description: "Application name." } },
      required: ["app"],
    },
    async handler({ app }) {
      const name = requireString(app, "app");
      await osa(`on run argv
  tell application (item 1 of argv) to quit
end run`, [name]);
      return text(`Asked ${name} to quit`);
    },
  },

  {
    name: "set_volume",
    description: "Set the system output volume, 0 to 100.",
    inputSchema: {
      type: "object",
      properties: { level: { type: "number", description: "Volume from 0 (muted) to 100." } },
      required: ["level"],
    },
    async handler({ level }) {
      const value = Math.min(Math.max(Math.round(requireNumber(level, "level")), 0), 100);
      await osa(`on run argv
  set volume output volume ((item 1 of argv) as number)
end run`, [value]);
      return text(`Output volume set to ${value}`);
    },
  },
];

serve({ name: "gaithano-macos", version: "1.0.0", tools });

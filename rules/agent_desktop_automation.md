---
name: agent-desktop-automation
description: Enforces reliable Windows 11 desktop automation invariants for agent-desktop across all AI sessions.
trigger: always_on
---

# Agent Desktop Automation Invariants

When operating, observing, or automating desktop applications on Windows 11 using the `agent-desktop` CLI, all AI agents MUST adhere to these strict engineering invariants:

## 1. Interactive Desktop Station Invariant (No Sandbox Crashes)
- Background AI terminals and subagents run inside isolated subshell window stations (`WinSta0\exebox-...`). Calling the raw native binary directly there fails with `EnumWindows failed to enumerate top-level windows`.
- **MANDATORY:** Always execute desktop commands using `agent-desk` on User PATH (`agent-desk <command>`) or `bin/agent-desk.ps1` targeting `WinSta0\default`, ensuring direct access to the user's active, visible Windows session.

## 2. PowerShell Ref Quoting & Win32 Argument Escaping Invariant
- In PowerShell, a bare `@token` is the reserved splatting operator. PowerShell silently strips or alters bare `@ref` arguments before the binary sees them.
- **MANDATORY:** Every element ref MUST be wrapped in single quotes in PowerShell: e.g. `'@s8f3k2p9:e12'`, NEVER `@s8f3k2p9:e12`.
- **Ref Normalization:** `agent-desk` normalizes both bare `@ref` and quoted `'@ref'` arguments, stripping outer quotes without injecting literal double-single quotes (`''@ref''`).
- **Win32 Argument Escaping:** Multi-word argument values with spaces or quotes are automatically escaped per standard Win32 `CommandLineToArgvW` rules.

## 3. Closed-Loop "Observe -> Act -> Verify" Invariant
- Never assume an action succeeded because the CLI returned exit code 0.
- **MANDATORY:** Stateful actions (`set-value`, `type`, `check`, `uncheck`, `toggle`) must be verified:
  1. Inspect `data.disposition.delivery` (`delivered_verified` vs `delivered_unverified`).
  2. Confirm state changes via `agent-desk is --property <checked|visible|focused> '<ref>'` or a targeted re-snapshot before taking subsequent steps.

## 4. Headless-First Execution
- Prioritize headless semantic accessibility calls (`set-value`, `click`, `select`, `check`, `expand`). They dispatch through Windows UI Automation without stealing focus or moving the user's physical mouse cursor.
- Use `--headed` ONLY when physical mouse movement, drag-and-drop, right-click context menus, or keystroke synthesis (`type`) are strictly required.

## 5. Token Efficiency & Subtree Drilling
- For large, dense applications (Chrome, File Explorer, VS Code, Slack):
  1. Use `--skeleton -i --compact` to get a shallow depth-3 map.
  2. Use `--root '<ref>'` to drill into the specific container panel.
  3. Never dump thousands of unfiltered nodes into the context window.

## 6. Custom Canvas & Multimodal Fallback
- When an app renders on a pure HTML5 `<canvas>`, WebGL, or DirectX surface and the accessibility tree returns 0 elements (`ref_count: 0`):
  1. Trigger `agent-desk screenshot --screen 0 <output.png>`.
  2. Inspect the captured screenshot with vision/multimodal reasoning to calculate bounding coordinates.
  3. Dispatch physical input using `agent-desk --headed mouse-click --xy X,Y`.

## 7. Safety & Remote Boundaries
- AI NEVER presses dangerous system shortcuts (`win+l`, `alt+f4`, `ctrl+shift+esc`) without explicit user instruction.
- AI NEVER pushes to remote Git repositories or publishes packages without explicit user verification and authorization.

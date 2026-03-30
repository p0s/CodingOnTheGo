# Codex Product Direction

## Contract legend
- **1.0 MUST**: required for the shipping product contract
- **Later / not 1.0**: intentionally deferred; do not make it a hidden launch requirement
- **Design invariant**: product truth that should not drift across implementations

## 1.0 product contract
- **Design invariant**: product shape remains `Codex / Connections / Settings` with `Project -> Thread` as the daily model.
- **1.0 MUST**: a reachable Codex app-server websocket is the preferred live lane behind the product shell.
- **1.0 MUST**: SSH stdio remains the bootstrap, repair, and fallback lane; it is not the preferred steady-state lane after websocket readiness.
- **1.0 MUST**: embedded Tailscale support, SSH forwarding/fallback, and optional companion publication of Codex websocket endpoint metadata are in scope for 1.0.
- **Later / not 1.0**: CloudKit / cross-device sync.
- **Later / not 1.0**: optional COTG macOS companion access as the only path or sole trust root.
- **Design invariant**: browser/history must stay host-backed and truthful; fallback or cached data must be labeled honestly.

## Product goal
- First setup gets the user back into coding in under 3 minutes.
- Repeat usage gets the user back into coding in about 10 seconds.

## Target user
- Solo developer
- One Mac
- 5 to 20 projects
- iPhone first

## Top-level shell
- `Codex`
- `Connections`
- `Settings`

## Default home
- Open into `Codex`.
- Keep the browser visible.
- Do not preselect a thread.

## Core product model
- Product shape is `Project -> Thread` first.
- Mac identity is secondary context.
- Foreground the current Mac only when more than one Mac matters or cross-Mac browsing is enabled.

## Codex view rules
- The browser plus the conversation workspace are the product.
- Do not use hero or marketing copy in daily use.
- Do not keep heavy setup or admin controls in the main chat canvas.
- Transcript is primary.
- Sticky composer is primary.

## Naming rules
- Prefer `Project` and `Thread` in user-facing copy.
- Use `Repo` or `Git` only when the context is truly Git-specific.
- Do not keep visible `Repos & Sessions` language for the main Codex browser.

## Secondary surfaces
- `Connections` owns Codex websocket readiness, discovery, optional companion-published endpoint readiness, SSH setup, trust, route verification, repair, and diagnostics.
- In `Connections`, always-required setup belongs in the primary pane, not in recovery.
- `Connections` should distinguish:
  - setup once
  - use now
  - technical details
- **Design invariant**: `Connections` should present Codex app-server websocket as the preferred live lane when ready, while keeping SSH visible as setup/control and raw stdio visible as repair/fallback rather than the main trust root.
- Workspace review appears as an inline summary with a full panel one interaction away.
- Deeper run and transport tools stay available, but secondary.

## Acceptance checklist
This is the intended product-shape checklist, not the live status ledger. Track current completion and blockers in ignored local release notes.

- [ ] Top-level shell is `Codex / Connections / Settings`
- [ ] Default home is `Codex`
- [ ] Default home shows the browser and no thread selected
- [ ] Default home does not look like a dashboard or onboarding card stack
- [ ] Browser is Project/Thread shaped, not card-catalog shaped
- [ ] Browser uses native list/sidebar patterns
- [ ] One-Mac default hides machine noise
- [ ] Visible copy says Project/Thread unless the context is truly Git-specific
- [ ] `New thread` and `Resume thread` are equally discoverable
- [ ] No hero or marketing framing remains in the daily Codex surface
- [ ] Transcript is the visual focal point
- [ ] Composer is sticky and primary
- [ ] Photo and voice tools are clearly available from main conversation chrome
- [ ] Approval mode is clearly visible in main session chrome
- [ ] Interrupt is easy to access while streaming
- [ ] Workspace review appears as inline summary plus full panel
- [ ] Connection admin controls are moved out of the main chat surface
- [ ] Discovery, trust, and route repair live in `Connections`
- [ ] SSH login setup is first-class in `Connections`, not buried under recovery
- [ ] `Connections` separates setup-once guidance from current-network reconnect guidance
- [ ] Advanced transport and run controls remain available, but secondary
- [ ] `New thread` creates a distinct persisted record
- [ ] Browser data is honest and not faked with local current-directory fallbacks
- [ ] Settings contains the iPhone browser presentation preference
- [ ] UI feels calm, premium, native, and restrained
- [ ] Liquid Glass is used mainly on chrome, not every content block
- [ ] Dark mode, Dynamic Type, accessibility, and normal/empty/error/loading/selected states remain correct
- [ ] UI tests and accessibility labels no longer enforce old machine-first vocabulary or hierarchy
- [ ] Old machine-first or connection-first cues no longer dominate daily usage

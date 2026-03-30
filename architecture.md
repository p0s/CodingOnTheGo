# Architecture Blueprint

This file is the concise execution blueprint. `spec.md` remains the source of truth.

## Contract legend

- **1.0 MUST**: required for the shipping iPhone-first 1.0 contract
- **Later / not 1.0**: intentionally deferred; keep the architecture honest, but do not gate 1.0 on it
- **Design invariant**: must stay true regardless of release phase

## Core principle

- **Design invariant**: **Route** = how the client can reach a Mac
- **Design invariant**: **Bootstrap** = how the client verifies and starts host capabilities
- **Design invariant**: **Protocol** = how the client talks to Codex once the host is reachable

Keep these layers separate in code and in UX.

## 1.0 contract

- **1.0 MUST**: a reachable Codex app-server websocket is the preferred primary live lane.
- **1.0 MUST**: that websocket may be directly reachable, SSH-forwarded from a loopback listener, or published/managed by the optional macOS companion.
- **1.0 MUST**: SSH stdio over Remote Login remains the bootstrap, repair, and compatibility fallback lane, not the preferred steady-state live lane after websocket readiness.
- **1.0 MUST**: embedded Tailscale support ships in the runtime stack.
- **1.0 MUST**: companion presence advertising and optional live-lane readiness publication ship in the macOS companion.
- **1.0 MUST**: first-pairing and repair work with `Codex.app` installed on the Mac and the user signed in there; they must not require a separate `codex` on `PATH`.
- **1.0 MUST**: when a macOS GUI session exists, any direct, companion-managed, or SSH-managed loopback websocket listener used for parity-sensitive work must run inside that GUI session; if that cannot be proven, refuse or fall back explicitly.
- **Later / not 1.0**: CloudKit / cross-device sync.
- **Later / not 1.0**: optional COTG macOS companion access as the only route or sole trust root.
- **Design invariant**: SSH remains available for first success and repair, but Codex app-server websocket is the preferred live path once ready.

## Execution authority

- **Design invariant**: machine capability facts are not the same thing as active executor authority.
- **Design invariant**: **Execution profile** = the active session/thread authority contract.
- Persist a first-class execution profile that includes:
  - requested approval and sandbox intent
  - baseline host config from `config/read`
  - constraints from `configRequirements/read`
  - effective approval/sandbox/read-write/network truth
  - runtime path/version/provenance
- SSH bootstrap resolves the host runtime in this order:
  1. `/Applications/Codex.app/Contents/Resources/codex`
  2. `~/Applications/Codex.app/Contents/Resources/codex`
  3. other discovered `Codex.app` bundle runtimes
  4. `command -v codex`
- Production iPhone/iPad builds prefer a ready Codex app-server websocket lane before SSH stdio; when no direct endpoint is reachable they use SSH as a bootstrap/control channel to start and forward the GUI-session loopback websocket before falling back to raw stdio repair. UI tests can still force deterministic stdio fallback coverage.
- `config/read` is baseline only. Effective authority comes from runtime facts plus baseline config, constraints, supported lifecycle overrides, and session-scoped grants.
- If a field or method cannot be proven on the installed runtime, keep it `unknown` or `unsupported`.
- If schema and live runtime disagree, the live runtime wins.

## Product shell

- Top-level tabs are exactly `Codex`, `Connections`, and `Settings`.
- Default daily home after setup is `Codex`.
- Default browsing scope is the current Mac only.
- The daily mental model is `Project -> Thread`, not `Machine -> Detail`.
- Machine identity becomes prominent only when more than one Mac exists or cross-Mac browsing is explicitly enabled.

### Codex

- iPhone: full-screen transcript, sticky composer, Project/Thread browser as sheet or drawer, inspector on demand.
- iPad: adaptive split layout with hierarchical browser sidebar, transcript main pane, and inspector on demand.
- Transcript is the focal surface.
- Browser sections are `Recent` and `Projects`.
- Projects expand to threads.
- `New thread` must create a distinct persisted `SessionRecord`; it must not silently reuse the latest session.
- Daily Codex chrome shows repo/path, branch/worktree, model, session-derived approval/sandbox/network mode, photo, and voice. Connection state and current Mac appear only when relevant.
- Route overrides, smoke tests, reasoning controls, and parallel-agent controls stay secondary in inspector or overflow surfaces.

### Connections

- Owns setup, route use, repair, trust, route verification, adding Macs, and advanced diagnostics.
- The main iPhone hierarchy is:
  1. `Set up this iPhone`
  2. `Ways to connect`
  3. `Technical details`
- `Set up this iPhone` owns the always-required steps:
  1. detect Mac
  2. choose Mac account
  3. set up SSH access
  4. verify the Mac fingerprint
- `Ways to connect` owns the route choices and fallback order:
  - same Wi-Fi or nearby
  - away from home
  - saved routes and priority
- `Technical details` owns route diagnostics, manual rescue routes, tailnet profiles, forgetting a saved Mac, host capability details, and testing-heavy information.
- Happy path order:
  1. detect Mac
  2. choose Mac account
  3. set up SSH access
  4. verify the Mac fingerprint
  5. connect on the current network
  6. add the away-from-home fallback
  7. open Codex
  8. start coding
- Auto-discovered Macs come first.
- Onboarding entry points at the machine-directory root split into nearby vs away-from-home paths before dropping into technical details.
- Manual route entry is advanced, not primary.
- Standard SSH setup must not live only under recovery.

### Settings

- Owns the iPhone browser presentation preference (`Sheet` or `Drawer`).
- Cross-Mac project browsing remains experimental and secondary.

## Recommended runtime priority

1. **Codex app-server websocket** when directly reachable, SSH-forwarded, or companion-published and ready
2. **Embedded Tailscale route** for fallback reachability
3. **Same-LAN route** for fallback reachability
4. **SSH bootstrap** for first-pairing, repair, and fallback
5. **SSH-forwarded Codex app-server websocket** when GUI-session readiness is proven
6. **`stdio://` Codex app-server over SSH** as the repair fallback lane
7. **Manual direct endpoint / rescue tools** only in advanced settings

## Route evaluation invariants

- Route scoring and UI must keep these states distinct:
  - configured
  - authenticated
  - reachable
  - eligible
  - recommended
  - active
  - last-good
- Embedded tailnet routes only qualify for SSH bootstrap when the embedded dial plan exposes a native SSH-capable endpoint.
- The native runtime is expected to publish that endpoint as a local proxy target that the SSH fallback lane can dial directly.
- External tailnet routes only qualify as reachable/recommended when the external Tailscale app is installed and the route is otherwise healthy.
- Healthy LAN/manual SSH routes beat degraded or not-ready tailnet routes.

## Connection modes

| Mode | Route | Bootstrap | Protocol | Use |
|---|---|---|---|---|
| Codex websocket live lane | Direct endpoint, LAN, tailnet, or SSH-forwarded loopback reachability | Direct readiness, SSH forwarding, or companion-managed readiness | Codex app-server websocket | **1.0 MUST** preferred steady-state |
| SSH bootstrap / repair | Embedded Tailscale or LAN | Standard macOS SSH (Remote Login) with bundle-runtime discovery first | SSH stdio app-server | **1.0 MUST** fallback and first-pairing |
| SSH websocket lane | Connected SSH fallback with verified websocket reuse | SSH-managed shared listener from the same resolved runtime, launched in the macOS GUI session when available | SSH-tunneled Codex app-server websocket | **1.0 MUST** zero-install websocket after host capability proof |
| Recovery | Manual route / remote desktop | Manual | Manual | Advanced only; not a live-lane trust root |

## Current mono-repo layout

```text
CodingOnTheGo/
├── apps/
│   ├── ios/CodingOnTheGo
│   └── macOS/CodingOnTheGoCompanion
├── Packages/
│   ├── SharedModels
│   ├── AppState
│   ├── Persistence
│   ├── SyncEngine
│   ├── Secrets
│   ├── Discovery
│   ├── TailnetEmbedded
│   ├── SSHTransport
│   ├── CodexRPC
│   ├── HostBootstrap
│   ├── RouteSelection
│   ├── GitWorkspace
│   ├── Notifications
│   ├── FeatureMachines
│   ├── FeatureThreads
│   ├── FeatureComposer
│   ├── FeatureReview
│   └── CompanionHost
└── docs/ and root planning files
```

## App targets

- **Coding On The Go (iPhone 1.0 / iPad + sync 1.1)**
  Machine directory, route selection, discovery, embedded Tailscale, SSH bootstrap, app-server client, conversation UI, Git/workspace UI, push/local notifications, iPad multiwindow.
- **Coding On The Go Companion (macOS)**  
  Presence, capability scans, managed listener lifecycle, login item, enhanced reconnect, push bridge, optional direct authenticated endpoint, Codex app handoff helpers.

## Package responsibilities

- `SharedModels`: machine, route, session, execution-profile, capability, sync DTOs
- `Persistence`: JSON machine-directory store plus local projections
- `SyncEngine`: local-only sync coordinator in `1.0`, with CloudKit private DB sync via `CKSyncEngine` deferred to the combined `1.1` iPad + sync release
- `Secrets`: Keychain + shared access-group wrappers
- `TailnetEmbedded`: libtailscale/TailscaleKit wrapper; no raw libtailscale types escape this package
- `Discovery`: Bonjour, LAN reachability, cached host probes, and merge of companion-published routes
- `SSHTransport`: SSH client, host key verification, bundle-runtime bootstrap, exec, port forwarding, file staging
- `HostBootstrap`: Remote Login checks, Codex runtime discovery, app-server launch/reuse flows
- `CodexRPC`: transport-independent JSON-RPC client, execution-profile-aware request builders, schema/runtime-driven server-request routing, event fan-out
- `RouteSelection`: route scoring, health, pinning, fallback, reconnect heuristics
- `GitWorkspace`: Git wrappers, worktree info, revert preview/apply orchestration
- `Notifications`: local notification coordinator, push enrollment, completion routing
- `CompanionHost`: companion-only host services and direct endpoint auth
  Direct endpoint auth is preferred for live use when ready, while SSH remains available for first-pairing and repair.

## Data model summary

- `MachineRecord`: logical Mac
- `RouteRecord`: one connectivity path for a machine
- `TailnetProfile`: one embedded or external tailnet profile
- `HostCapabilitySnapshot`: codex/git/companion/runtime features
- `SessionRecord`: recent UI context + last known thread/workspace; each new session is a distinct persisted record
- `CredentialRef`: stable identifier to a secret stored in Keychain

## Companion integration points

- Presence and reachability beacon
- Capability snapshot and diagnostics
- Pre-warmed shared loopback listener
- Reliable notification bridge
- Login item / helper lifecycle
- Optional direct authenticated endpoint
- Codex app deeplink / handoff utilities

## Implementation status

1. **Foundation**: delivered in the shared packages plus the iPhone/iPad/macOS app targets
2. **Zero-install path**: delivered and localhost runtime-verified over SSH stdio
3. **Discovery**: delivered with Bonjour plus cached host probes and route merge-back into the machine directory
4. **Embedded Tailscale**: adapter boundary, sign-in modeling, profile switching, traffic-ready promotion through a published loopback SOCKS5 bootstrap endpoint, SOCKS-capable SSH bootstrap consumption, and the optional local `TailscaleKit` package hook are delivered; physical-device validation requires a private local runtime artifact and credentials outside git
5. **Feature parity**: delivered for steer, queued prompts, approvals, review, image staging, Git/workspace UI, voice input, local notifications, Codex Mac handoff, and a real client-orchestrated subagent fallback when the backend does not expose native agents; push-backed broker validation remains externally gated
6. **Codex websocket live lane**: implemented in shared code as the preferred steady-state route when a direct, SSH-forwarded, or companion-published websocket endpoint is ready, with SSH stdio retained for first-pairing, repair, and fallback
7. **SSH websocket lane**: implemented in shared code, host/runtime tests, and iPhone/iPad UI for cases where no direct endpoint is reachable but SSH can prove GUI-session listener readiness

## Current verification posture

- Localhost SSH stdio fallback lane is runtime-verified.
- Real-host SSH stdio is runtime-verified against a non-localhost Mac where `PATH_CODEX=` is empty and the bundled runtime inside `Codex.app` is used for both stdio bootstrap and loopback-listener startup.
- Codex app-server websocket is now the preferred live lane when directly reachable, SSH-forwarded, or companion-published and ready; SSH-forwarded loopback websocket upgrade/fallback remains runtime-verified on iPhone/iPad simulator flows and on connected physical iPhone proof runs, including a codesign-sensitive turn that only succeeds once the listener is started inside the host GUI session with keychain signing access.
- Embedded Tailscale support and companion presence advertising are part of the `1.0` contract.
- Same-LAN discovery is implemented and covered by package tests.
- The repo now carries separate mobile app targets for truthful release scoping: the iPhone submission target remains `CodingOnTheGo` / `com.example.codingonthego.ios`, while the repo-native iPad continuation target is `CodingOnTheGoPad` / `com.example.codingonthego.ipad`; the physical-device and simulator iPad wrappers were retargeted accordingly instead of overloading the submission bundle.
- The macOS companion bundle target is now `com.example.codingonthego.companion`.
- The stable verifier now exercises both the iPad split-view inspector flow and the `openWindow` multiwindow request path; only the final visible-second-window assertion remains simulator/XCTest-limited.
- Scene-scoped recent-session sync now preserves distinct iPad windows by merging session records on machine plus scene instead of collapsing sibling windows onto one record.
- Embedded tailnet runtime traffic can be validated from a private local checkout with a `TailscaleKit` runtime artifact plus live credentials on connected iPhone and iPad devices; those artifacts and credentials are intentionally outside the public source tree.
- Networked verification is now proxy-aware: localhost and LAN checks run only after a system proxy or VPN hygiene preflight, while tailnet verification intentionally fails fast when `100.64.0.0/10` or `*.ts.net` bypass rules are missing.
- `scripts/verify_embedded_tailnet_runtime.sh` is the opt-in integration verifier for the embedded route: it checks proxy/tailnet bypass hygiene, validates the vendored native runtime hook, and runs the embedded package tests before a live signed-runtime app session is attempted.
- CloudKit is intentionally out of the `1.0` iPhone submission path and remains deferred to the combined `1.1` iPad + sync release; APNs also remain environment-gated.
- Companion-published endpoint access is optional for live use when ready, but it must not become the only trust root for machine identity or session truth.
- App Store packaging scripts can generate local, ignored review collateral under `marketing/app-store/`, while privacy manifests and in-app reviewer demo mode stay in the checked-in app targets.
- The connection screen now keeps the privacy-policy and support URLs in-app via the production web destinations so review/support flows are accessible without leaving the verified UI path.

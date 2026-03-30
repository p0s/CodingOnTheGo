# Coding On The Go Specification

Version: 2026-04-30
Product scope: **iPhone client (1.0)** + **combined iPad + cross-device sync follow-up (1.1)** + **macOS companion**
Host scope v1: **macOS only**

---
## Confidence legend

- **Confirmed from attached code**
- **Confirmed upstream**
- **Engineering inference**
- **Open risk**

## Contract legend

- **1.0 MUST**: required for the iPhone-first 1.0 product contract and release signoff
- **Later / not 1.0**: intentionally deferred; design for it honestly, but do not turn it into a 1.0 gate
- **Design invariant**: architectural rule that stays true across 1.0 and later work

## 1.0 contract snapshot

### 1.0 MUST
- **Design invariant**: keep route, bootstrap, and protocol separate in code and UX.
- **1.0 MUST**: a reachable Codex app-server websocket is the preferred primary live lane.
- **1.0 MUST**: that websocket may be directly reachable, SSH-forwarded from a loopback listener, or published/managed by the optional macOS companion.
- **1.0 MUST**: SSH stdio over Remote Login remains a required first-pairing, bootstrap, repair, and compatibility fallback lane; it is no longer the preferred steady-state lane once a Codex websocket lane is ready.
- **1.0 MUST**: embedded Tailscale support ships in the app/runtime path.
- **1.0 MUST**: companion presence advertising and optional Codex websocket endpoint publication ship in 1.0.
- **1.0 MUST**: first-pairing and repair still work with existing Codex tooling on the Mac over Remote Login / SSH, with no extra required host daemon, bridge, or service.
- **Design invariant**: browser/history stays host-backed and truthful; local fallback data must never pretend to be live host truth.

### Later / not 1.0
- **Later / not 1.0**: CloudKit / cross-device sync.
- **Later / not 1.0**: making the optional COTG macOS companion the only path or sole trust root.

---
## Executive decisions

1. **Primary runtime stack**
   - **1.0 MUST**: Embedded Tailscale route when a real vendored native runtime is present
   - Same-LAN route
   - **1.0 MUST**: Codex app-server websocket as the preferred live lane when directly reachable or safely forwarded
   - Standard SSH bootstrap for first-pairing, repair, and fallback
   - **1.0 MUST**: `stdio://` Codex app-server over SSH as the fallback repair lane
   - **1.0 MUST**: SSH-forwarded loopback websocket as the zero-install websocket lane after GUI-session readiness proof
   - **Later / not 1.0**: optional COTG macOS companion as the only path or sole trust root

2. **Zero-install first connect**
   - Required on the Mac:
     - Remote Login enabled
     - `Codex.app` installed
     - user signed into Codex on the Mac
     - Tailscale optional but recommended
   - Not required:
     - `npm install`
     - Node bridge
     - relay server
     - manual shell commands
     - LaunchAgent install
     - macOS companion install; it is an optional reliability/presence enhancer, not required for first-pairing or the SSH-forwarded websocket lane
     - helper daemon
     - `codex` on `PATH`

3. **Core mental model**
   - **Design invariant**: **Tailscale or LAN = route**
   - **Design invariant**: **SSH = bootstrap/control**
   - **Design invariant**: **Codex app-server = protocol**

5. **Execution authority contract**
   - **1.0 MUST**: machine capability facts and active executor authority stay separate.
   - **1.0 MUST**: SSH bootstrap resolves a usable Codex runtime by preferring the bundled runtime inside `Codex.app`, then falling back to `command -v codex` only when needed.
   - **1.0 MUST**: on macOS hosts, the preferred live lane is a Codex app-server websocket endpoint in the active GUI session, whether it is reached directly, through SSH forwarding, or via companion-published metadata; SSH may be used as a bootstrap-only control/forwarding channel for that websocket, while raw SSH stdio remains the repair fallback.
   - **1.0 MUST**: treat `config/read` as the baseline host config snapshot, not as the full truth of the active thread/session authority.
   - **1.0 MUST**: derive the active effective execution profile from resolved runtime facts, `config/read`, `configRequirements/read`, persisted session/thread state, supported `thread/start` or `thread/resume` overrides, supported `turn/start` overrides, and session-scoped approval grants.
   - **1.0 MUST**: requested and effective execution profile values stay separate, and any unsupported or unproven field is shown as `unknown` or `unsupported` instead of being implied.
   - **1.0 MUST**: if schema and live runtime disagree, the installed live runtime wins and the mismatch is documented honestly.

4. **Product frame**
   - Fresh, premium mobile-first product called **Coding On The Go**
   - Better multi-machine, multi-route, and iPad UX than Remodex
   - Local-first with optional hosted services only where they add real value
   - Codex product model is **Project -> Thread** first, with Mac identity secondary by default

---
## Short status

### What is working
- The repo contains real iPhone, iPad, and macOS companion targets with shared package boundaries that preserve route, bootstrap, and protocol separation.
- The public repository boundary is part of the release contract: source code is open under Apache-2.0, while private machine identifiers, live credentials, local agent instructions, App Store operations material, private audit logs, and optional vendored runtime binaries stay outside git.
- The localhost zero-install bootstrap/repair lane works over SSH stdio in the shipped iPhone and iPad runtime.
- Shared machine, route, session, sync, secret, workspace, and companion state exists across the package graph and is covered by unit, app, and runtime verification scripts.
- Fresh install now starts in an honest empty onboarding state. Production startup no longer seeds preview machines, fake recent sessions, or fake tailnet profiles.
- Production connection panes now handle “no machine selected” explicitly instead of falling back to preview models.
- Same-LAN discovery is implemented with Bonjour plus cached host probing, and discovered/manual routes merge back into the machine directory instead of living as a disconnected model layer.
- Route evaluation now keeps `configured`, `authenticated`, `reachable`, `eligible`, `recommended`, `active`, and `last-good` separate, so degraded or unavailable tailnet routes do not outrank healthy LAN or manual SSH routes.
- External Tailscale routes are only considered reachable or recommended when the external Tailscale app is installed, and embedded-tailnet SSH bootstrap now resolves through the embedded dial plan only when a native runtime has published a loopback SOCKS5 bootstrap endpoint that the SSH transport can actually use.
- `TailnetEmbedded` now has an explicit vendored-package hook for a local `TailscaleKit` package instead of relying on `canImport(...)` alone, so a signed native runtime artifact can be dropped into a known path without rewriting the package graph.
- The stable local verifier covers package tests, iPhone/iPad app tests, macOS companion tests, localhost SSH stdio fallback, the SSH-forwarded loopback websocket fallback path, and the iPad multiwindow request path.
- Real-host SSH verification proves the non-companion repair path against a reachable Mac where `PATH_CODEX=` is empty but `/Applications/Codex.app/Contents/Resources/codex` is executable: the client resolves the bundled runtime, can run `codex app-server` over SSH stdio for repair/config fallback, and can also use SSH as a bootstrap-only control channel to start and forward the GUI-session websocket listener.
- Real iPhone verification has proved the app can recover the SSH-forwarded websocket lane across relaunch without first decoding a raw stdio app-server session; earlier codesign-sensitive continuation proof also succeeded only after the listener was launched inside the macOS GUI session where keychain signing access is actually available.
- GitHub Actions now runs only cheap syntax/workflow sanity automatically. The expensive macOS hosted-safe tier (package tests, hosted-safe iPhone simulator UI checks, optional extended iPhone simulator UI checks, and macOS companion tests) is manual-only to avoid burning GitHub-hosted macOS minutes; localhost SSH, real-host, iPad split-view simulator proof, and physical-device proofs remain explicitly local or self-hosted only.
- For release signoff on real SSH and Tailscale behavior, the physically connected iPhone route matrix is the source of truth; simulator checks are still useful for UI regression coverage, but they do not replace `./scripts/run_connection_mode_matrix.sh`.
- The app packaging layer includes normalized `com.example.codingonthego.*` identifiers, real asset catalogs, app icons, and privacy manifests. Private App Store operations material stays out of the public source tree.
- Product decision for launch sequencing: the `1.0` App Store submission is iPhone-only so it can reach TestFlight / App Review without resetting on late iPad changes; native iPad support stays in the repo and ships together with cross-device iCloud/CloudKit sync in the planned `1.1` follow-up release.
- The repo-native iPad app is now a separate `CodingOnTheGoPad` target/scheme with bundle identifier `com.example.codingonthego.ipad`, hard-cut from the current iPhone baseline instead of extending the iPhone submission target; iPad-specific simulator and physical wrappers now target that dedicated app while the App Store `1.0` path stays on the iPhone-only `CodingOnTheGo` target with bundle identifier `com.example.codingonthego.ios`.
- The macOS companion still builds locally with the new lowercase identifiers, and the connected iPhone/iPad validation path reran cleanly on 2026-03-30 with successful build, install, and launch on both devices.
- The connection/support surface uses public placeholder privacy and support URLs in the source tree; replace them with canonical production URLs in release-specific private configuration before App Review. The physical iPhone safe lane now completes real smoke-test turns over both direct/manual SSH and the external Tailscale route.
- The source-of-truth product shell is now explicitly Codex-first: top-level tabs are `Codex`, `Connections`, and `Settings`; daily use starts in `Codex`; the default browser model is `Project -> Thread`; and single-Mac browsing stays scoped to the current Mac unless the user opts into cross-Mac mode.
- The shipping iPhone runtime now includes an explicit Advanced `Reviewer demo mode` toggle that swaps the app into bundled Mac, Project, Thread, transcript, and workspace fixtures so beta reviewers can exercise the real app shell without a reachable Mac, SSH trust, or tailnet setup.
- The iPhone Connections onboarding now distinguishes between one obvious saved SSH key and several historical saved SSH keys on the device, so the main setup flow can offer `Use Existing SSH Key` or `Try Existing SSH Keys` before pushing users into `Create SSH Key`.

### What still needs narrow completion or external validation
- Embedded Tailscale runtime validation requires a private local `TailscaleKit` package, real auth, and physical-device end-to-end proof on both iPhone and iPad; those artifacts and credentials stay outside git, and the feature should stay secondary in App Review unless a real reviewer credential path is prepared.
- The app now hard-cuts steady-state live use toward Codex app-server websocket when that lane is advertised, directly reachable, or safely SSH-forwarded; SSH stdio remains first-pairing, repair, and fallback, and any websocket failure falls back with an explicit transport state instead of silently treating stdio as preferred.
- Cross-device iCloud/CloudKit sync is intentionally deferred to the combined `1.1` follow-up release; the `1.0` iPhone submission ships with local-only metadata persistence.
- APNs is intentionally not part of the 1.0 submission candidate. Local/product notification behavior remains in scope, but push capability should stay disabled unless it is fully wired and signed in a later release.
- The current release train stays on `MARKETING_VERSION = 0.9.1` and `CURRENT_PROJECT_VERSION = 9`; do not flip to `1.0` until the remaining release-ops items are finished and the intended App Review build is attached.
- A live App Review host / demo credentials set is now optional rather than mandatory for beta review because the app can fall back to reviewer demo mode; only provide a reachable host if Apple should validate the true end-to-end SSH transport during App Review.
- XCTest on the current iPad simulator still cannot reliably prove the second visible app window after `openWindow`, so multiwindow automation remains partially gated by the platform test harness rather than the app code.

---
## Development note aliases

Use private, non-identifying machine aliases in notes:

- **p** = primary development Mac
- **c** = secondary development Mac

---
## Research basis

### Attached-code inspection summary

#### Remodex
- **Confirmed from attached code**: Remodex is not just an iOS front-end for `codex app-server`. It contains:
  - a Swift iOS app
  - a Node bridge (`phodex-bridge`)
  - optional relay / push plumbing
  - macOS launch agent helpers
- **Confirmed from attached code**: `CodexService+Transport.swift` implements multiple websocket transport paths, including a manual TCP websocket path meant to work around iOS/network stack issues on local/private transports.
- **Confirmed from attached code**: `CodexService+SecureTransport.swift` implements a product-specific secure pairing / trusted reconnect layer that does not come from upstream `codex app-server`.
- **Confirmed from attached code**: `phodex-bridge/src/git-handler.js` and `workspace-handler.js` provide product-owned Git/workspace RPC methods such as status, diff, commit, branch, worktree, and reverse-patch preview/apply.
- **Confirmed from attached code**: `macos-launch-agent.js` manages a background bridge service via launchd.
- **Confirmed from attached code**: the iOS app includes queueing, notifications, voice, thread fork, desktop handoff, and runtime-compatibility handling.

#### Litter
- **Confirmed from attached code**: Litter’s iOS client uses SSH as an orchestration path, including remote Codex capability checks and SSH port forwarding.
- **Confirmed from attached code**: `SSHSessionManager.swift` checks whether the remote Codex binary supports websocket app-server transport, launches it remotely, and sets up a local SSH forward to remote loopback.
- **Confirmed from attached code**: Litter stores SSH credentials in Keychain with `ThisDeviceOnly`, which avoids sync but does not meet this product’s cross-device secret goal.
- **Confirmed from attached code**: Litter performs Bonjour and LAN discovery, and also probes Tailscale local surfaces such as `100.100.100.100`.
- **Confirmed from attached code**: Litter is a strong reference for SSH bootstrap and discovery, but its current route/session model is not the premium Codex-first, repo/session-first UX target for this product.

#### Omnara
- **Confirmed from attached code**: Omnara relies heavily on a relay/server model with real-time session visibility and multi-client synchronization.
- **Confirmed from attached code**: it is useful as a reference for remote visibility, dashboarding, and session observation patterns, not as a local-first zero-install baseline.

#### Clawdex Mobile
- **Confirmed from attached code**: Clawdex uses a host-side authenticated bridge service with custom REST/WS endpoints and a setup wizard. This is not a zero-install baseline.
- **Confirmed from attached code**: it is useful as a reference for onboarding, host auth token UX, and reconnect/event replay patterns.

#### RustDesk
- **Confirmed from attached code**: RustDesk is useful as a reference for persistent peer directories, reconnect UX, and session recovery behavior.
- **Confirmed from attached code**: because of AGPL, it must be treated as pattern inspiration only.

### Upstream research summary

- **Confirmed upstream**: `codex app-server` is the interface OpenAI uses for rich clients and supports bidirectional JSON-RPC over **stdio (default JSONL)** and **websocket (experimental)**.
- **Confirmed upstream**: loopback websocket listeners remain appropriate for localhost and SSH port-forwarding workflows, while non-loopback websocket listeners are not safe to expose by default unless websocket auth is configured.
- **Confirmed upstream**: app-server already exposes threads, turns, steer, interrupt, review, approvals, model listing, filesystem APIs, command execution APIs, skills, apps/connectors, and auth/account surfaces.
- **Confirmed upstream**: libtailscale embeds a userspace Tailscale node inside a process, exposes a configurable control URL, can create several nodes in one app, provides a loopback SOCKS5 proxy with credentials, and supports direct outgoing/incoming connections.
- **Confirmed upstream**: Headscale is a self-hosted control server path for Tailscale-compatible clients, and Tailscale documents custom control server login flows.
- **Confirmed upstream**: Apple’s current Service Management guidance centers on `SMAppService` for login items / helpers on macOS 13+.
- **Confirmed upstream**: direct-download macOS apps signed with Developer ID and distributed outside the Mac App Store need notarization.
- **Confirmed upstream**: `CKSyncEngine` is the current Apple sync engine for CloudKit sync flows, and `kSecAttrSynchronizable` is the Apple-native hook for synced Keychain items.

---
## Core architecture

### 1) Route / bootstrap / protocol separation

This project should never collapse these layers into one vague “connection” concept.

| Layer | Definition | Examples | Why it matters |
|---|---|---|---|
| Route | Network path to the host | embedded tailnet, external tailnet, LAN, manual SSH address, direct Codex websocket endpoint | Users can save several routes for one Mac |
| Bootstrap | How the host is verified, started, or upgraded | Remote Login SSH, companion control channel | Bootstrap determines setup UX and recoverability |
| Protocol | How the running Codex surface is spoken to | SSH stdio, SSH-tunneled loopback websocket, direct Codex app-server websocket | Different transports have different latency, safety, and reconnect behavior |
| Execution profile | The active authority contract for this session/thread | approval policy, sandbox mode, writable roots, readable roots, network access, runtime provenance | The app must preserve and communicate actual authority, not infer it from route or host facts |

**Engineering inference**: treating these separately is the cleanest way to support multiple saved Macs, multiple routes per Mac, fast reconnect, and future companion upgrades without repeating state logic.

### 2) Connection modes

| Mode | Route | Bootstrap | Protocol | Default? | Notes |
|---|---|---|---|---|---|
| Codex websocket live lane | Direct endpoint, SSH-forwarded loopback, or companion-published endpoint | Direct readiness, SSH forwarding, or companion-managed readiness | Codex app-server websocket | Yes, when ready | **1.0 MUST** preferred steady-state live lane |
| SSH bootstrap / repair | Embedded Tailscale or LAN | Standard SSH | SSH stdio app-server | Fallback | **1.0 MUST** first-pairing, repair, and fallback lane |
| SSH websocket fallback | Connected SSH fallback with host websocket support | Standard SSH + remote reuse check | SSH-tunneled loopback websocket | Automatic when proven safe | **1.0 MUST** fallback websocket lane; must fall back or refuse explicitly on failure |
| Advanced manual | Manual route | User-managed | Manual endpoint | No | Recovery / debugging only; not a 1.0 trust root |

### 3) Recommended runtime priority + fallback stack

This is both the **implementation priority** and the **runtime route/transport preference order**.

1. **Codex app-server websocket** when directly reachable, SSH-forwarded, or companion-published and ready
2. **Embedded Tailscale route** for fallback reachability
3. **Same-LAN** route for fallback reachability
4. **Standard SSH bootstrap** with app-managed auth for first-pairing and repair
5. **SSH-forwarded loopback websocket** only as a proven GUI-session fallback over the same SSH connection
6. **`stdio://` app-server over SSH** as the repair fallback
7. **Manual direct endpoint / rescue tools** only in advanced settings

### 3a) Route recommendation and eligibility invariants

- Route evaluation must keep the following states separate in code and UX:
  - configured
  - authenticated
  - connected
  - reachable
  - eligible
  - recommended
  - active
  - last-good
- Embedded tailnet routes must not be treated as SSH-bootstrap-ready unless the embedded dial plan exposes a real native SSH-capable transport path.
- External tailnet routes must not be treated as reachable or recommended when the required external Tailscale app is unavailable on the client.
- Same-LAN and manual SSH routes must outrank degraded or not-ready tailnet routes when they are the healthiest eligible paths.

#### Why this order
- **Confirmed upstream**: stdio is the default, documented, production path for app-server, while websocket is explicitly experimental.
- **Confirmed upstream**: loopback websocket is acceptable for localhost and SSH forwarding, so it is the right zero-install websocket path when no directly reachable endpoint is available.
- **Engineering inference**: companion-managed websocket should be the preferred live lane because it provides durable presence, faster reconnect, and a host-side owner for endpoint reuse.
- **Engineering inference**: embedded Tailscale and LAN remain route choices for fallback reachability, not higher-priority live protocols than a ready Codex websocket endpoint.
- **Later / not 1.0**: CloudKit / cross-device sync and the optional COTG macOS companion as the only trust root are deliberately deferred; do not treat either as a hidden 1.0 requirement.


### 4) Proposed mono-repo layout

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
│   ├── HostBootstrap
│   ├── CodexRPC
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

### 5) Module responsibilities

- `SharedModels`: machine, route, tailnet, capability, session, and sync DTOs
- `Persistence`: JSON machine-directory storage and local projections
- `SyncEngine`: `CKSyncEngine` bridge and conflict policy
- `Secrets`: Keychain wrappers and access-group handling
- `Discovery`: Bonjour, LAN probes, cached route reachability, companion advertisements
- `TailnetEmbedded`: libtailscale/TailscaleKit wrapper
- `SSHTransport`: auth, host keys, exec, forwarding, file staging
- `HostBootstrap`: Remote Login + Codex detection and app-server startup
- `CodexRPC`: transport-independent JSON-RPC session
- `RouteSelection`: route scoring, recommendations, failover, reconnect heuristics
- `GitWorkspace`: Git/workspace wrappers for mobile UI
- `Notifications`: local + hosted push coordination
- `CompanionHost`: companion-managed services and direct endpoint support


---
## What `codex app-server` already gives us

The current upstream app-server surface is richer than many earlier Codex integrations assumed.

| Capability | Status |
|---|---|
| Threads and turns | **Confirmed upstream** |
| Resume and fork threads | **Confirmed upstream** |
| Steer active turns | **Confirmed upstream** |
| Interrupt active turns | **Confirmed upstream** |
| Review mode | **Confirmed upstream** |
| Streaming item / delta events | **Confirmed upstream** |
| Approvals for commands and file changes | **Confirmed upstream** |
| `command/exec` and PTY control | **Confirmed upstream** |
| Filesystem APIs (`fs/*`) | **Confirmed upstream** |
| Model listing + reasoning effort + image modality | **Confirmed upstream** |
| Skills and apps/connectors listing | **Confirmed upstream** |
| Account/auth endpoints and rate-limit surfaces | **Confirmed upstream** |

### Product consequence
**Engineering inference**: Coding On The Go should treat app-server as the canonical conversation, review, and approval protocol, not as an optional side surface. The missing product work is around route management, host bootstrap, reconnect, machine directory UX, Git/workspace helpers, and mobile-specific orchestration.

---
## What Remodex has that `codex app-server` does not give us directly

| Feature area | Does app-server directly provide it? | Conclusion |
|---|---|---|
| Secure QR pairing / trusted reconnect state | No | Real product-layer work |
| Custom route directory / multi-machine UX | No | Real product-layer work |
| Bridge-owned Git RPC | No | Wrapper / reimplementation needed |
| Workspace revert preview/apply UX | No | Wrapper / reimplementation needed |
| Mobile push pipeline | No | Product-layer work |
| Host launch agent lifecycle | No | Product-layer work |
| Mobile voice transcription UX | No | Product-layer work |
| Desktop handoff UX | No | Product-layer work |
| Websocket transport workarounds for iOS/private routes | No | Product-layer work |
| Zero-install SSH bootstrap | No | Product-layer work |

**Confirmed from attached code**: Remodex implements most of these itself.

---
## Why Remodex did not simply use only `codex app-server`

**Confirmed from attached code**: Remodex needed all of the following beyond app-server:
- a secure pairing / trusted reconnect system
- its own bridge-side Git and workspace operations
- iOS-specific websocket transport handling
- launchd background service behavior
- push / relay features
- Mac handoff and runtime compatibility handling

**Engineering inference**: Remodex’s bridge exists because app-server alone solves the **agent protocol**, not the whole **mobile product**. Coding On The Go should accept that lesson, but avoid inheriting Remodex’s product shape or bridge dependency.

---
## Exactly what the downsides of the zero-install approach are

| Downside | Why it matters | Product response |
|---|---|---|
| SSH session lifetime is fragile on mobile backgrounding | Backgrounded iOS apps can lose network continuity | Cache session state aggressively; restore fast; companion improves this later |
| No always-on host presence without companion | Pure zero-install cannot advertise rich presence as well | Add companion-enhanced presence after first success |
| Notifications are weaker without host helper state | Reliable push is easier with a companion | Ship best-effort zero-install notifications, companion for reliable mode |
| Image/file staging is less ergonomic than a custom bridge | app-server does not natively ingest device photo bytes as a first-class mobile upload concept | Stage files over SSH to a remote cache directory |
| Git/workspace surfaces need client wrappers | app-server gives exec/fs primitives, not polished mobile Git UX | Implement original wrappers on top of exec/fs/SSH |
| SSH auth and host-key UX is harder than QR pairing | TOFU, fingerprinting, passwords, and keys need careful UI | Invest heavily in setup UX and actionable errors |
| Remote listener reuse is harder without a companion | No durable service to keep it warm | Use companion as the preferred live lane; fall back to SSH stdio or SSH-forwarded websocket for first-pairing and repair |
| Host capability detection must be done each time or cached carefully | Different Mac configs and Codex versions matter | Add capability snapshots + health cache + explicit version parsing |

**Product decision**: keep SSH for first-connect simplicity and repair, but hard-cut steady-state live mirroring toward a Codex app-server websocket lane whenever one is directly reachable, SSH-forwardable, or companion-published.

---
## Feature mapping: direct app-server vs wrappers vs reimplementation

| User-visible feature | Direct app-server | Wrapper / orchestration | Full product reimplementation |
|---|---|---|---|
| Start / resume / fork threads | Yes | thin client adapter | No |
| Steer active runs | Yes | UI queue + state logic | No |
| Queue follow-up prompts while a run is in progress | No | Yes | No |
| Fast / plan / reasoning controls | Mostly yes (`model/list`, turn settings, plan/reasoning events) | Yes | No |
| Subagents | Partially surfaced upstream | Yes, subagent-aware UI/state required, including a client-orchestrated fallback when protocol-native agents are absent | No |
| Photo attachments | Partially (image modalities, `localImage`) | Yes: remote file staging | No |
| Git UI actions | No | Yes | No |
| Workspace revert preview / apply | No | Yes | No |
| Voice input | No | No | Yes |
| Notifications | No | Yes | Yes |
| Codex Mac app handoff | No | Yes | Yes |
| Machine directory / multi-route UX | No | No | Yes |
| Built-in Tailscale sign-in / tailnet management | No | No | Yes |
| Cross-device machine sync | No | No | Yes |
| Fast reconnect / route failover | No | Yes | Yes |
| Companion-enhanced presence | No | No | Yes |

---
## Host bootstrapping and live-lane flow

### Primary flow
1. User selects a machine or route candidate.
2. App resolves the best healthy route for that machine.
3. If the machine has a reachable Codex app-server websocket endpoint, the app opens that live lane first.
4. If no direct websocket endpoint is reachable, the app opens SSH using saved credentials or guided auth for first-pairing, websocket forwarding, repair, or fallback.
5. App verifies:
   - Remote Login reachable
   - host key trusted / accepted
   - `codex` exists
   - app-server capability snapshot
   - workspace / Git root if needed
6. On SSH fallback, the app starts or reuses `codex app-server`, preferring a GUI-session loopback websocket with SSH forwarding when capability and listener checks pass.
7. Client performs `initialize` → `initialized`.
8. App resumes the prior thread context or starts a new thread on the same proven live lane.

### Important constraints
- **Confirmed upstream**: stdio is the default app-server transport.
- **Confirmed upstream**: websocket is experimental.
- **Engineering inference**: the client must not require websocket for first-pairing or repair, but once a Codex app-server websocket lane is ready it should be preferred over raw SSH stdio; any mobile websocket failure must fall back or refuse with explicit transport state instead of silently lingering on the wrong lane.

---
## Machine / route / session model

### Core entities

#### `MachineRecord`
Represents the logical Mac, independent of any one route.

Suggested fields:
- `machineID`
- `displayName`
- `platform = macOS`
- `stableHostFingerprint`
- `lastKnownUser`
- `lastConnectedAt`
- `preferredRouteID`
- `lastSuccessfulRouteID`
- `capabilitySnapshotID`
- `notes`
- `isPinned`
- `sortRank`

#### `RouteRecord`
One connectivity path to a machine.

Suggested fields:
- `routeID`
- `machineID`
- `routeType`:
  - `embeddedTailnet`
  - `externalTailnet`
  - `localLAN`
  - `manualSSH`
  - `companionDirect`
- `tailnetProfileID?`
- `hostname`
- `ipAddress`
- `magicDNSName`
- `sshPort`
- `usernameHint`
- `companionEndpoint?`
- `requiresExternalApp`
- `lastHealth`
- `lastLatencyMs`
- `lastSuccessAt`
- `lastFailureAt`
- `failureReasonCode`
- `isRecommended`
- `isUserPinned`
- `discoverySource`
- `trustState`

#### `TailnetProfile`
One saved embedded or external tailnet profile.

Suggested fields:
- `tailnetProfileID`
- `profileType = embedded | external`
- `displayName`
- `controlURL`
- `accountLabel`
- `tailnetDNSName`
- `isActive`
- `lastActivatedAt`
- `supportsCustomControlServer`
- `requiresExternalApp`

#### `HostCapabilitySnapshot`
Cached host/runtime capabilities.

Suggested fields:
- `snapshotID`
- `machineID`
- `capturedAt`
- `codexVersion`
- `supportsAppServer`
- `supportsWebsocketListen`
- `supportsReview`
- `supportsThreadFork`
- `supportsApprovals`
- `supportsCommandExec`
- `supportsFSAPI`
- `supportsImageInputs`
- `gitVersion`
- `companionVersion`
- `companionState`
- `codexAppInstalled`
- `hostOSVersion`

#### `SessionRecord`
Recent reconnect context, not authoritative conversation history.

Suggested fields:
- `sessionID`
- `machineID`
- `routeID`
- `transportMode = sshStdio | sshWsTunnel | companionDirect`
- `threadID`
- `reviewThreadID?`
- `cwd`
- `lastModel`
- `lastReasoningEffort`
- `lastMode = local | worktree`
- `lastTurnID`
- `lastSeenAt`
- `resumeStrategy`
- `uiStateBlob`

#### `CredentialRef`
Non-secret pointer to Keychain material.

Suggested fields:
- `credentialRefID`
- `kind = sshKey | password | token | companionMutualAuth`
- `keychainAccount`
- `label`
- `isSynchronizable`
- `lastValidatedAt`

### UX implications
The top-level directory should always show logical machines first, then routes nested beneath them or inline-expanded beneath them.

Example labels:
- `MacBook 1 via Tailscale`
- `MacBook 1 via local`
- `MacBook 1 via companion`

The user should always be able to see:
- machine identity
- route type
- active route
- recommended route
- route health
- last used route
- last health check
- current reachability state

---
## Built-in Tailscale design

### Chosen direction
**Engineering inference**: v1 should use an **app-scoped embedded userspace Tailscale node** via libtailscale/TailscaleKit rather than making a full device-wide VPN / Packet Tunnel the default requirement.

### Why
- **Confirmed upstream**: libtailscale is designed to embed Tailscale into a process, entirely from userspace.
- **Confirmed upstream**: the Swift wrapper exposes:
  - configurable `controlURL`
  - multiple nodes in one application
  - loopback SOCKS5 proxy credentials
  - direct outgoing connections
  - incoming listeners
- **Engineering inference**: because Coding On The Go only needs its own traffic to reach the host, an app-scoped userspace node is the cleanest v1 plan.
- **Engineering inference**: avoiding a full VPN-style Packet Tunnel by default reduces entitlement, UX, and App Review complexity for the core product path.

### Embedded tailnet package responsibilities
Create `TailnetEmbedded` with:
- `TailnetProfileStore`
- `EmbeddedTailnetNodeManager`
- `EmbeddedTailnetAuthCoordinator`
- `TailnetRoutePublisher`
- `TailnetHealthMonitor`
- `TailnetDialerAdapter`

### Tailnet profile behavior
- Many saved tailnet profiles: **yes**
- One active embedded tailnet at a time in v1: **yes**
- Fast switching between embedded tailnets: **yes**
- Multiple active host sessions within one active embedded tailnet: **yes, where resource limits allow**
- True simultaneous multi-tailnet embedded traffic in v1: **not required**

### Embedded login options
- Web auth flow
- Auth key flow
- Custom control server URL
- Sign-out and switch profile
- Route health after activation

### Headscale / custom control servers
- **Confirmed upstream**: libtailscale exposes `controlURL`.
- **Confirmed upstream**: Tailscale and Headscale docs support custom control server login flows.
- **Product decision**: `TailnetProfile` must store `controlURL` per profile and clearly label non-default control planes in the UI.

### Open risks
- **Open risk**: embedded libtailscale shipping posture on iOS App Store needs early build, QA, and review validation even though the library technically supports the required userspace modes.
- **Open risk**: custom control servers may have materially different performance and reliability depending on DERP/STUN setup.

---
## How built-in Tailscale should be embedded in an App Store-ready iOS/iPadOS app

### Recommended answer
1. Embed libtailscale/TailscaleKit behind a private Swift package.
2. Keep the Tailscale wrapper **app-scoped** and **replaceable**.
3. Do not expose raw libtailscale types to the rest of the app.
4. Make route and session logic independent of whether the route is embedded or external.
5. Defer any full device-VPN / Packet Tunnel implementation unless a later product need clearly demands it.

### App packaging guidance
- Keep local-network privacy declarations correct for LAN discovery.
- Keep Tailscale auth, tailnet profile state, and connection status explicit in settings.
- Never make the separate Tailscale iOS app a hard dependency.
- Treat embedded tailnet activation as one route source among several.

---
## How to support both embedded Tailscale and the external Tailscale app cleanly

### Product model
The same machine can have multiple routes:

- Embedded Tailscale route
- External Tailscale route
- LAN route
- Manual SSH route
- Direct Codex websocket route

### Clean interoperability rules
- Route records are independent of the connectivity implementation.
- External Tailscale routes are just ordinary reachable hostnames/IPs from the system network perspective.
- Embedded routes are managed by the app and tied to a `TailnetProfile`.
- The route picker can show both at once.

### UX rules
- Show whether a route is:
  - `Embedded Tailscale`
  - `External Tailscale`
  - `Local`
  - `Companion`
- Show whether external Tailscale is:
  - available
  - not installed
  - installed but not currently providing reachability
- Do not force the user to choose a global one-time networking mode.

---
## How to support Headscale / custom control servers

### Embedded mode
- Add custom control server during tailnet profile creation.
- Store `controlURL`, display name, account label, and tailnet DNS metadata.
- Keep per-profile auth state separate.
- Surface custom-control-server errors distinctly from general auth failures.

### External mode
- Treat the external Tailscale app as outside our direct lifecycle control.
- Allow manual route entry or import of known machine routes.
- Validate reachability and surface actionable errors if the external tailnet path is down.

### Operational note
- **Confirmed upstream**: Tailscale’s docs expose custom control server support on Apple clients.
- **Engineering inference**: Coding On The Go should keep the control-server concept first-class in the model, not hidden deep in settings.

---
## LAN discovery design

### Why LAN matters
- It is the required fallback when embedded tailnet is not active.
- It improves desk-side onboarding.
- It provides a path even when Tailscale is intentionally unavailable.

### Discovery methods
1. Cached route probes for known machines
2. Bonjour discovery of `_ssh._tcp`
3. Companion service advertisement (custom Bonjour service later)
4. Targeted subnet reachability checks for remembered hosts
5. Manual add

### Privacy / platform implications
- **Confirmed upstream**: local-network privacy strings and Bonjour service declarations belong on the app target’s `Info.plist`.
- **Product decision**: only request local-network access when the user triggers LAN discovery or selects a LAN route.

### Discovery output
Discovery never creates a new machine blindly when a known fingerprint matches an existing machine. Instead:
- update the route record
- refresh health
- preserve the logical machine identity

---
## SSH transport design

### Chosen direction
Build `SSHTransport` on top of **SwiftNIO + NIOSSH** with a project-owned adapter surface.

### Why not Tailscale SSH as the default requirement
- **Engineering inference**: standard macOS Remote Login is more universal for this product than requiring Tailscale SSH specifically.
- **Product decision**: standard SSH over embedded Tailscale or LAN is the default bootstrap contract.
- **Open risk**: some Tailscale-specific UX may tempt a later shortcut; do not let that collapse the route/bootstrap separation.

### Supported auth methods
- Password
- Ed25519 private key
- RSA private key
- Optional passphrase
- Future: hardware-backed key flows if needed

### Host key trust
- TOFU with explicit fingerprint display
- Host-key mismatch is blocking and requires explicit user action
- Persist accepted host keys in secure storage
- Never silently overwrite a mismatched host key

### SSH capabilities required
- Command execution
- Stdio streaming
- Port forwarding
- File staging for attachments / temporary assets
- Optional long-lived control session reuse

### Bootstrap probes
During first successful SSH connect:
- detect shell
- detect `codex`
- parse `codex --version`
- probe `codex app-server --help`
- determine websocket support
- detect git
- detect Codex app installation if handoff is requested
- detect companion if installed

---
## `codex app-server` integration design

### Client transport interfaces
```swift
protocol CodexTransport {
    func send(_ message: Data) async throws
    func receive() async throws -> Data
    func close() async
}

protocol CodexSessionBootstrapper {
    func start(for route: RouteRecord, mode: TransportPreference) async throws -> CodexTransport
}
```

### Transport implementations
- `SSHStdioTransport`
- `SSHTunneledWebSocketTransport`
- `CompanionDirectTransport`

### Initialization contract
- Always send `initialize`
- Always send `initialized`
- Cache server capability snapshot by Codex version
- Opt into experimental API only when the client actually uses experimental surfaces

### Thread / turn handling
- `config/read`, `configRequirements/read`, optional `config/value/write` plumbing
- `thread/start`, `thread/resume`, `thread/fork`, `thread/read`, `thread/list`
- `turn/start`, `turn/steer`, `turn/interrupt`
- `review/start`
- generic approval / user-input / tool server-request routing
- item stream fan-out to UI

### Execution profile rules
- Persist both:
  - baseline host config snapshot from `config/read`
  - active effective execution profile for the session/thread
- Prefer bundle-runtime discovery order for SSH bootstrap:
  1. `/Applications/Codex.app/Contents/Resources/codex`
  2. `~/Applications/Codex.app/Contents/Resources/codex`
  3. other discovered `Codex.app` bundle runtimes
  4. `command -v codex`
- Runtime provenance must be recorded with the active profile.
- `thread/resume` overrides must only be treated as supported when the live runtime actually honors them.
- Current live runtime truth on the installed host: the schema advertises `thread/resume` execution overrides, but the installed runtime ignores them; the client must therefore mark resume override support as unsupported for that runtime and reapply desired authority on `turn/start`.
- Session-scoped permission grants widen the effective profile and must be persisted.
- Unknown or unsupported authority fields must stay unknown or unsupported in UI/state instead of falling back to machine-level booleans.

### Queueing follow-up prompts
- **Confirmed upstream**: `turn/steer` exists
- **Engineering inference**: queueing follow-up prompts while a run is busy still requires product-owned state
- Implement:
  - `QueuedDraft`
  - per-thread queue
  - pause/resume
  - explicit “send as steer” vs “send as next turn” behavior

### Image attachments
- Stage selected photos to a remote cache directory via SSH file upload
- Send them as `localImage` references in `turn/start`
- Garbage-collect staged files by age and session ownership

### Git / workspace operations
Build an internal `HostOps` layer that can run via:
- SSH `command/exec`
- SSH raw shell exec
- direct Codex app-server websocket host service
- macOS GUI-session listener launch for parity-sensitive loopback reuse when keychain/signing access differs from raw SSH stdio

Do **not** design Git/workspace UI directly against shell strings in feature views.

---
## Codex websocket live lane vs SSH fallback lanes

### Codex websocket primary live lane
- Codex app-server websocket endpoint is reachable directly or through SSH forwarding
- optional companion may publish endpoint readiness or keep a GUI-session listener warm
- client connects to the proven Codex app-server websocket endpoint when ready
- preferred for live mirroring, reconnect, and parity-sensitive work

### SSH bootstrap / repair lane
- SSH can exec `codex app-server` over JSONL stdio for repair/config fallback
- SSH can also hold a bootstrap-only control channel for listener startup and port forwarding when the websocket lane is preferred
- least host setup
- highest compatibility for first-pairing and repair

### SSH-forwarded websocket lane
- SSH probes whether websocket listen is supported
- SSH starts or reuses loopback-only listener
- SSH forwards local port → remote `127.0.0.1:PORT`
- client speaks websocket through the SSH tunnel
- only used when health checks pass

### Selection policy
- Prefer a Codex app-server websocket lane when readiness is proven.
- Use SSH stdio for first-pairing, repair, or compatibility fallback when no websocket lane is ready.
- Use SSH to start/reuse and forward a GUI-session websocket only after:
  - host capability snapshot says websocket supported
  - loopback listener startup succeeded
  - SSH port forward healthy
  - websocket handshake healthy
- fallback or refuse explicitly on any listener, forward, websocket, or endpoint readiness error

---
## Reconnect flow

### Goals
- Reopen app → show last machine immediately
- restore prior route preference
- reconnect fast without re-pairing
- recover even when the best route changed

### Reconnect stages
1. Restore last `SessionRecord`
2. Score candidate routes for the machine
3. Try the proven Codex app-server websocket lane first when advertised or restorable
4. Score network routes for fallback reachability
5. Reopen SSH with stored credentials / host-key trust when direct websocket is unavailable, forwarding is needed, or repair is needed
6. Resume thread if available
7. Rehydrate approval / run state from thread status and events

### Route scoring factors
- user pinning
- active embedded tailnet
- recent success
- recent latency
- recent failure streak
- companion availability
- route freshness

### Important UX rule
The UI must not force the user to reason about app-server transport selection during normal reconnect. Show the chosen route; hide the protocol unless needed.

---
## Product shell and machine directory design

### Top-level shell
The top-level navigation is:

- `Codex`
- `Connections`
- `Settings`

### Daily home
The daily home is **Codex**, not **Machines**, not **Connections**, and not a dashboard.

Default behavior:
- successful setup returns the user to `Codex`
- no session selected opens the repo/session browser immediately on iPhone
- default browsing scope is the current Mac only
- machine context becomes prominent only when more than one Mac exists or the user explicitly enables cross-Mac browsing

### Codex shape
Codex should feel like a remote native Codex client.

Rules:
- transcript is the focal surface
- the browser is repo-first and session-second
- iPhone uses a full-screen transcript with a browser sheet or drawer
- iPad uses an adaptive split layout with sidebar browser, transcript main pane, and inspector on demand
- daily use must not start with hero copy, marketing framing, chip clouds, or machine cards above the transcript

### Browser shape
The Codex browser should be a native hierarchical browser, not a card catalog.

Required sections:
- `Recent`
- `Repos`

Required behavior:
- each repo expands to show sessions
- `New session` is a repo-scoped action
- `Resume existing session` remains distinct from `Start new session`
- if repo inventory is unavailable, show an honest empty state instead of a fake local path fallback

### Connections shape
`Connections` owns setup, route use, repair, route verification, trust, advanced diagnostics, and adding Macs.

The screen must separate three jobs instead of mixing them:
1. **Set up this iPhone**
   - required once per Mac on this iPhone
   - detect Mac
   - choose Mac account
   - set up SSH access
   - verify the Mac fingerprint
2. **Ways to connect**
   - separate nearby paths from away-from-home paths
   - let the user add and prioritize more than one viable route for the same Mac
   - keep the default fallback path visible without forcing the user into diagnostics first
3. **Technical details**
   - diagnostics, raw route state, recovery, manual rescue routes, tailnet profiles, forgetting saved Macs, testing-heavy information
   - secondary by default

Happy path:
1. detect Mac
2. choose Mac account
3. set up SSH access
4. verify the Mac fingerprint
5. use on same Wi-Fi
6. add away-from-home fallback
7. open Codex
8. start coding

### Machine directory shape
The machine directory lives inside `Connections`, not as the default daily home.

When the user is still onboarding, the root actions should be split into:
- `Same Wi-Fi or nearby`
- `Away from home`

For each machine show:
- display name
- platform badge
- active route label
- route health summary
- last active time
- status pill: active / idle / unreachable / attention
- if recommended route differs from current route, show that recommendation subtly

### Connections detail screen
Each machine detail page inside `Connections` should include:
- a compact machine summary
- an always-visible `Set up this iPhone` section
- an always-visible `Ways to connect` section
- nearby, away-from-home, and saved-route-priority actions grouped clearly instead of duplicated across multiple cards
- recent sessions
- a collapsed `Technical details` section for diagnostics, manual rescue routes, tailnet profiles, forgetting a saved Mac, and deeper recovery tools

The main pane must not require users to open `Recovery and advanced` for standard SSH setup. If SSH login and host trust are universal prerequisites, they belong in the primary setup flow, not in recovery.

### Why this matters
**Engineering inference**: the product needs both a logical machine directory and a Codex-first daily shell. Putting the machine directory inside `Connections` preserves the clean multi-route model without forcing a machine-first mental model during normal coding.

---
## Sync / CloudKit / Keychain strategy

### What syncs across iPhone and iPad
- machines
- route records
- tailnet profile metadata
- UI preferences
- recent session metadata
- known machine metadata

### What does not go into normal synced records
- raw passwords
- private keys
- bearer tokens
- host-key secrets

### Chosen direction
- Local store: **JSON machine-directory persistence plus local projections** for on-device UX
- Cloud sync: **CloudKit private database via `CKSyncEngine`**
- Secrets: **Keychain**, with synchronizable items where appropriate, using shared access groups between app targets when needed

### Why
- **Confirmed upstream**: `CKSyncEngine` is Apple’s current sync engine for CloudKit operations
- **Confirmed upstream**: `kSecAttrSynchronizable` is the Apple-native way to sync eligible Keychain material through iCloud Keychain
- **Engineering inference**: explicit CloudKit sync gives better control than trying to auto-sync everything, especially because routes, health, and recent sessions have different merge semantics

### Merge semantics
- User-authored metadata: last-writer-wins with conflict journaling if necessary
- Health / reachability fields: device-local, not globally authoritative
- Recent sessions: append + prune
- Preferred route per machine: user-authored, sync-worthy
- Secrets: Keychain only

### Secret sync fallback
- If iCloud Keychain is unavailable, store secrets locally and mark them `This Device Only`
- Surface this clearly in the credential UI

---
## Auth / trust model

### Trust anchors
1. SSH host key trust
2. Stored credential reference
3. Tailnet profile / control server identity
4. Companion mutual trust (when installed)
5. Route health + capability snapshot

### Core rules
- A new mobile device must **not** displace an existing trusted device
- Trust is per user/account + per device credential, not “one phone at a time”
- The same Mac can be used from iPhone and iPad concurrently when the route/protocol path allows it

### Companion trust
- Companion uses the same logical machine identity but publishes extra capabilities
- Companion-published direct mode requires separate mutual authentication and endpoint trust
- Companion is an enhancement, not the original trust root

---
## Git and workspace feature design

### Required user-visible capabilities
- status
- diff
- commit
- push / pull
- branch switch/create
- worktree awareness
- revert preview / apply
- show dirty state clearly
- tie actions to the current thread/workspace

### Implementation direction
Build `GitWorkspace` as an internal abstraction over:
- `command/exec`
- raw SSH shell exec
- optional companion-published direct operations

### Workspace revert preview / apply
Implement a clean original version of:
- patch analysis
- reverse-apply check
- conflict summary
- apply after preview passes

Suggested implementation methods:
- `git diff --no-ext-diff`
- `git apply --reverse --check`
- `git apply --reverse`
- repo mutation lock per workspace

### Why not make Git a first-class custom host daemon requirement
Because the zero-install baseline must work with standard SSH and Codex only.

---
## Voice feature design

### v1 answer
Implement voice input on the client using Apple speech APIs.

### Why
- Keeps voice independent of host setup
- Avoids making the Mac do mobile speech work
- Works with both zero-install and companion-enhanced sessions

### UX
- tap-to-dictate in composer
- insert into draft
- clear permission explanation
- preserve drafts if transcription fails

---
## Notifications / push design

### Requirement reality
Notifications are a must-have product feature, but reliable long-duration completion notifications are easier with a host-side durable component.

### v1 design
1. **Local notifications**
   - while app is foregrounded or background-refresh window exists
2. **Best-effort zero-install completion notifications**
   - opportunistic and session-bound
3. **Reliable enhanced notifications**
   - provided by the macOS companion via optional hosted push broker

### Product honesty
- **Engineering inference**: pure zero-install sessions cannot match companion reliability for long-running background completion notifications on iOS.
- **Product decision**: do not block v1 on perfect zero-install push reliability; make the feature good in zero-install and excellent in companion mode.

### Hosted service posture
Allowed only for:
- APNs fan-out
- device registry
- notification delivery metadata
- diagnostics / crash reporting (opt-in)

---
## iPhone UX

### Principles
- quickest path back to the last repo/session
- calm transcript-first navigation
- composer optimized for one-handed use
- minimal ceremony to reconnect

### Primary surfaces
- Codex transcript screen
- Repo/session browser sheet or drawer
- Connections setup and recovery flow
- Inspector sheet for review and advanced controls
- Settings for preferences and secondary controls

### Conversation view
- compact repo/path chrome
- branch / worktree status
- model
- active effective approval/sandbox/network mode, not coarse host capability labels
- photo and voice tools
- machine / route only when relevant
- active turn status
- inline approvals
- inline workspace review summary
- sticky composer

---
## iPad UX

### Principles
- route and machine context visible without modal hopping
- efficient keyboard use
- better multi-host context than iPhone
- premium readability, not crowded terminal aesthetics

### Layout
- `NavigationSplitView`
  - Sidebar: machines + active tailnet context
  - Content: conversation or machine detail
  - Inspector: route details, Git/review pane, or host diagnostics

### Multi-host / multi-session support
- support opening two different hosts side by side where scene resources allow
- preserve separate session stacks per scene
- support drag/drop or shared attachments later

### Multiwindow expectations
- one scene can hold one active conversation plus inspector
- second scene can open a different machine
- restore scene-specific session state on reopen
- merge synced/persisted recent-session records by machine plus scene, so one iPad window does not clobber another

---
## macOS companion app architecture

### Product framing
- Name: **Coding On The Go Companion**
- Role: preferred host-side live lane after setup, while SSH remains available for first-pairing and repair

### Responsibilities
- machine presence
- route publication / route health
- fast reconnect support
- shared listener lifecycle
- diagnostics
- push/notification bridge
- host capability checks
- optional direct authenticated endpoint
- Codex app handoff helpers
- optional Git/workspace wrappers for enhanced mode

### Non-responsibilities
- Not required for first successful connection
- Not the only transport path
- Not the sole trust root; SSH host verification remains available for bootstrap and repair

### Companion operating modes
1. **Passive enhanced mode**
   - publishes capabilities and presence
   - no direct endpoint required
2. **Managed listener mode**
   - keeps loopback listener warm
   - improves reconnect speed
3. **Direct endpoint mode**
   - authenticated companion-published endpoint for the preferred Codex websocket lane
   - primary when mutually authenticated and ready, but not the only supported path

---
## How the macOS companion should fit into the transport, reconnect, and trust model

### Transport
- Companion publishes the preferred direct authenticated endpoint when available
- Companion can also manage or reuse loopback websocket listeners
- SSH remains the canonical bootstrap and repair path

### Reconnect
- Companion provides the first reconnect attempt because it stays local to the host
- Companion can persist recent host capability and route state
- Companion can support richer “wake and attach” flows later

### Trust
- Companion-published direct mode uses mutual auth and version compatibility checks.
- SSH host verification + user credential + route trust remain available for first-pairing, fallback, and repair.
- Companion is preferred for live use, but it is not the sole trust root.

---
## Helper / background task strategy on macOS

### Recommended direction
- Use `SMAppService` with a bundled login item / helper for background availability where needed
- Keep helper lifecycle transparent and user-controlled

### Why
- **Confirmed upstream**: Apple’s Service Management guidance for modern macOS points to `SMAppService` for login items, launch agents, and launch daemons
- **Engineering inference**: this is cleaner and more App-Review-friendly than ad hoc launchd plist writing in the long term

### Packaging rules
- Companion app bundle owns helper components
- Helper is versioned with the app
- Helper only exposes minimal host services
- No privileged daemon is required for v1

---
## Direct-download notarization plan vs later Mac App Store plan

### Recommended sequence
1. Ship the macOS companion first as a **Developer ID signed + notarized direct download**
2. Evaluate a later **Mac App Store** variant after the host-service model stabilizes

### Why direct download first
- more flexible operational posture
- faster iteration
- fewer packaging constraints for helper/login-item behavior
- aligns with how networking tools often ship their fuller macOS variants

### Why a Mac App Store build may still matter later
- easier trust for some users
- centralized updates
- lower friction in managed environments

### Important constraints
- **Confirmed upstream**: Developer ID-distributed Mac software built for modern macOS must be notarized
- **Confirmed upstream**: App Store-distributed VPN/networking-style apps live inside the sandbox / Network Extension ruleset, which carries different constraints

---
## App Store considerations

### iPhone / iPad app
- Must be App Store-ready in v1
- keep local network privacy usage declarations accurate
- keep permission prompts contextual and minimal
- no requirement for a separate Tailscale app
- secrets handled through Apple-secure storage

### macOS companion
- direct-download first is acceptable
- later MAS build should be capability-flagged if helper/networking behavior differs

### Compliance posture
- local-first by default
- minimal hosted services
- explicit privacy copy for tailnet auth, local network discovery, microphone, photos, and notifications

---
## Security / privacy model

### Data categories
- synced metadata
- device-local health / diagnostics
- secrets
- optional hosted push registry

### Rules
- do not sync secrets as plain CloudKit records
- encrypt at rest using platform facilities
- do not silently accept host key changes
- prefer loopback-only websocket listeners when using websocket mode
- avoid exposing unauthenticated non-loopback app-server websocket listeners

### Hosted services policy
Hosted services may exist for:
- APNs delivery
- diagnostics
- device registry
- none of these may be required for the first successful host connection

---
## Failure modes and fallback UX

| Failure | Detect how | User-facing copy should say | Fallback |
|---|---|---|---|
| SSH not enabled | TCP/SSH connect failure + known route context | “Remote Login appears to be off on this Mac. On the Mac, open System Settings → General → Sharing → turn on Remote Login.” | Try another route; keep machine saved |
| Codex missing | `command -v codex` fails | “Codex is not installed on the Mac. Install Codex on the Mac, then try again.” | No protocol fallback |
| Codex too old for websocket | help/version probe | “This Mac’s Codex can run over SSH stdio, but it is too old for the faster loopback websocket mode.” | Stay on stdio |
| Host key mismatch | SSH trust check | “The Mac’s SSH host key changed. This can happen after OS reinstall, hostname reuse, or tampering. Review the new fingerprint before continuing.” | Block until resolved |
| Auth failure | SSH auth result | “Authentication failed. Check your username, password, or private key.” | Let user switch credential |
| Embedded tailnet not connected | tailnet state | “Embedded Tailscale is signed out or disconnected.” | Try LAN or external route |
| External Tailscale route unavailable | reachability test | “The external Tailscale route is saved, but the device network path is not currently reachable.” | Try embedded or LAN |
| Headscale auth failure | embedded profile state | “The custom control server rejected the login or auth key.” | Re-auth profile |
| LAN host unreachable | connect failure | “This Mac is not reachable on the current local network.” | Try embedded tailnet |
| Loopback listener bootstrap failed | SSH launch / port-forward / handshake | “The faster shared listener could not be started. Using the safe SSH stdio path for repair.” | Explicit stdio repair fallback when supported |
| Companion missing or outdated | companion capability check | “Enhanced Host Mode is unavailable because the companion is not installed or is outdated.” | Stay on zero-install path |
| Companion helper inactive | helper status | “The companion is installed, but its background helper is not active.” | Offer fix steps, continue without enhanced mode |

---
## Explicit tradeoffs

### Chosen tradeoff
Prefer the **best end product** over minimizing code or preserving Remodex architecture.

### Specific tradeoffs
- choose a Codex-first repo/session daily model over a machine-first daily shell
- choose a proven Codex websocket live lane over raw SSH stdio for steady-state mirroring, while keeping stdio for first-pairing and repair
- choose embedded app-scoped Tailscale over requiring the separate Tailscale app
- choose explicit sync + secret separation over dumping everything into one store
- choose a real companion architecture over pretending raw SSH sessions solve background presence forever

---
## Explicit answers to the required research questions

### 1. What `codex app-server` already gives us
- threads, turns, resume, fork, archive
- steer and interrupt
- review mode
- streamed item and delta notifications
- approvals
- command execution
- filesystem APIs
- model and reasoning capability introspection
- skills and app listings
- auth/account surfaces

### 2. What Remodex has that `codex app-server` does not give us directly
- secure pairing / trusted reconnect
- machine/route UX
- Git/workspace product surfaces
- push/relay plumbing
- launch agent lifecycle
- mobile voice UX
- desktop handoff UX
- iOS transport workarounds

### 3. Why Remodex did not simply use only `codex app-server`
Because app-server solves the Codex protocol, not the whole remote-mobile product. Remodex’s attached code proves it added a bridge, transport workarounds, pairing, git/workspace RPC, and background lifecycle.

### 4. Exactly what the downsides / contra of the zero-install approach are
- weaker always-on presence
- harder reliable notifications
- more SSH UX work
- more client-side orchestration
- image/file staging complexity
- listener reuse limitations without companion

### 5. Which Remodex features map directly to `codex app-server`, which need wrappers, and which need real product reimplementation
See the feature mapping table above: conversation/review/approvals mostly map directly; queueing, Git, workspace, image staging need wrappers; machine routes, embedded Tailscale, sync, reconnect, and companion are real product reimplementation.

### 6. How built-in Tailscale should be embedded in an App Store-ready iOS/iPadOS app
As an app-scoped userspace node via libtailscale/TailscaleKit behind a private wrapper package, not as a default full-device VPN requirement.

### 7. How to support both embedded Tailscale and the external Tailscale app cleanly
Make both first-class route types under the same machine model and use the same route scoring / health system.

### 8. How to support Headscale/custom control servers
Store `controlURL` per tailnet profile, expose it in the model and UI, and keep auth state per profile.

### 9. How to structure the machine/route/session model for a good UI/UX
Separate logical `MachineRecord` from `RouteRecord`, cache capability snapshots per machine, and keep recent session state per scene/device.

### 10. How the macOS companion should fit into the transport, reconnect, and trust model
As an optional host-side enhancer for presence, reconnect, notifications, and endpoint reuse. It may publish or manage the preferred Codex websocket lane, while SSH remains the primary first-pairing and repair contract.

### 11. What the recommended priority + fallback stack should be and why
Codex app-server websocket when directly reachable, companion-published, or safely SSH-forwarded → embedded Tailscale/LAN/manual SSH route for reachability → SSH bootstrap/control for setup, listener startup, and forwarding → SSH stdio fallback for repair. The websocket lane is preferred for mirroring and reconnect; SSH remains the durable setup and repair path.

### 12. Anything important I am still missing
- precise image/file staging mechanics need an implementation spike
- reliable zero-install background notifications remain a risk area
- embedded libtailscale App Review / packaging validation should happen early
- companion-published direct endpoint auth should not be treated as the only websocket path

---
## Codex Mac app handoff

### Requirement
Preserve a handoff path to the Codex Mac app.

### Current upstream signals
- **Confirmed upstream**: the Codex app for macOS has documented deeplinks, including `codex://threads/<thread-id>` and `codex://new`.
- **Confirmed upstream**: the Codex app itself is built around worktrees, Git tools, automations, and parallel local threads.

### Product direction
- detect whether the Codex Mac app is installed
- when available, offer:
  - “Open this thread in Codex on Mac”
  - “Start a new Codex Mac thread in this workspace”
- implement via companion helper or SSH `open` wrappers where safe and documented

---
## Rollout / milestones

### Milestone 0 — repo and architecture foundation
- mono-repo skeleton
- package boundaries
- shared models
- planning files and docs
- publishable documentation baseline

### Milestone 1 — SSH bootstrap / repair lane
- Connections setup shell
- credentials UI
- SSH host-key trust
- Remote Login diagnostics
- Codex capability probe
- stdio app-server session

### Milestone 2 — machine/route quality
- Codex repo/session browser
- route persistence
- route health scoring
- reconnect cache
- actionable error UX
- LAN discovery

### Milestone 3 — embedded tailnet
- embedded tailnet auth
- multiple saved tailnet profiles
- one active embedded tailnet at a time
- route publication into machine directory

### Milestone 4 — feature parity
- queueing
- steer
- reasoning controls
- image staging
- Git/workspace UI
- voice
- notifications baseline
- iPad split view / multiwindow

### Milestone 5 — SSH websocket fallback lane
- websocket support detection
- SSH tunnel reuse
- loopback listener health checks
- auto-upgrade / fallback logic

### Milestone 6 — companion primary live lane
- presence
- login item
- shared listener reuse
- reliable enhanced notifications
- Codex Mac handoff helpers
- direct-download signing/notarization

---
## Source index

### Current upstream references
- OpenAI Codex app-server docs: https://developers.openai.com/codex/app-server
- OpenAI app-server source README: https://github.com/openai/codex/tree/main/codex-rs/app-server
- OpenAI Codex app docs: https://developers.openai.com/codex/app
- OpenAI Codex app commands / deeplinks: https://developers.openai.com/codex/app/commands
- OpenAI Codex app worktrees: https://developers.openai.com/codex/app/worktrees
- Tailscale libtailscale: https://github.com/tailscale/libtailscale
- Tailscale custom control server docs: https://tailscale.com/docs/how-to/set-up-custom-control-server
- Tailscale macOS variants: https://tailscale.com/docs/concepts/macos-variants
- Headscale docs: https://headscale.net/stable/
- Apple Network Extension: https://developer.apple.com/documentation/networkextension
- Apple local network privacy TN3179: https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy
- Apple Service Management / `SMAppService`: https://developer.apple.com/documentation/servicemanagement/smappservice
- Apple notarization docs: https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution
- Apple `CKSyncEngine`: https://developer.apple.com/documentation/cloudkit/cksyncengine-5sie5
- Apple `kSecAttrSynchronizable`: https://developer.apple.com/documentation/security/ksecattrsynchronizable

### Attached-code anchors inspected for this plan
- `remodex-main/CodexMobile/CodexMobile/Services/CodexService+Transport.swift`
- `remodex-main/CodexMobile/CodexMobile/Services/CodexService+Connection.swift`
- `remodex-main/CodexMobile/CodexMobile/Services/CodexService+SecureTransport.swift`
- `remodex-main/CodexMobile/CodexMobile/Services/CodexService.swift`
- `remodex-main/phodex-bridge/src/codex-transport.js`
- `remodex-main/phodex-bridge/src/git-handler.js`
- `remodex-main/phodex-bridge/src/workspace-handler.js`
- `remodex-main/phodex-bridge/src/macos-launch-agent.js`
- `litter-main/apps/ios/Sources/Litter/Models/SSHSessionManager.swift`
- `litter-main/apps/ios/Sources/Litter/Models/ConnectionTarget.swift`
- `litter-main/apps/ios/Sources/Litter/Models/NetworkDiscovery.swift`
- `litter-main/apps/ios/Sources/Litter/Models/DiscoveredServer.swift`
- `litter-main/apps/ios/Sources/Litter/Info.plist`
- `omnara-main/apps/mobile/src/screens/MainScreen.tsx`
- `omnara-main/src/omnara/session_sharing.py`
- `omnara-main/src/relay_server/websocket.py`
- `clawdex-mobile-main/services/mac-bridge/src/server.ts`
- `clawdex-mobile-main/apps/mobile/src/api/ws.ts`
- `clawdex-mobile-main/scripts/setup-wizard.sh`
- `rustdesk-master/flutter/lib/common.dart`
- `rustdesk-master/flutter/lib/models/terminal_model.dart`

---
## What I might still be missing

- Whether a small, ephemeral remote helper process for zero-install push is worthwhile before companion rollout
- Whether file staging should prefer SFTP, SCP-like exec streaming, or an app-server-adjacent upload wrapper
- The exact best boundary between scene-local state and global app state on iPad multiwindow
- The best way to represent companion-direct auth tokens in a way that remains clean for a later public/open-source posture
- Whether a future Linux-host abstraction should be introduced early as an internal protocol boundary or deferred entirely until after macOS v1 ships

---
## Future roadmap

- Codex cloud capabilities later, if product value justifies them
- direct iPhone-run Codex via subscription/API keys later, where practical
- dark mode later
- selectable app design presets in Settings later, similar to how popular coding IDEs let users pick a preferred look
- compact mode later as part of those design presets/settings, reducing UI density so more fits on screen
- a lightweight user feedback path later, potentially linked from the hosted support/privacy pages and backed by GitHub Discussions
- Android client later
- Claude support later, ideally in a way that stays compliant with Anthropic's policies and avoids account/provider bans
- direct "continue this real thread from iPhone" support later, so an existing thread can be reopened on mobile by identity/deep link instead of recreated manually
- Linux host compatibility later
- richer companion capabilities after the primary live lane:
  - durable endpoint resume
  - deeper push / automation hooks
  - worktree lifecycle helpers
  - richer direct endpoint transport
- possible public / open-source repo version later

---
## Recommended implementation posture

Keep the zero-install SSH path for first-pairing and repair, but do not treat it as the daily product ceiling. The right v1 shape is:

- **Codex app-server websocket live experience first when ready**
- **SSH bootstrap and repair experience always available**
- **shared machine/route/session model from day one**
- **original implementation throughout**

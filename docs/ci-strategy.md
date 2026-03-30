# GitHub Actions CI Strategy

Last updated: 2026-04-16

## CI tiers

1. `Automatic GitHub-hosted CI`
   - Cheap script, workflow, and test-plan syntax sanity on `ubuntu-latest`
   - No macOS-hosted build/test jobs by default
2. `Manual GitHub-hosted macOS CI`
   - Package tests
   - iPhone simulator unit tests
   - Hosted-safe iPhone simulator UI tests that use preview fixtures or app-owned seed data
   - macOS companion build/tests
   - Xcode project/test-plan wiring sanity
3. `Optional heavier GitHub-hosted CI`
   - Manual extended iPhone simulator-safe UI regressions that take longer but still do not depend on a real host, real Codex install, localhost SSH, Keychain integration, or physical hardware
4. `Local/manual or self-hosted Mac only`
   - **1.0 MUST** localhost SSH safe-lane proof
   - **1.0 MUST** real-host Codex proofs over LAN, external tailnet, or embedded tailnet
   - **1.0 MUST** SSH-forwarded websocket optimization-lane proof when that lane changes
   - Physical iPhone/iPad validation
   - Any check that depends on a connected Mac, a signed runtime artifact, local proxy/VPN state, or real Apple Keychain/device behavior

## What GitHub-hosted CI proves

- The automatic lane proves the checked-in shell scripts, workflow YAML files, and Xcode test plans at least parse cleanly without consuming macOS minutes.
- The manual macOS lane proves the Swift package graph still compiles and the hosted-safe package/unit subset passes in a clean GitHub-hosted macOS environment.
- The manual macOS lane proves the checked-in iPhone simulator UI surfaces still support the preview-fixture and app-seeded flows selected for CI.
- The manual macOS lane proves the macOS companion target still builds and its test target still passes on a clean GitHub-hosted macOS runner.

## What GitHub-hosted CI does not prove

- Physical iPhone or physical iPad behavior.
- Real-host behavior against a reachable Mac running Remote Login and `codex app-server`.
- Localhost SSH safe-lane behavior, SSH-forwarded websocket reuse, or any proof that depends on a real local `codex` binary.
- Embedded or external tailnet runtime truth, including device-side auth/runtime behavior and host network conditions.
- Companion presence advertising truth on a real host.
- Real Apple Keychain integration.
- Final visible-second-window proof for iPad multiwindow beyond what XCTest can infer on a simulator.
- The rendered iPhone UI against the phone's real saved Macs, threads, routes, credentials, and proxy/VPN state.

## UI/UX visual proof guidance

- Use simulator-safe preview fixtures, app-owned seed data, or reviewer demo mode for fast layout and shell iteration.
- If you need the simulator to render the phone's current Projects/Threads browser state without keeping the phone attached, use `./scripts/launch_simulator_live_phone_mirror.sh`. It copies the installed-app metadata from the connected phone once or reuses a previously exported snapshot, rewrites the preferred route into the simulator's localhost SSH safe lane, and launches the simulator app against that mirrored snapshot.
- When validating the rendered UI against real saved Macs, live threads, or live route and credential state on a connected iPhone, prefer the normal installed app plus `agent-device` `snapshot` or `screenshot`.
- Use physical XCTest on device when the flow itself is deterministic and seeded; its screenshot attachments remain valid proof for reviewer demo mode and other controlled paths.
- Do not treat physical `UI_TESTING` launches as the source of truth for live saved-state screens. On device they use an isolated metadata store and can diverge from the normal installed app.
- Keep `xcrun devicectl` in the install and launch lane; use it to build, install, and start the app, then capture visual proof through XCTest attachments or `agent-device`.

### Simulator live-state mirror recipe

1. Capture the real phone state once with `./scripts/launch_simulator_live_phone_mirror.sh --raw-key-path /tmp/cotg_app_test_key.raw`.
2. Reuse the exported `phone-machine-directory.json` on later runs with `--phone-metadata <path>` when the phone is no longer attached.
3. Treat this as a fast developer mirror for browser/session context, not as a replacement for the physical-device truth path.

### Connected iPhone screenshot audit recipe

1. For live saved-state UI, launch the normal installed app on the connected phone and capture through `agent-device`.
2. If `agent-device screenshot` fails, run `./scripts/capture_physical_live_screenshots.sh` on the connected phone. It launches the normal installed app with no `UI_TESTING` environment and captures live Connections plus live Codex/browser screenshots as XCTest attachments.
3. If the audit also needs live button/sheet behavior, run `./scripts/capture_physical_live_screenshots.sh --with-browser-audit` so the same pass proves `Done`, search, project disclosure, project-scoped `New thread`, resume-row navigation, and browser dismissal on the real phone.
4. For deterministic seeded UI, run focused physical UITests and capture proof screenshots through XCTest attachments.
5. If the run suddenly looks "untrusted" or the installed app will not launch, check the iPhone-side VPN/proxy path first. A broken device-side proxy or VPN path can block Apple's verification service and make a fresh install plus `xctrunner` look broken even when signing has not changed.
6. If the run still fails because the developer app certificate is not trusted, trust `com.example.codingonthego.ios.uitests.xctrunner` on the iPhone under Settings -> General -> VPN & Device Management, then rerun the wrapper.
7. When pausing, record the exact wrapper command, `xcresult` path, and exported PNG paths in ignored local release notes.

```bash
./scripts/capture_physical_live_screenshots.sh
./scripts/capture_physical_live_screenshots.sh --with-browser-audit
```

Do not:
- Do not use physical `UI_TESTING` launches as truth for live saved Macs, live threads, routes, or credentials.
- Do not rely on `devicectl` as the screenshot layer; it is the install/launch lane.
- If `agent-device snapshot` returns `AgentDeviceRunner` or `agent-device screenshot` fails with CoreDevice provider errors, switch to the focused physical XCTest attachment lane instead of assuming the app UI itself is wrong.

## Audit snapshot

| Entry point | Classification | Notes |
|---|---|---|
| `scripts/verify_github_hosted_ci.sh` | Safe for GitHub-hosted CI | Hosted-safe verifier for packages, hosted-safe iPhone simulator checks, optional extended iPhone simulator checks, and macOS companion tests |
| `scripts/verify_local_runtime_matrix.sh` | Local/self-hosted Mac only | New honest replacement for the old broad local verifier; still includes localhost SSH and loopback-listener proof |
| `scripts/verify_local_v1.sh` | Obsolete wrapper | Kept only as a compatibility shim; forwards to `verify_local_runtime_matrix.sh` |
| `scripts/run_appstate_localhost_test.sh` | Local/self-hosted Mac only | Requires localhost SSH integration and a marked test key |
| `scripts/run_physical_real_host_test.sh` | Local/self-hosted Mac only | Requires a connected physical iPhone plus a reachable real host and, optionally, tailnet credentials |
| `scripts/run_physical_ipad_test.sh` | Local/self-hosted Mac only | Requires a connected physical iPad plus a reachable real host |
| `scripts/validate_physical_devices.sh` | Local/self-hosted Mac only | Requires connected iPhone/iPad hardware and provisioning |
| `scripts/run_connection_mode_matrix.sh` | Local/self-hosted Mac only | Wraps physical real-host phone tests across route modes |
| `scripts/run_cross_device_continuity.sh` | Local/self-hosted Mac only | Chains physical phone + iPad continuity proofs |
| `scripts/run_physical_ipad_parity.sh` | Local/self-hosted Mac only | Physical iPad parity/relaunch proof |
| `scripts/verify_safe_lane_localhost.sh` | Local/self-hosted Mac only | Requires localhost SSH plus a real `codex app-server` on the host side |
| `scripts/capture_physical_live_screenshots.sh` | Local/self-hosted Mac only | Runs the installed-app live screenshot fallback on the connected iPhone, exports `.xcresult` attachments, and optionally includes the live browser/button audit in the same pass |
| `Packages/*` unit tests | Mostly safe for GitHub-hosted CI | `AppState` and `SSHTransport` contain localhost integration tests that self-skip unless explicitly enabled; `Secrets` contains a real Keychain test that self-skips unless enabled; the hosted package lane now runs the full package graph without hidden regex exclusions |
| `apps/ios/CodingOnTheGo/Tests/CodingOnTheGoTests` | Needs split | Basic unit tests are hosted-safe; `testLocalhostSafeLaneConnectsOnSimulator` is local/self-hosted only |
| `apps/ios/CodingOnTheGo/Tests/CodingOnTheGoUITests` | Needs split | Preview-fixture/manual-form/simulator-layout tests are hosted-safe on the iPhone simulator; localhost/reconnect/route-mode tests are local-only; physical tests are hardware-only; the compact Codex overflow action sheet and current iPad split-view assertions remain local/self-hosted because the current GitHub-hosted simulator/XCTest stack does not surface those paths reliably enough for honest hosted proof |
| `apps/macOS/CodingOnTheGoCompanion/Tests/CodingOnTheGoCompanionTests` | Safe for GitHub-hosted CI | Pure host-app test target |

## Workflows

- `.github/workflows/ci.yml`
  - Automatic: `Script sanity` only
  - Manual `workflow_dispatch`: `Xcode project sanity (manual)`, `Swift package tests (hosted-safe)`, `iPhone simulator (hosted-safe)`, and `macOS companion`
- `.github/workflows/simulator-ui-extended.yml`
  - `Extended simulator UI (hosted-safe)` manual-only simulator-safe UI matrix

Manual hosted macOS jobs explicitly select an installed Xcode 26.x toolchain on `macos-15` instead of inheriting the runner's default Xcode, and the manual Xcode project sanity lane bootstraps `xcodegen` if the runner image does not already provide it. Hosted simulator jobs also pre-boot the targeted simulator and retry once after an exit-65 install/launch failure. That helps the iPhone hosted-safe lane, and it also clarified an important limit during this audit: clean GitHub-hosted iPad simulator runs on `macos-15` are still surfacing the app in a compact shell instead of exposing the split-view accessibility identifiers the current iPad assertions require, so iPad split-view proof stays in the local/self-hosted tier for now.

## Required local checks before submission

Run these on a local or self-hosted Mac before release-candidate signoff:

```bash
./scripts/verify_local_runtime_matrix.sh
./scripts/validate_physical_devices.sh
./scripts/run_companion_matrix.sh
./scripts/run_physical_real_host_test.sh
./scripts/run_physical_ipad_test.sh
```

Run the current iPad split-view simulator UITests directly under Xcode or `xcodebuild` on a local/self-hosted Mac, because clean GitHub-hosted runners are still surfacing the app in a compact shell instead of the regular-width split-view shell those assertions target.

Use the broader route/device wrappers when the release changes connectivity behavior:

```bash
./scripts/run_connection_mode_matrix.sh
./scripts/run_physical_ipad_parity.sh
./scripts/run_cross_device_continuity.sh
./scripts/verify_embedded_tailnet_runtime.sh
```

## Physical iPhone/iPad + real-host matrix

Before submission, run the relevant local matrix for the candidate build:

1. `./scripts/verify_local_runtime_matrix.sh`
2. `./scripts/validate_physical_devices.sh`
3. `./scripts/run_physical_real_host_test.sh`
4. `./scripts/run_physical_ipad_test.sh`
5. If route logic changed: `./scripts/run_connection_mode_matrix.sh`
6. If resume/cross-device/iPad parity changed: `./scripts/run_physical_ipad_parity.sh` and `./scripts/run_cross_device_continuity.sh`

These are the only checks in-repo that can honestly prove physical-device behavior and real-host behavior for this product.

CloudKit / cross-device sync and companion direct endpoint access are not `1.0` release gates. Keep their tests and docs honest, but do not treat them as substitutes for safe-lane, optimization-lane, tailnet, or real-device verification.

# Coding On The Go

Coding On The Go is a local-first Apple-platform client for continuing Codex work from iPhone, iPad, and an optional macOS companion.

The product keeps three concerns separate:

- Route: how the mobile client can reach a Mac, such as LAN, manual SSH, external tailnet, or embedded tailnet.
- Bootstrap: how the Mac is verified and prepared, primarily macOS Remote Login over SSH.
- Protocol: how the running Codex surface is spoken to, including Codex app-server stdio and websocket lanes.

## Repository Layout

- `apps/ios/CodingOnTheGo`: iPhone and iPad app targets.
- `apps/macOS/CodingOnTheGoCompanion`: optional macOS companion target.
- `Packages`: shared Swift packages for app state, persistence, discovery, SSH, Codex RPC, routing, secrets, notifications, and feature state.
- `docs`: product and platform references that are safe to publish.
- `scripts`: repeatable local verification helpers.

## Requirements

- macOS with Xcode installed.
- Swift 6 toolchain support.
- XcodeGen for regenerating checked-in Xcode projects after project graph changes.
- Optional local `Vendor/TailscaleKit` package if you are validating the embedded tailnet runtime. The public repository does not vendor that binary artifact.

## Common Commands

Regenerate Xcode projects after editing `project.yml` files:

```bash
xcodegen generate --spec apps/ios/CodingOnTheGo/project.yml
xcodegen generate --spec apps/macOS/CodingOnTheGoCompanion/project.yml
```

Run hosted-safe package verification:

```bash
./scripts/verify_github_hosted_ci.sh packages
```

Run the broader local release verifier when you have the required local Apple tooling and devices:

```bash
./scripts/verify_local_v1.sh
```

Some physical-device and real-host scripts require explicit environment variables for device identifiers, hostnames, users, and optional tailnet credentials. Do not commit those values.

## Public Repository Posture

The app is designed to keep host details, route metadata, SSH credentials, and Codex session state local to the user's devices unless the user explicitly configures external services. Private release notes, App Store operations material, local agent instructions, live credentials, and optional vendored runtime binaries are intentionally kept out of the public source tree. See `spec.md` for the product and release boundary.

## Privacy

Coding On The Go does not include analytics, ads, or third-party tracking. SSH credentials are stored in the Apple keychain, and host/thread metadata is kept local unless the user explicitly configures optional sync or relay services.

## License

This project is open source under the Apache License 2.0. See `LICENSE.md`.

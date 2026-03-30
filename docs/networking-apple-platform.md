# Apple Platform Networking Notes

## Apple references
- Network Extension overview: https://developer.apple.com/documentation/networkextension
- Packet tunnel provider: https://developer.apple.com/documentation/networkextension/nepackettunnelprovider
- TN3179 local network privacy: https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy
- `NSLocalNetworkUsageDescription`: https://developer.apple.com/documentation/bundleresources/information-property-list/nslocalnetworkusagedescription

## Tailscale references
- libtailscale repo: https://github.com/tailscale/libtailscale
- Tailscale custom control server docs: https://tailscale.com/docs/how-to/set-up-custom-control-server
- Tailscale macOS variants: https://tailscale.com/docs/concepts/macos-variants

## Local network
- Discovery that uses Bonjour or other local-network access must be paired with the correct app `Info.plist` privacy strings and service declarations.
- Put local-network privacy keys on the app target, not only on extensions.

## Network Extension
- A Packet Tunnel / Network Extension is the Apple-sanctioned route when an app is implementing a system VPN-like tunnel.
- For Coding On The Go v1, the preferred embedded-tailnet direction is an **app-scoped userspace node** via libtailscale/TailscaleKit rather than a full device-wide packet tunnel, because the product only needs its own traffic path.

## Project interpretation
- Treat full device-VPN style embedding as a later escalation path, not the default v1 plan.
- Keep the embedded-tailnet wrapper isolated so the implementation can evolve if App Review, entitlement, or platform constraints change.

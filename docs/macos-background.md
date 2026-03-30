# macOS Helper / Background Notes

## Apple references
- Service Management: https://developer.apple.com/documentation/servicemanagement
- `SMAppService`: https://developer.apple.com/documentation/servicemanagement/smappservice
- Notarizing macOS software before distribution: https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution
- Developer ID overview: https://developer.apple.com/developer-id/

## Related references
- Tailscale macOS variants: https://tailscale.com/docs/concepts/macos-variants

## Preferred direction
- Use Apple Service Management APIs and a bundled login item for background availability where needed.
- Keep helper behavior transparent and user-controllable.

## Direct-download posture
- The macOS companion can ship first as a Developer ID-signed, notarized direct download.
- This is the preferred early distribution path for host tooling flexibility.

## Later Mac App Store posture
- A Mac App Store build may be useful later, but should avoid assuming extra flexibility that only a direct-download build has.
- Keep the companion architecture modular so distribution-specific capability flags are easy to apply.

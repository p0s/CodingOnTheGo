# Internal Style Guide

## Product tone
- Calm
- Premium
- Fast
- Legible
- Actionable
- Never “hacker toy” roughness in primary UX

## UI rules
- Default to readable density over maximum density
- Make the Codex shell feel like a remote Codex client, not a dashboard
- Default daily browsing to `Project -> Thread`; machine identity is secondary unless multi-Mac context matters
- Make machine and route state obvious in `Connections` and secondary surfaces without dominating the main Codex canvas
- Use color as a secondary signal, not the only signal
- Prefer progressive disclosure for advanced transport and recovery controls
- Keep transcript and sticky composer visually primary in `Codex`
- Use Liquid Glass mainly on chrome surfaces such as bars, toolbars, sheets, drawers, and inspectors
- Keep iPhone fast for one-handed reconnect
- Make iPad first-class: sidebars, inspector panels, split view, multiwindow

## Architecture rules
- Separate route, bootstrap, and protocol layers
- Prefer explicit state machines for connection lifecycle
- Hide third-party dependencies behind adapters
- Make capability detection version-aware and cacheable
- Do not store secrets in general synced records

## Error UX rules
- Say what failed
- Say why it likely failed
- Say what to check on the Mac or network
- Say exactly how to fix it when possible

## Implementation rules
- Small composable Swift packages
- High-signal naming
- Test route selection, reconnect, and capability parsing
- Avoid hidden singleton coupling unless there is a clear platform reason

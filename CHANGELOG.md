# Changelog

All notable changes to OrderBell are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.1] - 2026-09-02

### Security

- Replaced the dynamic regular expression in the redundant Admin order URL boundary with an exact canonical-origin comparison and a static numeric-ID validator. Store input was already restricted to canonical `myshopify.com` hosts, but the literal comparison removes an incomplete-sanitization warning and remains fail closed if that grammar ever changes.

## [0.1.0] - 2026-09-02

### Added

- Read-only, local Shopify order polling through official Shopify CLI authentication.
- Native Omarchy bar status, panel, and desktop notifications.
- Quiet first-run baseline, durable per-store deduplication, bounded recent-order state, and retry handling.
- Privacy-first notifications, test-order filtering, and multi-store configuration.
- Inclusive, bounded catch-up queries with six-hour checkpoint steps, a five-minute replay overlap, a 59-day recovery horizon, and a fail-closed 20 × 100 pagination ceiling.
- Bounded notification delivery with count-only burst summaries, a 64-entry durable queue, and per-run/per-entry retry ceilings.
- Durable configuration cleanup that clears disabled notification work and removes retained test rows, queued test alerts, and their tracked unread contribution before network access.
- Hardened QML process lifecycle with bounded arbitrary-chunk parsing, ASCII-safe JSON transport, explicit startup/abnormal-exit handling, PID-zero signal prevention, and policy-consistent cancellation.
- Exact multi-store unread accounting with display-only count abbreviation and explicit catch-up health in the bar and panel.
- GraphQL Admin API `2026-07` query with explicit version pinning.
- Security policy, privacy notice, threat model, data map, test plan, and release checklist.

### Changed

- Simplified the configured panel toolbar to contextual actions and made first-run setup directly keyboard reachable with explicit validation.
- Added accessible names, roles, descriptions, focus handling, disabled states, and readable semantic secondary text across stock Omarchy themes.
- Made pending notification delivery visible in the bar and distinguished empty, checking, catch-up, authentication, and error states.
- Set the requested lifetime of normal OrderBell toasts to 30 seconds while preserving DND behavior, bounded delivery, history, and the durable unread badge.
- Gave durable restart backlog a bounded delivery chance before Shopify access, sharing the same five-command budget with newly discovered orders.
- Added a headless behavioral load test for the production panel with minimal Omarchy component mocks.
- Added a strictly sanitized Shopify shop display name to the worker protocol, durable state, panel, recent-order rows, and notifications; the canonical domain remains visible and is still the only identity used for commands and Admin URLs.

### Security

- Prevented flag-like remote shop labels from occupying Omarchy's optional notification-description slot.
- Escaped remote markup at Omarchy's styled notification-body boundary while keeping the panel plain text.
- Classified malformed local timestamps, outbox types, deeply nested or oversized-number JSON, and timestamp overflow at their correct fail-closed trust boundaries.
- Guaranteed child termination and reaping if selector setup fails after a subprocess starts.
- Updated CI actions to reviewed Node 24 revisions pinned by full commit SHA.

[Unreleased]: https://github.com/tbraxa/omarchy-orderbell/compare/v0.1.1...HEAD
[0.1.1]: https://github.com/tbraxa/omarchy-orderbell/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/tbraxa/omarchy-orderbell/releases/tag/v0.1.0

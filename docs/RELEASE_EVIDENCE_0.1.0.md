# Release Evidence: OrderBell 0.1.0

This record documents the release decision without publishing a store domain, order number, amount, customer data, token, or username-bearing local path. The immutable `v0.1.0` tag and GitHub release are the canonical mapping to the full release commit; an in-tree document cannot safely self-reference its own commit hash.

## Release scope

- Plugin ID: `io.github.tbraxa.orderbell`
- Version/tag: `0.1.0` / `v0.1.0`
- Runtime scope: local, read-only polling through official Shopify CLI with requested scope `read_orders`
- Shopify API: pinned stable `2026-07`
- Marketplace category/tags: `Productivity`; `bar`, `quickshell`; suggested tag `shopify`
- Owner direction: a public repository, release preparation, and marketplace publication were explicitly requested. The final marketplace issue body and all ownership/checklist statements still require a separate explicit confirmation immediately before issue creation.

The release tag, GitHub Actions run, release notes, and marketplace issue must all name or resolve to the same exact commit. No later commit may be substituted into an existing approval.

## Release environment

The native checks were run on:

- Omarchy `4.0.2-1`;
- Shopify CLI `4.7.0`;
- Python `3.14.7`;
- Node.js `26.7.0`;
- Qt `6.11.2`;
- Hyprland `0.56.2`; and
- Linux `7.1.9-arch1-2` on x86-64.

The release remains compatible with the documented lower runtime floors; the versions above describe the release machine, not new minimums.

## Automated and static evidence

The final release tree is required to pass, without skips or network-dependent fixtures:

| Gate | Expected release result |
| --- | --- |
| Python worker integration/security suite | 60/60 pass |
| JavaScript model suite | 25/25 pass |
| Headless QML model/service/panel suite | 41/41 pass |
| Python compile, strict JSON, QML parse/format, manifest validation | Pass |
| `omarchy plugin validate .` on Omarchy 4 | Pass |
| Repeated QML run and timezone-independent worker runs | Pass; no retry-to-green |
| Secret scan of the clean public history and release worktree | Zero findings |
| Current Omarchy marketplace validation/security baseline on the public exact commit | Clear, zero blocking findings |
| GitHub Actions on the public exact commit | Green before tag and submission |

The GitHub release notes record the full commit SHA and public CI run that close the external rows. Deterministic tests cover exact notification argv, privacy, one/five/burst order boundaries, pagination, deduplication, crash transitions, outbox retries, hostile JSON/text/types, state corruption, symlink/permission failures, child cleanup, midnight/DST/clock jumps, and six-hour/59-day catch-up limits.

Independent security-focused review passes examined subprocess construction, store/URL validation, response and state bounds, pagination, durable transitions, filesystem handling, notification rendering, error redaction, and process cleanup. These passes improve review independence but are not represented as a third-party certification or a guarantee of absence of defects.

## Authorized live-store evidence

No production order was created or modified for this release.

On 2026-09-01, an authorized existing store supplied one naturally occurring order after the quiet baseline on unpublished/private pre-release candidate `acd6915271089e990b493a85f20a61aeab978ac5`. The identifier is recorded here solely as local provenance; the candidate commit object and its prior lineage are intentionally not reachable from the clean public branch or tag:

- the order was detected by a read-only poll;
- unread state increased from zero to one;
- privacy mode showed a generic order row with store/status context and omitted the order number and amount;
- the durable delivery outbox drained to zero;
- Omarchy notification history recorded an `OrderBell` normal-urgency alert with a bounded Admin action;
- DND was off; and
- later polls retained one unread row with zero failure count and did not duplicate the alert.

The user did not notice the original toast. Evidence showed successful native acceptance rather than delivery loss: the old candidate relied on Omarchy's eight-second normal default. The release tree therefore requests a 30-second normal toast for individual, burst, and local test alerts, still respects DND, and retains the unread badge until explicit acknowledgment.

Because that natural order preceded final UX/security hardening, it proves detection, privacy rendering, native notification acceptance, and non-replay only on that named candidate. The final tree later changed durable outbox scheduling so old queued work gets a bounded attempt before Shopify access; the candidate event is therefore **not** evidence for the exact release's outbox transition. That final transition is covered by deterministic exact-tree tests. Before publication, the exact public build must be installed over the candidate while preserving state, complete a successful read-only poll without replay, and pass **Send test notification** with its requested 30-second lifetime. A new naturally occurring order would be required to claim a complete live new-order transition on the tagged commit.

On `2026-09-01` UTC, the pre-public multi-file update to installed candidate `0ad44263a6824cb5c8a0e1b66c66ced356231699` briefly produced a deliberately fail-closed protocol-shape error while the running shell still held the prior JavaScript model and had already loaded the new worker. The identifier is recorded here solely as local provenance; the candidate commit object and its prior lineage are intentionally not reachable from the clean public branch or tag. A clean `omarchy restart shell` loaded all plugin components from one revision. The subsequent authorized read-only poll returned `ok`, retained one unread/recent order with zero pending notification entries, and emitted no duplicate. The public update instructions therefore require an immediate restart after an enabled update and disclose the short fail-closed mixed-revision window; this preserves durable OrderBell state, bar settings/placement, and Shopify CLI authentication. The exact public release commit still requires the separate install/update and no-replay gate described above.

## Native UX and accessibility evidence

The live fractional-scale dark-theme flow was inspected in first-run, configured/settings, empty, and genuine-unread states. Release changes address the observed toolbar clutter, keyboard-inaccessible first-run form, inert empty save, low secondary-text contrast, hidden pending state, ambiguous empty/error messaging, and missing accessibility metadata.

The semantic secondary-text blend measured at least `4.69:1` against the popup background across the 22 stock theme definitions available on the release machine. This is a deterministic color calculation, not a full WCAG certification. Automated QML tests cover focus, contextual actions, pending bar attention, labels/roles/descriptions, plain-text rendering, and settings transitions. A sanitized synthetic or setup-state image is the only preview permitted in the public repository; live-store screenshots stay outside version control.

On `2026-09-01` UTC, installed candidate `0ad44263a6824cb5c8a0e1b66c66ced356231699` also completed a timed local test against Omarchy's persisted popup state. A normal-urgency OrderBell test alert requested `30000` milliseconds, remained live after `12023` milliseconds, and moved to native history after `30216` milliseconds. In a separate DND-on check, the same alert produced no live popup, was retained directly in native history with the requested timeout, and DND was restored to its original off state. The owner-only OrderBell status remained authoritative and healthy with one existing unread/recent order and zero queued alerts after these checks. This proves that candidate's local attention layers and DND behavior without contacting Shopify or modifying an order; it does not prove that a human will notice every toast. The exact public release commit must repeat the local test gate before tagging.

## Accepted limits

- Local polling is not instant push: default latency is up to 60 seconds while the desktop session is running, and longer during sleep, logout, offline periods, throttling, or bounded catch-up.
- A desktop protocol can prove that Omarchy accepted a notification, not that a human saw it. The requested 30-second toast lifetime, native history, and durable unread badge are layered attention aids; OrderBell does not generate attention-based duplicate retries.
- Deterministic tests prove suspend-like watermark/time behavior. A physical suspend/resume and a naturally occurring order on the exact final commit remain manual observations, not CI claims.
- Marketplace listing is an exact-commit validation and maintainer decision, not a security certification.
- The installed Shopify CLI session may independently retain scopes granted for other tools. OrderBell requests and invokes only `read_orders` and never passes `--allow-mutations`.

No known critical or high-severity defect is accepted for `0.1.0`. The limits above are product/verification boundaries rather than concealed failures.

## Rollback and incident response

Disable immediately with:

```bash
omarchy plugin disable io.github.tbraxa.orderbell
```

Follow [SECURITY.md](../SECURITY.md#emergency-disable-and-rollback) for notification-loss, credential/PII, unsafe-navigation, or write-capability incidents. Removing the plugin does not revoke Shopify CLI authentication and does not silently delete durable state.

## Release-owner decision

The owner approves publication only if the final clean-tree gate, public exact-commit CI, public install verification, release tag, and marketplace bot validation match this record. Maintainer approval of the marketplace listing may remain an external pending step after submission.

# Test Plan

## Purpose

OrderBell's tests must show that new-order delivery is correct across ordinary failures while the security boundaries remain fail closed. A green unit suite is necessary but not sufficient for release; Omarchy integration and an explicitly authorized, read-only Shopify acceptance run are separate gates.

CI contains no Shopify credentials and performs no live Shopify request. All automated network/CLI behavior uses deterministic synthetic fixtures and fake executables.

## Automated test layers

### Python worker unit and component tests

Run:

```bash
python3 -m unittest discover -s tests -p 'test_worker*.py'
```

Required coverage areas:

- canonical store parser: accepted boundary values and rejection of schemes, paths, ports, queries, fragments, user info, uppercase, Unicode lookalikes, IP literals, invalid labels, whitespace tricks, controls, and overlong names;
- fixed argv construction for Shopify, a requested 30-second lifetime for normal-urgency Omarchy notifications, and `xdg-open`; prove no shell and no `--allow-mutations`;
- missing/unsupported CLI command handling and stable classification of authentication, authorization, throttle, timeout, transport, server, and unknown failures; the exact CLI version is recorded by the manual release acceptance rather than inferred from unstable human-readable output;
- stdout/stderr/time limits and kill/reap behavior, including selector/resource failure after child start;
- GraphQL envelope/type validation, errors, cost/throttle metadata, nulls, unknown enum/display values, Unicode, controls, size ceilings, cursor cycles, page and record caps;
- Shopify shop display-name NFKC/control/whitespace/length canonicalization, mandatory presence, cross-page consistency, legacy-state migration, corrupt-state rejection, canonical-domain fallback, and proof that names never affect identity or click targets;
- explicit inclusive lower/upper search bounds; complete pagination with stable ordering, repeated boundary nodes, duplicate IDs, out-of-window rejection, and responses changing between pages;
- first-poll baseline with no historical notifications;
- one, five, more-than-five burst, out-of-order, test, and already-seen orders;
- deterministic deduplication and at-least-once pending-delivery recovery around every durable transition;
- six-hour `catching_up` chunks, the 59-day fail-closed horizon, the 20 × 100 edge ceiling, and backward-clock recovery;
- 64-entry outbox validation/compaction, `pendingCount` queue-entry semantics, one shared five-attempt budget across pre-fetch restart recovery and post-fetch delivery, eight failures per entry, and durable `notify=false`/test-filter cleanup (outbox, test rows, split unread contribution) before either delivery or network access;
- state schema validation, contextual malformed/deep/extreme JSON and timestamp failure classification, corrupt-state rejection without automatic overwrite plus fail-closed preservation, atomic replacement, permissions, XDG fallbacks, disk/full/permission errors, symlinks, and concurrent per-store locking;
- restart, suspend-like long gaps, backward/forward clock jumps, midnight, leap day, and daylight-saving transitions;
- privacy-mode panel and notification text, sanitization, length caps, action URL construction, and exclusion of every prohibited data field;
- bounded worker JSON protocol for `poll`, `status`, and `mark-read`.

Tests patch time, process, environment, and filesystem boundaries explicitly. They do not depend on network, the developer's home directory, current timezone, or an installed Shopify session.

### JavaScript model tests

Run:

```bash
node --test tests/model.test.mjs
```

Required cases include strict worker-protocol parsing (including mandatory `stateAuthoritative: boolean` and `displayName: string | null`), unknown/new fields, malformed/truncated/oversized payloads, Unicode/code-point boundaries, multi-store aggregation, preservation for non-authoritative/busy failures, replacement by authoritative post-state errors and committed catch-up, exact unread aggregation above the display cap, unread transitions, sanitization, relative-time boundaries, and privacy rendering inputs.

### QML static and load checks

Run the deterministic QML model/service suite with:

```bash
tests/run-qml
```

The harness resolves Qt 6 `qmltestrunner` and supplies committed, minimal mocks for Quickshell process types plus the Omarchy `qs.Commons`/`qs.Ui` contracts needed to instantiate the production panel. It makes no Shopify request and starts no real worker. Model, service, and panel behavior are loaded automatically; the production bar/widget composition remains a live-shell acceptance gate. CI also performs dependency-free structural and policy checks over every QML document. On the release machine, Qt 6 `qmlformat` must parse every QML file and `qmllint` must be reviewed with the Omarchy import root available. Unknown Omarchy/Quickshell types must not be hidden with blanket warning suppression. The release environment additionally loads the exact commit in Omarchy 4 and inspects shell logs for component, binding, anchor, type, and process errors.

Service regressions include exit-code/envelope consistency, abnormal exit, `FailedToStart`, PID-zero cancellation and late-start-after-grace paths, watchdog TERM/KILL gating, arbitrary/tiny/oversized stdout chunks, unterminated output, stderr redaction, policy changes during startup/running, exact-once queue rebuilding across multi-store reconfiguration, sequential multi-store execution, queue/busy accounting, preservation of the last known store view only for `stateAuthoritative=false`/busy results, replacement by authoritative post-state failures, and proof that authentication/test-notification actions cannot overwrite last-known Shopify sync health or its timestamp. Panel regressions include keyboard-first setup and empty-save validation, contextual action visibility, configured Settings open/close transitions, focus-driven settings scrolling, pending-delivery bar attention, accessibility metadata, plain-text shop-name rendering, canonical-domain secondary context, and display-name use in recent-order rows.

### Manifest and repository checks

- parse `manifest.json` as strict JSON;
- require exact schema version, permanent plugin ID, semantic version, both kinds and existing safe relative entry points;
- validate setting defaults/types/ranges and reject symlinks;
- run `omarchy plugin validate .` on Omarchy 4;
- scan repository history/worktree for secrets and forbidden shell/privilege/download patterns;
- verify documentation links and the declared runtime dependency set.

## Failure-injection matrix

| Scenario | Expected result |
| --- | --- |
| First valid result contains old orders | Baseline persisted; zero notifications |
| Two orders arrive between polls | Two deterministic pending deliveries and notifications; both visible |
| Six or more eligible orders arrive in one poll | Count-only live/test burst summary; no per-order notification flood; unread count still reflects the orders |
| Crash before pending state write | Cursor does not advance; orders reconcile next run |
| Crash after pending write, before notification | Pending delivery retries after restart |
| Crash after notification, before delivery acknowledgment | Possible duplicate, never silent loss; next durable state converges |
| Restart has pending delivery, then Shopify is offline, requires authentication, or catch-up fails before a request | Existing delivery gets a bounded attempt first; a successful acknowledgment remains durable and the independent poll error preserves its checkpoint |
| Restart delivery fails or more than five old entries remain | Failed attempt is persisted, or five entries are acknowledged; Shopify is skipped and the durable remainder is reported as `degraded` |
| Old backlog and newly fetched orders need delivery in one run | Pre-fetch and post-fetch phases share one five-command ceiling; the durable remainder resumes next run |
| Page 2 malformed or cursor repeats | Current GraphQL reconciliation is rejected and its checkpoint/order changes are not committed; earlier policy cleanup or delivery acknowledgments remain durable and are returned authoritatively |
| Window needs a 21st page / exceeds 2,000 edges | `catchup_too_large`; no checkpoint advance |
| Watermark is seven hours behind | First six-hour chunk is committed and returned as `catching_up`; next chunk requested after 60 seconds |
| Watermark is more than 59 days behind | Non-retryable `catchup_window_exceeded`; no Shopify request and no checkpoint advance |
| CLI timeout/offline/5xx | Process terminated/reaped; retryable `error` envelope with bounded backoff and `stateAuthoritative=true` after state load |
| Worker executable fails to start | Current job fails safely, no signal is sent to PID zero, and the remaining queue continues |
| Settings change while worker is starting/running | Old-policy job is cancelled/ignored and work restarts under the new validated policy; no stale result is applied |
| Worker JSON arrives in arbitrary single-character chunks | Incremental bounds hold and the one valid ASCII-safe envelope parses identically; overflow/truncation fails safely |
| 401/403/scope mismatch | Stable actionable auth error; no rapid retry, raw stderr hidden |
| Shopify throttle | Respect bounded retry/backoff signal; no tight loop |
| State file corrupted | No unsafe overwrite or historical flood; the documented owner-only backup/rebaseline procedure provides the explicit recovery path and discloses the next quiet baseline |
| State path is a symlink | Refuse operation without following target |
| Two workers poll one store | One owns lock; second emits `busy` without API request |
| More than five notification entries await delivery | At most five commands run; remaining queue entries stay durable and `pendingCount` counts entries, not represented orders |
| One notification entry fails eight times | No ninth delivery command; explicit non-retryable retry-limit status and durable pending entry |
| Omarchy accepts a notification | Normal urgency and a requested 30-second timeout are fixed in argv; durable unread remains after the toast expires |
| Notifications or test orders are disabled | Whole outbox, or test rows/test queue entries/their tracked unread share, are durably removed before the API call, even if that call then fails; seen identities remain for dedupe |
| Notebook sleeps for hours | Reconciliation starts after resume; identity-based dedupe, no timer assumption |
| Privacy mode on | Panel and individual notification contain neither order name/number nor amount; store and statuses remain visible; burst summary contains only store and count |
| Shop name contains compatibility glyphs, controls, bidi overrides, extra whitespace, or more than 64 code points | Canonical NFKC plain text is persisted/displayed; controls are removed, whitespace collapsed, and output capped; empty or malformed results fail closed |
| Paginated responses disagree on shop name | Current GraphQL reconciliation is rejected; its name/checkpoint/order changes are not committed, while earlier policy cleanup or delivery acknowledgments remain durable and authoritative |
| Malicious order text | Controls/newlines stripped; no argv splitting or action change |

## Manual Omarchy acceptance

Run only after automated gates pass on the exact release commit:

1. Validate and install the local repository on a disposable Omarchy 4 user/profile.
2. Confirm a generic icon, semantic colors in at least one dark and one light stock theme, keyboard focus, readable scaling, narrow/wide bar behavior, and no clipped translated/long values.
3. Confirm enabling, disabling, shell restart, logout/login, suspend/resume, network loss/recovery, enabled update followed immediately by `omarchy restart shell`, and removal. During update, any old-model/new-worker protocol mismatch must fail closed; restart must clear it without changing durable order state or replaying an alert.
4. Check shell/journal output for QML warnings, raw CLI output, store/order data, and process leaks.
5. Measure idle and active CPU, memory, process count, and request cadence for one and several fake stores.

## Authorized Shopify acceptance

This is manual and is never implied by CI. Prefer a dedicated Shopify development store with synthetic identities when the owner authorizes one. If the owner instead authorizes an existing store, the acceptance is strictly read-only: OrderBell must not create, edit, fulfill, cancel, refund, or otherwise mutate an order merely to produce a test event. Authenticate with `read_orders`, verify the quiet baseline, run **Send test notification** for the local alert path, and observe a naturally occurring genuine order for the complete live path when available.

For an exact release commit, verify a read-only poll, unchanged deduplication/unread state after restart or update, no duplicate replay, the Admin URL construction without opening or changing an order, and the local normal-urgency test path. Preserve the original DND value; confirm the test alert remains live beyond 12 seconds and enters native history at about the requested 30-second lifetime, then enable DND, confirm a second test produces no live popup but is retained in history, and restore DND. A genuine order observed on a reviewed release candidate proves only the unchanged boundaries explicitly named in its evidence. If later code changes an outbox or other state transition, the old event must not be presented as live proof of that final transition: the exact release commit needs deterministic transition tests and a local notification acceptance check, while a new natural event would be required for a full exact-commit end-to-end claim.

Record only commit SHA, tester, UTC date, Shopify CLI version, Omarchy version, scenario class, and pass/fail evidence that contains no domain, order number, amount, customer data, token, or username-bearing path. A real suspend/resume and compositor toast-visibility check remains manual; deterministic tests prove watermark/time logic but cannot prove physical user attention.

## Exit criteria

No known critical/high issue; no flaky test; no skipped security/correctness case; all CI jobs green on the exact commit; local Omarchy validation/load clean; authorized Shopify acceptance and its limits recorded; privacy/security/docs reviewed; release checklist approved by the release owner.

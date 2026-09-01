# Architecture

## Scope

OrderBell `0.1.1` is one Omarchy service plus one bar widget backed by a short-lived local worker. It reads recent Shopify orders, determines which are newly observed, keeps minimal durable delivery state, and asks Omarchy to show notifications. It does not run a separate daemon or receive inbound traffic.

```text
Omarchy shell (long-lived)
  ├─ Service.qml ── timer/config/process orchestration
  ├─ BarWidget.qml + Panel.qml ── semantic Omarchy UI
  └─ Model.js ── bounded status/model transformation
           │ argv + bounded JSON stdout
           ▼
bin/orderbell-worker (short-lived Python stdlib process)
  ├─ validates one canonical store
  ├─ acquires one per-store runtime lock
  ├─ invokes official Shopify CLI with fixed argv
  ├─ validates the shop display name and paginates a GraphQL response
  ├─ updates owner-only state atomically
  └─ invokes Omarchy notification CLI with fixed argv
           │                         │
           ▼                         ▼
Shopify CLI → Shopify API       Omarchy notification daemon
```

The formal QML/worker exchange is documented in [WORKER_PROTOCOL.md](WORKER_PROTOCOL.md).

## Components

### Manifest and Omarchy service

`manifest.json` declares both `service` and `bar-widget` kinds and sets `keepLoaded: true`. The service owns polling while the widget is absent from an open panel; the widget is presentation, not the reliability boundary. Omarchy supplies settings declared in the manifest.

`Service.qml` validates settings, schedules a worker per store, prevents overlapping process launches, enforces a per-job watchdog, incrementally byte-bounds arbitrary stdout chunks, parses exactly one worker result, and exposes status to the UI. The worker escapes non-ASCII code points on the JSON wire, so a Quickshell string-chunk boundary can never split a UTF-8 sequence before accounting. Failed process startup, abnormal termination, watchdog shutdown, and configuration changes during startup/running are separate tested paths; the service never sends a POSIX signal until Quickshell has reported a positive child PID. Poll results alone may change sync health and “last checked”; local actions cannot make a failed Shopify sync appear healthy. The configured interval is clamped to 60–3600 seconds.

`Panel.qml` edits non-secret settings through Omarchy's native `updateEntryInline` configuration API. The manifest schema remains the machine-readable setting contract, but setup does not depend on a separate settings screen existing in Omarchy.

### Worker

`bin/orderbell-worker` has five public operations:

- `poll --store DOMAIN`: execute a complete read/reconcile/deliver cycle;
- `status --store DOMAIN`: read sanitized local state without network access; and
- `mark-read --store DOMAIN`: clear the local unread marker without changing Shopify;
- `authenticate --store DOMAIN`: launch official Shopify CLI's browser/PKCE authentication with a `read_orders` request; and
- `test-notification --store DOMAIN`: send a synthetic local notification without reading an order.

Every operation emits exactly one bounded, newline-terminated JSON object. Non-ASCII content is JSON-escaped on stdout; after decoding it has the same Unicode value. Error output presented to QML is a stable code and sanitized message, never raw CLI stderr. The worker uses no third-party Python package.

### Shopify boundary

Authentication is owned by official Shopify CLI. OrderBell can launch the same command from its panel, or the user can run it transparently in a terminal:

```bash
shopify store auth --store STORE.myshopify.com --scopes read_orders
```

The CLI may preserve or merge scopes from a pre-existing store session. OrderBell requests and uses exactly `read_orders`; it cannot narrow unrelated prior grants stored by Shopify CLI.

Polling invokes `shopify store execute` with a fixed query file, `--json`, the validated store, variables encoded as one JSON argument, and `--version 2026-07`. Mutations are disabled by Shopify CLI unless `--allow-mutations` is passed; OrderBell never passes it and never uses `--verbose`.

The GraphQL query requests only fields required by the data map: `shop.name` plus the minimal order/pagination fields. The shop name is bounded and canonicalized for presentation, and every page in a poll must return the same sanitized value. The canonical `*.myshopify.com` domain remains the sole store identity for Shopify CLI and browser actions. Every poll selects an explicit inclusive UTC `[since, until]` window. An initialized store starts at the saved watermark minus a five-minute overlap and advances by no more than six hours at a time. Pagination is capped at 20 pages of 100 edges, and every returned order and page must validate inside the selected window before its `until` can become the new watermark.

### Durable state and delivery

State is namespaced per store using SHA-256 of the canonical domain. It retains the validated canonical domain and a sanitized Shopify shop display name (or `null` before the first successful poll). Durable data lives under `${XDG_STATE_HOME:-$HOME/.local/state}/orderbell/stores/`; runtime locks live below `${XDG_RUNTIME_DIR}/orderbell/`. Store operations refuse symlinked directories and files, use owner-only permissions, and replace state atomically.

Correctness follows these invariants:

1. The first complete successful poll establishes a baseline and sends no historical notifications.
2. A store has at most one active poll.
3. A polling window is complete only after every required page is decoded and validated, with at most 20 × 100 edges.
4. The time watermark never advances past an unvalidated window or non-durable state.
5. Delivery is at least once across process failure; deterministic order IDs prevent normal duplicates. More than five new eligible orders in one poll are durably represented by count-only live/test burst summaries instead of individual alerts.
6. Every worker envelope declares whether durable state was successfully read and validated. A pre-state, lock, or global failure preserves the last known good panel data; handled post-state Shopify/delivery failures return the authoritative post-cleanup/post-delivery state so stale unread or pending counts cannot survive in the UI.
7. Offline/suspended gaps and backward-clock recovery are processed in committed chunks of at most six hours and normally reported as `catching_up` (`degraded` takes precedence on a delivery problem); automatic catch-up fails closed if the watermark is more than 59 days behind or a chunk needs more than 2,000 edges.
8. The outbox contains at most 64 entries. At most five notification commands run per worker invocation, and an entry stops retrying after eight failed delivery attempts.

State is not an order archive or source of truth. Shopify remains authoritative.

## Poll lifecycle

```text
scheduled
   │
   ├─ invalid config ───────────────► error (no subprocess)
   │
   ├─ store lock held ──────────────► busy (retry later)
   │
   ▼
read last good state
   ▼
apply notification/test-order policy cleanup durably
   ▼
attempt the existing durable outbox with the shared five-command budget
   │
   ├─ blocked/remainder ─────────────► degraded; skip Shopify this run
   │
   ▼
execute version-pinned GraphQL pages
   │
   ├─ auth/timeout/throttle/offline/malformed ─► error + bounded backoff
   │                                             (authoritative after state load)
   │
   ▼
validate complete ordered result
   │
   ├─ no baseline ─► persist baseline, no notifications
   │
   ▼
derive deterministic unseen set
   ▼
persist window watermark + unread + pending delivery/outbox state
   ▼
send sanitized Omarchy notifications with the remaining shared budget
   ▼
persist each delivery acknowledgment
   ▼
emit bounded status JSON
   │
   └─ gap/clock-recovery window ─────► catching_up; schedule another poll in 60 s
```

## Failure and backoff model

Authentication errors require user action and do not busy-loop. Shopify throttling and retryable transport/server failures produce a bounded next-poll delay. Subprocess execution has a timeout and captured output has a byte ceiling in both the Python worker and QML consumer. The QML layer accepts arbitrary process-output chunking, accounts bytes incrementally without repeatedly joining the stream, and joins once only after a normal exit; excess output or an unterminated/invalid envelope fails safely. A setting change cancels an old-policy job and requeues work under the new policy. Pagination, recent-order retention, outbox retention, and displayed strings are bounded by constants reviewed in code and tests. `pendingCount` reports queue entries, not represented orders: one count-only burst summary contributes one pending entry.

At the start of a poll, `notify=false` clears the whole durable outbox. Independently, `includeTestOrders=false` removes retained test rows and test-order outbox entries, subtracts the internal `unreadTestCount` from the public total, and resets that subcount. The cleanup is persisted before delivery or API access, so disabling a display/delivery class cannot be undone by a later notification or network failure. Seen test identities remain in the bounded deduplication set to prevent replay if test inclusion is re-enabled.

An enabled pre-existing outbox gets the first bounded delivery opportunity before Shopify is contacted. If its FIFO head fails or the shared five-command allowance is exhausted, the worker returns `degraded` and intentionally skips the Shopify request for that run. If it drains, reconciliation proceeds and any newly enqueued entries may use only the remaining allowance. This prevents durable alerts from being held hostage by network/authentication failure without allowing one poll to exceed its process or attention budget.

The protocol's required `stateAuthoritative` boolean closes the UI side of this transition. It is `true` after state was read and validated—even if a later Shopify request fails—and `false` for pre-state, lock, usage, interruption, and global failures. QML replaces counts, rows, display name, and last-success time only for authoritative envelopes; otherwise it retains the prior view while showing the new bounded error.

System clock changes, midnight, and daylight-saving transitions do not define newness. Ordering and deduplication use Shopify order identity plus durable cursor state; timestamps are display and ordering inputs, not the sole delivery key.

## Design system

The UI uses Omarchy native components and semantic tokens for background, foreground, accent, success, warning, danger, spacing, radius, and typography. Secondary text is a semantic foreground/muted blend chosen to remain readable across stock themes rather than raw low-contrast muted text. It does not infer theme colors, ship a parallel theme, or use Shopify trade dress. The bar uses a generic shopping-bag/receipt glyph and communicates states with restrained semantic color plus text/tooltips—not color alone.

The compact layer answers three questions: is polling healthy, are there unread orders, and when was the last successful check? Pending delivery also activates the bar so a queued alert cannot look “all caught up.” The panel adds recent sanitized orders and recovery guidance without exposing customer PII. It shows Shopify's sanitized shop name as the friendly label and the canonical domain separately so presentation never obscures identity. With privacy mode enabled (the default), both the panel and per-order notifications hide order name/number and amount while retaining store and status context. Burst notifications always contain only the shop label (or canonical-domain fallback) and count. Normal alerts request Omarchy's maximum 30-second toast lifetime, respect DND, enter Omarchy history, and never retry merely because human attention cannot be proven; the durable unread badge is the persistent fallback.

## Future webhook relay (not in 0.1.1)

True push delivery requires a public HTTPS receiver. A future architecture would be a separate, opt-in product:

```text
Shopify orders/create webhook
  → HMAC-verifying HTTPS edge
  → durable event ID deduplication and queue
  → authenticated desktop subscription
  → periodic Shopify reconciliation
```

It would require Shopify app OAuth/review, protected-customer-data analysis, key rotation, tenant isolation, replay protection, deletion/retention controls, operational monitoring, incident response, and a documented service operator. Webhooks alone cannot replace reconciliation because delivery can be duplicated, delayed, or missed.

None of that code, infrastructure, authentication, or network traffic exists in `0.1.1`. It must not be silently added behind the local plugin's settings.

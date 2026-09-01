# Worker Protocol

This document is the normative interface between OrderBell's Omarchy service and `bin/orderbell-worker` for protocol `schemaVersion: 1`. The worker is a short-lived, UTF-8 command-line process. It never writes protocol data to stderr and emits exactly one newline-terminated JSON object to stdout, including for usage, validation, dependency, state, authentication, and interruption failures. The serialized wire document uses JSON escapes for every non-ASCII code point (and is therefore ASCII as well as valid UTF-8); after JSON decoding, Unicode values are unchanged. This prevents an arbitrary Quickshell string-chunk boundary from splitting a multibyte sequence before the consumer's byte accounting.

## Commands

All commands require one canonical lowercase `*.myshopify.com` hostname. A scheme, path, port, query, fragment, user info, IP address, whitespace, Unicode lookalike, invalid DNS label, or uppercase character is rejected before any child process or store-specific filesystem operation.

```text
orderbell-worker poll --store DOMAIN
  [--notify | --no-notify]
  [--privacy | --show-details]
  [--include-test-orders]
  [--timeout 20]
  [--interval 60]

orderbell-worker status --store DOMAIN [--interval 60]
orderbell-worker mark-read --store DOMAIN [--interval 60]
orderbell-worker authenticate --store DOMAIN [--timeout 300]
orderbell-worker test-notification --store DOMAIN
  [--privacy | --show-details]
  [--timeout 20]
```

`poll` defaults to no notification, privacy on, test orders excluded, a 20-second whole-poll deadline, and a 60-second requested interval. `--timeout` is 1–120 seconds and applies to the complete page set, not separately to every page. `--interval` is 60–3600 seconds and is used as a scheduling hint in the result; the worker never sleeps between polls.

`authenticate` has a distinct default timeout of 300 seconds and permits 1–900 seconds for browser/PKCE completion. It invokes exactly:

```text
shopify store auth --store DOMAIN --scopes read_orders --json --no-color
```

The JSON result is byte-bounded, parsed, then discarded. Authentication succeeds only when its `store` equals `DOMAIN` and its scope array contains `read_orders`. Extra scopes can be present because Shopify CLI merges grants for an existing store-auth session. Associated-user fields, URLs, stdout, and stderr are never relayed.

`test-notification` performs no Shopify request. `status` performs no network or notification request. `mark-read` sets the total and internal test unread counters to zero and clears recent-row unread flags; it does not acknowledge or remove notification outbox entries.

## Process result

Exit status `0` means the JSON envelope is a valid operational result. This includes `baseline`, `catching_up`, `degraded`, and `busy`: callers must inspect both `status` and `error`, not only the process exit status. Usage, validation, authentication, Shopify, state, dependency, timeout, and internal failures return a non-zero status. A handled interrupt returns `130` after the active child process group is terminated and reaped.

The complete top-level shape is:

```json
{
  "schemaVersion": 1,
  "stateAuthoritative": true,
  "status": "ok",
  "store": "example.myshopify.com",
  "displayName": "Example Shop",
  "recentOrders": [],
  "unreadCount": 0,
  "pendingCount": 0,
  "error": null,
  "nextPollSeconds": 60,
  "lastSuccessfulPollAt": null
}
```

The encoded document, including its trailing newline, is at most 64 KiB. Consumers must independently enforce their own input bound before parsing.

### Top-level fields

| Field | Type and invariant |
| --- | --- |
| `schemaVersion` | Integer `1`. Unknown versions are incompatible. |
| `stateAuthoritative` | Boolean. `true` means the worker successfully read and validated this store's state and the returned display name, rows, unread count, pending count, and last-success time are the current durable view—even when `status` is `error` after a later Shopify failure. `false` is mandatory for pre-state, `busy`, usage, interruption, and global failure envelopes; consumers must preserve prior store data in that case. |
| `status` | One of `ok`, `baseline`, `catching_up`, `degraded`, `error`, or `busy`. |
| `store` | The requested canonical store, or `null` when arguments failed before a store could be accepted. QML must require an exact match for store-specific jobs. |
| `displayName` | Shopify's canonicalized shop name, or `null` before it is known / when failure occurs before state can be loaded. It is NFKC-normalized plain text, has no Unicode control/format/private-use characters, uses collapsed whitespace, and contains 1–64 Unicode code points. It is presentation only; callers must use `store` for identity and URLs. |
| `recentOrders` | Array of at most 20 sanitized order objects, newest first. |
| `unreadCount` | Integer from `0` through `2147483647`. It can exceed the number of retained recent rows. |
| `pendingCount` | Number of durable outbox entries awaiting acknowledgment (`0`–`64` in a valid loaded state). It is not an order count: one burst entry can represent many orders. |
| `error` | `null`, or the bounded error object below. |
| `nextPollSeconds` | Integer from `60` through `3600`, incorporating bounded exponential backoff and jitter after retryable failures. A successful incomplete catch-up chunk requests `60`. |
| `lastSuccessfulPollAt` | UTC ISO-8601 timestamp ending in `Z`, or `null` before the first complete successful poll. |

Status semantics are:

- `ok`: the requested operation completed and `error` is `null`;
- `baseline`: the first complete poll established quiet history and emitted no historical order notifications;
- `catching_up`: one bounded historical-gap or backward-clock-recovery window was fully validated, made durable, and reflected in all returned counts/rows; `error` is `null` and another poll is requested after 60 seconds. A normal lagging window uses this status when its `until` is earlier than `pollStart`; backward-clock recovery uses it for the recovery window even if that window reaches `pollStart` in one chunk;
- `degraded`: at least one notification remains pending and `error` describes the bounded delivery failure or deferral. An already-durable backlog is attempted before Shopify, so this status can also mean the worker intentionally skipped the Shopify request after that backlog could not drain safely;
- `error`: the operation failed safely and did not claim incomplete polling progress; and
- `busy`: another process owns this store's exclusive poll/action lock; retry after the supplied short delay.

If a notification delivery problem occurs during a catch-up/recovery poll, `degraded` takes precedence over `catching_up`; the requested next poll remains 60 seconds.

An error object is always sanitized and has exactly these public fields:

```json
{
  "code": "authentication_required",
  "message": "Shopify authentication is missing, expired, or lacks read_orders.",
  "retryable": false
}
```

Codes are stable machine hints, while messages are bounded user-facing English text. Callers must tolerate a new code but reject an unknown top-level `status`. Raw Shopify/Omarchy diagnostics are never part of the protocol.

### Recent order object

```json
{
  "idHash": "64 lowercase hexadecimal characters",
  "name": "#1042",
  "createdAt": "2026-09-01T18:20:30Z",
  "amount": "123.45",
  "currency": "CZK",
  "financialStatus": "PAID",
  "fulfillmentStatus": "UNFULFILLED",
  "test": false,
  "url": "https://example.myshopify.com/admin/orders/123456789",
  "unread": true
}
```

`idHash` is SHA-256 of the validated Shopify Order GID; the raw GID is neither returned nor persisted. `name` is normalized, stripped of controls and format characters, whitespace-collapsed, and capped at 64 characters. Amount is a non-negative canonical decimal string and currency is a three-letter uppercase Shopify currency code. Statuses are uppercase API enum values or `null`.

The URL is never accepted from Shopify. It is rebuilt from the already validated store plus a numeric `legacyResourceId`, and the numeric ID must match the Order GID. QML performs the same validation/reconstruction before opening it.

Privacy mode controls notification and panel rendering; the local worker protocol remains the same bounded owner-only model. With privacy on, native notifications contain neither order number/name nor amount. The sanitized shop label remains visible, with the canonical domain as fallback before a name is known.

## Poll transaction

Polling invokes the official CLI without a shell:

```text
shopify store execute
  --store DOMAIN
  --version 2026-07
  --json
  --query-file ABSOLUTE_PLUGIN_PATH/graphql/orders.graphql
  --variables ONE_JSON_ARGUMENT
```

The variables contain `first: 100`, an optional pagination cursor, and a filter exactly shaped as `created_at:>='SINCE_UTC_TIMESTAMP' AND created_at:<='UNTIL_UTC_TIMESTAMP'`. Both endpoints are inclusive, and the query uses matching `sortKey: CREATED_AT`. The fixed query also selects `shop { name }`. Ambient `SHOPIFY_FLAG_*` variables are removed so they cannot replace the store, query, version, output mode, or mutation policy. OrderBell never passes `--verbose` or `--allow-mutations`.

The first successful poll uses `[pollStart − 5 minutes, pollStart]` and establishes the quiet baseline. An initialized store normally uses `[watermark − 5 minutes, min(pollStart, watermark + 6 hours)]`. Thus the explicit checkpoint is the validated `until`, never a remote maximum timestamp or the later time at which processing happened. If a saved watermark is in the local future after the wall clock moved backwards, the worker conservatively rewinds by the same skew, includes the five-minute overlap, and rebuilds coverage in chunks of at most six hours. This recovery may prefer a duplicate over a silent skip.

If the saved watermark is more than 59 days behind `pollStart`, or its forward-clock skew exceeds 59 days, the worker returns a non-retryable catch-up/clock-recovery error before querying Shopify and does not alter the checkpoint. This bound deliberately stays inside the ordinary history available to `read_orders`; OrderBell never requests `read_all_orders`.

Each selected window permits at most 20 pages of 100 edges (2,000 total). Every returned order must fall inside the inclusive lower and upper bounds. Every page must contain one valid shop name, and its sanitized canonical value must match across the complete page set. The complete window response must pass byte, time, page, record, JSON, GraphQL-error, search-warning, type, cursor-progress, identifier, timestamp, money, enum, shop-name, and URL checks. A 21st page, an out-of-window result, inconsistent shop name, partial/malformed pagination, or any other validation failure rejects the whole window and leaves its checkpoint unchanged. Orders are processed in stable `(createdAt, id)` order. The five-minute overlap plus hashed identity deduplication handles boundary races and normal replay.

On the first complete poll, every overlapping identity is recorded as the baseline but no notification or unread event is created. Later unseen eligible identities become unread and, only with `--notify`, enter the durable outbox before a notification is attempted.

Delivery is at least once. With one through five newly observed eligible orders in a poll, the worker queues individual order entries unless an existing backlog first needs compaction to stay bounded. More than five new eligible orders in one poll compacts the backlog and represents the new batch as count-only burst entries separated into live and test classes. A burst notification shows only the represented count and sanitized shop label (or canonical-domain fallback) and opens the canonical store's Admin order list; one burst contributes `1` to `pendingCount`, regardless of its order count.

The outbox contains at most 64 entries. Compaction changes the number and shape of entries, not the represented live/test counts. After policy cleanup, an already-durable backlog gets a bounded delivery chance before any Shopify request. If that FIFO cannot drain because a command fails, an entry reached its retry limit, the deadline expires, or the per-run attempt allowance is consumed while entries remain, the worker returns `degraded` and skips Shopify for that invocation. If the old backlog drains, polling proceeds; newly queued entries share the same remaining allowance. Thus one complete worker run invokes at most five notification delivery commands across both pre-fetch and post-fetch phases. A failed command increments that entry's durable failed-attempt counter and ends delivery for the run; after eight failures for an entry, later runs return `notification_retry_limit` without a ninth command. Each successful native notification is acknowledged with a separate atomic state write. A crash after display but before acknowledgment may repeat that notification; a crash cannot silently acknowledge one that was never durably queued.

At the start of every poll, `--no-notify` durably clears the complete outbox. Independently, when `--include-test-orders` is absent, retained test rows plus queued test-order/test-burst entries are removed, the internal `unreadTestCount` is subtracted from `unreadCount`, and that subcount is reset to zero. This cleanup happens before either delivery or the Shopify request and therefore remains effective even if either phase fails. Excluded test orders are still added to the identity deduplication set, so enabling them later does not replay tests that were already observed while excluded.

## Durable state and locking

Per-store state is internal, not an extension API:

```text
${XDG_STATE_HOME:-$HOME/.local/state}/orderbell/stores/<sha256(store)>.json
${XDG_RUNTIME_DIR}/orderbell/<sha256(store)>.lock
```

OrderBell-owned directories are mode `0700`; state and lock files are mode `0600`. State reads are size-bounded and refuse non-regular, wrong-owner, group/world-accessible, or symlinked files. Writes use a new owner-only file in the same directory, `fsync`, atomic replacement, and directory `fsync`. State/runtime directory components and targets are checked for symlinks. One non-blocking `fcntl` lock serializes poll, authentication, and local state actions per store.

State contains only schema/store consistency values, the canonical sanitized `displayName` (or `null`), a time watermark, at most 8,192 recent identity hashes/timestamps, at most 20 sanitized recent-order objects, an outbox of at most 64 individual-order/count-summary entries, total `unreadCount`, internal `unreadTestCount`, poll failure count, per-entry notification failure counts, and last-success time. The test subcount is always an integer from zero through the total unread count; it exists so disabling test inclusion never has to guess how much live unread state to preserve. The loader accepts an earlier pre-release schema-v1 state without `displayName` as `null`, and it accepts a state without `unreadTestCount` by reconstructing only the test share provable from retained test rows/outbox entries, capped by the total unread count. Noncanonical stored display names fail closed as corrupt state.

State never contains a Shopify credential, raw GID, raw API response, raw CLI diagnostic, customer field, line item, address, note, or payment data.

Deleting state intentionally causes the next successful poll to establish a new silent baseline. Disabling or removing the plugin does not revoke or alter Shopify CLI authentication.

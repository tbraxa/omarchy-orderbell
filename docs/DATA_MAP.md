# Data Map

This inventory is normative for `0.1.1`. A field or destination not listed here must not be introduced without updating the privacy notice, threat model, tests, and release review.

| Location / flow | Data | Purpose | Protection / retention |
| --- | --- | --- | --- |
| Omarchy plugin settings | Canonical store domains; polling interval; privacy, test-order and notification booleans | User configuration | Managed by Omarchy in its normal user configuration; no token or order data |
| Shopify CLI credential store | Shopify online access token and CLI session metadata | Authenticate `store execute` | Owned and managed exclusively by official Shopify CLI; OrderBell does not locate, read, copy, log, or delete it |
| Worker argv to Shopify CLI | Canonical store; API version `2026-07`; fixed query-file path; JSON pagination variables including inclusive UTC lower/upper bounds | Execute the read-only query | Argument array, no shell; no token; variables contain no customer/order content; each catch-up checkpoint step is at most six hours plus the preceding five-minute replay overlap, and every window is capped at 20 × 100 edges |
| Shopify CLI stdout (transient) | GraphQL envelope, Shopify shop display name, and selected order fields | Validate the presentation label and reconcile orders | Byte/time bounded; parsed as hostile input; raw value is not persisted or forwarded; the sanitized shop name must match on every page |
| Shopify CLI stderr (transient) | CLI diagnostics that may be sensitive | Classify failures | Byte bounded; never emitted raw or persisted; reduced to stable error code/message |
| Durable per-store state | Schema version; canonical-store consistency value; sanitized Shopify shop display name or `null`; watermark; up to 8,192 hashed identity/timestamp entries; up to 20 sanitized recent orders; total unread count plus test-order unread subcount; up to 64 notification queue entries (individual order or count-only live/test burst); per-entry failed-attempt count; poll failure count; last-success time | Recovery, deduplication, friendly display and at-least-once notification | `${XDG_STATE_HOME:-$HOME/.local/state}/orderbell/stores/<sha256>.json`; directories `0700`, files `0600`, atomic writes, symlinks refused; shop name is canonical NFKC plain text capped at 64 code points; disabling notifications clears the queue, while disabling test orders removes test rows/queue entries and their tracked unread share, at the next poll before API access; otherwise retained until replaced or user deletion |
| Runtime lock | Store hash, lock ownership/liveness metadata if required | Prevent overlapping polls | `${XDG_RUNTIME_DIR}/orderbell/<sha256>.lock`; owner-only and session-lifetime; no order data |
| Worker stdout to QML | Protocol version; durable-state authority boolean; status (including committed `catching_up` progress); canonical store; sanitized shop display name or `null`; bounded sanitized recent orders; unread count; notification-queue entry count; stable error; next-poll delay; last-success time | Render bar/panel and schedule recovery without retaining stale durable counts | Exactly one byte-bounded JSON object per invocation; `stateAuthoritative=true` only after state was read and validated, so post-cleanup/post-delivery values replace the panel even when a later Shopify step fails; pre-state/lock/global failures use `false` and preserve the prior view; QML independently requires the display name to be canonical NFKC plain text of at most 64 code points; `pendingCount` is `len(outbox)`, so a burst summary counts as one regardless of represented orders; held in Omarchy process memory, not an OrderBell log; privacy mode controls rendering, not this local exchange |
| OrderBell panel | Sanitized shop name, canonical domain and status context; generic order rows by default; optionally sanitized order name/number and amount | Show local recent-order state without confusing presentation text with store identity | Privacy mode defaults on and hides order name/number and amount; shop/domain context remains visible; every remote string is rendered as plain text; no customer PII |
| Omarchy notification | Sanitized shop label (canonical-domain fallback); individual generic new-order text by default; optionally sanitized order name/number and amount; count/store-label only for burst summaries; locally built Admin action URL | Alert the desktop user | Normal urgency with a requested 30-second lifetime; respects DND and is stored/displayed according to Omarchy notification history; display name never influences the click target; privacy mode defaults on; more than five newly eligible orders in one poll use live/test count summaries, and no more than five queue entries are attempted per worker run |
| Browser action | `https://<validated-store>/admin/orders/<numeric-legacy-id>` | Open the selected order in Shopify Admin | Constructed locally; activated by user; normal browser and Shopify session policies apply |

## Selected Shopify order fields

The query also reads the store-level `shop.name`. It is presentation metadata, sanitized and capped at 64 Unicode code points, and is never used as the store's security identity.

The query and parser may consume only the following order-level fields:

- stable Shopify order identity and numeric legacy ID;
- order display name/number;
- creation timestamp;
- current total amount and ISO currency code;
- display financial and fulfillment status;
- test-order flag; and
- pagination cursor/metadata.

No customer object, email, phone, address, note, line item, payment instrument, raw global ID, or raw response is part of the local public model. A global order ID may be validated transiently if Shopify requires it for identity, but it is transformed into a deterministic non-reversible local identifier and is not exposed through worker output.

## Deletion behavior

`omarchy plugin disable` stops future polling and leaves OrderBell state, but current Omarchy 4 removes the bar widget's placement and per-widget settings. `omarchy plugin remove` removes the plugin checkout and Omarchy placement but intentionally does not run cleanup code. The user can inspect and delete the `orderbell` state root using the file manager. Shopify CLI authentication must be reviewed or revoked through Shopify's current supported mechanism; OrderBell does not manipulate it.

## Prohibited data

Tokens, authorization headers, cookies, customer identity/contact/address data, order notes, line items, payment data, raw API payloads, raw CLI stderr, browser history, keystrokes, device identifiers, analytics IDs, and telemetry events must never enter durable OrderBell state or project-operated infrastructure.

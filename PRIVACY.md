# Privacy Notice

OrderBell is local-first software. It has no OrderBell account, telemetry, analytics, advertising, crash-reporting service, update beacon, or project-operated server.

## Data flow

For each configured store, OrderBell starts official Shopify CLI locally. Shopify CLI authenticates to Shopify and submits a read-only GraphQL Admin API query. The CLI returns a bounded JSON result to the local worker. The worker emits a smaller, sanitized JSON status to the Omarchy shell. No order data is sent to an OrderBell-operated service because no such service exists.

When the user activates an order action, the desktop opens a locally reconstructed Shopify Admin URL derived only from the validated canonical store and numeric order ID. Normal Shopify and browser privacy terms then apply.

## Data used

The local model may use Shopify's shop display name and an order's numeric legacy ID, display name/number, creation time, current amount and currency, financial status, fulfillment status, and test-order flag. The shop name is presentation text only; the validated canonical domain remains the store identity used for Shopify commands and Admin links. These fields support deduplication, ordering, display, and the Admin link.

OrderBell does not request, display, or persist customer names, email addresses, phone numbers, billing or shipping addresses, order notes, line items, payment details, or raw API responses. `read_orders` nevertheless authorizes Shopify CLI to query order resources; least privilege reduces exposure but does not turn the host account into a security boundary.

## Data stored locally

The durable state is intentionally bounded and per-store. It contains the canonical domain, Shopify's normalized shop display name (or `null` before the first successful poll), a watermark, delivery/deduplication metadata, at most 20 sanitized recent-order summaries, at most 8,192 recent identity timestamps, at most 64 notification-queue entries, a total unread count and internal test-order unread subcount, retry metadata, and timestamps. The display name is stripped of Unicode control/format/private-use characters, whitespace-collapsed, normalized to NFKC, and capped at 64 Unicode code points. A queue entry can be either one order or a count-only burst summary, so the public `pendingCount` is the number of queued entries rather than the number of represented orders. Filenames use a hash of the store hostname. The configured store hostname itself is present in Omarchy's plugin settings and inside owner-only state for consistency validation.

State lives under `${XDG_STATE_HOME:-$HOME/.local/state}/orderbell/`. Runtime locks live under `${XDG_RUNTIME_DIR}/orderbell/`. Directory permissions are `0700`, state files are `0600`, updates are atomic, and symlinked destinations are refused.

Privacy mode is enabled by default. It hides order name/number and amount in both the OrderBell panel and per-order Omarchy notification text/history; the sanitized shop name (with canonical-domain fallback) and order statuses remain visible so the UI is still useful. Notification bodies escape remote markup before crossing into Omarchy's styled-text renderer. Alerts request a 30-second normal-urgency lifetime, respect DND, and remain subject to Omarchy's bounded notification-history policy. The panel also shows the canonical domain separately. Turning privacy mode off allows the order name/number and amount to appear in panel rows and individual-order notifications. Burst summaries always contain only the shop label and represented count, regardless of privacy mode. The same order fields remain in owner-only local state and process memory because deduplication, recovery, and a later privacy-mode change must remain consistent.

Shopify CLI stores its own authentication material independently. OrderBell never reads or deletes it. Refer to Shopify CLI documentation and Shopify's privacy terms for that processing.

The field-by-field inventory and retention behavior are in [docs/DATA_MAP.md](docs/DATA_MAP.md).

## Retention and deletion

Recent-order and deduplication records are bounded by implementation limits; they are not an accounting archive. Runtime locks expire with the login session or process lifecycle. Durable state remains until OrderBell replaces it during normal operation or the user deletes the state directory. At the start of the next poll, disabling desktop notifications durably clears every queued notification entry. Disabling test orders removes retained test rows, test outbox entries, and the internally tracked test-order share of the unread count; their identity hashes remain in the short deduplication window so re-enabling the setting cannot replay an already observed test. This cleanup occurs before Shopify access and is retained even if that network poll later fails. Neither setting revokes Shopify CLI authentication.

Disabling or removing the plugin stops OrderBell processing but deliberately leaves durable state for safe reinstall/recovery. After removal, inspect and delete `${XDG_STATE_HOME:-$HOME/.local/state}/orderbell/` using the file manager if local erasure is desired. Revoke Shopify CLI authorization separately when required.

## Network destinations

- Shopify endpoints contacted by official Shopify CLI for authentication and GraphQL Admin API access.
- A validated Shopify HTTPS Admin URL, only after a user activates an order action.

There are no analytics, map, advertising, OrderBell backend, or unrelated third-party endpoints.

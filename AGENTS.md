# OrderBell contributor rules

OrderBell is an unofficial, read-only Omarchy plugin for Shopify order notifications.

## Non-negotiable boundaries

- Request only `read_orders`; never add a write scope, `read_reports`, or `read_all_orders`.
- Use Shopify CLI `store auth` and `store execute`; never read, copy, log, or persist its credentials.
- Never use `sh -c`, `bash -c`, `eval`, `shell=True`, or command strings assembled from remote/user data.
- Validate stores as canonical lowercase `*.myshopify.com` hostnames. Never accept a scheme, path, port, query, fragment, user info, IP literal, or arbitrary URL.
- Treat all Shopify output as hostile. Parse bounded JSON, sanitize displayed text, and construct click URLs only from a validated store plus a numeric legacy order ID.
- Do not persist customer names, email addresses, phone numbers, addresses, notes, line items, raw API responses, or raw CLI stderr.
- Keep state/config directories at `0700`, files at `0600`, and writes atomic. Refuse symlinked state/config targets.
- The plugin must not install packages, open inbound ports, run with privilege, create a separate daemon, or auto-update itself.
- Use Omarchy semantic theme tokens and native components. Do not edit `/usr/share/omarchy`.

## Engineering quality

- Critical polling, parsing, deduplication, pagination, outbox, and sanitization behavior needs tests.
- First successful poll establishes a baseline and must not notify historical orders.
- Prefer at-least-once delivery with deterministic deduplication over silently losing an order.
- A watermark advances only after the complete page set is validated and durable state is written.
- One poll may run per store at a time. Handle timeout, authentication, throttling, malformed responses, restart, suspend, and midnight explicitly.
- No release is complete until Python tests, JavaScript tests, QML lint/load checks, `omarchy plugin validate`, and security scans pass.

## File ownership during parallel work

- Polling worker: `bin/`, `graphql/`, `tests/test_worker*.py`, worker fixtures/fakes.
- Omarchy UI: `Service.qml`, `BarWidget.qml`, `Panel.qml`, `Model.js`, QML/JS tests.
- Project/release material: `manifest.json`, docs, README, policies, CI, license, changelog.

# Threat Model

## Method and security objective

This model uses assets, trust boundaries, abuse cases, and explicit residual risks. Its objective is narrow: notify an authenticated desktop user about newly observed orders without granting write access, handling a Shopify token, persisting customer PII, or turning remote/user-controlled values into code or arbitrary URLs.

The model applies to OrderBell `0.1.2` running under an ordinary user in an Omarchy 4 session. It must be revisited for every new data field, executable, permission, network destination, dependency, or webhook feature.

## Assets

| Asset | Required property |
| --- | --- |
| Shopify CLI session/token | Never read, copy, log, display, or persist it in OrderBell. |
| Order metadata | Minimize fields; keep owner-only, bounded, sanitized, and local. |
| Notification correctness | Do not silently skip an order after claiming durable progress; avoid normal duplicates. |
| Store/admin navigation | Open only a numeric order path on a validated canonical store. |
| Desktop availability | Bound subprocess time, output, pagination, state, and retry frequency. |
| User attention | Make stale/error state visible; never present a failed check as current. |

## Trust boundaries

1. **Omarchy settings → QML:** store strings and booleans are untrusted configuration.
2. **QML → worker:** command-line values are untrusted even when previously validated.
3. **Worker → Shopify CLI:** executable lookup and the same-user environment are host trust dependencies.
4. **Shopify CLI/Shopify → worker:** stdout, stderr, exit status, JSON types, sizes, ordering, cursors, and strings are hostile input.
5. **Worker → filesystem:** pre-existing paths may be malformed, symlinks, corrupted, rolled back, or concurrently accessed.
6. **Worker → notification/browser:** text and action URLs cross into other desktop components.
7. **Plugin → Omarchy shell:** QML runs unsandboxed inside a long-lived same-user process.

## Threats and controls

| Threat | Primary controls | Residual risk |
| --- | --- | --- |
| Store value causes SSRF or arbitrary navigation | Strict lowercase `*.myshopify.com` parser; reject URL syntax, IPs, ports and paths; rebuild Admin URL from canonical store plus numeric legacy ID | DNS, TLS, browser, Shopify, and local resolver integrity remain external dependencies |
| Command/argument injection | Fixed executable/argument arrays; no shell; one JSON-encoded variables argument; fixed query file | A compromised `shopify`, `omarchy`, `xdg-open`, or `PATH` under the same user can misbehave |
| GraphQL mutation or excess scope | Only `read_orders`; static query; no `--allow-mutations`; test command construction | Shopify CLI session might have other scopes granted for unrelated use; OrderBell still does not invoke them |
| Credential disclosure | Token remains opaque to OrderBell; no verbose CLI; sanitized stable errors; no raw stderr/state | Same-user malware or another unsandboxed plugin may access CLI-managed credentials |
| Remote JSON exhausts memory/disk/UI | Byte ceilings, timeouts, six-hour checkpoint steps with a five-minute overlap, at most 20 × 100 edges per inclusive window, string caps, strict type checks, bounded retained state | A legitimate window above the cap fails closed and needs operator review |
| Malformed/partial pagination hides orders | Validate every page and every order against both window bounds before advancing to the explicit `until`; retain last good state | Shopify can remain unavailable; notification is delayed until reconciliation succeeds |
| Crash between observing and notifying loses an order | Durable pending-delivery/outbox transition before delivery; at-least-once retry; deterministic deduplication | A crash after desktop notification but before acknowledgment can produce a duplicate |
| Restart/suspend/midnight causes replay or loss | Durable per-store watermark and identity set; inclusive five-minute overlap; committed six-hour `catching_up` chunks; timestamps are not the sole key | Catch-up beyond 59 days or above 2,000 edges in one chunk fails closed; manual state deletion intentionally causes a fresh quiet baseline |
| Concurrent workers corrupt state or duplicate | Atomic per-store runtime lock; owner-only state; file and directory synchronization; descriptor-relative atomic replacement | A hostile same-user process can remove locks or tamper with state before or after a transaction |
| Symlink/hard-link/path swap redirects a state save | Fixed XDG root and hash-based filenames; held owner-private directory descriptor opened no-follow; exclusive no-follow temporary entry; descriptor-relative inspect/replace/cleanup; directory-path, temporary-inode and installed-inode verification | Path-component replacement cannot redirect the transaction after the verified directory descriptor is opened, but an unrestricted same-user process remains outside the security boundary and can tamper later; an error after replacement or synchronization can leave durability outcome ambiguous to the caller |
| Merchant-controlled shop/order text spoofs UI or notification context | NFKC normalization, Unicode C* removal, whitespace collapse, length caps, page-to-page shop-name consistency, fixed titles/actions, plain-text QML rendering, notification-body markup escaping, canonical domain shown separately, argv execution | Legitimate sanitized names can still resemble another brand; the canonical domain is the authoritative identity |
| Notification history leaks commercial data | Privacy mode defaults on; no customer PII; user opt-in for amount/order number | Anyone with visual/session access may see even a generic notification or unread count |
| User misses a short or DND-silenced toast | Normal alerts request 30 seconds, respect DND, enter native history, and leave a durable unread badge until explicit acknowledgment | No desktop protocol can prove that a human noticed a toast; OrderBell does not create duplicate retries based on attention |
| Disabling test orders leaves stale test data or subtracts live unread state | Before network access, remove test recent rows/outbox entries and subtract only the separately tracked test unread subcount; retain identity hashes for dedupe | A legacy pre-release state without the split counter can remove only the test share provable from retained rows/outbox, preserving live unread at the cost of a possible conservative residual count |
| Click action opens attacker-controlled target | Ignore remote URLs; construct HTTPS URL locally from validated store and numeric legacy ID | Browser session and Shopify authorization determine what is displayed after opening |
| Error logging leaks raw response/token | One bounded stdout protocol; stable error codes/messages; raw stderr discarded after classification | Host process/debug tooling can inspect a running process; OrderBell never promises protection from root |
| Malformed, unterminated, or adversarially chunked worker output exhausts or confuses the shell | Worker emits ASCII-safe JSON; QML counts arbitrary chunks incrementally, caps bytes and chunk count, joins once, and requires one exact envelope after normal process exit | Quickshell and Qt string/process implementations remain trusted host dependencies |
| Startup failure or reconfiguration signals the shell process group | Treat `FailedToStart` separately; stop a process still in `Starting` through Quickshell's lifecycle API; send TERM/KILL only after a started event and a positive child PID; regression-test the PID-zero path | A compromised Quickshell implementation or same-user process remains outside this plugin's privilege boundary |
| Alert bursts or retries degrade notebook performance | More than five new eligible orders per poll become count-only live/test summaries; outbox cap 64; at most five notification commands per run and eight failed attempts per entry | A summary sacrifices per-order notification detail; after eight failures an entry remains pending and blocked until the applicable queue is explicitly cleared (`notify=false` for all, or test inclusion off for test entries) |
| Tight polling retries degrade notebook performance or trigger throttling | Interval clamp, one poll/store, six-hour chunking, 59-day horizon, process timeout, retry/backoff, no always-running worker daemon | Many configured stores still consume proportional requests and short-lived processes |
| Compromised update changes behavior | Public source, CI, immutable action SHAs, review checklist, marketplace exact-commit scan | Current Omarchy installation tracks mutable upstream HEAD; users must review updates |

## Misuse cases explicitly rejected

- A value such as `https://shop.myshopify.com@evil.example/`, `SHOP.myshopify.com`, `127.0.0.1`, `shop.myshopify.com:443`, or `shop.example.com` never reaches Shopify CLI.
- A remote order name cannot add notification arguments, a command, a URL, or a newline.
- A remote shop name cannot replace the canonical store identity, alter a Shopify CLI argument or click URL, inject markup, or change across pages without rejecting the poll.
- A GraphQL response cannot direct the browser; only the validated local store and numeric legacy ID form the target.
- A partial page set, out-of-window order, malformed cursor, unknown currency/status type, oversized response, 21st page, or more-than-59-day gap cannot advance the watermark.
- A plugin setting cannot request a new Shopify field, scope, mutation, executable, or arbitrary query file.

## Out of scope and operational assumptions

OrderBell does not defend against root, a fully compromised Linux user, a malicious replacement of trusted executables, a compromised Shopify account, Shopify platform compromise, or someone who can unlock and operate the desktop. These are important system risks but not security boundaries this plugin can create.

The host is expected to receive Omarchy, Python, browser, certificate-store, and Shopify CLI security updates. The user is expected to review other unsandboxed Omarchy plugins and lock or encrypt the device.

## Review triggers

Security review is mandatory before adding any write capability, scope, customer field, inbound listener, relay/backend, telemetry, secret, non-Shopify destination, runtime dependency, privilege, background daemon, installer, custom updater, arbitrary URL, or broader retained history.

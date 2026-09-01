# Security Policy

OrderBell is a small but security-sensitive desktop integration: it processes commerce metadata, launches an authenticated CLI, and runs as unsandboxed code inside the long-lived Omarchy shell process. Security reports are treated as release blockers when confidentiality, integrity, availability, or notification correctness may be affected.

## Supported versions

| Version | Supported |
| --- | --- |
| `0.1.x` | Yes |
| `< 0.1.0` | No |

The latest minor release receives security fixes. Older versions may be fixed when practical, but no unsupported version should continue using a retired Shopify API version.

## Reporting a vulnerability

Do not open a public issue for a suspected vulnerability or include a token, store domain, order data, local path, exploit, or raw diagnostic output in a public report.

After the repository is published, use GitHub's **Report a vulnerability** private advisory form for `tbraxa/omarchy-orderbell`. Before that form exists, contact the maintainer privately through an already established channel. Include:

- the affected commit or version;
- the security impact and prerequisites;
- a minimal reproduction using synthetic data;
- whether any credential or real order data might have been exposed; and
- a safe way to contact you.

You should receive acknowledgment within 72 hours. No disclosure deadline is promised before impact and remediation are understood, but the maintainer will coordinate a release and credit when requested.

## Security invariants

Every change must preserve these boundaries:

1. The only requested Shopify scope is `read_orders`. Never request a write scope, `read_reports`, or `read_all_orders`.
2. OrderBell uses Shopify CLI `store auth` and `store execute`. It never locates, reads, copies, logs, exports, or persists Shopify CLI credentials.
3. `shopify store execute` is called with an argument array, a fixed query file, `--json`, and `--version 2026-07`. The plugin never passes `--allow-mutations`.
4. No subprocess is started through `sh -c`, `bash -c`, `eval`, `shell=True`, or a command string assembled from user or remote data.
5. Stores must be canonical lowercase `*.myshopify.com` hostnames. Schemes, paths, ports, query strings, fragments, user information, IP literals, and arbitrary URLs are rejected.
6. Shopify output is hostile input: it is bounded, decoded strictly, type-checked, sanitized, and accepted only after every page needed for the selected inclusive `[since, until]` window is valid. The shop display name is NFKC-normalized, control/format/private-use characters are removed, whitespace is collapsed, output is capped at 64 Unicode code points, and every page must agree on the same sanitized value.
7. Click targets are constructed only from a validated canonical store plus a numeric Shopify legacy order ID. The merchant-controlled display name is never used as identity, a subprocess selector, or part of a URL.
8. Customer names, emails, phones, addresses, notes, line items, raw responses, GraphQL global IDs, tokens, and raw CLI stderr are not persisted.
9. State/config directories are mode `0700`, files are mode `0600`, writes are atomic, and symlinked targets are refused.
10. One worker may poll a given store at a time. A catch-up poll advances its checkpoint by at most six hours while replaying a five-minute overlap, permits at most 20 pages × 100 edges, and refuses automatic catch-up beyond 59 days. Timeouts, response-size limits, rate-limit backoff, a 64-entry outbox, burst summaries, at most five notification attempts per run, and at most eight failed attempts per entry bound resource use.
11. The plugin installs no package, opens no inbound port, uses no privilege elevation, creates no independent daemon, and has no self-update path.
12. Disabling notifications or test-order inclusion is enforced durably before the next network request. Test filtering removes retained test rows, test delivery entries, and only the separately tracked test share of unread state; it does not guess by subtracting from live unread orders.
13. The QML process boundary incrementally bounds arbitrary output chunks, accepts only one strict ASCII-safe JSON envelope after a normal exit, handles process-start failure explicitly, and never sends TERM/KILL before Quickshell has reported a positive child PID.
14. Notification bodies escape remote markup at the Omarchy StyledText boundary; alerts use normal urgency, request a 30-second lifetime, respect DND, and rely on native history plus the unread badge rather than attention-based retries.

The rationale, attack scenarios, and residual risks are detailed in [docs/THREAT_MODEL.md](docs/THREAT_MODEL.md).

## Shopify CLI credential boundary

The official Shopify CLI stores an online access token after `shopify store auth`. Its storage location and implementation are controlled by the installed CLI version. Shopify CLI may preserve or merge scopes already granted in a stored session; OrderBell requests and uses exactly `read_orders`, but it cannot claim that an independently managed CLI session has no other grant. OrderBell deliberately treats that credential store as opaque and asks the CLI to execute the query. It never uses Shopify CLI's `--verbose` mode.

This design prevents OrderBell from handling a plaintext token, but it is not a sandbox. A malicious program or unsandboxed Omarchy plugin running as the same Linux user may be able to access the CLI's files or impersonate executables through a compromised environment. Users should:

- verify `shopify version` and install the CLI only from Shopify's official distribution;
- use full-disk encryption and a locked desktop session;
- keep the granted scope at `read_orders`; and
- remove untrusted plugins and software from the same account.

Removing OrderBell does not revoke Shopify CLI authentication. Follow the current official Shopify CLI/account procedure when revocation is required.

## Dependency and update policy

Runtime dependencies are Omarchy 4, Python's standard library, and official Shopify CLI 4.0 or newer. New runtime libraries require a documented threat/dependency review and must not be installed by plugin code.

The GraphQL Admin API is pinned to stable version `2026-07`, released July 1, 2026 and currently documented by Shopify as accessible until July 16, 2027. Shopify releases stable versions quarterly and supports each for at least 12 months. Maintainers review the developer changelog every quarter and must ship and test a newer pinned version well before retirement; silent fall-forward is treated as a defect, not a migration strategy.

GitHub Actions are pinned to immutable full commit SHAs. Dependency and action updates are reviewed separately from feature changes.

## Emergency disable and rollback

If notification loss, credential/PII exposure, unexpected Shopify writes, or unsafe navigation is suspected, disable OrderBell immediately:

```bash
omarchy plugin disable io.github.tbraxa.orderbell
```

Do not delete state or revoke credentials before preserving a sanitized incident timeline unless active exposure requires it. If credential exposure is plausible, use Shopify's current supported revocation process; OrderBell does not manipulate Shopify CLI credentials. Maintainers will publish a private-advisory-coordinated fix, an immutable replacement tag, impact and upgrade guidance, and explicit state/credential cleanup steps when applicable. Re-enable only a reviewed release whose exact commit is named in the advisory. Current Omarchy 4 removes a disabled bar widget's placement and settings, although OrderBell's durable state and Shopify CLI authentication remain; restore the recorded non-secret configuration after re-enabling. A functional-only regression can be rolled back while disabled by checking out the previously reviewed tag in the installed plugin repository, running `omarchy restart shell` so no prior QML or JavaScript remains loaded, enabling it again, and restoring its settings; security advisories may instead require remaining disabled.

## Disclosure scope

Examples of in-scope findings include command or argument injection, arbitrary URL opening, token or PII disclosure, unsafe state-file handling, notification spoofing, deduplication failure that hides orders, unbounded remote input, write-capable Shopify behavior, and bypasses of store-domain validation.

General Shopify availability, a compromised user account, a malicious same-user process with unrestricted filesystem access, and social engineering outside OrderBell are not vulnerabilities in this repository, though hardening reports are welcome.

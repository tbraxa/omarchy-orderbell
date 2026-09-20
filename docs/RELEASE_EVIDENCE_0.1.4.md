# OrderBell 0.1.4: persistent CLI setup and dependency diagnostics

## Scope

A Node upgrade can strand a globally installed Shopify CLI inside the old Node installation. Version 0.1.4 recommends installing official `@shopify/cli` as a separately managed mise npm tool and maps the specific unavailable-Shopify-shim diagnostic to a sanitized `dependency_missing` error. Store reconnect is not the remedy. Existing installations need the documented one-time host migration; the plugin cannot migrate them automatically.

No runtime installer, fallback executable, new network destination, scope, field, state schema, checkpoint algorithm, notification policy or UI change is introduced. Raw diagnostics remain private. The standard manual-setup marketplace classification must remain.

## Local validation on 2026-09-20

- Python 3.11.16: 71 worker tests passed.
- Node 26.9.0: 25 model tests passed.
- Qt: 41 QML tests passed, none skipped.
- Added an integration regression for unavailable-shim failure, secret redaction, preserved checkpoint, recovery and exactly-once normal notification across re-poll; the existing classifier table also covers the new diagnostic.
- Host migration installed Shopify CLI 4.7.0 under mise's independent npm-tool directory. CLI startup succeeded with both installed Node 26.8.2 and 26.9.0, neither of which contained a Node-local Shopify executable. Runtime selection for this test was process-local, not a change to the user's global Node choice.

## Evidence boundary

Exact-commit CI/CodeQL, installed acceptance times, marketplace update request and release decision are recorded externally after completion. Full new visual/theme/scaling, physical suspend/DND or independent security audit is not claimed for this diagnostic/documentation patch. Runtime compatibility with arbitrary future versions is not guaranteed. Keep CLI upgrades explicitly reviewed and verify successful polling after dependency changes.

## Recovery

Keep store credentials and durable state. The normal bounded catch-up mechanism resumes from the saved watermark after the CLI is restored; it may deliver alerts for missed orders. Never delete state or silently advance the watermark to mask an outage. Rolling back plugin code does not undo the separately managed CLI installation, but restores the less useful generic diagnostic.

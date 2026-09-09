# OrderBell 0.1.3: timestamp-boundary correction

## Scope and incident

A read-only production diagnosis on 2026-09-09 reproduced a persistent `search_filter_violation`: Shopify returned a whole-second lower-bound order for a fractional-second search bound. The previous strict comparison rejected it, retained the fractional checkpoint, and repeated the failure. A control query using whole-second bounds succeeded. No raw store response, store identity, order details or credentials are included here.

This patch normalizes both polling bounds down to whole UTC seconds before query, validation and checkpointing. Existing state remains readable and is not reset. Lower-bound coverage is conservative; the upper fractional tail is deferred to an overlapping subsequent poll. No acceptance tolerance, scope, field, executable, dependency, destination, UI, protocol, notification policy or filesystem-write change is introduced.

## Automated evidence

Local candidate checks on 2026-09-09:

- Python 3.11.16: 70 worker tests passed, including two new regression tests with boundary/recovery subcases.
- Node 26.8.1: 25 model tests passed.
- Qt QML: 41 tests passed, none skipped.
- Initial invocation with the ambient mise shim failed before worker execution because the parent workspace configuration was untrusted. Tests were then run using explicit Python/toolchain paths without changing trust or user configuration; this is an environment correction, not a flaky-test retry.

The new tests cover baseline, ordinary polling, catch-up and backward-clock windows; both inclusive endpoints; rejection one microsecond outside; recovery from a fractional failed checkpoint; identical query and checkpoint precision; deferred fractional-tail coverage; and repeat-poll notification deduplication.

## Release and acceptance boundary

The final commit, exact-commit CI/CodeQL, installed real-store recovery and repeated poll results must be linked from the release/update request after they occur. This file does not invent those results. Existing version 0.1.2 manual UI and notification evidence is historical; no new full light/dark/scaling, physical suspend, DND or naturally occurring new-order acceptance is claimed for this unchanged UI/notification patch. Marketplace approval requires review of the new exact commit and is not inherited from 0.1.2.

## Upgrade and rollback

Update the installed plugin using the reviewed source and immediately restart the Omarchy shell. Preserve durable state and Shopify CLI authentication. Successful reconciliation resets the failure count automatically. Rolling back code to v0.1.2 preserves state compatibility but can reintroduce the timestamp-boundary stall. Do not delete state or rebaseline to hide the failure.

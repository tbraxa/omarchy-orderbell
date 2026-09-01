# Release Evidence: OrderBell 0.1.1

This record supplements the full [0.1.0 evidence](RELEASE_EVIDENCE_0.1.0.md). The immutable `v0.1.1` tag, GitHub release, CI run, and marketplace validation are the canonical mapping to the exact patch-release commit; an in-tree document cannot safely self-reference its own commit hash.

## Patch scope

- Plugin ID: `io.github.tbraxa.orderbell`
- Version/tag: `0.1.1` / `v0.1.1`
- Runtime scope remains local, read-only polling through the official Shopify CLI with requested scope `read_orders`.
- No data field, permission, dependency, process, network destination, GraphQL query, state transition, notification policy, or UI flow changed.

After `v0.1.0` was published but before marketplace submission, GitHub CodeQL reported `js/incomplete-sanitization` at the redundant QML-side Admin order URL validator. The dynamic regular expression interpolated a store that had already passed the strict canonical `*.myshopify.com` grammar, and every regular-expression metacharacter admitted by that grammar was escaped. Independent review therefore found no controllable expression injection or unsafe URL path. The implementation was nevertheless replaced with a literal canonical-origin prefix comparison followed by a static numeric legacy-order-ID expression. This removes the ambiguous construction, preserves the exact accepted URL language, and remains safe if the store grammar is extended later.

`v0.1.0` remains an immutable historical release. `v0.1.1` is the first marketplace candidate and the recommended version.

## Required exact-commit gates

Before tagging or marketplace submission, the `0.1.1` commit must independently pass:

- Python worker tests, JavaScript model tests including hostile URL suffix/origin cases, and QML tests with no skips;
- local Omarchy validation plus public GitHub CI and full-history secret scanning;
- GitHub CodeQL for Actions, JavaScript/TypeScript, and Python with no open alert on the exact commit;
- the current Omarchy marketplace validator and automated security baseline with no finding or capability;
- installation of the exact public commit without changing bar settings or durable OrderBell state;
- an authorized read-only poll that preserves the retained unread/recent identity, leaves the outbox empty, and emits no duplicate notification; and
- the native normal-urgency 30-second test-notification path plus DND suppression/history/restoration.

The live-store, privacy, UX, accessibility, threat-model, rollback, and accepted-limit evidence recorded for `0.1.0` remains applicable because the patch does not alter those paths or contracts. A fresh naturally occurring order on `0.1.1` is still required before claiming a complete live new-order transition on the exact patch release.

## Release-owner decision

The owner approves marketplace submission only if the final public `v0.1.1` commit, installed checkout, green CI/CodeQL results, marketplace validation, release notes, and proposed issue body all match this record. The five marketplace checklist statements still require explicit owner confirmation immediately before issue creation.

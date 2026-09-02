# Release Evidence: OrderBell 0.1.2

This is a pre-release gate record, not a statement that `0.1.2` has shipped or passed review. It supplements the immutable historical [0.1.0 evidence](RELEASE_EVIDENCE_0.1.0.md) and [0.1.1 evidence](RELEASE_EVIDENCE_0.1.1.md). The final 40-character commit SHA, public CI and CodeQL runs, tag, release, installed-checkout acceptance, and marketplace re-review must be recorded in external evidence bound to the exact release commit; none is invented here.

## Patch scope

- Plugin ID: `io.github.tbraxa.orderbell`
- Intended version/tag: `0.1.2` / `v0.1.2`
- Runtime scope remains local, read-only polling through official Shopify CLI with requested scope `read_orders`.
- Shopify permission, GraphQL query and API version, retained fields, notification policy, UI flow, dependencies, executables, and network destinations do not change.
- Durable state-write implementation and its failure tests change to close the marketplace review's path-rebinding/time-of-check-time-of-use finding.
- The automatically discovered root `AGENTS.md` is removed from the distributable tree. Ordinary contributor documentation points to the normative security, privacy, architecture, data, and test contracts instead, and CI rejects a tracked case-insensitive `AGENTS.md` basename at any path.

## State-write remediation

The prior writer validated pathnames and later used pathname-based temporary creation, replacement, mode handling, and cleanup. A hostile same-user process could try to replace a checked directory component between those operations. Although a fully compromised Linux user is not a privilege boundary OrderBell can defend, a save must not be redirected through a changed pathname.

The `0.1.2` transaction is required to:

1. open the owner-private store-state directory once with directory, no-follow, and close-on-exec flags;
2. verify through the held descriptor and a no-follow path lookup that the expected path still names the same owner-private directory device/inode;
3. inspect the existing target relative to that descriptor and accept only an owner-owned, single-link, mode-private regular file;
4. create a random temporary basename relative to the descriptor with exclusive, no-follow, close-on-exec flags and mode `0600`;
5. write and synchronize through the still-open temporary file descriptor, then verify its type, owner, link count, mode, size, and device/inode against the directory entry;
6. revalidate the target and directory binding before descriptor-relative atomic replacement;
7. verify the installed target is the inode written by the worker, synchronize the held directory, and verify the installed inode and expected directory binding again; and
8. perform failure cleanup only by unlinking the temporary basename relative to the held directory descriptor.

Deterministic failure injection must cover descriptor-relative operation, directory replacement, target replacement with a link, temporary-entry substitution, post-replacement target substitution, file and directory synchronization failure, zero-byte writes, and temporary cleanup. An attacker-selected external file or replacement directory must remain unchanged.

This remediation prevents pathname-component replacement from redirecting the transaction after the verified directory descriptor is opened. It is not a sandbox against an unrestricted process running as the same Linux user. If a failure occurs after replacement or during directory synchronization, a new directory entry can already be visible even though its identity or crash durability was not accepted; the caller cannot assume that either the previous or intended state remains, and a later invocation must revalidate the on-disk state before use.

## Required exact-commit gates

Every status below remains pending until evidence names the same final release commit. A local command result from an earlier dirty worktree is not release evidence.

| Gate | Required evidence | Pre-release status |
| --- | --- | --- |
| Identity | Clean tree and full 40-character SHA; manifest, changelog and intended tag all say `0.1.2` | Pending |
| Python worker | Full-SHA-pinned CI setup of Python 3.11 plus compile check and complete deterministic worker suite, including every new state-write swap and failure case, with no skip or retry | Pending |
| Model and QML | JavaScript tests, deterministic QML suite, parse/lint review, and live Omarchy 4 load | Pending |
| Repository policy | Manifest/docs/link validation; CI proof that no tracked case-insensitive `AGENTS.md` basename exists; full-history/worktree secret scan | Pending |
| Independent security review | Code review of the held-directory transaction, failure cleanup, post-replacement ambiguity, tests, threat model, and residual same-user risk | Pending |
| Public automation | Green GitHub CI and CodeQL for Actions, JavaScript/TypeScript, and Python on the exact commit; URLs recorded externally | Pending |
| Installed update | Exact public commit installed over retained state, followed immediately by shell restart; state/unread identity preserved and no duplicate alert | Pending |
| Authorized read-only acceptance | Successful poll without mutation or replay, plus normal-urgency 30-second local test notification and DND/history/restoration checks | Pending |
| Marketplace | Current validator, automated security baseline, and manual re-review accept the exact `0.1.2` commit with both prior blockers resolved | Pending |
| Release decision | Human release owner verifies all evidence, creates the immutable tag/release, and explicitly approves marketplace resubmission | Pending |

The exact commands and manual scenarios are normative in [TEST_PLAN.md](TEST_PLAN.md) and [RELEASE_CHECKLIST.md](RELEASE_CHECKLIST.md). Marketplace validation is exact-commit review, not a general security certification.

## Historical and live-evidence boundary

The previous evidence remains historical and must not be rewritten to imply it tested this state writer. An authorized read-only update/re-poll on the exact `0.1.2` candidate can establish state compatibility, no replay, and local notification behavior. A fresh naturally occurring order on `0.1.2` is required before claiming a complete live new-order transition on the exact patch release; OrderBell must not create or modify a production order to manufacture that event.

## Release-owner decision

Do not tag, publish, recommend, or resubmit `0.1.2` until every applicable gate above and every item in the release checklist has commit-bound evidence. The owner must compare the final installed checkout, tag, release notes, CI/CodeQL results, marketplace result, and proposed listing to the same exact commit immediately before approval.

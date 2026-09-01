# Release Checklist

This checklist is a gate, not a claim that publication is complete. The version named by `manifest.json` remains unpublished until every applicable item has dated, commit-bound evidence, the final release commit is tagged, and a human release owner approves it.

## 1. Identity and scope

- [ ] Release commit is identified by a full 40-character SHA and the worktree is clean.
- [ ] `manifest.json` ID remains permanently `io.github.tbraxa.orderbell`, name `OrderBell`, author `Tomas / tbraxa`, and version matches the tag/changelog.
- [ ] Plugin kinds are `service` and `bar-widget`; all entry points exist and are regular non-symlink files.
- [ ] Runtime/plugin and user installation paths use exactly `read_orders` and contain no mutation, `--allow-mutations`, `read_reports`, `read_all_orders`, write scope, privilege escalation, dependency installer, inbound listener, daemon, telemetry, or self-updater; CI-only runner toolchain provisioning is reviewed separately.
- [ ] Generic commerce icon and unofficial/not-affiliated disclaimer are visible; no Shopify logo or trade dress is shipped.

## 2. Dependency and API review

- [ ] Runtime dependency inventory remains Omarchy 4, Python standard library, and official Shopify CLI >=4.0.
- [ ] No plugin code installs or upgrades a dependency.
- [ ] GitHub Actions are pinned to reviewed full commit SHAs and have least-privilege permissions.
- [ ] GraphQL query is read-only, minimal, and pinned to stable `2026-07`.
- [ ] Shopify changelog/schema checked for the pinned query; a migration issue is scheduled well before July 16, 2027 retirement.

## 3. Automated evidence

- [ ] `python3 -m compileall -q bin tests`
- [ ] `python3 -m unittest discover -s tests -p 'test_worker*.py'`
- [ ] `node --test tests/model.test.mjs`
- [ ] `tests/run-qml`
- [ ] Qt 6 QML parse/lint checks are green or every type-information-only diagnostic is reviewed without blanket suppression.
- [ ] Manifest/repository validation job is green.
- [ ] Secret scan is green on the full history and release worktree.
- [ ] No test is skipped, retried to green, network-dependent, timezone-dependent, or flaky.
- [ ] Failure-injection matrix in `docs/TEST_PLAN.md` is covered and mapped to test names.
- [ ] Catch-up/window, 20 × 100 pagination, 59-day horizon, shop-name canonicalization/consistency, burst-summary, 64-entry outbox, delivery-attempt, and disabled-queue cleanup limits match constants and have deterministic boundary tests.

## 4. Security and privacy review

- [ ] Two-person review (or an independent reviewer) covers subprocess argv, store validation, response bounds, pagination, state transitions, symlink handling, notification sanitization, URL construction, and error redaction.
- [ ] Token/PII canary fixtures prove secrets and prohibited fields never appear in stdout, state, notifications, error messages, or logs.
- [ ] Directory/file modes and atomic write behavior verified on the release filesystem.
- [ ] Corrupt-state recovery instructions move one exact hashed file to a private backup, never delete automatically, and disclose the next quiet baseline.
- [ ] Threat model, data map, privacy notice, security policy, and worker protocol match code field-for-field.
- [ ] Static marketplace security-baseline scan has no blocking finding; any review capability is understood and recorded.
- [ ] No unresolved critical/high vulnerability or correctness bug; accepted lower risks have an owner and rationale.

## 5. Omarchy integration

- [ ] `omarchy plugin validate .` passes on current stable Omarchy 4.
- [ ] Clean install from the exact release source succeeds; disable/re-enable has no stale process and its current Omarchy settings/placement reset is documented.
- [ ] Bar and panel load with no QML/import/binding/process warnings.
- [ ] UI reviewed on stock light and dark themes, 1× and fractional scaling, keyboard-only operation, narrow display, long/hostile shop and order values, friendly-name/canonical-domain distinction, empty/busy/stale/error states, and multi-store state.
- [ ] Colors use Omarchy semantic tokens and status is not conveyed by color alone.
- [ ] Shell restart, logout/login, suspend/resume, offline/recovery, enabled plugin update plus immediate restart, disable, and remove all behave as documented; any mixed-revision response fails closed and clears after restart without replay.
- [ ] Idle/active CPU, memory, process count, and Shopify request cadence are measured and accepted.
- [ ] Removal leaves only documented state and does not touch Shopify CLI credentials.

## 6. Authorized Shopify acceptance

- [ ] Explicit owner authorization and the chosen read-only store scenario are recorded; no production order is created or mutated for testing.
- [ ] OrderBell requests exactly `read_orders`; any unrelated scope already retained by Shopify CLI is documented as outside OrderBell's use.
- [ ] First poll is a quiet baseline.
- [ ] **Send test notification** on the exact final commit verifies normal urgency, remains live beyond 12 seconds, enters native history at about the requested 30-second lifetime, produces no live popup but remains in history under DND, and restores the original DND value without a Shopify order mutation.
- [ ] A naturally occurring genuine order, or an explicitly authorized development-store test order, verifies the named candidate's new-order detection, unread state, privacy output, notification acceptance, and no duplicate replay; any later transition change is excluded from that claim and covered on the exact release by deterministic tests.
- [ ] Restart/update and read-only re-poll preserve the genuine order state without duplicate delivery; offline and suspend behavior are either manually exercised or recorded as residual manual coverage backed by deterministic recovery tests.
- [ ] Evidence records commit(s), versions, UTC time, scenario class, tester and result—no token, store domain, order number/amount, customer data, or local username path.
- [ ] Any dedicated test access/data is cleaned up or revoked using Shopify's current documented process; existing-store credentials remain under Shopify CLI ownership.

## 7. Release and marketplace preparation

- [ ] README installation/removal, limitations, local polling, and future webhook boundary are accurate.
- [ ] The final release commit has a dated changelog section matching the manifest version, an empty `Unreleased` section, and the maintainer's ISO release date.
- [ ] Public GitHub repository root contains one plugin, manifest, README, license, and optional reviewed `preview.png`.
- [ ] Preview contains only synthetic data and no Shopify logo/customer/store/order information.
- [ ] The SemVer tag matching the manifest version points to the reviewed commit; release notes include security/privacy boundaries and known limitations.
- [ ] Marketplace ID availability is rechecked immediately before submission.
- [ ] Proposed marketplace category is `Productivity`; proposed tags are `bar` and `quickshell` (subject to current allowed values).
- [ ] Owner reviews the marketplace submission body and explicitly confirms every ownership/checklist statement before any issue is created.
- [ ] No GitHub repository, release, tag, marketplace issue, or external publication is created by automation without explicit owner approval.

## 8. Post-release

- [ ] Install the public command into a clean test account and compare checked-out SHA with the intended release.
- [ ] Monitor private security reports and functional issues without collecting telemetry.
- [ ] Publish a rollback/security advisory plan for any notification-loss, credential, PII, or write-capability regression.
- [ ] Schedule quarterly Shopify API/changelog and dependency/action review.

Release owner: ____________________  Commit: ________________________________________

UTC approval time: ____________________  Result: **release / do not release**

# Contributing to OrderBell

Thank you for helping make merchant notifications dependable. Correctness, privacy, and a quiet Omarchy-native experience take priority over feature count.

## Development prerequisites

- Omarchy 4 for native plugin validation and manual shell testing.
- Python 3.11 or newer.
- Node.js 20 or newer for JavaScript model tests.
- Qt 6 QML tooling (`qmllint` and `qmlformat`) for static QML checks.
- Shopify CLI 4.0 or newer only for an explicitly authorized Shopify acceptance test.

The runtime plugin uses Python's standard library. Do not add a runtime package manager, installer, vendored executable, or downloaded script.

## Local checks

Run the deterministic suite from the repository root:

```bash
python3 -m compileall -q bin tests
python3 -m unittest discover -s tests -p 'test_worker*.py'
node --test tests/model.test.mjs
tests/run-qml
python3 -m json.tool manifest.json >/dev/null
omarchy plugin validate .
```

`tests/run-qml` resolves Qt 6's `qmltestrunner`, uses only committed deterministic Quickshell process mocks, and fails if the required QML tool is unavailable. CI parses every QML document with `qmlformat` and executes that same deterministic suite. A clean `omarchy plugin validate .`, a reviewed local `qmllint` run with Omarchy's import root, and a real load inside an Omarchy 4 shell are still required before release because generic Ubuntu CI cannot fully reproduce Omarchy's Quickshell module graph.

CI tests use fake `shopify`, `omarchy`, and `xdg-open` executables plus synthetic fixtures. Never put a real token, store response, order, customer, store domain, username-bearing path, or Shopify CLI credential directory into a fixture or log.

## Change rules

- Read `AGENTS.md`, `SECURITY.md`, `PRIVACY.md`, and `docs/ARCHITECTURE.md` before editing runtime behavior.
- Keep the scope exactly `read_orders`; write behavior belongs in a different product and is not accepted here.
- Preserve argument-array subprocess execution and strict canonical store validation.
- Treat GraphQL/CLI output as hostile and bounded.
- Update tests with every behavior change, including negative and recovery cases.
- Use Omarchy semantic theme tokens and native components. Do not hard-code a private theme's colors or modify `/usr/share/omarchy`.
- Use a generic commerce icon. Do not add Shopify logos, product screenshots, or trade dress without documented permission.
- Do not weaken privacy mode, persist new fields, or add a network destination without updating the data map, threat model, privacy notice, and tests.
- Do not claim a live Shopify test occurred unless release evidence records the tester, UTC time, commit, environment, exact read-only scenario, and result—without exposing store or order data. Never create or modify a production order for acceptance testing.

## Pull requests

Keep pull requests focused. Describe the invariant being changed, threat-model impact, data-flow impact, tests added, and rollback plan. Security-sensitive changes should be isolated from formatting or dependency updates.

All commits must leave generated artifacts and credentials out of the repository. GitHub Actions must use full commit SHAs with a human-readable version comment. The release owner completes [docs/RELEASE_CHECKLIST.md](docs/RELEASE_CHECKLIST.md); passing CI alone is not release approval.

Report vulnerabilities privately as described in [SECURITY.md](SECURITY.md).

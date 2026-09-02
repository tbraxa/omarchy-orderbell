from __future__ import annotations

import datetime as dt
import errno
import fcntl
import hashlib
import json
import os
import runpy
import signal
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from typing import Any
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
WORKER = ROOT / "bin" / "orderbell-worker"
FAKES = ROOT / "tests" / "worker_fakes"
STORE = "orderbell-test.myshopify.com"
SHOP_NAME = "Northwind"


def timestamp(seconds: int = 0) -> str:
    value = dt.datetime.now(dt.timezone.utc) + dt.timedelta(seconds=seconds)
    return value.isoformat(timespec="microseconds").replace("+00:00", "Z")


def order(
    identifier: int,
    *,
    created_at: str | None = None,
    name: str | None = None,
    amount: str = "123.45",
    currency: str = "CZK",
    financial: str | None = "PAID",
    fulfillment: str | None = "UNFULFILLED",
    test: bool = False,
) -> dict[str, Any]:
    return {
        "id": f"gid://shopify/Order/{identifier}",
        "legacyResourceId": str(identifier),
        "name": name if name is not None else f"#{identifier}",
        "createdAt": created_at or timestamp(-30),
        "test": test,
        "displayFinancialStatus": financial,
        "displayFulfillmentStatus": fulfillment,
        "currentTotalPriceSet": {
            "shopMoney": {"amount": amount, "currencyCode": currency}
        },
    }


def page(
    nodes: list[dict[str, Any]],
    *,
    has_next: bool = False,
    end_cursor: str | None = None,
    warning: bool = False,
    shop_name: Any = SHOP_NAME,
) -> dict[str, Any]:
    edges = [
        {"cursor": f"cursor-{index}-{node['legacyResourceId']}", "node": node}
        for index, node in enumerate(nodes)
    ]
    if edges:
        if end_cursor is not None:
            edges[-1]["cursor"] = end_cursor
        else:
            end_cursor = edges[-1]["cursor"]
    result: dict[str, Any] = {
        "data": {
            "shop": {"name": shop_name},
            "orders": {
                "edges": edges,
                "pageInfo": {"hasNextPage": has_next, "endCursor": end_cursor},
            }
        }
    }
    if warning:
        result["extensions"] = {
            "search": [
                {
                    "path": ["orders"],
                    "warnings": [
                        {"field": "created_at", "message": "Invalid search field"}
                    ],
                }
            ]
        }
    return result


class WorkerIntegrationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="orderbell-tests-")
        self.base = Path(self.temporary.name)
        self.state_home = self.base / "state"
        self.runtime = self.base / "runtime"
        self.runtime.mkdir(mode=0o700)
        self.state_home.mkdir(mode=0o700)
        self.scenario = self.base / "scenario.json"
        self.shopify_log = self.base / "shopify.log"
        self.omarchy_log = self.base / "omarchy.log"
        self.env = dict(os.environ)
        self.env.update(
            {
                "PATH": f"{FAKES}{os.pathsep}{self.env.get('PATH', '')}",
                "XDG_STATE_HOME": str(self.state_home),
                "XDG_RUNTIME_DIR": str(self.runtime),
                "ORDERBELL_FAKE_SHOPIFY_SCENARIO": str(self.scenario),
                "ORDERBELL_FAKE_SHOPIFY_LOG": str(self.shopify_log),
                "ORDERBELL_FAKE_OMARCHY_LOG": str(self.omarchy_log),
            }
        )
        self.set_execute(page([]))

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def set_scenario(self, value: dict[str, Any]) -> None:
        self.scenario.write_text(json.dumps(value), encoding="utf-8")

    def set_execute(self, first_page: dict[str, Any] | None = None, **spec: Any) -> None:
        if first_page is not None:
            spec.setdefault("pages", {})["__first__"] = {"stdout": first_page}
        self.set_scenario({"execute": spec})

    def run_worker(
        self,
        *arguments: str,
        env: dict[str, str] | None = None,
        wall_timeout: int = 12,
    ) -> tuple[subprocess.CompletedProcess[bytes], dict[str, Any]]:
        effective = dict(self.env)
        if env:
            effective.update(env)
        process = subprocess.run(
            [str(WORKER), *arguments],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=effective,
            timeout=wall_timeout,
            check=False,
        )
        self.assertEqual(process.stderr, b"", process.stderr.decode("utf-8", "replace"))
        self.assertLessEqual(len(process.stdout), 64 * 1024)
        self.assertEqual(process.stdout.count(b"\n"), 1)
        # The QML stream boundary may split arbitrary byte chunks. An
        # ASCII-only JSON wire format makes every split a valid QString split;
        # JSON decoding still restores sanitized Unicode order text.
        process.stdout.decode("ascii", "strict")
        document = json.loads(process.stdout)
        self.assertEqual(
            set(document),
            {
                "schemaVersion",
                "stateAuthoritative",
                "status",
                "store",
                "displayName",
                "recentOrders",
                "unreadCount",
                "pendingCount",
                "error",
                "nextPollSeconds",
                "lastSuccessfulPollAt",
            },
        )
        self.assertIsInstance(document["stateAuthoritative"], bool)
        return process, document

    def log_lines(self, path: Path) -> list[list[str]]:
        if not path.exists():
            return []
        return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines()]

    def assert_notification_presentation(self, call: list[str]) -> None:
        self.assertEqual(
            call[:10],
            [
                "notification",
                "send",
                "--app-name",
                "OrderBell",
                "-g",
                "󰄬",
                "-u",
                "normal",
                "-t",
                "30000",
            ],
        )

    def state_path(self) -> Path:
        key = hashlib.sha256(STORE.encode("ascii")).hexdigest()
        return self.state_home / "orderbell" / "stores" / f"{key}.json"

    def state_json(self) -> dict[str, Any]:
        return json.loads(self.state_path().read_text(encoding="utf-8"))

    def write_state_json(self, state: dict[str, Any]) -> None:
        self.state_path().write_text(
            json.dumps(state, separators=(",", ":")) + "\n",
            encoding="utf-8",
        )
        os.chmod(self.state_path(), 0o600)

    def baseline(self, nodes: list[dict[str, Any]] | None = None) -> dict[str, Any]:
        self.set_execute(page(nodes or []))
        process, document = self.run_worker(
            "poll", "--store", STORE, "--notify", "--privacy"
        )
        self.assertEqual(process.returncode, 0)
        self.assertEqual(document["status"], "baseline")
        return document

    def create_failed_notification_backlog(self, order_id: int) -> dict[str, Any]:
        self.baseline()
        self.set_execute(page([order(order_id)]))
        _, pending = self.run_worker(
            "poll",
            "--store",
            STORE,
            "--notify",
            env={"ORDERBELL_FAKE_OMARCHY_RC": "1"},
        )
        self.assertEqual(pending["status"], "degraded")
        self.assertEqual(pending["pendingCount"], 1)
        return self.state_json()

    def test_invalid_store_input_never_reaches_a_process(self) -> None:
        invalid = [
            "HTTPS://shop.myshopify.com",
            "https://shop.myshopify.com",
            "shop.myshopify.com/admin",
            "shop.myshopify.com:443",
            "shop.myshopify.com?x=1",
            "user@shop.myshopify.com",
            "SHOP.myshopify.com",
            ".myshopify.com",
            "127.0.0.1",
            "shop.myshopify.com;touch-pwned",
            "shop.myshopify.com\n--verbose",
        ]
        for candidate in invalid:
            with self.subTest(candidate=candidate):
                process, result = self.run_worker("poll", "--store", candidate)
                self.assertEqual(process.returncode, 2)
                self.assertEqual(result["error"]["code"], "invalid_store")
                self.assertFalse(result["stateAuthoritative"])
        self.assertFalse(self.shopify_log.exists())
        self.assertFalse((self.base / "pwned").exists())

    def test_valid_dns_boundary_store_names_are_accepted(self) -> None:
        for candidate in ("a.myshopify.com", "shop--name.myshopify.com", f"{'z' * 63}.myshopify.com"):
            with self.subTest(candidate=candidate):
                process, result = self.run_worker("status", "--store", candidate)
                self.assertEqual(process.returncode, 0)
                self.assertEqual(result["store"], candidate)

    def test_first_poll_is_a_silent_baseline_and_files_are_private(self) -> None:
        existing = order(101)
        result = self.baseline([existing])
        self.assertTrue(result["stateAuthoritative"])
        self.assertEqual(result["unreadCount"], 0)
        self.assertEqual(result["pendingCount"], 0)
        self.assertEqual(result["displayName"], SHOP_NAME)
        self.assertEqual(len(result["recentOrders"]), 1)
        self.assertFalse(result["recentOrders"][0]["unread"])
        self.assertFalse(self.omarchy_log.exists())

        state_path = self.state_path()
        self.assertEqual(stat.S_IMODE(state_path.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(state_path.parent.stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE(state_path.parent.parent.stat().st_mode), 0o700)
        lock_dir = self.runtime / "orderbell"
        self.assertEqual(stat.S_IMODE(lock_dir.stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE(next(lock_dir.iterdir()).stat().st_mode), 0o600)

        argv = self.log_lines(self.shopify_log)[0]
        self.assertEqual(argv[:2], ["store", "execute"])
        self.assertEqual(argv[argv.index("--store") + 1], STORE)
        self.assertEqual(argv[argv.index("--version") + 1], "2026-07")
        self.assertIn("--json", argv)
        self.assertIn("--query-file", argv)
        self.assertNotIn("--allow-mutations", argv)
        self.assertNotIn("--verbose", argv)
        variables = json.loads(argv[argv.index("--variables") + 1])
        self.assertRegex(
            variables["query"],
            r"^created_at:>='[0-9]{4}-[0-9]{2}-[0-9]{2}T.*Z' AND "
            r"created_at:<='[0-9]{4}-[0-9]{2}-[0-9]{2}T.*Z'$",
        )
        self.assertEqual(variables["first"], 100)
        self.assertIsNone(variables["after"])

    def test_multiple_orders_are_stable_notified_once_and_marked_read(self) -> None:
        self.baseline()
        same_time = timestamp(-5)
        self.set_execute(page([order(3, created_at=same_time), order(20, created_at=same_time)]))
        process, result = self.run_worker(
            "poll", "--store", STORE, "--notify", "--show-details"
        )
        self.assertEqual(process.returncode, 0)
        self.assertEqual(result["status"], "ok")
        self.assertEqual(result["unreadCount"], 2)
        self.assertEqual(result["pendingCount"], 0)

        notification_calls = self.log_lines(self.omarchy_log)
        self.assertEqual(len(notification_calls), 2)
        # Stable order is (createdAt, GraphQL id), independent of response order.
        self.assertEqual(notification_calls[0][-1], f"https://{STORE}/admin/orders/20")
        self.assertEqual(notification_calls[1][-1], f"https://{STORE}/admin/orders/3")
        for call in notification_calls:
            self.assert_notification_presentation(call)
            self.assertEqual(call[-3], "--exec")
            self.assertEqual(call[-2], "xdg-open")
            self.assertEqual(len(call[-1].split()), 1)

        _, duplicate = self.run_worker(
            "poll", "--store", STORE, "--notify", "--show-details"
        )
        self.assertEqual(duplicate["unreadCount"], 2)
        self.assertEqual(len(self.log_lines(self.omarchy_log)), 2)

        _, marked = self.run_worker("mark-read", "--store", STORE)
        self.assertEqual(marked["unreadCount"], 0)
        self.assertTrue(all(not item["unread"] for item in marked["recentOrders"]))

    def test_exactly_five_orders_remain_individual_notifications(self) -> None:
        self.baseline()
        created_at = timestamp(-5)
        self.set_execute(
            page(
                [order(30 + index, created_at=created_at) for index in range(5)]
            )
        )

        _, result = self.run_worker(
            "poll", "--store", STORE, "--notify", "--privacy"
        )

        self.assertEqual(result["status"], "ok")
        self.assertEqual(result["unreadCount"], 5)
        self.assertEqual(result["pendingCount"], 0)
        calls = self.log_lines(self.omarchy_log)
        self.assertEqual(len(calls), 5)
        for call in calls:
            self.assert_notification_presentation(call)
        self.assertTrue(all(call[10] == "New Shopify order" for call in calls))
        self.assertTrue(all(call[-3] == "--exec" for call in calls))

    def test_pagination_is_complete_before_watermark_advance(self) -> None:
        self.baseline()
        first = page([order(201)], has_next=True, end_cursor="next-page")
        second = page([order(202)])
        self.set_scenario(
            {
                "execute": {
                    "pages": {
                        "__first__": {"stdout": first},
                        "next-page": {"stdout": second},
                    }
                }
            }
        )
        _, result = self.run_worker("poll", "--store", STORE, "--no-notify")
        self.assertEqual(result["status"], "ok")
        self.assertEqual(result["unreadCount"], 2)
        calls = self.log_lines(self.shopify_log)
        self.assertEqual(len(calls), 3)  # baseline plus both pages
        variables = json.loads(calls[-1][calls[-1].index("--variables") + 1])
        self.assertEqual(variables["after"], "next-page")

    def test_shop_display_name_is_normalized_sanitized_and_persisted(self) -> None:
        hostile_formatting = " \u202e  Ｎｏｒｔｈｗｉｎｄ\n\t  Prague  "
        self.set_execute(page([], shop_name=hostile_formatting))
        process, result = self.run_worker("poll", "--store", STORE)
        self.assertEqual(process.returncode, 0)
        self.assertEqual(result["displayName"], "Northwind Prague")
        self.assertEqual(self.state_json()["displayName"], "Northwind Prague")
        self.assertNotIn("\u202e", json.dumps(result, ensure_ascii=False))

        long_name = "Ž" * 80
        self.set_execute(page([], shop_name=long_name))
        _, truncated = self.run_worker("poll", "--store", STORE)
        self.assertEqual(truncated["displayName"], "Ž" * 64)
        self.assertEqual(len(truncated["displayName"]), 64)

    def test_malformed_shop_display_name_fails_closed(self) -> None:
        malformed: list[dict[str, Any]] = []
        missing = page([])
        del missing["data"]["shop"]
        malformed.append(missing)
        malformed.append({**page([]), "data": {**page([])["data"], "shop": None}})
        malformed.append(page([], shop_name=None))
        malformed.append(page([], shop_name="\u202e\n\t"))
        malformed.append(page([], shop_name="x" * 1025))
        extra = page([])
        extra["data"]["shop"]["unexpected"] = "field"
        malformed.append(extra)

        for index, document in enumerate(malformed):
            with self.subTest(index=index):
                store = f"malformed-shop-{index}.myshopify.com"
                self.set_execute(document)
                process, result = self.run_worker("poll", "--store", store)
                self.assertNotEqual(process.returncode, 0)
                self.assertEqual(result["error"]["code"], "malformed_response")
                self.assertIsNone(result["displayName"])

    def test_shop_display_name_must_match_across_every_page(self) -> None:
        self.baseline()
        before = self.state_json()["watermarkCreatedAt"]
        first = page([order(205)], has_next=True, end_cursor="shop-name-page", shop_name="Northwind")
        second = page([order(206)], shop_name="Northwind Europe")
        self.set_scenario(
            {
                "execute": {
                    "pages": {
                        "__first__": {"stdout": first},
                        "shop-name-page": {"stdout": second},
                    }
                }
            }
        )
        process, result = self.run_worker("poll", "--store", STORE)
        self.assertNotEqual(process.returncode, 0)
        self.assertEqual(result["error"]["code"], "malformed_response")
        self.assertEqual(result["displayName"], SHOP_NAME)
        self.assertEqual(self.state_json()["displayName"], SHOP_NAME)
        self.assertEqual(self.state_json()["watermarkCreatedAt"], before)

    def test_legacy_schema_v1_state_without_display_name_migrates_losslessly(self) -> None:
        self.baseline()
        state = self.state_json()
        del state["displayName"]
        self.write_state_json(state)

        process, legacy = self.run_worker("status", "--store", STORE)
        self.assertEqual(process.returncode, 0)
        self.assertIsNone(legacy["displayName"])
        self.assertNotIn("displayName", self.state_json())

        self.set_execute(page([], shop_name="Northwind Prague"))
        process, migrated = self.run_worker("poll", "--store", STORE)
        self.assertEqual(process.returncode, 0)
        self.assertEqual(migrated["displayName"], "Northwind Prague")
        self.assertEqual(self.state_json()["displayName"], "Northwind Prague")

    def test_noncanonical_display_name_in_state_is_refused(self) -> None:
        self.baseline()
        for invalid in (" Northwind ", "Northwind\nShop", "\u202eNorthwind", "x" * 65, 42):
            with self.subTest(invalid=invalid):
                state = self.state_json()
                state["displayName"] = invalid
                self.write_state_json(state)
                process, result = self.run_worker("status", "--store", STORE)
                self.assertNotEqual(process.returncode, 0)
                self.assertEqual(result["error"]["code"], "state_corrupt")
                # Restore a valid state before testing the next hostile value.
                state["displayName"] = SHOP_NAME
                self.write_state_json(state)

    def test_invalid_state_timestamps_are_nonretryable_local_corruption(self) -> None:
        self.baseline([order(204)])
        original = self.state_json()
        calls_before = len(self.log_lines(self.shopify_log))

        for location in ("recent", "watermark", "seen", "last-success"):
            with self.subTest(location=location):
                state = json.loads(json.dumps(original))
                if location == "recent":
                    state["recentOrders"][0]["createdAt"] = "not-a-timestamp"
                elif location == "watermark":
                    state["watermarkCreatedAt"] = "not-a-timestamp"
                elif location == "seen":
                    seen_id = next(iter(state["seen"]))
                    state["seen"][seen_id] = "not-a-timestamp"
                else:
                    state["lastSuccessfulPollAt"] = "not-a-timestamp"
                self.write_state_json(state)

                process, result = self.run_worker("poll", "--store", STORE)

                self.assertNotEqual(process.returncode, 0)
                self.assertEqual(result["error"]["code"], "state_corrupt")
                self.assertFalse(result["error"]["retryable"])
                self.assertFalse(result["stateAuthoritative"])
                self.assertIn("OrderBell state", result["error"]["message"])
                self.assertEqual(len(self.log_lines(self.shopify_log)), calls_before)

        self.write_state_json(original)

    def test_extreme_offset_timestamps_keep_remote_and_state_error_contexts(self) -> None:
        self.baseline()
        original = self.state_json()
        before = original["watermarkCreatedAt"]
        extremes = (
            "0001-01-01T00:00:00+23:59",
            "9999-12-31T23:59:59-23:59",
        )

        for value in extremes:
            with self.subTest(context="remote", value=value):
                self.set_execute(page([order(207, created_at=value)]))
                process, result = self.run_worker("poll", "--store", STORE)
                self.assertNotEqual(process.returncode, 0)
                self.assertEqual(result["error"]["code"], "malformed_response")
                self.assertTrue(result["error"]["retryable"])
                self.assertEqual(self.state_json()["watermarkCreatedAt"], before)

        valid_state = self.state_json()
        for value in extremes:
            with self.subTest(context="state", value=value):
                state = json.loads(json.dumps(valid_state))
                state["watermarkCreatedAt"] = value
                self.write_state_json(state)
                calls_before = len(self.log_lines(self.shopify_log))

                process, result = self.run_worker("poll", "--store", STORE)

                self.assertNotEqual(process.returncode, 0)
                self.assertEqual(result["error"]["code"], "state_corrupt")
                self.assertFalse(result["error"]["retryable"])
                self.assertEqual(len(self.log_lines(self.shopify_log)), calls_before)

        self.write_state_json(valid_state)

    def test_unhashable_outbox_kind_is_nonretryable_local_corruption(self) -> None:
        self.baseline([order(208)])
        state = self.state_json()
        public = state["recentOrders"][0]
        state["outbox"] = [
            {
                "kind": [],
                "eventId": public["idHash"],
                "order": public,
                "attempts": 0,
            }
        ]
        self.write_state_json(state)
        calls_before = len(self.log_lines(self.shopify_log))

        process, result = self.run_worker("poll", "--store", STORE)

        self.assertNotEqual(process.returncode, 0)
        self.assertEqual(result["error"]["code"], "state_corrupt")
        self.assertFalse(result["error"]["retryable"])
        self.assertEqual(len(self.log_lines(self.shopify_log)), calls_before)

    def test_pagination_cursor_metadata_is_fail_closed(self) -> None:
        self.baseline()
        prior = self.state_json()["watermarkCreatedAt"]

        mismatched = page([order(211)])
        mismatched["data"]["orders"]["pageInfo"]["endCursor"] = "not-the-edge"
        self.set_execute(mismatched)
        _, mismatch = self.run_worker("poll", "--store", STORE)
        self.assertEqual(mismatch["error"]["code"], "malformed_response")
        self.assertEqual(self.state_json()["watermarkCreatedAt"], prior)

        first = page([order(212)], has_next=True, end_cursor="reused-cursor")
        second = page([order(213)], end_cursor="reused-cursor")
        self.set_scenario(
            {
                "execute": {
                    "pages": {
                        "__first__": {"stdout": first},
                        "reused-cursor": {"stdout": second},
                    }
                }
            }
        )
        _, reused = self.run_worker("poll", "--store", STORE)
        self.assertEqual(reused["error"]["code"], "malformed_response")
        self.assertEqual(self.state_json()["watermarkCreatedAt"], prior)

        duplicated_order = order(214)
        first = page(
            [duplicated_order],
            has_next=True,
            end_cursor="duplicate-order-page",
        )
        second = page([duplicated_order], end_cursor="different-edge-cursor")
        self.set_scenario(
            {
                "execute": {
                    "pages": {
                        "__first__": {"stdout": first},
                        "duplicate-order-page": {"stdout": second},
                    }
                }
            }
        )
        _, duplicated = self.run_worker("poll", "--store", STORE)
        self.assertEqual(duplicated["error"]["code"], "malformed_response")
        self.assertEqual(self.state_json()["watermarkCreatedAt"], prior)

        empty_continuation = page([])
        empty_continuation["data"]["orders"]["pageInfo"] = {
            "hasNextPage": True,
            "endCursor": "impossible",
        }
        self.set_execute(empty_continuation)
        _, empty = self.run_worker("poll", "--store", STORE)
        self.assertEqual(empty["error"]["code"], "malformed_response")
        self.assertEqual(self.state_json()["watermarkCreatedAt"], prior)

    def test_page_limit_is_an_explicit_lossless_catchup_error(self) -> None:
        self.baseline()
        prior = self.state_json()["watermarkCreatedAt"]
        pages: dict[str, Any] = {}
        key = "__first__"
        created_at = timestamp(-5)
        for page_index in range(20):
            next_cursor = f"page-{page_index + 1}"
            nodes = [
                order(10_000 + page_index * 100 + item, created_at=created_at)
                for item in range(100)
            ]
            pages[key] = {
                "stdout": page(
                    nodes,
                    has_next=True,
                    end_cursor=next_cursor,
                )
            }
            key = next_cursor
        self.set_scenario({"execute": {"pages": pages}})

        process, result = self.run_worker(
            "poll", "--store", STORE, "--timeout", "20", wall_timeout=25
        )
        self.assertNotEqual(process.returncode, 0)
        self.assertEqual(result["error"]["code"], "catchup_too_large")
        self.assertFalse(result["error"]["retryable"])
        self.assertEqual(self.state_json()["watermarkCreatedAt"], prior)
        self.assertEqual(self.state_json()["unreadCount"], 0)

    def test_durable_outbox_retries_after_restart_without_losing_order(self) -> None:
        self.baseline()
        self.set_execute(page([order(301)]))
        failing_env = {
            "ORDERBELL_FAKE_OMARCHY_RC": "1",
            "ORDERBELL_FAKE_OMARCHY_STDERR": "shpat_NOTIFICATION_SECRET",
        }
        _, degraded = self.run_worker(
            "poll", "--store", STORE, "--notify", env=failing_env
        )
        self.assertEqual(degraded["status"], "degraded")
        self.assertEqual(degraded["pendingCount"], 1)
        self.assertNotIn("shpat_", json.dumps(degraded))
        self.assertEqual(len(self.state_json()["outbox"]), 1)

        _, recovered = self.run_worker("poll", "--store", STORE, "--notify")
        self.assertEqual(recovered["status"], "ok")
        self.assertEqual(recovered["pendingCount"], 0)
        self.assertEqual(recovered["unreadCount"], 1)
        self.assertEqual(len(self.log_lines(self.omarchy_log)), 2)
        state_text = self.state_path().read_text(encoding="utf-8")
        self.assertNotIn("shpat_", state_text)

    def test_restart_backlog_drains_before_offline_fetch_failure(self) -> None:
        pending = self.create_failed_notification_backlog(302)
        checkpoint = pending["watermarkCreatedAt"]
        self.set_execute(
            None,
            default={"stderr": "ENOTFOUND network", "exitCode": 1},
        )

        process, result = self.run_worker("poll", "--store", STORE, "--notify")

        self.assertNotEqual(process.returncode, 0)
        self.assertEqual(result["status"], "error")
        self.assertEqual(result["error"]["code"], "offline")
        self.assertTrue(result["stateAuthoritative"])
        self.assertEqual(result["pendingCount"], 0)
        self.assertEqual(self.state_json()["outbox"], [])
        self.assertEqual(self.state_json()["watermarkCreatedAt"], checkpoint)
        self.assertEqual(len(self.log_lines(self.omarchy_log)), 2)
        self.assertEqual(len(self.log_lines(self.shopify_log)), 3)

    def test_restart_backlog_drains_before_auth_fetch_failure(self) -> None:
        pending = self.create_failed_notification_backlog(303)
        checkpoint = pending["watermarkCreatedAt"]
        self.set_execute(
            None,
            default={"stderr": "HTTP 401 unauthorized", "exitCode": 1},
        )

        process, result = self.run_worker("poll", "--store", STORE, "--notify")

        self.assertNotEqual(process.returncode, 0)
        self.assertEqual(result["status"], "error")
        self.assertEqual(result["error"]["code"], "authentication_required")
        self.assertTrue(result["stateAuthoritative"])
        self.assertEqual(result["pendingCount"], 0)
        self.assertEqual(self.state_json()["outbox"], [])
        self.assertEqual(self.state_json()["watermarkCreatedAt"], checkpoint)
        self.assertEqual(len(self.log_lines(self.omarchy_log)), 2)
        self.assertEqual(len(self.log_lines(self.shopify_log)), 3)

    def test_restart_backlog_drains_before_permanent_catchup_error(self) -> None:
        state = self.create_failed_notification_backlog(304)
        state["watermarkCreatedAt"] = timestamp(-60 * 24 * 60 * 60)
        self.write_state_json(state)
        checkpoint = state["watermarkCreatedAt"]
        shopify_calls = len(self.log_lines(self.shopify_log))

        process, result = self.run_worker("poll", "--store", STORE, "--notify")

        self.assertNotEqual(process.returncode, 0)
        self.assertEqual(result["status"], "error")
        self.assertEqual(result["error"]["code"], "catchup_window_exceeded")
        self.assertFalse(result["error"]["retryable"])
        self.assertTrue(result["stateAuthoritative"])
        self.assertEqual(result["pendingCount"], 0)
        self.assertEqual(self.state_json()["outbox"], [])
        self.assertEqual(self.state_json()["watermarkCreatedAt"], checkpoint)
        self.assertEqual(len(self.log_lines(self.omarchy_log)), 2)
        self.assertEqual(len(self.log_lines(self.shopify_log)), shopify_calls)

    def test_failed_restart_delivery_blocks_fetch_and_increments_attempt(self) -> None:
        self.create_failed_notification_backlog(306)
        shopify_calls = len(self.log_lines(self.shopify_log))

        process, result = self.run_worker(
            "poll",
            "--store",
            STORE,
            "--notify",
            env={"ORDERBELL_FAKE_OMARCHY_RC": "1"},
        )

        self.assertEqual(process.returncode, 0)
        self.assertEqual(result["status"], "degraded")
        self.assertEqual(result["error"]["code"], "notification_failed")
        self.assertTrue(result["stateAuthoritative"])
        self.assertEqual(result["pendingCount"], 1)
        self.assertEqual(self.state_json()["outbox"][0]["attempts"], 2)
        self.assertEqual(len(self.log_lines(self.omarchy_log)), 2)
        self.assertEqual(len(self.log_lines(self.shopify_log)), shopify_calls)

    def test_legacy_order_outbox_shape_is_migrated_without_losing_delivery(self) -> None:
        self.baseline()
        self.set_execute(page([order(305)]))
        _, pending = self.run_worker(
            "poll",
            "--store",
            STORE,
            "--notify",
            env={"ORDERBELL_FAKE_OMARCHY_RC": "1"},
        )
        self.assertEqual(pending["pendingCount"], 1)
        state = self.state_json()
        state["outbox"][0].pop("kind")
        self.write_state_json(state)

        _, recovered = self.run_worker("poll", "--store", STORE, "--notify")
        self.assertEqual(recovered["status"], "ok")
        self.assertEqual(recovered["pendingCount"], 0)
        self.assertEqual(len(self.log_lines(self.omarchy_log)), 2)

    def test_privacy_notification_shows_store_and_statuses_but_no_order_details(self) -> None:
        self.baseline()
        self.set_execute(
            page(
                [
                    order(
                        311,
                        name="#PRIVATE-311",
                        amount="987654.32",
                        financial="PARTIALLY_PAID",
                        fulfillment="IN_PROGRESS",
                    )
                ]
            )
        )
        _, result = self.run_worker(
            "poll", "--store", STORE, "--notify", "--privacy"
        )
        self.assertEqual(result["status"], "ok")
        call = self.log_lines(self.omarchy_log)[0]
        self.assert_notification_presentation(call)
        displayed = " ".join(call[10:12])
        self.assertIn(SHOP_NAME, displayed)
        self.assertNotIn(STORE, displayed)
        self.assertIn("Payment: Partially Paid", displayed)
        self.assertIn("Fulfillment: In Progress", displayed)
        self.assertNotIn("#PRIVATE-311", displayed)
        self.assertNotIn("987654.32", displayed)
        self.assertNotIn("CZK", displayed)
        self.assertEqual(call[-1], f"https://{STORE}/admin/orders/311")

    def test_hostile_shop_markup_is_plain_text_at_every_notification_boundary(self) -> None:
        self.baseline()
        remote_name = '<b>North &amp;\n--exec "Shop"</b><br>'
        stored_name = '<b>North &amp; --exec "Shop"</b><br>'
        encoded_name = "&lt;b&gt;North &amp;amp; --exec &quot;Shop&quot;&lt;/b&gt;&lt;br&gt;"

        self.set_execute(page([order(312)], shop_name=remote_name))
        _, private = self.run_worker(
            "poll", "--store", STORE, "--notify", "--privacy"
        )
        self.assertEqual(private["displayName"], stored_name)

        self.set_execute(page([order(313)], shop_name=remote_name))
        _, detailed = self.run_worker(
            "poll", "--store", STORE, "--notify", "--show-details"
        )
        self.assertEqual(detailed["displayName"], stored_name)

        created_at = timestamp(-5)
        self.set_execute(
            page(
                [order(314 + index, created_at=created_at) for index in range(6)],
                shop_name=remote_name,
            )
        )
        _, burst = self.run_worker(
            "poll", "--store", STORE, "--notify", "--privacy"
        )
        self.assertEqual(burst["displayName"], stored_name)

        _, tested = self.run_worker(
            "test-notification", "--store", STORE, "--privacy"
        )
        self.assertEqual(tested["displayName"], stored_name)
        self.assertEqual(self.state_json()["displayName"], stored_name)

        calls = self.log_lines(self.omarchy_log)
        self.assertEqual(len(calls), 4)
        expected_bodies = [
            f"{encoded_name} · Payment: Paid · Fulfillment: Unfulfilled",
            f"{encoded_name} · 123.45 CZK · Paid · Unfulfilled",
            f"Store: {encoded_name}",
            f"{encoded_name} · Order details are hidden.",
        ]
        for call, expected_body in zip(calls, expected_bodies, strict=True):
            self.assert_notification_presentation(call)
            self.assertEqual(call[11], expected_body)
            self.assertNotIn("<", call[11])
            self.assertNotIn(">", call[11])
            self.assertEqual(call.count("--exec"), 1)
            self.assertEqual(call[-3], "--exec")
            self.assertEqual(call[-2], "xdg-open")

    def test_burst_is_one_store_labeled_count_only_notification(self) -> None:
        self.baseline()
        created_at = timestamp(-5)
        self.set_execute(
            page(
                [order(320 + index, created_at=created_at) for index in range(12)]
            )
        )
        _, result = self.run_worker(
            "poll", "--store", STORE, "--notify", "--privacy"
        )
        self.assertEqual(result["status"], "ok")
        self.assertEqual(result["unreadCount"], 12)
        self.assertEqual(result["pendingCount"], 0)
        calls = self.log_lines(self.omarchy_log)
        self.assertEqual(len(calls), 1)
        self.assert_notification_presentation(calls[0])
        self.assertEqual(calls[0][10], "12 new Shopify orders")
        self.assertEqual(calls[0][11], f"Store: {SHOP_NAME}")
        self.assertEqual(calls[0][-1], f"https://{STORE}/admin/orders")
        displayed = " ".join(calls[0][10:12])
        self.assertNotIn("123.45", displayed)
        self.assertNotIn("Paid", displayed)
        self.assertNotIn("Unfulfilled", displayed)

    def test_burst_notification_prefixes_flag_like_shop_name(self) -> None:
        self.baseline()
        created_at = timestamp(-5)
        self.set_execute(
            page(
                [order(325 + index, created_at=created_at) for index in range(6)],
                shop_name="--exec",
            )
        )

        _, result = self.run_worker(
            "poll", "--store", STORE, "--notify", "--privacy"
        )

        self.assertEqual(result["status"], "ok")
        calls = self.log_lines(self.omarchy_log)
        self.assertEqual(len(calls), 1)
        self.assert_notification_presentation(calls[0])
        self.assertEqual(calls[0][11], "Store: --exec")
        self.assertEqual(calls[0].count("--exec"), 1)
        self.assertEqual(calls[0][-3:], ["--exec", "xdg-open", f"https://{STORE}/admin/orders"])

    def test_failed_burst_stays_compact_and_retries_as_one_summary(self) -> None:
        self.baseline()
        created_at = timestamp(-5)
        nodes = [order(330 + index, created_at=created_at) for index in range(12)]
        self.set_execute(page(nodes))
        _, pending = self.run_worker(
            "poll",
            "--store",
            STORE,
            "--notify",
            env={"ORDERBELL_FAKE_OMARCHY_RC": "1"},
        )
        self.assertEqual(pending["status"], "degraded")
        self.assertEqual(pending["pendingCount"], 1)
        entry = self.state_json()["outbox"][0]
        self.assertEqual(entry["kind"], "burst")
        self.assertEqual(entry["count"], 12)
        self.assertEqual(entry["attempts"], 1)

        _, recovered = self.run_worker("poll", "--store", STORE, "--notify")
        self.assertEqual(recovered["status"], "ok")
        self.assertEqual(recovered["pendingCount"], 0)
        calls = self.log_lines(self.omarchy_log)
        self.assertEqual(len(calls), 2)
        for call in calls:
            self.assert_notification_presentation(call)
        self.assertTrue(all(call[10] == "12 new Shopify orders" for call in calls))

    def test_notification_attempts_are_limited_per_run_and_resume_next_poll(self) -> None:
        existing = [order(340 + index) for index in range(8)]
        self.baseline(existing)
        state = self.state_json()
        state["outbox"] = [
            {
                "kind": "order",
                "eventId": public["idHash"],
                "order": public,
                "attempts": 0,
            }
            for public in state["recentOrders"]
        ]
        self.write_state_json(state)
        self.set_execute(page([]))

        _, deferred = self.run_worker("poll", "--store", STORE, "--notify")
        self.assertEqual(deferred["status"], "degraded")
        self.assertEqual(deferred["error"]["code"], "notification_backlog")
        self.assertEqual(deferred["pendingCount"], 3)
        self.assertEqual(len(self.log_lines(self.omarchy_log)), 5)
        self.assertEqual(len(self.log_lines(self.shopify_log)), 1)

        _, drained = self.run_worker("poll", "--store", STORE, "--notify")
        self.assertEqual(drained["status"], "ok")
        self.assertEqual(drained["pendingCount"], 0)
        self.assertEqual(drained["unreadCount"], 0)
        self.assertEqual(len(self.log_lines(self.omarchy_log)), 8)
        self.assertEqual(len(self.log_lines(self.shopify_log)), 2)

    def test_pre_and_post_fetch_delivery_share_one_five_attempt_budget(self) -> None:
        self.baseline([order(350 + index) for index in range(4)])
        state = self.state_json()
        state["outbox"] = [
            {
                "kind": "order",
                "eventId": public["idHash"],
                "order": public,
                "attempts": 0,
            }
            for public in state["recentOrders"]
        ]
        self.write_state_json(state)
        self.set_execute(page([order(354), order(355)]))

        _, deferred = self.run_worker("poll", "--store", STORE, "--notify")

        self.assertEqual(deferred["status"], "degraded")
        self.assertEqual(deferred["error"]["code"], "notification_backlog")
        self.assertEqual(deferred["pendingCount"], 1)
        self.assertEqual(deferred["unreadCount"], 2)
        self.assertEqual(len(self.log_lines(self.omarchy_log)), 5)
        self.assertEqual(len(self.log_lines(self.shopify_log)), 2)

        _, drained = self.run_worker("poll", "--store", STORE, "--notify")
        self.assertEqual(drained["status"], "ok")
        self.assertEqual(drained["pendingCount"], 0)
        self.assertEqual(len(self.log_lines(self.omarchy_log)), 6)
        self.assertEqual(len(self.log_lines(self.shopify_log)), 3)

    def test_per_entry_notification_retry_limit_prevents_infinite_attempts(self) -> None:
        self.baseline()
        self.set_execute(page([order(360)]))
        failing_env = {"ORDERBELL_FAKE_OMARCHY_RC": "1"}
        for _ in range(8):
            _, failed = self.run_worker(
                "poll", "--store", STORE, "--notify", env=failing_env
            )
            self.assertEqual(failed["status"], "degraded")
        self.assertEqual(len(self.log_lines(self.omarchy_log)), 8)
        self.assertEqual(self.state_json()["outbox"][0]["attempts"], 8)

        _, capped = self.run_worker(
            "poll", "--store", STORE, "--notify", env=failing_env
        )
        self.assertEqual(capped["status"], "degraded")
        self.assertEqual(capped["error"]["code"], "notification_retry_limit")
        self.assertFalse(capped["error"]["retryable"])
        self.assertEqual(len(self.log_lines(self.omarchy_log)), 8)

    def test_poll_deadline_also_bounds_notification_delivery(self) -> None:
        self.baseline()
        self.set_execute(page([order(370)]))
        slow_bin = self.base / "slow-bin"
        slow_bin.mkdir()
        slow_omarchy = slow_bin / "omarchy"
        slow_omarchy.write_text(
            "#!/bin/sh\nsleep 4\nexit 0\n",
            encoding="utf-8",
        )
        slow_omarchy.chmod(0o700)
        environment = {
            "PATH": f"{slow_bin}{os.pathsep}{FAKES}{os.pathsep}{self.env.get('PATH', '')}"
        }
        started = time.monotonic()
        _, result = self.run_worker(
            "poll",
            "--store",
            STORE,
            "--notify",
            "--timeout",
            "1",
            env=environment,
            wall_timeout=4,
        )
        elapsed = time.monotonic() - started
        self.assertLess(elapsed, 2.5)
        self.assertEqual(result["status"], "degraded")
        self.assertIn(
            result["error"]["code"],
            {"timeout", "notification_budget_exhausted"},
        )
        self.assertEqual(result["pendingCount"], 1)

    def test_disabling_notifications_durably_clears_live_backlog(self) -> None:
        self.baseline()
        new_order = order(380)
        self.set_execute(page([new_order]))
        _, pending = self.run_worker(
            "poll",
            "--store",
            STORE,
            "--notify",
            env={"ORDERBELL_FAKE_OMARCHY_RC": "1"},
        )
        self.assertEqual(pending["pendingCount"], 1)

        self.set_execute(None, default={"rawStdout": "not-json"})
        _, failed_poll = self.run_worker(
            "poll", "--store", STORE, "--no-notify"
        )
        self.assertEqual(failed_poll["error"]["code"], "malformed_response")
        self.assertEqual(failed_poll["pendingCount"], 0)
        self.assertEqual(self.state_json()["outbox"], [])

        self.set_execute(page([new_order]))
        _, reenabled = self.run_worker("poll", "--store", STORE, "--notify")
        self.assertEqual(reenabled["pendingCount"], 0)
        self.assertEqual(len(self.log_lines(self.omarchy_log)), 1)

    def test_disabling_test_orders_durably_clears_test_backlog(self) -> None:
        self.baseline()
        created_at = timestamp(-5)
        test_orders = [
            order(390 + index, test=True, created_at=created_at)
            for index in range(6)
        ]
        self.set_execute(page(test_orders))
        _, pending = self.run_worker(
            "poll",
            "--store",
            STORE,
            "--notify",
            "--include-test-orders",
            env={"ORDERBELL_FAKE_OMARCHY_RC": "1"},
        )
        self.assertEqual(pending["pendingCount"], 1)
        self.assertEqual(pending["unreadCount"], 6)
        self.assertEqual(len(pending["recentOrders"]), 6)
        self.assertEqual(self.state_json()["outbox"][0]["kind"], "burst")
        self.assertTrue(self.state_json()["outbox"][0]["test"])

        self.set_execute(None, default={"rawStdout": "not-json"})
        _, failed_poll = self.run_worker("poll", "--store", STORE, "--notify")
        self.assertEqual(failed_poll["error"]["code"], "malformed_response")
        self.assertEqual(failed_poll["pendingCount"], 0)
        self.assertEqual(failed_poll["unreadCount"], 0)
        self.assertEqual(failed_poll["recentOrders"], [])
        self.assertEqual(self.state_json()["outbox"], [])
        self.assertEqual(self.state_json()["unreadTestCount"], 0)

        self.set_execute(page(test_orders))
        _, reenabled = self.run_worker(
            "poll",
            "--store",
            STORE,
            "--notify",
            "--include-test-orders",
        )
        self.assertEqual(reenabled["pendingCount"], 0)
        self.assertEqual(len(self.log_lines(self.omarchy_log)), 1)

    def test_malformed_json_does_not_advance_watermark(self) -> None:
        self.baseline()
        before = self.state_json()["watermarkCreatedAt"]
        self.set_execute(None, default={"rawStdout": "{definitely-not-json"})
        process, result = self.run_worker("poll", "--store", STORE)
        self.assertNotEqual(process.returncode, 0)
        self.assertEqual(result["error"]["code"], "malformed_response")
        self.assertTrue(result["stateAuthoritative"])
        self.assertEqual(self.state_json()["watermarkCreatedAt"], before)

    def test_extreme_numeric_shopify_json_is_a_retryable_malformed_response(self) -> None:
        self.baseline()
        before = self.state_json()["watermarkCreatedAt"]
        hostile = '{"data":{"ignored":' + "9" * 5000 + "}}"
        self.set_execute(None, default={"rawStdout": hostile})

        process, result = self.run_worker("poll", "--store", STORE)

        self.assertNotEqual(process.returncode, 0)
        self.assertEqual(result["error"]["code"], "malformed_response")
        self.assertTrue(result["error"]["retryable"])
        self.assertEqual(self.state_json()["watermarkCreatedAt"], before)

    def test_extreme_numeric_auth_json_is_a_nonretryable_verification_error(self) -> None:
        hostile = '{"store":"' + STORE + '","ignored":' + "9" * 5000 + "}"
        self.set_scenario({"auth": {"rawStdout": hostile}})

        process, result = self.run_worker("authenticate", "--store", STORE)

        self.assertNotEqual(process.returncode, 0)
        self.assertEqual(
            result["error"]["code"],
            "authentication_verification_failed",
        )
        self.assertFalse(result["error"]["retryable"])

    def test_extreme_numeric_state_json_is_nonretryable_local_corruption(self) -> None:
        self.baseline()
        calls_before = len(self.log_lines(self.shopify_log))
        self.state_path().write_text(
            '{"schemaVersion":' + "9" * 5000 + "}",
            encoding="utf-8",
        )
        os.chmod(self.state_path(), 0o600)

        process, result = self.run_worker("poll", "--store", STORE)

        self.assertNotEqual(process.returncode, 0)
        self.assertEqual(result["error"]["code"], "state_corrupt")
        self.assertFalse(result["error"]["retryable"])
        self.assertEqual(len(self.log_lines(self.shopify_log)), calls_before)

    def test_graphql_search_warning_fails_closed(self) -> None:
        self.baseline()
        before = self.state_json()["watermarkCreatedAt"]
        self.set_execute(page([], warning=True))
        _, result = self.run_worker("poll", "--store", STORE)
        self.assertEqual(result["error"]["code"], "search_warning")
        self.assertEqual(self.state_json()["watermarkCreatedAt"], before)

    def test_cli_error_classification_and_no_secret_leakage(self) -> None:
        cases = [
            ("HTTP 401 unauthorized shpat_AUTH_SECRET", "authentication_required", False),
            ("HTTP 429 throttled shpat_RATE_SECRET", "throttled", True),
            ("HTTP 503 service unavailable shpat_SERVER_SECRET", "shopify_unavailable", True),
            ("ENOTFOUND network shpat_NETWORK_SECRET", "offline", True),
        ]
        for index, (diagnostic, code, retryable) in enumerate(cases):
            with self.subTest(code=code):
                # Each case gets a separate store so failure counters cannot
                # affect assertions and no prior watermark is involved.
                store = f"failure-{index}.myshopify.com"
                self.set_execute(None, default={"stderr": diagnostic, "exitCode": 1})
                _, result = self.run_worker("poll", "--store", store)
                serialized = json.dumps(result)
                self.assertEqual(result["error"]["code"], code)
                self.assertEqual(result["error"]["retryable"], retryable)
                self.assertNotIn("shpat_", serialized)
                self.assertNotIn(diagnostic, serialized)

    def test_timeout_and_live_output_limit_are_bounded(self) -> None:
        self.set_execute(None, default={"sleep": 2})
        process, timed_out = self.run_worker(
            "poll", "--store", STORE, "--timeout", "1", wall_timeout=5
        )
        self.assertNotEqual(process.returncode, 0)
        self.assertEqual(timed_out["error"]["code"], "timeout")

        self.set_execute(None, default={"spamStdoutBytes": 5 * 1024 * 1024})
        process, overflow = self.run_worker(
            "poll", "--store", STORE, "--timeout", "5", wall_timeout=8
        )
        self.assertNotEqual(process.returncode, 0)
        self.assertEqual(overflow["error"]["code"], "output_too_large")

    def test_selector_setup_failure_always_kills_reaps_and_closes_child(self) -> None:
        worker = runpy.run_path(str(WORKER), run_name="orderbell_worker_selector_test")
        real_popen = worker["subprocess"].Popen
        real_selector = worker["selectors"].DefaultSelector
        captured: list[subprocess.Popen[bytes]] = []

        def capture_process(*args: Any, **kwargs: Any) -> subprocess.Popen[bytes]:
            process = real_popen(*args, **kwargs)
            captured.append(process)
            return process

        class FailSecondRegistration:
            def __init__(self) -> None:
                self.delegate = real_selector()
                self.registrations = 0

            def register(self, *args: Any, **kwargs: Any) -> Any:
                self.registrations += 1
                if self.registrations == 2:
                    raise OSError(errno.EMFILE, "synthetic selector exhaustion")
                return self.delegate.register(*args, **kwargs)

            def close(self) -> None:
                self.delegate.close()

        with (
            mock.patch.object(worker["subprocess"], "Popen", side_effect=capture_process),
            mock.patch.object(worker["selectors"], "DefaultSelector", FailSecondRegistration),
            self.assertRaises(OSError),
        ):
            worker["run_bounded"](
                [sys.executable, "-c", "import time; time.sleep(20)"],
                timeout=2,
            )

        self.assertEqual(len(captured), 1)
        child = captured[0]
        self.assertIsNotNone(child.poll())
        self.assertTrue(child.stdout is not None and child.stdout.closed)
        self.assertTrue(child.stderr is not None and child.stderr.closed)

    def test_hostile_control_characters_are_sanitized_and_never_reparsed(self) -> None:
        self.baseline()
        hostile_name = "#401\n--exec\t\u202exdg-open malware"
        self.set_execute(page([order(401, name=hostile_name)]))
        _, result = self.run_worker(
            "poll", "--store", STORE, "--notify", "--show-details"
        )
        rendered = json.dumps(result, ensure_ascii=False)
        self.assertNotIn("\n--exec", rendered)
        self.assertNotIn("\u202e", rendered)
        call = self.log_lines(self.omarchy_log)[0]
        self.assertEqual(call.count("--exec"), 1)
        self.assertEqual(call[-2:], ["xdg-open", f"https://{STORE}/admin/orders/401"])
        self.assertFalse(any("\n" in argument or "\u202e" in argument for argument in call))

    def test_symlinked_and_world_readable_state_are_refused(self) -> None:
        _, initial = self.run_worker("status", "--store", STORE)
        self.assertEqual(initial["status"], "ok")
        target = self.base / "do-not-touch.json"
        target.write_text("SENTINEL", encoding="utf-8")
        self.state_path().symlink_to(target)
        process, result = self.run_worker("status", "--store", STORE)
        self.assertNotEqual(process.returncode, 0)
        self.assertEqual(result["error"]["code"], "unsafe_state")
        self.assertEqual(target.read_text(encoding="utf-8"), "SENTINEL")

        self.state_path().unlink()
        self.baseline()
        os.chmod(self.state_path(), 0o644)
        process, result = self.run_worker("status", "--store", STORE)
        self.assertNotEqual(process.returncode, 0)
        self.assertEqual(result["error"]["code"], "unsafe_state")

    def test_state_write_transaction_is_descriptor_relative(self) -> None:
        self.baseline()
        worker = runpy.run_path(str(WORKER), run_name="orderbell_worker_dirfd_test")
        state = self.state_json()
        state["failureCount"] = 1
        real_open = worker["os"].open
        real_replace = worker["os"].replace
        real_fsync = worker["os"].fsync
        directory_opens: list[tuple[int, int, int | None, int]] = []
        temporary_opens: list[tuple[str, int, int, int | None, int]] = []
        replacements: list[tuple[str, str, int | None, int | None]] = []
        fsynced: list[int] = []
        closed: list[int] = []
        real_close = worker["os"].close

        def traced_open(
            path: Any,
            flags: int,
            mode: int = 0o777,
            *,
            dir_fd: int | None = None,
        ) -> int:
            opened = real_open(path, flags, mode, dir_fd=dir_fd)
            if Path(path) == self.state_path().parent:
                directory_opens.append((flags, mode, dir_fd, opened))
            elif isinstance(path, str) and path.startswith(".orderbell-"):
                temporary_opens.append((path, flags, mode, dir_fd, opened))
            return opened

        def traced_replace(
            source: str,
            target: str,
            *,
            src_dir_fd: int | None = None,
            dst_dir_fd: int | None = None,
        ) -> None:
            replacements.append((source, target, src_dir_fd, dst_dir_fd))
            real_replace(
                source,
                target,
                src_dir_fd=src_dir_fd,
                dst_dir_fd=dst_dir_fd,
            )

        def traced_fsync(fd: int) -> None:
            fsynced.append(fd)
            real_fsync(fd)

        def traced_close(fd: int) -> None:
            closed.append(fd)
            real_close(fd)

        with (
            mock.patch.dict(worker["os"].environ, self.env, clear=True),
            mock.patch.object(worker["os"], "open", side_effect=traced_open),
            mock.patch.object(worker["os"], "replace", side_effect=traced_replace),
            mock.patch.object(worker["os"], "fsync", side_effect=traced_fsync),
            mock.patch.object(worker["os"], "close", side_effect=traced_close),
        ):
            worker["write_state"](STORE, state)

        self.assertEqual(len(directory_opens), 1)
        directory_flags, _, parent_directory_fd, held_directory_fd = directory_opens[0]
        self.assertIsNone(parent_directory_fd)
        self.assertEqual(directory_flags & os.O_ACCMODE, os.O_RDONLY)
        for required in (os.O_DIRECTORY, os.O_NOFOLLOW, os.O_CLOEXEC):
            self.assertEqual(directory_flags & required, required)
        self.assertEqual(len(temporary_opens), 1)
        temporary, flags, mode, directory_fd, state_fd = temporary_opens[0]
        self.assertNotIn(os.sep, temporary)
        self.assertEqual(mode, 0o600)
        self.assertEqual(directory_fd, held_directory_fd)
        for required in (os.O_CREAT, os.O_EXCL, os.O_NOFOLLOW, os.O_CLOEXEC):
            self.assertEqual(flags & required, required)
        self.assertEqual(
            replacements,
            [(temporary, self.state_path().name, directory_fd, directory_fd)],
        )
        self.assertIn(directory_fd, fsynced)
        self.assertIn(state_fd, closed)
        self.assertIn(held_directory_fd, closed)
        self.assertEqual(self.state_json()["failureCount"], 1)
        self.assertEqual(list(self.state_path().parent.glob(".orderbell-*.tmp")), [])

    def test_state_write_directory_swap_never_reaches_attacker_target(self) -> None:
        self.baseline()
        worker = runpy.run_path(str(WORKER), run_name="orderbell_worker_swap_test")
        state = self.state_json()
        state["failureCount"] = 1
        stores = self.state_path().parent
        target_name = self.state_path().name
        backup = self.base / "stores-held-by-worker"
        attacker = self.base / "attacker-directory"
        attacker.mkdir(mode=0o700)
        real_replace = worker["os"].replace
        swapped = False

        def swap_then_replace(
            source: str,
            target: str,
            *,
            src_dir_fd: int | None = None,
            dst_dir_fd: int | None = None,
        ) -> None:
            nonlocal swapped
            self.assertFalse(swapped)
            stores.rename(backup)
            stores.symlink_to(attacker, target_is_directory=True)
            swapped = True
            real_replace(
                source,
                target,
                src_dir_fd=src_dir_fd,
                dst_dir_fd=dst_dir_fd,
            )

        with (
            mock.patch.dict(worker["os"].environ, self.env, clear=True),
            mock.patch.object(worker["os"], "replace", side_effect=swap_then_replace),
            self.assertRaises(worker["WorkerError"]) as caught,
        ):
            worker["write_state"](STORE, state)

        self.assertTrue(swapped)
        self.assertEqual(caught.exception.code, "unsafe_state")
        self.assertEqual(list(attacker.iterdir()), [])
        saved = json.loads((backup / target_name).read_text(encoding="utf-8"))
        self.assertEqual(saved["failureCount"], 1)
        self.assertEqual(list(backup.glob(".orderbell-*.tmp")), [])

    def test_state_target_swap_between_validation_and_replace_is_not_followed(self) -> None:
        self.baseline()
        worker = runpy.run_path(str(WORKER), run_name="orderbell_worker_target_swap_test")
        state = self.state_json()
        state["failureCount"] = 1
        valuable = self.base / "valuable-target-after-validation"
        valuable.write_text("DO NOT TOUCH", encoding="utf-8")
        real_verify = worker["_verify_state_directory_binding"]
        verification_count = 0

        def verify_then_swap_target(directory_fd: int, directory: Path) -> None:
            nonlocal verification_count
            real_verify(directory_fd, directory)
            verification_count += 1
            if verification_count == 2:
                target = self.state_path().name
                os.unlink(target, dir_fd=directory_fd)
                os.symlink(valuable, target, dir_fd=directory_fd)

        globals_ = worker["write_state"].__globals__
        with (
            mock.patch.dict(worker["os"].environ, self.env, clear=True),
            mock.patch.dict(
                globals_,
                {"_verify_state_directory_binding": verify_then_swap_target},
            ),
        ):
            worker["write_state"](STORE, state)

        self.assertEqual(verification_count, 3)
        self.assertEqual(valuable.read_text(encoding="utf-8"), "DO NOT TOUCH")
        self.assertTrue(self.state_path().is_file())
        self.assertFalse(self.state_path().is_symlink())
        self.assertEqual(self.state_json()["failureCount"], 1)

    def test_changed_temporary_entry_is_refused_before_replace_and_cleaned(self) -> None:
        self.baseline()
        worker = runpy.run_path(str(WORKER), run_name="orderbell_worker_temp_swap_test")
        state = self.state_json()
        state["failureCount"] = 1
        original = self.state_path().read_bytes()
        real_open = worker["os"].open
        real_verify = worker["_verify_state_directory_binding"]
        temporary: str | None = None
        temporary_directory_fd: int | None = None
        verification_count = 0

        def traced_open(
            path: Any,
            flags: int,
            mode: int = 0o777,
            *,
            dir_fd: int | None = None,
        ) -> int:
            nonlocal temporary, temporary_directory_fd
            opened = real_open(path, flags, mode, dir_fd=dir_fd)
            if isinstance(path, str) and path.startswith(".orderbell-"):
                temporary = path
                temporary_directory_fd = dir_fd
            return opened

        def verify_then_change_temporary(directory_fd: int, directory: Path) -> None:
            nonlocal verification_count
            real_verify(directory_fd, directory)
            verification_count += 1
            if verification_count == 2:
                self.assertIsNotNone(temporary)
                self.assertEqual(directory_fd, temporary_directory_fd)
                os.unlink(temporary, dir_fd=directory_fd)
                attacker_fd = real_open(
                    temporary,
                    os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                    0o600,
                    dir_fd=directory_fd,
                )
                try:
                    os.write(attacker_fd, b"attacker-controlled temporary")
                finally:
                    os.close(attacker_fd)

        globals_ = worker["write_state"].__globals__
        with (
            mock.patch.dict(worker["os"].environ, self.env, clear=True),
            mock.patch.object(worker["os"], "open", side_effect=traced_open),
            mock.patch.dict(
                globals_,
                {"_verify_state_directory_binding": verify_then_change_temporary},
            ),
            self.assertRaises(worker["WorkerError"]) as caught,
        ):
            worker["write_state"](STORE, state)

        self.assertEqual(caught.exception.code, "unsafe_state")
        self.assertEqual(self.state_path().read_bytes(), original)
        self.assertEqual(list(self.state_path().parent.glob(".orderbell-*.tmp")), [])

    def test_state_write_verifies_the_installed_inode(self) -> None:
        self.baseline()
        worker = runpy.run_path(str(WORKER), run_name="orderbell_worker_inode_test")
        state = self.state_json()
        state["failureCount"] = 1
        valuable = self.base / "valuable-state-target"
        valuable.write_text("DO NOT TOUCH", encoding="utf-8")
        real_replace = worker["os"].replace

        def replace_then_swap_target(
            source: str,
            target: str,
            *,
            src_dir_fd: int | None = None,
            dst_dir_fd: int | None = None,
        ) -> None:
            real_replace(
                source,
                target,
                src_dir_fd=src_dir_fd,
                dst_dir_fd=dst_dir_fd,
            )
            self.assertIsNotNone(dst_dir_fd)
            os.unlink(target, dir_fd=dst_dir_fd)
            os.symlink(valuable, target, dir_fd=dst_dir_fd)

        with (
            mock.patch.dict(worker["os"].environ, self.env, clear=True),
            mock.patch.object(
                worker["os"],
                "replace",
                side_effect=replace_then_swap_target,
            ),
            self.assertRaises(worker["WorkerError"]) as caught,
        ):
            worker["write_state"](STORE, state)

        self.assertEqual(caught.exception.code, "unsafe_state")
        self.assertEqual(valuable.read_text(encoding="utf-8"), "DO NOT TOUCH")

    def test_failed_state_write_cleans_temporary_relative_to_held_fd(self) -> None:
        self.baseline()
        worker = runpy.run_path(str(WORKER), run_name="orderbell_worker_cleanup_test")
        state = self.state_json()
        state["failureCount"] = 1
        original = self.state_path().read_bytes()
        real_open = worker["os"].open
        real_fsync = worker["os"].fsync
        real_unlink = worker["os"].unlink
        temporary_directory_fd: int | None = None
        cleanups: list[tuple[str, int | None]] = []

        def traced_open(
            path: Any,
            flags: int,
            mode: int = 0o777,
            *,
            dir_fd: int | None = None,
        ) -> int:
            nonlocal temporary_directory_fd
            opened = real_open(path, flags, mode, dir_fd=dir_fd)
            if isinstance(path, str) and path.startswith(".orderbell-"):
                temporary_directory_fd = dir_fd
            return opened

        def fail_file_fsync(fd: int) -> None:
            if stat.S_ISREG(os.fstat(fd).st_mode):
                raise OSError(errno.EIO, "synthetic state fsync failure")
            real_fsync(fd)

        def traced_unlink(path: str, *, dir_fd: int | None = None) -> None:
            cleanups.append((path, dir_fd))
            real_unlink(path, dir_fd=dir_fd)

        with (
            mock.patch.dict(worker["os"].environ, self.env, clear=True),
            mock.patch.object(worker["os"], "open", side_effect=traced_open),
            mock.patch.object(worker["os"], "fsync", side_effect=fail_file_fsync),
            mock.patch.object(worker["os"], "unlink", side_effect=traced_unlink),
            self.assertRaises(worker["WorkerError"]) as caught,
        ):
            worker["write_state"](STORE, state)

        self.assertEqual(caught.exception.code, "state_io")
        self.assertTrue(caught.exception.retryable)
        self.assertIsNotNone(temporary_directory_fd)
        self.assertEqual(len(cleanups), 1)
        self.assertEqual(cleanups[0][1], temporary_directory_fd)
        self.assertNotIn(os.sep, cleanups[0][0])
        self.assertEqual(self.state_path().read_bytes(), original)
        self.assertEqual(list(self.state_path().parent.glob(".orderbell-*.tmp")), [])

    def test_directory_fsync_failure_has_no_temporary_leak(self) -> None:
        self.baseline()
        worker = runpy.run_path(str(WORKER), run_name="orderbell_worker_dirsync_test")
        state = self.state_json()
        state["failureCount"] = 1
        real_fsync = worker["os"].fsync

        def fail_directory_fsync(fd: int) -> None:
            if stat.S_ISDIR(os.fstat(fd).st_mode):
                raise OSError(errno.EIO, "synthetic directory fsync failure")
            real_fsync(fd)

        with (
            mock.patch.dict(worker["os"].environ, self.env, clear=True),
            mock.patch.object(worker["os"], "fsync", side_effect=fail_directory_fsync),
            self.assertRaises(worker["WorkerError"]) as caught,
        ):
            worker["write_state"](STORE, state)

        self.assertEqual(caught.exception.code, "state_io")
        self.assertTrue(caught.exception.retryable)
        self.assertEqual(self.state_json()["failureCount"], 1)
        self.assertEqual(list(self.state_path().parent.glob(".orderbell-*.tmp")), [])

    def test_zero_length_state_write_fails_without_looping_or_leaking(self) -> None:
        self.baseline()
        worker = runpy.run_path(str(WORKER), run_name="orderbell_worker_zero_write_test")
        state = self.state_json()
        state["failureCount"] = 1
        original = self.state_path().read_bytes()

        with (
            mock.patch.dict(worker["os"].environ, self.env, clear=True),
            mock.patch.object(worker["os"], "write", return_value=0),
            self.assertRaises(worker["WorkerError"]) as caught,
        ):
            worker["write_state"](STORE, state)

        self.assertEqual(caught.exception.code, "state_io")
        self.assertTrue(caught.exception.retryable)
        self.assertEqual(self.state_path().read_bytes(), original)
        self.assertEqual(list(self.state_path().parent.glob(".orderbell-*.tmp")), [])

    def test_hardlinked_lock_is_refused_without_modifying_its_target(self) -> None:
        lock_root = self.runtime / "orderbell"
        lock_root.mkdir(mode=0o700)
        target = self.base / "valuable-file"
        target.write_text("DO NOT TRUNCATE", encoding="utf-8")
        os.chmod(target, 0o600)
        key = hashlib.sha256(STORE.encode("ascii")).hexdigest()
        os.link(target, lock_root / f"{key}.lock")
        process, result = self.run_worker("poll", "--store", STORE)
        self.assertNotEqual(process.returncode, 0)
        self.assertEqual(result["error"]["code"], "unsafe_state")
        self.assertFalse(result["stateAuthoritative"])
        self.assertEqual(target.read_text(encoding="utf-8"), "DO NOT TRUNCATE")

    def test_busy_envelope_is_not_state_authoritative(self) -> None:
        self.baseline()
        key = hashlib.sha256(STORE.encode("ascii")).hexdigest()
        lock_path = self.runtime / "orderbell" / f"{key}.lock"
        with lock_path.open("r+b") as held:
            fcntl.flock(held.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            process, result = self.run_worker("poll", "--store", STORE)

        self.assertEqual(process.returncode, 0)
        self.assertEqual(result["status"], "busy")
        self.assertEqual(result["error"]["code"], "busy")
        self.assertFalse(result["stateAuthoritative"])
        self.assertEqual(len(self.log_lines(self.shopify_log)), 1)

    def test_authenticate_requests_exactly_read_orders_and_sanitizes_output(self) -> None:
        self.set_scenario(
            {
                "auth": {
                    "stdout": {
                        "store": STORE,
                        "scopes": ["read_orders", "read_products"],
                        "associatedUser": {
                            "email": "owner@example.test",
                            "firstName": "Secret",
                            "lastName": "Owner",
                        },
                    }
                }
            }
        )
        process, result = self.run_worker(
            "authenticate", "--store", STORE, "--timeout", "30"
        )
        self.assertEqual(process.returncode, 0)
        serialized = json.dumps(result)
        self.assertNotIn("owner@example", serialized)
        self.assertNotIn("Secret Owner", serialized)
        self.assertNotIn("shpat_", serialized)
        argv = self.log_lines(self.shopify_log)[0]
        self.assertEqual(
            argv,
            [
                "store",
                "auth",
                "--store",
                STORE,
                "--scopes",
                "read_orders",
                "--json",
                "--no-color",
            ],
        )

    def test_authentication_fails_closed_for_wrong_store_or_missing_scope(self) -> None:
        cases = [
            ({"store": "other.myshopify.com", "scopes": ["read_orders"]}, "authentication_verification_failed"),
            ({"store": STORE, "scopes": ["read_products"]}, "authentication_scope_missing"),
            ({"store": STORE, "scopes": "read_orders"}, "authentication_verification_failed"),
        ]
        for auth_output, expected in cases:
            with self.subTest(expected=expected, output=auth_output):
                self.set_scenario({"auth": {"stdout": auth_output}})
                process, result = self.run_worker("authenticate", "--store", STORE)
                self.assertNotEqual(process.returncode, 0)
                self.assertEqual(result["error"]["code"], expected)

    def test_test_notification_uses_safe_click_argv(self) -> None:
        self.baseline()
        process, result = self.run_worker(
            "test-notification", "--store", STORE, "--privacy"
        )
        self.assertEqual(process.returncode, 0)
        self.assertEqual(result["status"], "ok")
        call = self.log_lines(self.omarchy_log)[0]
        self.assert_notification_presentation(call)
        self.assertEqual(call[11], f"{SHOP_NAME} · Order details are hidden.")
        self.assertEqual(call[-3:], ["--exec", "xdg-open", f"https://{STORE}/admin/orders"])
        self.assertEqual(call.count("--exec"), 1)

    def test_notifications_fall_back_to_canonical_store_before_name_is_known(self) -> None:
        process, result = self.run_worker(
            "test-notification", "--store", STORE, "--show-details"
        )
        self.assertEqual(process.returncode, 0)
        self.assertIsNone(result["displayName"])
        call = self.log_lines(self.omarchy_log)[0]
        self.assert_notification_presentation(call)
        self.assertEqual(call[11], f"Connected to {STORE}.")

    def test_test_orders_are_ignored_unless_explicitly_enabled(self) -> None:
        self.baseline()
        self.set_execute(page([order(501, test=True)]))
        _, ignored = self.run_worker("poll", "--store", STORE, "--notify")
        self.assertEqual(ignored["unreadCount"], 0)
        self.assertFalse(self.omarchy_log.exists())

        # A different test order proves the opt-in path without replaying a
        # previously deduplicated event.
        self.set_execute(page([order(502, test=True)]))
        _, included = self.run_worker(
            "poll",
            "--store",
            STORE,
            "--notify",
            "--include-test-orders",
        )
        self.assertEqual(included["unreadCount"], 1)
        self.assertEqual(len(self.log_lines(self.omarchy_log)), 1)

    def test_raw_graphql_ids_and_ambient_verbose_flags_are_not_persisted(self) -> None:
        self.baseline()
        self.set_execute(page([order(601)]))
        environment = {
            "SHOPIFY_FLAG_VERBOSE": "1",
            "SHOPIFY_FLAG_ALLOW_MUTATIONS": "1",
            "SHOPIFY_FLAG_QUERY": "mutation { dangerous }",
            "SHOPIFY_CLI_THEME_TOKEN": "shpat_AMBIENT_SECRET",
        }
        _, result = self.run_worker("poll", "--store", STORE, env=environment)
        self.assertEqual(result["status"], "ok")
        state_text = self.state_path().read_text(encoding="utf-8")
        self.assertNotIn("gid://shopify/Order", state_text)
        self.assertNotIn("shpat_", state_text)
        argv = self.log_lines(self.shopify_log)[-1]
        self.assertNotIn("--verbose", argv)
        self.assertNotIn("--allow-mutations", argv)

    def test_query_is_read_only_and_cli_usage_is_always_json(self) -> None:
        query = (ROOT / "graphql" / "orders.graphql").read_text(encoding="utf-8")
        self.assertIn("query OrderBellOrders", query)
        self.assertRegex(query, r"shop\s*\{\s*name\s*\}")
        self.assertIn("sortKey: CREATED_AT", query)
        self.assertNotIn("mutation", query.lower())
        self.assertNotIn("customer", query.lower())
        self.assertNotIn("email", query.lower())
        process, result = self.run_worker("--help")
        self.assertEqual(process.returncode, 2)
        self.assertEqual(result["error"]["code"], "usage")

    def test_whole_poll_deadline_covers_all_pages(self) -> None:
        self.baseline()
        first = page([order(701)], has_next=True, end_cursor="slow-second")
        second = page([order(702)])
        self.set_scenario(
            {
                "execute": {
                    "pages": {
                        "__first__": {"stdout": first, "sleep": 0.65},
                        "slow-second": {"stdout": second, "sleep": 0.65},
                    }
                }
            }
        )
        before = self.state_json()["watermarkCreatedAt"]
        process, result = self.run_worker(
            "poll", "--store", STORE, "--timeout", "1", wall_timeout=5
        )
        self.assertNotEqual(process.returncode, 0)
        self.assertEqual(result["error"]["code"], "timeout")
        self.assertEqual(self.state_json()["watermarkCreatedAt"], before)
        self.assertEqual(self.state_json()["unreadCount"], 0)

    def test_remote_orders_must_stay_inside_the_bounded_search_window(self) -> None:
        self.baseline()
        prior = self.state_json()["watermarkCreatedAt"]
        self.set_execute(page([order(801, created_at=timestamp(240))]))
        _, future = self.run_worker("poll", "--store", STORE)
        self.assertEqual(future["error"]["code"], "search_filter_violation")
        self.assertFalse(future["error"]["retryable"])
        self.assertEqual(self.state_json()["watermarkCreatedAt"], prior)

        watermark = dt.datetime.fromisoformat(prior.replace("Z", "+00:00"))
        too_old = (watermark - dt.timedelta(minutes=6)).isoformat(
            timespec="microseconds"
        ).replace("+00:00", "Z")
        self.set_execute(page([order(802, created_at=too_old)]))
        _, old = self.run_worker("poll", "--store", STORE)
        self.assertEqual(old["error"]["code"], "search_filter_violation")
        self.assertEqual(self.state_json()["watermarkCreatedAt"], prior)

    def test_catchup_is_chunked_and_future_watermarks_are_safely_recovered(self) -> None:
        self.baseline()
        state = self.state_json()
        old_watermark = (
            dt.datetime.now(dt.timezone.utc) - dt.timedelta(hours=7)
        ).replace(microsecond=123456)
        state["watermarkCreatedAt"] = old_watermark.isoformat(
            timespec="microseconds"
        ).replace("+00:00", "Z")
        self.write_state_json(state)
        chunk_order_time = (old_watermark + dt.timedelta(hours=1)).isoformat(
            timespec="microseconds"
        ).replace("+00:00", "Z")
        self.set_execute(page([order(811, created_at=chunk_order_time)]))

        _, catching_up = self.run_worker("poll", "--store", STORE, "--no-notify")
        self.assertEqual(catching_up["status"], "catching_up")
        self.assertIsNone(catching_up["error"])
        self.assertEqual(catching_up["nextPollSeconds"], 60)
        self.assertEqual(catching_up["unreadCount"], 1)
        self.assertEqual(catching_up["recentOrders"][0]["name"], "#811")
        checkpoint = dt.datetime.fromisoformat(
            self.state_json()["watermarkCreatedAt"].replace("Z", "+00:00")
        )
        self.assertEqual(checkpoint, old_watermark + dt.timedelta(hours=6))
        argv = self.log_lines(self.shopify_log)[-1]
        variables = json.loads(argv[argv.index("--variables") + 1])
        expected_since = (old_watermark - dt.timedelta(minutes=5)).isoformat(
            timespec="microseconds"
        ).replace("+00:00", "Z")
        expected_until = (old_watermark + dt.timedelta(hours=6)).isoformat(
            timespec="microseconds"
        ).replace("+00:00", "Z")
        self.assertEqual(
            variables["query"],
            f"created_at:>='{expected_since}' AND created_at:<='{expected_until}'",
        )

        state = self.state_json()
        state["watermarkCreatedAt"] = timestamp(2 * 60 * 60)
        self.write_state_json(state)
        self.set_execute(page([]))
        before = dt.datetime.now(dt.timezone.utc)
        _, recovered = self.run_worker("poll", "--store", STORE, "--no-notify")
        after = dt.datetime.now(dt.timezone.utc)
        self.assertEqual(recovered["status"], "catching_up")
        self.assertIsNone(recovered["error"])
        recovered_checkpoint = dt.datetime.fromisoformat(
            self.state_json()["watermarkCreatedAt"].replace("Z", "+00:00")
        )
        self.assertGreaterEqual(recovered_checkpoint, before)
        self.assertLessEqual(recovered_checkpoint, after)

    def test_poll_windows_are_deterministic_across_midnight_dst_and_clock_jumps(self) -> None:
        worker = runpy.run_path(str(WORKER), run_name="orderbell_worker_time_tests")
        poll_window = worker["_poll_window"]
        default_state = worker["default_state"]
        parse_timestamp = worker["parse_timestamp"]

        # Europe/Prague's skipped and repeated local hours normalize to an
        # unambiguous UTC sequence; the host timezone is never consulted.
        spring_before, spring_before_text = parse_timestamp(
            "2024-03-31T01:30:00+01:00"
        )
        spring_after, spring_after_text = parse_timestamp(
            "2024-03-31T03:30:00+02:00"
        )
        self.assertEqual(spring_before_text, "2024-03-31T00:30:00Z")
        self.assertEqual(spring_after_text, "2024-03-31T01:30:00Z")
        self.assertEqual(spring_after - spring_before, dt.timedelta(hours=1))
        _, autumn_early = parse_timestamp("2024-10-27T02:30:00+02:00")
        _, autumn_late = parse_timestamp("2024-10-27T02:30:00+01:00")
        self.assertEqual(autumn_early, "2024-10-27T00:30:00Z")
        self.assertEqual(autumn_late, "2024-10-27T01:30:00Z")

        state = default_state(STORE)
        state["initialized"] = True
        state["watermarkCreatedAt"] = "2024-02-29T23:58:00Z"
        midnight = poll_window(
            state,
            dt.datetime(2024, 3, 1, 0, 3, tzinfo=dt.timezone.utc),
        )
        self.assertEqual(midnight.since, dt.datetime(2024, 2, 29, 23, 53, tzinfo=dt.timezone.utc))
        self.assertEqual(midnight.until, dt.datetime(2024, 3, 1, 0, 3, tzinfo=dt.timezone.utc))
        self.assertFalse(midnight.catching_up)

        # A suspend-like seven-hour gap commits only the first lossless six-hour
        # chunk, while a future watermark rewinds by the exact clock skew.
        state["watermarkCreatedAt"] = "2026-01-01T00:00:00Z"
        resume = poll_window(
            state,
            dt.datetime(2026, 1, 1, 7, 0, tzinfo=dt.timezone.utc),
        )
        self.assertEqual(resume.since, dt.datetime(2025, 12, 31, 23, 55, tzinfo=dt.timezone.utc))
        self.assertEqual(resume.until, dt.datetime(2026, 1, 1, 6, 0, tzinfo=dt.timezone.utc))
        self.assertTrue(resume.catching_up)

        state["watermarkCreatedAt"] = "2026-01-01T14:00:00Z"
        rollback = poll_window(
            state,
            dt.datetime(2026, 1, 1, 12, 0, tzinfo=dt.timezone.utc),
        )
        self.assertEqual(rollback.since, dt.datetime(2026, 1, 1, 9, 55, tzinfo=dt.timezone.utc))
        self.assertEqual(rollback.until, dt.datetime(2026, 1, 1, 12, 0, tzinfo=dt.timezone.utc))
        self.assertTrue(rollback.catching_up)

    def test_catchup_beyond_supported_horizon_fails_without_checkpointing(self) -> None:
        self.baseline()
        state = self.state_json()
        state["watermarkCreatedAt"] = timestamp(-60 * 24 * 60 * 60)
        self.write_state_json(state)
        prior = state["watermarkCreatedAt"]
        calls_before = len(self.log_lines(self.shopify_log))

        process, result = self.run_worker("poll", "--store", STORE)
        self.assertNotEqual(process.returncode, 0)
        self.assertEqual(result["error"]["code"], "catchup_window_exceeded")
        self.assertFalse(result["error"]["retryable"])
        self.assertEqual(self.state_json()["watermarkCreatedAt"], prior)
        self.assertEqual(len(self.log_lines(self.shopify_log)), calls_before)

    def test_oversized_state_and_atomic_write_race_fail_closed(self) -> None:
        self.run_worker("status", "--store", STORE)
        self.state_path().write_bytes(b"{" + b"x" * (2 * 1024 * 1024) + b"}")
        os.chmod(self.state_path(), 0o600)
        _, oversized = self.run_worker("status", "--store", STORE)
        self.assertEqual(oversized["error"]["code"], "state_corrupt")

        self.state_path().unlink()
        self.baseline()
        prior_state = self.state_json()
        backup = self.base / "stores-before-write"
        symlink_target = self.base / "attacker-target"
        self.set_execute(
            None,
            default={
                "stdout": page([order(803)]),
                "replaceStoresWithSymlink": True,
            },
        )
        _, refused = self.run_worker(
            "poll",
            "--store",
            STORE,
            env={
                "ORDERBELL_FAKE_STATE_BACKUP": str(backup),
                "ORDERBELL_FAKE_STATE_SYMLINK_TARGET": str(symlink_target),
            },
        )
        self.assertEqual(refused["error"]["code"], "unsafe_state")
        saved = json.loads((backup / self.state_path().name).read_text(encoding="utf-8"))
        self.assertEqual(saved["watermarkCreatedAt"], prior_state["watermarkCreatedAt"])
        self.assertEqual(saved["unreadCount"], prior_state["unreadCount"])
        self.assertEqual(list(symlink_target.iterdir()), [])

    def test_seen_and_outbox_cardinality_limits_are_state_size_realistic(self) -> None:
        self.baseline()
        original = self.state_json()

        too_many_seen = dict(original)
        too_many_seen["seen"] = {
            f"{index:064x}": timestamp(-30) for index in range(8193)
        }
        self.write_state_json(too_many_seen)
        process, seen_result = self.run_worker("status", "--store", STORE)
        self.assertNotEqual(process.returncode, 0)
        self.assertEqual(seen_result["error"]["code"], "state_corrupt")

        too_many_outbox = dict(original)
        too_many_outbox["outbox"] = [{} for _ in range(65)]
        self.write_state_json(too_many_outbox)
        process, outbox_result = self.run_worker("status", "--store", STORE)
        self.assertNotEqual(process.returncode, 0)
        self.assertEqual(outbox_result["error"]["code"], "state_corrupt")

    def test_sigterm_kills_and_reaps_active_shopify_process_group(self) -> None:
        pid_file = self.base / "shopify.pid"
        self.set_execute(None, default={"sleep": 20})
        environment = dict(self.env)
        environment["ORDERBELL_FAKE_SHOPIFY_PID_FILE"] = str(pid_file)
        process = subprocess.Popen(
            [str(WORKER), "poll", "--store", STORE, "--timeout", "30"],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=environment,
        )
        child_pid: int | None = None
        try:
            deadline = time.monotonic() + 5
            while child_pid is None and time.monotonic() < deadline:
                try:
                    candidate = pid_file.read_text(encoding="ascii").strip()
                    if candidate:
                        parsed = int(candidate)
                        if parsed > 1:
                            child_pid = parsed
                except (FileNotFoundError, ValueError):
                    pass
                if child_pid is None:
                    time.sleep(0.02)
            self.assertIsNotNone(child_pid, "fake Shopify child did not publish a valid PID")
            process.send_signal(signal.SIGTERM)
            stdout, stderr = process.communicate(timeout=5)
        finally:
            if process.poll() is None:
                process.send_signal(signal.SIGTERM)
                try:
                    process.communicate(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.communicate(timeout=5)
        self.assertEqual(stderr, b"")
        self.assertEqual(process.returncode, 130)
        result = json.loads(stdout)
        self.assertEqual(result["error"]["code"], "interrupted")
        assert child_pid is not None
        with self.assertRaises(ProcessLookupError):
            os.kill(child_pid, 0)


if __name__ == "__main__":
    unittest.main()

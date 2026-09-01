import QtQuick
import QtTest
import Quickshell.Io
import "../.."

TestCase {
  name: "OrderBellService"
  property var service: null

  Component {
    id: serviceComponent
    Service { autoStart: false }
  }

  function init() {
    service = serviceComponent.createObject(this)
    verify(service !== null)
    wait(1)
  }

  function cleanup() {
    service.destroy()
    service = null
    wait(1)
  }

  function worker() {
    for (var i = 0; i < ProcessRegistry.processes.length; i++)
      if (ProcessRegistry.processes[i].running) return ProcessRegistry.processes[i]
    return null
  }

  function responseValue(store, options) {
    var config = options || {}
    return {
      schemaVersion: 1,
      stateAuthoritative: config.stateAuthoritative === undefined
        ? true : config.stateAuthoritative,
      status: config.status || "ok",
      store: store,
      displayName: config.displayName === undefined
        ? store.substring(0, store.indexOf(".")).toUpperCase() : config.displayName,
      recentOrders: config.recentOrders || [],
      unreadCount: config.unreadCount || 0,
      pendingCount: config.pendingCount || 0,
      error: config.error === undefined ? null : config.error,
      nextPollSeconds: config.nextPollSeconds || 60,
      lastSuccessfulPollAt: config.lastSuccessfulPollAt === undefined
        ? "2026-09-01T18:30:01Z" : config.lastSuccessfulPollAt
    }
  }

  function response(store, unread) {
    return JSON.stringify(responseValue(store, { unreadCount: unread || 0 }))
  }

  function errorResponse(store, code, message, status, stateAuthoritative) {
    return JSON.stringify({
      schemaVersion: 1,
      stateAuthoritative: stateAuthoritative === undefined
        ? true : stateAuthoritative,
      status: status || "error",
      store: store,
      displayName: null,
      recentOrders: [],
      unreadCount: 0,
      pendingCount: 0,
      error: { code: code, message: message, retryable: true },
      nextPollSeconds: 300,
      lastSuccessfulPollAt: null
    })
  }

  function sampleOrder(store, unread) {
    return {
      idHash: "a".repeat(64),
      name: "#1042",
      createdAt: "2026-09-01T18:29:01Z",
      amount: "42.50",
      currency: "EUR",
      financialStatus: "PAID",
      fulfillmentStatus: "UNFULFILLED",
      test: false,
      url: "https://" + store + "/admin/orders/123456789",
      unread: unread === true
    }
  }

  function configure(stores) {
    service.settings = {
      stores: stores,
      refreshIntervalSec: 1,
      privacyMode: true,
      includeTestOrders: false,
      notify: true
    }
    wait(1)
  }

  function test_settings_are_validated_and_clamped() {
    configure("one.myshopify.com, invalid-one")
    compare(service.configuredStores, ["one.myshopify.com"])
    compare(service.invalidStores.length, 1)
    compare(service.refreshIntervalSec, 60)
    compare(service.privacyMode, true)
    verify(service.lastError.indexOf("invalid-one") !== -1)

    // The valid store list is unchanged, but the validation result is not.
    configure("one.myshopify.com, invalid-two")
    verify(service.lastError.indexOf("invalid-two") !== -1)
    verify(service.lastError.indexOf("invalid-one") === -1)
  }

  function test_policy_change_preserves_surviving_poll_error_text() {
    var store = "one.myshopify.com"
    configure(store)
    service.refresh(true)
    wait(1)
    var process = worker()
    verify(process !== null)
    process.complete(1, errorResponse(store, "offline", "Shopify is offline"), "")
    wait(1)
    compare(service.lastError, "Shopify is offline")

    service.settings = {
      stores: store,
      refreshIntervalSec: 120,
      privacyMode: false,
      includeTestOrders: false,
      notify: true
    }
    wait(1)
    compare(service.lastError, "Shopify is offline")
    compare(service.errorCount, 1)
  }

  function test_store_limit_failure_is_visible_and_fail_closed() {
    var stores = []
    for (var i = 0; i < 21; i++) stores.push("store" + i + ".myshopify.com")
    configure(stores.join(","))
    compare(service.configuredStores, [])
    compare(service.configured, false)
    verify(service.lastError.indexOf("20") !== -1)
    verify(worker() === null)
  }

  function test_multi_store_polling_is_strictly_sequential() {
    configure("one.myshopify.com,two.myshopify.com")
    service.refresh(true)
    wait(1)

    var process = worker()
    verify(process !== null)
    compare(process.command.slice(1, 4), ["poll", "--store", "one.myshopify.com"])
    process.complete(0, response("one.myshopify.com", 0), "")
    wait(1)

    process = worker()
    verify(process !== null)
    compare(process.command.slice(1, 4), ["poll", "--store", "two.myshopify.com"])
    process.complete(0, response("two.myshopify.com", 2), "")
    wait(1)

    compare(service.storeStates.length, 2)
    compare(service.stateForStore("one.myshopify.com").displayName, "ONE")
    compare(service.stateForStore("two.myshopify.com").displayName, "TWO")
    compare(service.unreadCount, 2)
    verify(worker() === null)
  }

  function test_multi_store_reconfigure_runs_each_new_policy_poll_once() {
    var stores = ["one.myshopify.com", "two.myshopify.com", "three.myshopify.com"]
    configure(stores.join(","))
    service.refresh(true)
    wait(1)

    var process = worker()
    verify(process !== null)
    compare(process.command.slice(1, 4), ["poll", "--store", stores[0]])

    service.autoStart = true
    service.settings = {
      stores: stores.join(","),
      refreshIntervalSec: 120,
      privacyMode: false,
      includeTestOrders: false,
      notify: false
    }
    wait(1)
    compare(process.sentSignals, [15])

    // The old-policy A result is ignored. The rebuilt queue must then contain
    // exactly A, B, C once each, all using the new policy.
    process.complete(143, "", "")
    wait(1)
    var startedStores = []
    for (var i = 0; i < stores.length; i++) {
      process = worker()
      verify(process !== null)
      startedStores.push(process.command[3])
      verify(process.command.indexOf("--show-details") !== -1)
      verify(process.command.indexOf("--no-notify") !== -1)
      verify(process.command.indexOf("120") !== -1)
      process.complete(0, response(process.command[3], 0), "")
      wait(1)
    }

    compare(startedStores, stores)
    compare(service._jobQueue.length, 0)
    compare(service._refreshPending, false)
    verify(worker() === null)
  }

  function test_failed_start_releases_job_and_continues_the_store_queue() {
    configure("one.myshopify.com,two.myshopify.com")
    var process = ProcessRegistry.processes[0]
    process.autoEmitStarted = false
    service.refresh(true)
    wait(1)
    tryCompare(process, "running", true, 250)
    compare(process.processId, null)
    compare(process.command.slice(1, 4), ["poll", "--store", "one.myshopify.com"])

    process.failToStart()
    process.autoEmitStarted = true
    wait(1)
    compare(service.stateForStore("one.myshopify.com").error.message,
      "OrderBell worker could not start")
    verify(process.running)
    compare(process.command.slice(1, 4), ["poll", "--store", "two.myshopify.com"])
    process.complete(0, response("two.myshopify.com", 0), "")
    wait(1)
    compare(service.stateForStore("two.myshopify.com").status, "ok")
  }

  function test_reconfigure_during_starting_never_signals_pid_zero() {
    var store = "one.myshopify.com"
    configure(store)
    var process = ProcessRegistry.processes[0]
    process.autoEmitStarted = false
    service.refresh(true)
    wait(1)
    compare(process.processId, null)
    compare(service.busy, true)

    service.autoStart = true
    service.settings = {
      stores: store,
      refreshIntervalSec: 60,
      privacyMode: false,
      includeTestOrders: false,
      notify: false
    }
    wait(1)
    compare(process.sentSignals, [])
    tryCompare(process, "running", true, 250)
    verify(process.command.indexOf("--show-details") !== -1)
    verify(process.command.indexOf("--no-notify") !== -1)

    process.markStarted()
    process.complete(0, response(store, 0), "")
    wait(1)
    compare(service.stateForStore(store).status, "ok")
  }

  function test_late_start_after_expired_grace_is_terminated_by_positive_pid() {
    var store = "one.myshopify.com"
    configure(store)
    var process = ProcessRegistry.processes[0]
    process.autoEmitStarted = false
    service.refresh(true)
    wait(1)
    verify(process.running)
    compare(process.processId, null)

    // Model the state left after a timeout/cancellation request whose first
    // Starting-phase grace period elapsed before QProcess acquired its PID.
    service._jobTimedOut = true
    service.handleWorkerKillTimeout()
    compare(process.sentSignals, [])

    process.markStarted()
    compare(process.processId, 4242)
    compare(process.sentSignals, [15])
    compare(service._workerKillTimerRunning, true)
    service.handleWorkerKillTimeout()
    compare(process.sentSignals, [15, 9])

    process.complete(143, "", "")
    wait(1)
    compare(service.stateForStore(store).error.message, "OrderBell worker timed out")
  }

  function test_actions_use_the_same_argv_worker_boundary() {
    configure("one.myshopify.com")
    service.authenticate("one.myshopify.com")
    wait(1)
    var process = worker()
    verify(process !== null)
    compare(process.command.slice(1), ["authenticate", "--store", "one.myshopify.com",
      "--timeout", "300"])
    process.complete(0, response("one.myshopify.com", 0), "")
    wait(1)
    compare(service.actionStatus, "Shopify authentication completed")
    compare(service.actionStatusError, false)
    // Successful authentication schedules a fresh read of the store.
    process = worker()
    verify(process !== null)
    compare(process.command.slice(1, 4), ["poll", "--store", "one.myshopify.com"])
    process.complete(0, response("one.myshopify.com", 0), "")
  }

  function test_exit_zero_malformed_action_fails_closed() {
    configure("one.myshopify.com")
    service.lastError = "Existing polling error"
    service.lastUpdatedMs = 123456
    service.testNotification("one.myshopify.com")
    wait(1)
    var process = worker()
    verify(process !== null)
    process.complete(0, "", "shpat_secret-must-never-reach-the-ui")
    wait(1)
    compare(service.actionStatus, "The worker returned malformed JSON")
    compare(service.actionStatusError, true)
    compare(service.lastError, "Existing polling error")
    compare(service.lastUpdatedMs, 123456)
    verify(service.actionStatus.indexOf("shpat_") === -1)
  }

  function test_nonzero_valid_error_envelope_surfaces_its_message() {
    configure("one.myshopify.com")
    service.authenticate("one.myshopify.com")
    wait(1)
    var process = worker()
    verify(process !== null)
    process.complete(7, errorResponse("one.myshopify.com", "auth_required", "Sign in again"), "")
    wait(1)
    compare(service.actionStatus, "Sign in again")
    compare(service.lastError, "")
  }

  function test_action_does_not_replace_prior_poll_health_or_timestamp() {
    configure("one.myshopify.com")
    service.refresh(true)
    wait(1)
    var process = worker()
    verify(process !== null)
    process.complete(1, errorResponse("one.myshopify.com", "auth_required", "Sign in again"), "")
    wait(1)

    var prior = service.stateForStore("one.myshopify.com")
    var priorUpdated = service.lastUpdatedMs
    compare(prior.status, "error")
    compare(service.lastError, "Sign in again")
    verify(priorUpdated > 0)

    service.testNotification("one.myshopify.com")
    wait(1)
    process = worker()
    verify(process !== null)
    process.complete(0, response("one.myshopify.com", 0), "")
    wait(1)

    var after = service.stateForStore("one.myshopify.com")
    compare(service.actionStatus, "Test notification sent")
    compare(after.status, prior.status)
    compare(JSON.stringify(after.error), JSON.stringify(prior.error))
    compare(after.lastSuccessfulPollAt, prior.lastSuccessfulPollAt)
    compare(service.lastError, "Sign in again")
    compare(service.lastUpdatedMs, priorUpdated)
  }

  function test_mark_read_updates_only_acknowledged_order_fields_then_polls() {
    var store = "one.myshopify.com"
    configure(store)
    var unreadOrder = sampleOrder(store, true)
    service.storeStates = [{
      store: store,
      displayName: "ONE",
      status: "error",
      recentOrders: [unreadOrder],
      unreadCount: 1,
      pendingCount: 4,
      error: { code: "network", message: "Shopify is offline", retryable: true },
      lastSuccessfulPollAt: "2026-08-31T12:00:00Z",
      nextPollSeconds: 240,
      nextPollAtMs: 987654321,
      polling: false
    }]
    service.lastError = "Shopify is offline"
    service.lastUpdatedMs = 424242

    service.markRead(store)
    wait(1)
    var process = worker()
    verify(process !== null)
    var marked = responseValue(store, {
      displayName: null,
      recentOrders: [sampleOrder(store, false)],
      unreadCount: 0,
      pendingCount: 0,
      lastSuccessfulPollAt: "2026-09-01T18:30:01Z"
    })
    process.complete(0, JSON.stringify(marked), "")
    wait(1)

    var state = service.stateForStore(store)
    compare(service.actionStatus, "Orders marked as read")
    compare(state.unreadCount, 0)
    compare(state.displayName, "ONE")
    compare(state.recentOrders.length, 1)
    compare(state.recentOrders[0].unread, false)
    compare(state.status, "error")
    compare(state.error.code, "network")
    compare(state.error.message, "Shopify is offline")
    compare(state.pendingCount, 4)
    compare(state.lastSuccessfulPollAt, "2026-08-31T12:00:00Z")
    compare(state.nextPollSeconds, 240)
    compare(state.nextPollAtMs, 987654321)
    compare(service.lastError, "Shopify is offline")
    compare(service.lastUpdatedMs, 424242)

    // The selective acknowledgement is followed by a real health refresh.
    process = worker()
    verify(process !== null)
    compare(process.command.slice(1, 4), ["poll", "--store", store])
    process.complete(0, response(store, 0), "")
  }

  function test_exit_code_and_envelope_status_must_be_consistent() {
    configure("one.myshopify.com")
    service.testNotification("one.myshopify.com")
    wait(1)
    var process = worker()
    verify(process !== null)
    process.complete(9, response("one.myshopify.com", 0), "shpat_nonzero-secret")
    wait(1)
    compare(service.actionStatus, "OrderBell worker returned an inconsistent result")
    verify(service.actionStatus.indexOf("shpat_") === -1)

    service.testNotification("one.myshopify.com")
    wait(1)
    process = worker()
    verify(process !== null)
    process.complete(0, errorResponse("one.myshopify.com", "internal", "Contradictory error"), "")
    wait(1)
    compare(service.actionStatus, "OrderBell worker returned an inconsistent result")
  }

  function test_poll_preserves_known_good_data_during_lock_contention() {
    var store = "one.myshopify.com"
    configure(store)
    service.storeStates = [{
      store: store,
      displayName: "ONE",
      status: "ok",
      recentOrders: [sampleOrder(store, true)],
      unreadCount: 1,
      pendingCount: 3,
      error: null,
      lastSuccessfulPollAt: "2026-08-31T12:00:00Z",
      nextPollSeconds: 60,
      nextPollAtMs: 0,
      polling: false
    }]
    service.lastUpdatedMs = 1

    service.refresh(true)
    wait(1)
    var process = worker()
    verify(process !== null)
    process.complete(0, errorResponse(store, "busy", "Another poll is already running",
      "busy", false), "")
    wait(1)

    var state = service.stateForStore(store)
    compare(state.status, "busy")
    compare(state.displayName, "ONE")
    compare(state.error.code, "busy")
    compare(state.unreadCount, 1)
    compare(state.pendingCount, 3)
    compare(state.recentOrders.length, 1)
    compare(state.lastSuccessfulPollAt, "2026-08-31T12:00:00Z")
    verify(service.lastUpdatedMs > 1)
  }

  function test_authoritative_poll_error_replaces_durable_counts_after_state_changes() {
    var store = "one.myshopify.com"
    configure(store)
    service.storeStates = [{
      store: store,
      displayName: "ONE",
      status: "ok",
      recentOrders: [sampleOrder(store, true)],
      unreadCount: 1,
      pendingCount: 3,
      error: null,
      lastSuccessfulPollAt: "2026-08-31T12:00:00Z",
      nextPollSeconds: 60,
      nextPollAtMs: 0,
      polling: false
    }]

    service.refresh(true)
    wait(1)
    var process = worker()
    verify(process !== null)
    process.complete(1, errorResponse(store, "offline", "Shopify is offline",
      "error", true), "")
    wait(1)

    var state = service.stateForStore(store)
    compare(state.status, "error")
    compare(state.displayName, null)
    compare(state.recentOrders.length, 0)
    compare(state.unreadCount, 0)
    compare(state.pendingCount, 0)
    compare(state.lastSuccessfulPollAt, "")
    compare(state.error.code, "offline")
  }

  function test_poll_accepts_catching_up_as_poll_only_progress() {
    var store = "one.myshopify.com"
    configure(store)
    service.storeStates = [{
      store: store,
      displayName: "ONE",
      status: "ok",
      recentOrders: [sampleOrder(store, true)],
      unreadCount: 1,
      pendingCount: 2,
      error: null,
      lastSuccessfulPollAt: "2026-08-31T12:00:00Z",
      nextPollSeconds: 60,
      nextPollAtMs: 0,
      polling: false
    }]

    service.refresh(true)
    wait(1)
    var process = worker()
    verify(process !== null)
    process.complete(0, JSON.stringify(responseValue(store, {
      status: "catching_up",
      recentOrders: [sampleOrder(store, true)],
      unreadCount: 3,
      pendingCount: 4,
      lastSuccessfulPollAt: "2026-09-01T18:31:00Z"
    })), "")
    wait(1)

    var state = service.stateForStore(store)
    compare(state.status, "catching_up")
    compare(state.displayName, "ONE")
    compare(state.error, null)
    compare(state.unreadCount, 3)
    compare(state.pendingCount, 4)
    compare(state.recentOrders.length, 1)
    compare(state.lastSuccessfulPollAt, "2026-09-01T18:31:00Z")
    compare(service.recentOrders[0].displayName, "ONE")
    compare(service.catchingUp, true)
  }

  function test_worker_json_can_arrive_in_arbitrary_chunks() {
    var store = "one.myshopify.com"
    configure(store)
    service.refresh(true)
    wait(1)
    var process = worker()
    verify(process !== null)
    var payload = response(store, 2)
    var split = Math.floor(payload.length / 2)
    process.feed(process.stdout, payload.substring(0, split))
    process.complete(0, payload.substring(split), "")
    wait(1)
    compare(service.stateForStore(store).status, "ok")
    compare(service.stateForStore(store).unreadCount, 2)
  }

  function test_settings_change_cancels_old_policy_poll_and_restarts_safely() {
    var store = "one.myshopify.com"
    configure(store)
    service.refresh(true)
    wait(1)
    var process = worker()
    verify(process !== null)
    verify(process.command.indexOf("--privacy") !== -1)
    verify(process.command.indexOf("--notify") !== -1)

    service.autoStart = true
    service.settings = {
      stores: store,
      refreshIntervalSec: 3600,
      privacyMode: false,
      includeTestOrders: false,
      notify: false
    }
    wait(1)
    compare(process.sentSignals, [15])
    compare(service._workerKillTimerRunning, true)

    // Even a syntactically valid result from the cancelled policy snapshot is
    // ignored and cannot update sync health.
    process.complete(0, response(store, 9), "")
    wait(1)
    compare(service.lastUpdatedMs, 0)

    process = worker()
    verify(process !== null)
    verify(process.command.indexOf("--show-details") !== -1)
    verify(process.command.indexOf("--no-notify") !== -1)
    verify(process.command.indexOf("3600") !== -1)
    process.complete(0, JSON.stringify(responseValue(store, {
      nextPollSeconds: 3600
    })), "")
    wait(1)
    compare(service.stateForStore(store).status, "ok")
  }

  function test_nonzero_malformed_poll_never_surfaces_stderr() {
    configure("one.myshopify.com")
    service.refresh(true)
    wait(1)
    var process = worker()
    verify(process !== null)
    process.complete(23, "not-json", "shpat_highly-sensitive-token")
    wait(1)
    compare(service.lastError, "The worker returned malformed JSON")
    compare(service.stateForStore("one.myshopify.com").error.message,
      "The worker returned malformed JSON")
    verify(service.lastError.indexOf("shpat_") === -1)
  }

  function test_poll_timeout_preserves_data_and_does_not_advance_last_updated() {
    var store = "one.myshopify.com"
    configure(store)
    service.storeStates = [{
      store: store,
      displayName: "ONE",
      status: "ok",
      recentOrders: [sampleOrder(store, true)],
      unreadCount: 1,
      pendingCount: 0,
      error: null,
      lastSuccessfulPollAt: "2026-08-31T12:00:00Z",
      nextPollSeconds: 60,
      nextPollAtMs: 0,
      polling: false
    }]
    service.lastUpdatedMs = 9090

    service.refresh(true)
    wait(1)
    var process = worker()
    verify(process !== null)
    service.handleWorkerTimeout()
    process.complete(0, response(store, 0), "secret timeout diagnostic")
    wait(1)

    var state = service.stateForStore(store)
    compare(state.status, "error")
    compare(state.displayName, "ONE")
    compare(state.error.message, "OrderBell worker timed out")
    compare(state.unreadCount, 1)
    compare(state.recentOrders.length, 1)
    compare(service.lastError, "OrderBell worker timed out")
    compare(service.lastUpdatedMs, 9090)
  }

  function test_abnormal_exit_cannot_be_accepted_with_a_valid_ok_envelope() {
    var store = "one.myshopify.com"
    configure(store)
    service.refresh(true)
    wait(1)
    var process = worker()
    verify(process !== null)
    process.complete(0, response(store, 7), "", 1)
    wait(1)
    var state = service.stateForStore(store)
    compare(state.status, "error")
    compare(state.error.message, "OrderBell worker exited abnormally")
    compare(service.lastUpdatedMs, 0)
  }

  function test_watchdog_uses_term_then_kill_and_timeout_is_deterministic() {
    configure("one.myshopify.com")
    service.lastError = "Existing polling error"
    service.lastUpdatedMs = 777
    service.testNotification("one.myshopify.com")
    wait(1)
    var process = worker()
    verify(process !== null)
    compare(service._workerWatchdogIntervalMs, 60000)
    compare(service._workerWatchdogRunning, true)

    service.handleWorkerTimeout()
    compare(process.sentSignals, [15])
    compare(service._workerWatchdogRunning, false)
    compare(service._workerKillTimerRunning, true)
    service.handleWorkerKillTimeout()
    compare(process.sentSignals, [15, 9])
    process.complete(0, response("one.myshopify.com", 0), "shpat_timeout-secret")
    wait(1)

    compare(service.actionStatus, "OrderBell worker timed out")
    compare(service.lastError, "Existing polling error")
    compare(service.lastUpdatedMs, 777)
    compare(service._workerWatchdogRunning, false)
    compare(service._workerKillTimerRunning, false)
    verify(service.actionStatus.indexOf("shpat_") === -1)
  }

  function test_authentication_gets_extended_watchdog() {
    configure("one.myshopify.com")
    service.authenticate("one.myshopify.com")
    wait(1)
    var process = worker()
    verify(process !== null)
    compare(service._workerWatchdogIntervalMs, 330000)
    compare(service._workerWatchdogRunning, true)
    service.handleWorkerTimeout()
    process.complete(143, "", "sensitive-auth-cli-diagnostics")
    wait(1)
    compare(service.actionStatus, "OrderBell worker timed out")
    compare(service._workerWatchdogRunning, false)
    compare(service._workerKillTimerRunning, false)
  }

  function test_capture_is_bounded_before_parsing() {
    service.appendStdout("x".repeat(128 * 1024 + 1))
    compare(service._stdoutOverflow, true)
    compare(service._stdoutChunks.length, 0)
    compare(service._stdoutBytes, 0)
  }

  function test_active_oversized_stream_is_terminated_immediately() {
    var store = "one.myshopify.com"
    configure(store)
    service.refresh(true)
    wait(1)
    var process = worker()
    verify(process !== null)
    process.feed(process.stdout, "x".repeat(128 * 1024 + 1))
    compare(process.sentSignals, [15])
    compare(service._workerKillTimerRunning, true)
    process.complete(143, "", "")
    wait(1)
    compare(service.stateForStore(store).error.message,
      "The worker response exceeded its size limit")
  }

  function test_excessive_tiny_chunks_are_bounded_without_quadratic_joining() {
    var store = "one.myshopify.com"
    configure(store)
    service.refresh(true)
    wait(1)
    var process = worker()
    verify(process !== null)
    for (var i = 0; i <= service._maximumStdoutChunks; i++)
      process.feed(process.stdout, " ")
    compare(service._stdoutOverflow, true)
    compare(service._stdoutChunks.length, 0)
    compare(process.sentSignals, [15])
    process.complete(143, "", "")
    wait(1)
    compare(service.stateForStore(store).error.message,
      "The worker response exceeded its size limit")
  }
}

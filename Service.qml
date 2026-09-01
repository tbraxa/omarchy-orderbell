import QtQuick
import Quickshell.Io
import "Model.js" as Model

// One instance is created by the Omarchy service host. Every monitor's bar
// widget reads this same object, so polling and notifications happen once.
Item {
  id: root

  property var settings: ({})
  // Tests may turn startup off before the event loop runs. Production keeps it
  // on and begins polling as soon as a validated store list is injected.
  property bool autoStart: true

  readonly property string workerPath: decodeURIComponent(
    Qt.resolvedUrl("bin/orderbell-worker").toString().replace(/^file:\/\//, ""))
  readonly property var parsedStoreSetting: Model.parseStoreList(setting("stores", ""))
  readonly property var configuredStores: parsedStoreSetting.stores
  readonly property var invalidStores: parsedStoreSetting.invalid
  readonly property int refreshIntervalSec: Model.clampInteger(
    setting("refreshIntervalSec", 60), 60, Model.minimumPollSeconds, Model.maximumPollSeconds)
  readonly property bool privacyMode: setting("privacyMode", true) !== false
  readonly property bool includeTestOrders: setting("includeTestOrders", false) === true
  readonly property bool notify: setting("notify", true) !== false

  property var storeStates: []
  readonly property var aggregate: Model.aggregateStoreStates(storeStates)
  readonly property var recentOrders: aggregate.orders
  readonly property double unreadCount: aggregate.unreadCount
  readonly property int pendingCount: aggregate.pendingCount
  readonly property int errorCount: aggregate.errorCount
  readonly property bool authRequired: aggregate.authRequired
  readonly property bool catchingUp: aggregate.catchingUpCount > 0
  readonly property bool configured: configuredStores.length > 0
  readonly property bool busy: _currentJob !== null || workerProcess.running
    || _jobQueue.length > 0
  readonly property bool refreshing: (_currentJob && _currentJob.kind === "poll") || hasQueuedKind("poll")

  property string actionStatus: ""
  property bool actionStatusError: false
  property string lastError: ""
  property double lastUpdatedMs: 0

  property var _jobQueue: []
  property var _currentJob: null
  property bool _refreshPending: false
  property string _configFingerprint: ""
  property var _stdoutChunks: []
  property int _stdoutBytes: 0
  property bool _stdoutOverflow: false
  property bool _jobTimedOut: false
  property bool _jobCancelledForReconfigure: false
  property bool _jobFailedToStart: false
  property bool _workerHasStarted: false

  readonly property int _normalWorkerTimeoutMs: 60000
  readonly property int _authenticationWorkerTimeoutMs: 330000
  readonly property int _workerKillGraceMs: 3000
  readonly property int _maximumStdoutChunks: 4096
  readonly property int _workerWatchdogIntervalMs: workerWatchdog.interval
  readonly property bool _workerWatchdogRunning: workerWatchdog.running
  readonly property bool _workerKillTimerRunning: workerKillTimer.running

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function configFingerprint() {
    // parseStoreList bounds both arrays before they reach this point. Include
    // its diagnostics so editing only an invalid entry still reconfigures the
    // service and refreshes the user-facing validation message.
    return JSON.stringify({
      stores: configuredStores,
      invalid: invalidStores,
      tooMany: parsedStoreSetting.tooMany === true,
      truncated: parsedStoreSetting.truncated === true,
      interval: refreshIntervalSec,
      privacy: privacyMode,
      tests: includeTestOrders,
      notify: notify
    })
  }

  function storeConfigurationError() {
    if (parsedStoreSetting.tooMany === true)
      return "Use no more than 20 canonical Shopify store domains"
    if (parsedStoreSetting.truncated === true)
      return "The Shopify store setting exceeded its safe limit"
    if (invalidStores.length > 0)
      return "Ignored invalid store entries: " + invalidStores.join(", ")
    return ""
  }

  function currentErrorMessage() {
    var configurationError = storeConfigurationError()
    if (configurationError !== "") return configurationError
    for (var i = 0; i < storeStates.length; i++) {
      if (storeStates[i] && storeStates[i].error)
        return String(storeStates[i].error.message || "")
    }
    return ""
  }

  function stateIndex(store) {
    var wanted = Model.normalizeStore(store)
    for (var i = 0; i < storeStates.length; i++)
      if (storeStates[i].store === wanted) return i
    return -1
  }

  function stateForStore(store) {
    var index = stateIndex(store)
    return index >= 0 ? storeStates[index] : null
  }

  function replaceState(store, value) {
    var index = stateIndex(store)
    if (index < 0) return
    var next = storeStates.slice()
    next[index] = value
    storeStates = next
  }

  function setPolling(store, polling) {
    var previous = stateForStore(store)
    if (!previous || previous.polling === polling) return
    var next = {}
    for (var key in previous) next[key] = previous[key]
    next.polling = polling
    replaceState(store, next)
  }

  function reconfigure() {
    var fingerprint = configFingerprint()
    if (_configFingerprint === fingerprint) return
    _configFingerprint = fingerprint

    var now = Date.now()
    var nextStates = []
    for (var i = 0; i < configuredStores.length; i++) {
      var previous = stateForStore(configuredStores[i])
      nextStates.push(previous || Model.initialStoreState(configuredStores[i], now))
    }
    storeStates = nextStates

    // Drop work for removed stores. Under production auto-start, replace every
    // queued poll with one canonical, configured-order poll per store. This
    // both refreshes a cancelled in-flight store and prevents retained polls
    // from being replayed by the old global refresh-pending mechanism.
    var kept = []
    for (var q = 0; q < _jobQueue.length; q++) {
      var queued = _jobQueue[q]
      if (configuredStores.indexOf(queued.store) === -1) continue
      if (!autoStart || queued.kind !== "poll") kept.push(queued)
    }
    if (autoStart) {
      for (var p = 0; p < configuredStores.length; p++)
        kept.push({ kind: "poll", store: configuredStores[p] })
    }
    _jobQueue = kept
    _refreshPending = false

    // A poll or notification action already in flight carries a snapshot of
    // the old privacy/test/notification policy. Stop it before starting work
    // with the new configuration and ignore its eventual exit as health data.
    if (_currentJob && workerProcess.running) {
      _jobCancelledForReconfigure = true
      workerWatchdog.stop()
      requestWorkerTermination()
    }

    if (!configured) {
      pollTimer.stop()
      lastError = currentErrorMessage()
      return
    }

    lastError = currentErrorMessage()
    if (autoStart) {
      pollTimer.stop()
      Qt.callLater(startNextJob)
    }
    else scheduleNextPoll()
  }

  function hasQueuedKind(kind) {
    for (var i = 0; i < _jobQueue.length; i++) if (_jobQueue[i].kind === kind) return true
    return false
  }

  function jobExists(kind, store) {
    if (_currentJob && _currentJob.kind === kind && _currentJob.store === store) return true
    for (var i = 0; i < _jobQueue.length; i++) {
      if (_jobQueue[i].kind === kind && _jobQueue[i].store === store) return true
    }
    return false
  }

  function enqueue(kind, store, front) {
    var valid = Model.normalizeStore(store)
    if (valid === "" || configuredStores.indexOf(valid) === -1 || jobExists(kind, valid)) return false
    var queue = _jobQueue.slice()
    var job = { kind: kind, store: valid }
    if (front === true) queue.unshift(job)
    else queue.push(job)
    _jobQueue = queue
    Qt.callLater(startNextJob)
    return true
  }

  function refresh(manual) {
    if (!configured) return
    var now = Date.now()
    var added = false
    var missed = false
    for (var i = 0; i < configuredStores.length; i++) {
      var state = stateForStore(configuredStores[i])
      var due = manual === true || !state || Number(state.nextPollAtMs || 0) <= now
      if (due) {
        if (enqueue("poll", configuredStores[i], false)) added = true
        else missed = true
      }
    }
    if (missed && refreshing) _refreshPending = manual === true
    pollTimer.stop()
    startNextJob()
  }

  function refreshIfStale() {
    if (!configured) return
    var stale = lastUpdatedMs <= 0 || Date.now() - lastUpdatedMs >= refreshIntervalSec * 1000
    if (stale) refresh(false)
  }

  function markRead(store) {
    var valid = Model.normalizeStore(store)
    if (valid !== "") enqueue("mark-read", valid, true)
  }

  function authenticate(store) {
    var valid = Model.normalizeStore(store)
    if (valid !== "") enqueue("authenticate", valid, true)
  }

  function testNotification(store) {
    var valid = Model.normalizeStore(store)
    if (valid !== "") enqueue("test-notification", valid, true)
  }

  function commandForJob(job) {
    if (!job) return []
    if (job.kind === "poll") {
      return Model.pollCommand(workerPath, job.store, {
        notify: notify,
        privacyMode: privacyMode,
        includeTestOrders: includeTestOrders,
        refreshIntervalSec: refreshIntervalSec
      })
    }
    return Model.workerActionCommand(workerPath, job.kind, job.store, privacyMode)
  }

  function startNextJob() {
    if (workerProcess.running || _currentJob) return
    if (_jobQueue.length === 0) {
      if (_refreshPending) {
        _refreshPending = false
        refresh(true)
        return
      }
      scheduleNextPoll()
      return
    }

    var queue = _jobQueue.slice()
    var job = queue.shift()
    _jobQueue = queue
    var command = commandForJob(job)
    if (command.length === 0) {
      lastError = "OrderBell refused an invalid worker command"
      Qt.callLater(startNextJob)
      return
    }

    _currentJob = job
    _stdoutChunks = []
    _stdoutBytes = 0
    _stdoutOverflow = false
    _jobTimedOut = false
    _jobCancelledForReconfigure = false
    _jobFailedToStart = false
    _workerHasStarted = false
    workerWatchdog.stop()
    workerKillTimer.stop()
    if (job.kind === "poll") setPolling(job.store, true)
    else {
      actionStatusTimer.stop()
      actionStatusError = false
      if (job.kind === "authenticate") actionStatus = "Opening Shopify authentication…"
      else if (job.kind === "mark-read") actionStatus = "Marking orders as read…"
      else if (job.kind === "test-notification") actionStatus = "Sending a test notification…"
    }
    workerProcess.command = command
    workerWatchdog.interval = job.kind === "authenticate"
      ? _authenticationWorkerTimeoutMs : _normalWorkerTimeoutMs
    workerWatchdog.restart()
    workerProcess.running = true
  }

  function appendStdout(data) {
    if (_stdoutOverflow) return
    var chunk = String(data || "")
    if (chunk === "") return
    var chunkBytes = Model.utf8ByteLength(chunk)
    if (_stdoutBytes > Model.workerResponseByteLimit - chunkBytes
        || _stdoutChunks.length >= _maximumStdoutChunks) {
      _stdoutOverflow = true
      _stdoutChunks = []
      _stdoutBytes = 0
      if (_currentJob && workerProcess.running) {
        workerWatchdog.stop()
        requestWorkerTermination()
      }
    } else {
      _stdoutChunks.push(chunk)
      _stdoutBytes += chunkBytes
    }
  }

  function handleWorkerTimeout() {
    if (!_currentJob || !workerProcess.running || _jobTimedOut) return
    _jobTimedOut = true
    workerWatchdog.stop()
    requestWorkerTermination()
  }

  function requestWorkerTermination() {
    if (!_currentJob || !workerProcess.running) return
    // Quickshell creates its QProcess before it has a positive PID. Calling
    // Process.signal() in that Starting window can become kill(0, signal), so
    // ask QProcess to terminate through its running property until started.
    workerKillTimer.restart()
    var processId = Number(workerProcess.processId || 0)
    if (_workerHasStarted && isFinite(processId) && processId > 0)
      workerProcess.signal(15)
    else workerProcess.running = false
  }

  function handleWorkerStarted() {
    if (!_currentJob || !workerProcess.running) return
    _workerHasStarted = true
    // QProcess can remain in Starting after setRunning(false) requested a
    // termination. The first grace timer may therefore expire before a PID
    // exists. If that late start belongs to work we already rejected, send a
    // PID-scoped TERM now and begin a fresh TERM→KILL grace period.
    if (_jobCancelledForReconfigure || _jobTimedOut || _stdoutOverflow)
      requestWorkerTermination()
  }

  function handleWorkerStoppedWithoutExit() {
    // Quickshell emits runningChanged but no exited signal for
    // QProcess::FailedToStart. Normal/crash exits emit exited first, and that
    // path has already cleared _currentJob before runningChanged arrives.
    if (workerProcess.running || !_currentJob) return
    _jobFailedToStart = !_jobTimedOut && !_jobCancelledForReconfigure
    finishJob(-1, 1)
  }

  function handleWorkerKillTimeout() {
    if (!_currentJob || !workerProcess.running) return
    var processId = Number(workerProcess.processId || 0)
    if (_workerHasStarted && isFinite(processId) && processId > 0)
      workerProcess.signal(9)
  }

  function responseMatchesExit(job, exitCode, parsed) {
    if (!job || !parsed.ok) return false
    var status = parsed.value.status
    var hasError = parsed.value.error !== null
    if (status === "error") return exitCode !== 0 && hasError
    if (status === "busy") return exitCode === 0 && hasError
    if (status === "degraded")
      return job.kind === "poll" && exitCode === 0 && hasError
    if (status === "catching_up")
      return job.kind === "poll" && exitCode === 0 && !hasError
    if (status === "baseline")
      return job.kind === "poll" && exitCode === 0 && !hasError
    return status === "ok" && exitCode === 0 && !hasError
  }

  function applyPollResult(job, parsed) {
    var previous = stateForStore(job.store)
    if (!previous) return
    var now = Date.now()
    var merged = Model.mergeStoreResult(previous, parsed.value, now, refreshIntervalSec)
    replaceState(job.store, merged)
    lastUpdatedMs = now
    if (parsed.value.error) lastError = parsed.value.error.message
    else {
      var remainingError = ""
      for (var i = 0; i < storeStates.length; i++) {
        if (storeStates[i].error) {
          remainingError = storeStates[i].error.message
          break
        }
      }
      lastError = remainingError || storeConfigurationError()
    }
  }

  function applyPollFailure(job, message) {
    var previous = stateForStore(job.store)
    if (!previous) return
    replaceState(job.store, Model.processFailure(previous, job.store, message,
      Date.now(), refreshIntervalSec))
    lastError = message
  }

  function applyMarkReadResult(job, parsed) {
    var previous = stateForStore(job.store)
    if (!previous) return
    // A write action may acknowledge data, but it must not masquerade as a
    // health check. Preserve status, error, retry timing and last sync data.
    var next = {}
    for (var key in previous) next[key] = previous[key]
    if (parsed.value.displayName !== null)
      next.displayName = parsed.value.displayName
    next.recentOrders = parsed.value.recentOrders.slice()
    next.unreadCount = parsed.value.unreadCount
    replaceState(job.store, next)
  }

  function finishJob(exitCode, exitStatus) {
    workerWatchdog.stop()
    workerKillTimer.stop()
    var job = _currentJob
    if (!job) return
    var timedOut = _jobTimedOut
    var cancelled = _jobCancelledForReconfigure
    var failedToStart = _jobFailedToStart
    if (job.kind === "poll") setPolling(job.store, false)

    if (cancelled) {
      if (job.kind !== "poll") {
        actionStatus = "Action cancelled because settings changed"
        actionStatusError = false
        actionStatusTimer.restart()
      }
      _currentJob = null
      _jobTimedOut = false
      _jobCancelledForReconfigure = false
      _jobFailedToStart = false
      _workerHasStarted = false
      _stdoutChunks = []
      _stdoutBytes = 0
      _stdoutOverflow = false
      Qt.callLater(startNextJob)
      return
    }

    var parsed = _stdoutOverflow
      ? { ok: false, error: "The worker response exceeded its size limit" }
      : Model.parseWorkerResponse(_stdoutChunks.join(""), job.store)
    var normalExit = Number(exitStatus) === 0
    var consistent = !timedOut && !failedToStart && normalExit
      && responseMatchesExit(job, exitCode, parsed)
    var failure = timedOut ? "OrderBell worker timed out"
      : (failedToStart ? "OrderBell worker could not start"
        : (!parsed.ok ? parsed.error
        : (!normalExit ? "OrderBell worker exited abnormally"
          : (!consistent ? "OrderBell worker returned an inconsistent result"
            : (parsed.value.error ? parsed.value.error.message : "OrderBell worker failed safely")))))

    if (job.kind === "poll") {
      if (consistent) applyPollResult(job, parsed)
      else applyPollFailure(job, failure)
    }

    // Actions report only their own outcome. They never replace polling
    // health or the timestamp of the last completed poll.
    var actionSucceeded = consistent && parsed.value.status === "ok"

    if (job.kind === "authenticate") {
      actionStatus = actionSucceeded ? "Shopify authentication completed" : failure
      if (actionSucceeded) enqueue("poll", job.store, false)
    } else if (job.kind === "mark-read") {
      if (actionSucceeded) {
        applyMarkReadResult(job, parsed)
        actionStatus = "Orders marked as read"
        enqueue("poll", job.store, false)
      } else actionStatus = failure
    } else if (job.kind === "test-notification") {
      actionStatus = actionSucceeded ? "Test notification sent" : failure
    }
    if (job.kind !== "poll") {
      actionStatusError = !actionSucceeded
      actionStatusTimer.restart()
    }

    _currentJob = null
    _jobTimedOut = false
    _jobCancelledForReconfigure = false
    _jobFailedToStart = false
    _workerHasStarted = false
    _stdoutChunks = []
    _stdoutBytes = 0
    _stdoutOverflow = false
    Qt.callLater(startNextJob)
  }

  function scheduleNextPoll() {
    pollTimer.stop()
    if (!autoStart || !configured || workerProcess.running || _jobQueue.length > 0) return
    var nextAt = 0
    var now = Date.now()
    for (var i = 0; i < storeStates.length; i++) {
      var candidate = Number(storeStates[i].nextPollAtMs || now)
      if (nextAt === 0 || candidate < nextAt) nextAt = candidate
    }
    pollTimer.interval = Math.max(1000, Math.min(2147483647, nextAt - now))
    pollTimer.restart()
  }

  onSettingsChanged: Qt.callLater(reconfigure)
  Component.onCompleted: Qt.callLater(reconfigure)
  Component.onDestruction: {
    workerWatchdog.stop()
    workerKillTimer.stop()
    if (workerProcess.running) {
      var processId = Number(workerProcess.processId || 0)
      if (_workerHasStarted && isFinite(processId) && processId > 0)
        workerProcess.signal(15)
      else workerProcess.running = false
    }
  }

  Timer {
    id: pollTimer
    repeat: false
    onTriggered: root.refresh(false)
  }

  Timer {
    id: actionStatusTimer
    interval: 2600
    repeat: false
    onTriggered: {
      root.actionStatus = ""
      root.actionStatusError = false
    }
  }

  Timer {
    id: workerWatchdog
    repeat: false
    onTriggered: root.handleWorkerTimeout()
  }

  Timer {
    id: workerKillTimer
    interval: root._workerKillGraceMs
    repeat: false
    onTriggered: root.handleWorkerKillTimeout()
  }

  Process {
    id: workerProcess
    running: false
    command: []
    stdout: SplitParser {
      // Empty marker forwards arbitrary chunks instead of buffering an
      // attacker-controlled unterminated line inside the native parser.
      splitMarker: ""
      onRead: function(data) { root.appendStdout(data) }
    }
    // stderr can contain paths, tokens or upstream CLI diagnostics. The
    // validated and sanitized JSON envelope on stdout is the sole UI
    // error channel, so stderr is deliberately drained and discarded.
    stderr: SplitParser {
      splitMarker: ""
      onRead: function(data) {}
    }
    onStarted: root.handleWorkerStarted()
    onExited: function(exitCode, exitStatus) { root.finishJob(exitCode, exitStatus) }
    onRunningChanged: root.handleWorkerStoppedWithoutExit()
  }
}

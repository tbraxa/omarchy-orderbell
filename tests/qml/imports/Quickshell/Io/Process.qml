import QtQml

QtObject {
  id: root
  property bool running: false
  property var command: []
  property var stdout: null
  property var stderr: null
  property var processId: null
  property var sentSignals: []
  property bool _completing: false
  property bool autoEmitStarted: true
  signal started()
  signal exited(int exitCode, int exitStatus)

  onRunningChanged: {
    if (running && autoEmitStarted) markStarted()
    else if (!running) processId = null
  }

  function markStarted() {
    if (!running || Number(processId || 0) > 0) return
    processId = 4242
    started()
  }

  function complete(exitCode, stdoutText, stderrText, exitStatus) {
    feed(stdout, stdoutText)
    feed(stderr, stderrText)
    _completing = true
    exited(exitCode, exitStatus === undefined ? 0 : Number(exitStatus))
    running = false
    _completing = false
  }

  function failToStart() {
    processId = null
    running = false
  }

  function feed(stream, text) {
    if (stream && typeof stream.feedLine === "function" && String(text || "") !== "")
      stream.feedLine(String(text))
  }

  function signal(number) {
    var next = sentSignals.slice()
    next.push(Number(number))
    sentSignals = next
  }

  Component.onCompleted: ProcessRegistry.add(root)
  Component.onDestruction: ProcessRegistry.remove(root)
}

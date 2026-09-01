pragma Singleton
import QtQml

QtObject {
  property var detachedCommands: []

  function execDetached(command) {
    var next = detachedCommands.slice()
    next.push(command)
    detachedCommands = next
  }

  function resetDetachedCommands() { detachedCommands = [] }
  function env(name) { return "" }
}

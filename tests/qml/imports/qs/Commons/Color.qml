pragma Singleton
import QtQuick

QtObject {
  readonly property color accent: "#7aa2f7"
  readonly property color muted: "#8b8f9a"
  readonly property color urgent: "#f7768e"
  readonly property QtObject popups: QtObject {
    readonly property color text: "#c0caf5"
  }
}

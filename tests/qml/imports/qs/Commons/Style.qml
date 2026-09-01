pragma Singleton
import QtQml

QtObject {
  readonly property QtObject font: QtObject {
    readonly property string family: "sans-serif"
    readonly property int caption: 10
    readonly property int bodySmall: 11
    readonly property int body: 12
    readonly property int icon: 14
    readonly property int display: 32
  }
  readonly property QtObject spacing: QtObject {
    readonly property int panelGap: 12
    readonly property int rowPaddingX: 12
  }

  function space(value) { return Number(value) }
}

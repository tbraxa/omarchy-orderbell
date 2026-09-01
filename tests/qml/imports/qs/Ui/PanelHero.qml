import QtQuick

Item {
  property Component iconComponent: null
  property string title: ""
  property string meta: ""
  property string detail: ""
  property color foreground: "white"
  property string fontFamily: "sans-serif"
  property real iconOpacity: 1
  implicitHeight: 40
}

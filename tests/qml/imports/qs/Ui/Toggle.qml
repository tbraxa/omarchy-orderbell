import QtQuick

Item {
  property string label: ""
  property string description: ""
  property bool checked: false
  property color foreground: "white"
  property color accent: "blue"
  property string fontFamily: "sans-serif"
  signal clicked()
  implicitWidth: 240
  implicitHeight: 54
}

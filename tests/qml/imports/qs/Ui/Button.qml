import QtQuick

Item {
  property string text: ""
  property string iconText: ""
  property color foreground: "white"
  property string fontFamily: "sans-serif"
  property real fontSize: 12
  property real iconSize: 14
  property bool bordered: false
  property bool hasCursor: false
  property bool focusable: false
  signal hovered(bool on)
  signal clicked()
  implicitWidth: 80
  implicitHeight: 28
}

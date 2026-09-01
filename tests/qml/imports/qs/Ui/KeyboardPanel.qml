import QtQuick

Item {
  property Item anchorItem: null
  property var owner: null
  property QtObject bar: null
  property bool open: false
  property Item focusTarget: null
  property int contentWidth: 1
  property int contentHeight: 1

  width: contentWidth
  height: contentHeight

  function fittedContentWidth(value) { return Math.max(1, Number(value) || 1) }
  function fittedContentHeight(value) { return Math.max(1, Number(value) || 1) }
}

import QtQuick

Item {
  id: root

  property QtObject bar: null
  property string moduleName: ""
  property var settings: ({})
  property string ipcTarget: ""
  property bool manageIpc: true
  property alias controller: panelController
  readonly property bool opened: panelController.open

  QtObject {
    id: panelController
    property bool open: false
    function show() { open = true }
    function hide() { open = false }
  }
}

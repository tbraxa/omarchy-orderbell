import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

BarWidget {
  id: root
  moduleName: "io.github.tbraxa.orderbell"

  readonly property bool sharedServiceSupported: bar && bar.shell
    && typeof bar.shell.serviceFor === "function"
  readonly property var sharedService: sharedServiceSupported
    ? bar.shell.serviceFor(moduleName) : null
  readonly property var service: sharedService

  function pushSettings() {
    if (service) service.settings = settings
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("service" in target) target.service = root.service
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  function refreshService() {
    if (service) service.refresh(true)
  }

  function togglePanel() {
    if (panelLoader.item) panelLoader.item.toggle()
  }

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item
    ? panelLoader.item.popoutSwitchClosing === true : false

  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: {
    injectPanel()
    pushSettings()
  }
  onSettingsChanged: {
    injectPanel()
    pushSettings()
  }
  onServiceChanged: {
    injectPanel()
    pushSettings()
  }
  Component.onCompleted: pushSettings()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  IpcHandler {
    target: root.moduleName

    function refresh(): void { root.refreshService() }
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.togglePanel() }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // Font Awesome's generic shopping bag. Deliberately not Shopify's mark.
    text: "\uf290"
    useActiveColor: true
    active: Model.barNeedsAttention(root.service)
    activeColor: root.service && root.service.errorCount > 0 ? Color.urgent : Color.accent
    dimmed: !root.service
    tooltipText: Model.barTooltip(root.service)
    Accessible.role: Accessible.Button
    Accessible.name: "OrderBell"
    Accessible.description: tooltipText
    Accessible.focusable: true
    Accessible.onPressAction: root.togglePanel()
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.MiddleButton) root.refreshService()
      else root.togglePanel()
    }
  }

  BorderSurface {
    id: unreadBadge
    visible: root.service && root.service.unreadCount > 0
    anchors.top: parent.top
    anchors.right: parent.right
    anchors.topMargin: Style.space(3)
    anchors.rightMargin: Style.space(1)
    implicitWidth: Math.max(Style.space(12), badgeText.implicitWidth + Style.space(4))
    implicitHeight: Style.space(12)
    radius: height / 2
    color: Style.selectedFillFor(root.bar ? root.bar.barForeground : Color.foreground, Color.accent)
    borderSpec: Border.controlSpec("selected",
      root.bar ? root.bar.barForeground : Color.foreground, Color.accent)

    Text {
      id: badgeText
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: !root.service ? "" : (root.service.unreadCount > 9 ? "9+" : String(root.service.unreadCount))
      color: Style.selectedStateColor(root.bar ? root.bar.barForeground : Color.foreground, Color.accent)
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: Style.font.caption
      font.bold: true
    }
  }
}

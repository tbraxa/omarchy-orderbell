pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "io.github.tbraxa.orderbell"
  ipcTarget: "io.github.tbraxa.orderbell"
  manageIpc: false

  property var service: null
  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  property bool cursorActive: false
  property string cursorIdentity: ""
  property string selectedStoreDomain: ""
  property double nowMs: Date.now()
  property bool settingsOpen: false
  property bool draftPrivacyMode: true
  property bool draftIncludeTestOrders: false
  property bool draftNotify: true
  property string settingsError: ""
  readonly property bool settingsControlFocused: storesField.activeFocus
    || intervalField.activeFocus || privacyToggle.activeFocus
    || notificationsToggle.activeFocus || testOrdersToggle.activeFocus
    || testNotificationButton.activeFocus || saveButton.activeFocus
    || cancelButton.activeFocus

  readonly property color foreground: Color.popups.text
  readonly property color urgent: Color.urgent
  readonly property color accent: Color.accent
  // Some stock themes deliberately make Color.muted very faint. Blend it
  // toward the popup foreground so essential secondary copy remains readable
  // across the stock palette without abandoning Omarchy's semantic colors.
  readonly property color dim: Qt.rgba(
    Color.muted.r * 0.20 + foreground.r * 0.80,
    Color.muted.g * 0.20 + foreground.g * 0.80,
    Color.muted.b * 0.20 + foreground.b * 0.80,
    1.0)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property var stores: service ? service.storeStates : []
  readonly property var orders: service ? service.recentOrders : []
  readonly property int selectedStoreIndex: findStoreIndex(selectedStoreDomain)
  readonly property var selectedStore: selectedStoreIndex >= 0 ? stores[selectedStoreIndex] : null
  readonly property string selectedStoreName: selectedStore ? selectedStore.store : ""
  readonly property bool setupRequired: service !== null && !service.configured
  readonly property bool selectedStoreNeedsAuthentication: selectedStore !== null
    && Model.isAuthError(selectedStore.error)
  readonly property bool settingsSectionVisible: settingsOpen || setupRequired
  readonly property var actionKeys: {
    // Setup already presents the complete form and its Save action. Hiding
    // Settings and Refresh here avoids controls that cannot change anything
    // until the first canonical store has been saved.
    if (!service || !service.configured) return []
    var keys = ["settings", "refresh"]
    if (selectedStore) {
      keys.push("admin")
      if (selectedStoreNeedsAuthentication) keys.push("authenticate")
      if (selectedStore.unreadCount > 0) keys.push("mark-read")
    }
    return keys
  }
  readonly property var navigation: Model.navigationItems(
    actionKeys, stores, orders, selectedStoreName)
  readonly property int currentNavigationIndex: navigationIndex(cursorIdentity)
  readonly property var currentNavigation: cursorActive && currentNavigationIndex >= 0
    ? navigation[currentNavigationIndex] : null

  readonly property string heroMeta: {
    if (!service) return "SERVICE UNAVAILABLE"
    if (!service.configured) return "ADD A STORE TO BEGIN"
    if (service.refreshing) return "CHECKING FOR ORDERS"
    if (service.authRequired) return "SHOPIFY SIGN-IN REQUIRED"
    if (service.errorCount > 0) return "SYNC NEEDS ATTENTION"
    if (service.catchingUp) return "CATCHING UP SAFELY"
    if (service.pendingCount > 0) return "DELIVERY CATCHING UP"
    if (service.unreadCount > 0) return service.unreadCount === 1
      ? "ONE NEW ORDER" : Model.countLabel(service.unreadCount, 9999) + " NEW ORDERS"
    return "ALL CAUGHT UP"
  }
  readonly property string heroDetail: {
    if (!service || !service.configured) return ""
    if (service.unreadCount > 0) return Model.countLabel(service.unreadCount, 9999)
    if (service.pendingCount > 0) return String(service.pendingCount)
    return service.configuredStores.length === 1 ? "1 store" : service.configuredStores.length + " stores"
  }
  readonly property string statusLine: {
    if (!service) return "OrderBell's shared service could not be loaded."
    if (service.actionStatus !== "") return service.actionStatus
    if (settingsError !== "") return settingsError
    if (service.lastError !== "") return service.lastError
    if (service.pendingCount > 0) return service.pendingCount === 1
      ? "One notification is queued for retry."
      : service.pendingCount + " notifications are queued for bounded retry."
    if (service.catchingUp) return "Scanning missed orders in bounded windows; OrderBell will continue automatically."
    if (service.invalidStores.length > 0) return "Some store entries were ignored because they are not canonical myshopify.com domains."
    if (!service.configured) return "Add your lowercase shop-name.myshopify.com domain below."
    if (service.lastUpdatedMs <= 0) return "Waiting for the first secure read-only sync."
    return "Last checked " + Model.relativeTime(service.lastUpdatedMs, nowMs)
  }
  readonly property bool statusLineUrgent: {
    if (!service || settingsError !== "") return true
    if (service.actionStatus !== "") return service.actionStatusError === true
    return service.lastError !== ""
  }

  function open() {
    controller.show()
    ensureSelection()
    if (service) service.refreshIfStale()
    Qt.callLater(focusInitialTarget)
  }

  function close() { controller.hide() }
  function toggle() { opened ? close() : open() }

  function focusInitialTarget() {
    if (setupRequired) {
      storesField.forceActiveFocus()
      storesField.selectAll()
    } else keyCatcher.forceActiveFocus()
  }

  function firstAuthenticationStore() {
    for (var i = 0; i < stores.length; i++) {
      if (stores[i] && Model.isAuthError(stores[i].error)) return stores[i].store
    }
    return ""
  }

  function preferAuthenticationStore() {
    if (!service || !service.authRequired || selectedStoreNeedsAuthentication) return
    var authStore = firstAuthenticationStore()
    if (authStore !== "") selectedStoreDomain = authStore
  }

  function switchPanel(direction) {
    if (bar && typeof bar.switchPanelFrom === "function")
      return bar.switchPanelFrom(barIdentity, direction)
    return false
  }

  function findStoreIndex(store) {
    for (var i = 0; i < stores.length; i++)
      if (stores[i] && stores[i].store === store) return i
    return -1
  }

  function storeTitle(storeState) {
    return Model.storeDisplayName(storeState ? storeState.displayName : null,
      storeState ? storeState.store : "")
  }

  function navigationIndex(identity) {
    var wanted = String(identity || "")
    for (var i = 0; i < navigation.length; i++)
      if (navigation[i].identity === wanted) return i
    return -1
  }

  function storeForNavigation(item) {
    if (!item || item.kind !== "store") return null
    var index = findStoreIndex(item.key)
    return index >= 0 ? stores[index] : null
  }

  function orderForNavigation(item) {
    if (!item || item.kind !== "order") return null
    for (var i = 0; i < orders.length; i++) {
      var order = orders[i]
      if (String(order.store || "") + "|" + String(order.idHash || "") === item.key)
        return order
    }
    return null
  }

  function ensureSelection() {
    if (stores.length === 0) selectedStoreDomain = ""
    else if (findStoreIndex(selectedStoreDomain) < 0) selectedStoreDomain = stores[0].store
    if (cursorActive && navigationIndex(cursorIdentity) < 0) {
      cursorActive = false
      cursorIdentity = ""
    }
    if (opened) preferAuthenticationStore()
  }

  function moveCursor(dx, dy) {
    var items = Array.isArray(navigation) ? navigation : []
    if (items.length === 0) return
    if (!cursorActive) {
      cursorActive = true
      cursorIdentity = items[0].identity
      scrollCursorIntoView()
      return
    }
    var delta = dy !== 0 ? dy : dx
    var current = navigationIndex(cursorIdentity)
    if (current < 0) {
      cursorActive = false
      cursorIdentity = ""
      return
    }
    var next = Math.max(0, Math.min(items.length - 1, current + delta))
    cursorIdentity = items[next].identity
    scrollCursorIntoView()
  }

  function setCursor(kind, key) {
    cursorActive = true
    var items = Array.isArray(navigation) ? navigation : []
    for (var i = 0; i < items.length; i++) {
      var item = items[i]
      if (item.kind === kind && item.key === key) {
        cursorIdentity = item.identity
        return
      }
    }
    cursorActive = false
    cursorIdentity = ""
  }

  function hasCursor(kind, key) {
    return cursorActive && currentNavigation && currentNavigation.kind === kind
      && currentNavigation.key === key
  }

  function activateCursor() {
    if (!cursorActive || !currentNavigation) return
    if (currentNavigation.kind === "action") invokeAction(currentNavigation.key)
    else if (currentNavigation.kind === "store") selectStore(currentNavigation.key)
    else if (currentNavigation.kind === "order") openOrder(orderForNavigation(currentNavigation))
  }

  function selectStore(store) {
    if (findStoreIndex(store) >= 0) selectedStoreDomain = store
  }

  function openOrder(order) {
    if (!order || String(order.url || "") === "") return
    // Model.parseWorkerResponse rebuilt this URL from a validated store and a
    // numeric order id. No remote URL is ever opened directly.
    Qt.openUrlExternally(order.url)
  }

  function invokeAction(key) {
    if (!actionEnabled(key)) return
    if (key === "settings") toggleSettings()
    else if (key === "refresh") service.refresh(true)
    else if (key === "admin" && selectedStore)
      Qt.openUrlExternally(Model.adminOrdersUrl(selectedStore.store))
    else if (key === "authenticate" && selectedStore)
      service.authenticate(selectedStore.store)
    else if (key === "mark-read" && selectedStore)
      service.markRead(selectedStore.store)
    else if (key === "test-notification" && selectedStore)
      service.testNotification(selectedStore.store)
  }

  function actionEnabled(key) {
    if (key === "settings") return service && service.configured
      && root.bar && root.bar.shell
      && typeof root.bar.shell.updateEntryInline === "function"
    if (!service) return false
    if (key === "admin") return selectedStore !== null
    if (key === "mark-read") return selectedStore !== null
      && selectedStore.unreadCount > 0 && !service.busy
    if (key === "refresh") return service.configured && !service.busy
    return selectedStore !== null && !service.busy
  }

  function settingValue(name, fallback) {
    var value = root.settings ? root.settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function resetSettingsDraft() {
    storesField.text = String(settingValue("stores", ""))
    intervalField.text = String(settingValue("refreshIntervalSec", 60))
    draftPrivacyMode = settingValue("privacyMode", true) !== false
    draftIncludeTestOrders = settingValue("includeTestOrders", false) === true
    draftNotify = settingValue("notify", true) !== false
    settingsError = ""
  }

  function toggleSettings() {
    settingsOpen = !settingsOpen
    if (settingsOpen) {
      resetSettingsDraft()
      Qt.callLater(function() {
        storesField.forceActiveFocus()
        storesField.selectAll()
      })
    } else {
      settingsError = ""
      Qt.callLater(function() { keyCatcher.forceActiveFocus() })
    }
  }

  function leaveSettingsFocus() {
    settingsError = ""
    if (setupRequired) {
      close()
      return
    }
    settingsOpen = false
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function persistSettings(values) {
    var entry = { id: root.moduleName }
    var current = root.settings || ({})
    for (var existing in current) if (existing !== "id") entry[existing] = current[existing]
    for (var key in values) entry[key] = values[key]
    root.settings = entry
    if (root.hostWidget && "settings" in root.hostWidget) root.hostWidget.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      return root.bar.shell.updateEntryInline(root.moduleName, entry)
    return false
  }

  function saveSettings() {
    var parsed = Model.parseStoreList(storesField.text)
    if ((parsed.invalid && parsed.invalid.length > 0) || parsed.tooMany === true
        || parsed.truncated === true) {
      settingsError = parsed.tooMany === true
        ? "Use no more than 20 canonical store domains."
        : (parsed.truncated === true ? "The store list is too long."
          : "Every store must be a lowercase shop-name.myshopify.com domain.")
      return
    }
    if (parsed.stores.length === 0) {
      settingsError = "Add at least one canonical myshopify.com store domain."
      return
    }
    var intervalText = String(intervalField.text || "").trim()
    if (!/^\d{2,4}$/.test(intervalText) || Number(intervalText) < 60
        || Number(intervalText) > 3600) {
      settingsError = "Check interval must be a whole number from 60 to 3600 seconds."
      return
    }
    persistSettings({
      stores: parsed.stores.join(", "),
      refreshIntervalSec: Number(intervalText),
      privacyMode: draftPrivacyMode,
      includeTestOrders: draftIncludeTestOrders,
      notify: draftNotify
    })
    settingsError = ""
    settingsOpen = false
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function actionLabel(key) {
    if (key === "settings") return settingsOpen ? "Close settings" : "Settings"
    if (key === "refresh") return "Refresh"
    if (key === "admin") return "Open Admin"
    if (key === "authenticate") return "Sign in"
    if (key === "mark-read") return "Mark read"
    if (key === "test-notification") return "Test notification"
    return "Action"
  }

  function emptyOrdersMessage() {
    if (!service) return "Order status is unavailable."
    if (service.refreshing) return "Checking Shopify…"
    if (service.authRequired) return "Sign in to load recent orders."
    if (service.errorCount > 0) return "Recent orders are unavailable until sync recovers."
    if (service.catchingUp) return "Catching up on missed orders…"
    if (service.lastUpdatedMs <= 0) return "Waiting for the first secure sync."
    return "No recent orders yet."
  }

  function scrollItemIntoView(item) {
    if (!item || !panelFlick) return
    Qt.callLater(function() {
      if (!item || !panelFlick) return
      var mapped = item.mapToItem(panelFlick.contentItem, 0, 0)
      var margin = Style.space(8)
      var top = mapped.y
      var bottom = top + item.height
      var viewTop = panelFlick.contentY
      var viewBottom = viewTop + panelFlick.height
      var maximum = Math.max(0, panelFlick.contentHeight - panelFlick.height)
      if (top < viewTop + margin) panelFlick.contentY = Math.max(0, top - margin)
      else if (bottom > viewBottom - margin)
        panelFlick.contentY = Math.min(maximum, bottom + margin - panelFlick.height)
    })
  }

  function actionGlyph(key) {
    if (key === "settings") return "\uf013"
    if (key === "refresh") return "\uf021"
    if (key === "admin") return "\uf35d"
    if (key === "authenticate") return "\uf2f6"
    if (key === "mark-read") return "\uf00c"
    if (key === "test-notification") return "\uf0f3"
    return ""
  }

  function scrollCursorIntoView() {
    if (!currentNavigation || !panelFlick) return
    var item = null
    if (currentNavigation.kind === "store") {
      var storeIndex = findStoreIndex(currentNavigation.key)
      if (storeIndex >= 0) item = storeRepeater.itemAt(storeIndex)
    } else if (currentNavigation.kind === "order") {
      var order = orderForNavigation(currentNavigation)
      if (order) {
        for (var i = 0; i < orders.length; i++) {
          var candidateKey = String(orders[i].store || "") + "|" + String(orders[i].idHash || "")
          if (candidateKey === currentNavigation.key) {
            item = orderRepeater.itemAt(i)
            break
          }
        }
      }
    }
    if (!item) {
      if (currentNavigation.kind === "action") panelFlick.contentY = 0
      return
    }
    scrollItemIntoView(item)
  }

  implicitWidth: buttonProxy.implicitWidth
  implicitHeight: buttonProxy.implicitHeight

  onOpenedChanged: {
    if (!opened) return
    cursorActive = false
    cursorIdentity = ""
    nowMs = Date.now()
    if (panelFlick) panelFlick.contentY = 0
    ensureSelection()
    if (service) service.refreshIfStale()
    Qt.callLater(focusInitialTarget)
  }
  onStoresChanged: ensureSelection()
  onOrdersChanged: ensureSelection()
  onActionKeysChanged: ensureSelection()
  onNavigationChanged: ensureSelection()
  onSettingsChanged: {
    if (!settingsOpen) Qt.callLater(resetSettingsDraft)
  }
  Component.onCompleted: Qt.callLater(resetSettingsDraft)

  // This item only supplies the legacy Panel implicit-size contract; the real
  // bar button lives in BarWidget.qml and is the popup anchor.
  Item { id: buttonProxy; implicitWidth: 1; implicitHeight: 1; visible: false }

  Timer {
    interval: 15000
    running: root.opened
    repeat: true
    onTriggered: root.nowMs = Date.now()
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(contentColumn.implicitHeight, Style.space(640))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.settingsControlFocused
      onMoveRequested: function(dx, dy) { root.moveCursor(dx, dy) }
      onActivateRequested: root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(text) {
        if (text === "r" || text === "R") root.invokeAction("refresh")
        else if (text === ",") root.invokeAction("settings")
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: contentColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: contentColumn
          width: panelFlick.width
          spacing: Style.spacing.panelGap

          PanelHero {
            id: hero
            width: parent.width
            title: "OrderBell"
            meta: root.heroMeta
            detail: root.heroDetail
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconOpacity: 1.0
            iconComponent: Component {
              Item {
                implicitWidth: Style.font.display
                implicitHeight: Style.font.display

                Text {
                  anchors.centerIn: parent
                  textFormat: Text.PlainText
                  text: "\uf290"
                  color: root.service && root.service.errorCount > 0 ? root.urgent : root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.display
                }

                Rectangle {
                  visible: root.service && root.service.unreadCount > 0
                  anchors.right: parent.right
                  anchors.bottom: parent.bottom
                  width: Style.space(7)
                  height: width
                  radius: width / 2
                  color: root.accent
                }
              }
            }
          }

          Text {
            width: parent.width
            textFormat: Text.PlainText
            text: root.statusLine
            color: root.statusLineUrgent ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Flow {
            id: actionFlow
            width: parent.width
            spacing: Style.space(6)

            Repeater {
              model: root.actionKeys

              Button {
                required property var modelData
                required property int index
                text: root.actionLabel(String(modelData))
                iconText: root.actionGlyph(String(modelData))
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                iconSize: Style.font.body
                bordered: true
                hasCursor: root.hasCursor("action", String(modelData))
                enabled: root.actionEnabled(String(modelData))
                focusable: enabled
                opacity: enabled ? 1.0 : 0.45
                Accessible.role: Accessible.Button
                Accessible.name: text
                Accessible.description: enabled ? "" : "This action is currently unavailable."
                Accessible.focusable: enabled
                Accessible.onPressAction: if (enabled) root.invokeAction(String(modelData))
                onHovered: function(on) {
                  if (on) root.setCursor("action", String(modelData))
                }
                onClicked: root.invokeAction(String(modelData))
              }
            }
          }

          Column {
            id: settingsSection
            visible: root.settingsSectionVisible
            width: parent.width
            spacing: Style.space(8)

            PanelSeparator { foreground: root.foreground }
            PanelSectionHeader {
              text: root.service && root.service.configured ? "SETTINGS" : "SETUP"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }
            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: "Add up to 20 canonical lowercase myshopify.com domains from Shopify Admin, separated by commas. Credentials stay with the official Shopify CLI."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            TextField {
              id: storesField
              objectName: "orderbellStoresField"
              width: parent.width
              placeholderText: "shop-name.myshopify.com"
              foreground: root.foreground
              Accessible.name: "Shopify store domains"
              Accessible.description: "One to 20 canonical lowercase myshopify.com domains, separated by commas."
              maximumLength: 4096
              selectByMouse: true
              onAccepted: intervalField.forceActiveFocus()
              onActiveFocusChanged: if (activeFocus) root.scrollItemIntoView(storesField)
              Keys.onEscapePressed: root.leaveSettingsFocus()
            }

            RowLayout {
              width: parent.width
              spacing: Style.space(8)

              Text {
                textFormat: Text.PlainText
                text: "Check every"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }

              TextField {
                id: intervalField
                objectName: "orderbellIntervalField"
                Layout.preferredWidth: Style.space(86)
                placeholderText: "60"
                foreground: root.foreground
                Accessible.name: "Check interval in seconds"
                Accessible.description: "A whole number from 60 to 3600."
                maximumLength: 4
                inputMethodHints: Qt.ImhDigitsOnly
                validator: IntValidator { bottom: 60; top: 3600 }
                onAccepted: root.saveSettings()
                onActiveFocusChanged: if (activeFocus) root.scrollItemIntoView(intervalField)
                Keys.onEscapePressed: root.leaveSettingsFocus()
              }

              Text {
                Layout.fillWidth: true
                textFormat: Text.PlainText
                text: "seconds"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
            }

            Toggle {
              id: privacyToggle
              width: parent.width
              label: "Hide order details"
              description: "Recommended: hide order number and amount."
              checked: root.draftPrivacyMode
              foreground: root.foreground
              accent: root.accent
              fontFamily: root.fontFamily
              Accessible.role: Accessible.CheckBox
              Accessible.name: label
              Accessible.description: description
              Accessible.checkable: true
              Accessible.checked: checked
              Accessible.focusable: true
              Accessible.onToggleAction: root.draftPrivacyMode = !root.draftPrivacyMode
              onClicked: root.draftPrivacyMode = !root.draftPrivacyMode
              onActiveFocusChanged: if (activeFocus) root.scrollItemIntoView(privacyToggle)
              Keys.onEscapePressed: root.leaveSettingsFocus()
            }

            Toggle {
              id: notificationsToggle
              width: parent.width
              label: "Desktop notifications"
              description: "Disabling this discards pending notifications."
              checked: root.draftNotify
              foreground: root.foreground
              accent: root.accent
              fontFamily: root.fontFamily
              Accessible.role: Accessible.CheckBox
              Accessible.name: label
              Accessible.description: description
              Accessible.checkable: true
              Accessible.checked: checked
              Accessible.focusable: true
              Accessible.onToggleAction: root.draftNotify = !root.draftNotify
              onClicked: root.draftNotify = !root.draftNotify
              onActiveFocusChanged: if (activeFocus) root.scrollItemIntoView(notificationsToggle)
              Keys.onEscapePressed: root.leaveSettingsFocus()
            }

            Toggle {
              id: testOrdersToggle
              width: parent.width
              label: "Include test orders"
              description: "Include orders that Shopify explicitly marks as test."
              checked: root.draftIncludeTestOrders
              foreground: root.foreground
              accent: root.accent
              fontFamily: root.fontFamily
              Accessible.role: Accessible.CheckBox
              Accessible.name: label
              Accessible.description: description
              Accessible.checkable: true
              Accessible.checked: checked
              Accessible.focusable: true
              Accessible.onToggleAction: root.draftIncludeTestOrders = !root.draftIncludeTestOrders
              onClicked: root.draftIncludeTestOrders = !root.draftIncludeTestOrders
              onActiveFocusChanged: if (activeFocus) root.scrollItemIntoView(testOrdersToggle)
              Keys.onEscapePressed: root.leaveSettingsFocus()
            }

            Button {
              id: testNotificationButton
              objectName: "orderbellTestNotificationButton"
              visible: root.service && root.service.configured && root.selectedStore !== null
              text: "Send test notification"
              iconText: "\uf0f3"
              foreground: root.foreground
              fontFamily: root.fontFamily
              bordered: true
              focusable: visible && enabled
              enabled: visible && !root.service.busy
              opacity: enabled ? 1.0 : 0.45
              Accessible.role: Accessible.Button
              Accessible.name: text
              Accessible.description: root.selectedStore === null ? ""
                : "Send a local test notification for " + root.storeTitle(root.selectedStore) + "."
              Accessible.focusable: enabled
              Accessible.onPressAction: if (enabled) root.invokeAction("test-notification")
              onClicked: root.invokeAction("test-notification")
              onActiveFocusChanged: if (activeFocus) root.scrollItemIntoView(testNotificationButton)
              Keys.onEscapePressed: root.leaveSettingsFocus()
            }

            Text {
              visible: root.settingsError !== ""
              width: parent.width
              textFormat: Text.PlainText
              text: root.settingsError
              color: root.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            Row {
              spacing: Style.space(6)

              Button {
                id: saveButton
                text: "Save"
                iconText: "\uf00c"
                foreground: root.foreground
                fontFamily: root.fontFamily
                bordered: true
                focusable: true
                Accessible.role: Accessible.Button
                Accessible.name: text
                Accessible.description: "Validate and save OrderBell settings."
                Accessible.focusable: true
                Accessible.onPressAction: root.saveSettings()
                onClicked: root.saveSettings()
                onActiveFocusChanged: if (activeFocus) root.scrollItemIntoView(saveButton)
                Keys.onEscapePressed: root.leaveSettingsFocus()
              }

              Button {
                id: cancelButton
                visible: root.service && root.service.configured
                text: "Cancel"
                foreground: root.foreground
                fontFamily: root.fontFamily
                bordered: true
                focusable: true
                Accessible.role: Accessible.Button
                Accessible.name: text
                Accessible.description: "Discard unsaved settings."
                Accessible.focusable: visible
                Accessible.onPressAction: if (visible) clicked()
                onClicked: {
                  root.resetSettingsDraft()
                  root.settingsOpen = false
                  keyCatcher.forceActiveFocus()
                }
                onActiveFocusChanged: if (activeFocus) root.scrollItemIntoView(cancelButton)
                Keys.onEscapePressed: root.leaveSettingsFocus()
              }
            }
          }

          Column {
            visible: root.stores.length > 0
            width: parent.width
            spacing: Style.space(8)

            PanelSeparator { foreground: root.foreground }
            PanelSectionHeader {
              text: root.stores.length === 1 ? "STORE" : "STORES"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Column {
              id: storeColumn
              width: parent.width
              spacing: Style.space(6)

              Repeater {
                id: storeRepeater
                model: root.stores
                StoreCard {
                  required property var modelData
                  required property int index
                  width: storeColumn.width
                  storeState: modelData
                  rowIndex: index
                }
              }
            }
          }

          Column {
            visible: root.service && root.service.configured
            width: parent.width
            spacing: Style.space(8)

            PanelSeparator { foreground: root.foreground }
            PanelSectionHeader {
              text: "RECENT ORDERS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Text {
              visible: root.orders.length === 0
              width: parent.width
              textFormat: Text.PlainText
              text: root.emptyOrdersMessage()
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              horizontalAlignment: Text.AlignHCenter
            }

            Column {
              id: orderColumn
              width: parent.width
              spacing: Style.space(5)

              Repeater {
                id: orderRepeater
                model: root.orders
                OrderRow {
                  required property var modelData
                  required property int index
                  width: orderColumn.width
                  order: modelData
                  rowIndex: index
                }
              }
            }
          }

          Column {
            width: parent.width
            spacing: Style.space(4)

            PanelSeparator { foreground: root.foreground }
            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: "UNOFFICIAL SHOPIFY COMPANION"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 0.8
              horizontalAlignment: Text.AlignHCenter
              wrapMode: Text.WordWrap
            }
            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: "Not affiliated with or endorsed by Shopify."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              horizontalAlignment: Text.AlignHCenter
              wrapMode: Text.WordWrap
            }
          }
        }
      }
    }
  }

  component StoreCard: CursorSurface {
    id: storeCard
    property var storeState: null
    property int rowIndex: 0
    readonly property bool selected: root.selectedStoreIndex === rowIndex
    readonly property bool hasProblem: storeState && storeState.error !== null

    readonly property string storeKey: String(storeState && storeState.store || "")

    hasCursor: root.hasCursor("store", storeKey)
    current: selected
    bordered: true
    foreground: root.foreground
    implicitHeight: storeLayout.implicitHeight + Style.spacing.rowPaddingX
    Accessible.role: Accessible.Button
    Accessible.name: root.storeTitle(storeState) + ", " + Model.stateMeta(storeState, root.nowMs)
    Accessible.description: storeKey
    Accessible.focusable: true
    Accessible.selected: selected
    Accessible.onPressAction: root.selectStore(storeKey)

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: root.setCursor("store", storeCard.storeKey)
      onClicked: root.selectStore(storeCard.storeKey)
    }

    RowLayout {
      id: storeLayout
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(9)

      Rectangle {
        Layout.alignment: Qt.AlignVCenter
        Layout.preferredWidth: Style.space(8)
        Layout.preferredHeight: Style.space(8)
        radius: width / 2
        color: storeCard.hasProblem ? root.urgent
          : (storeCard.storeState && storeCard.storeState.unreadCount > 0 ? root.accent : root.dim)
      }

      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          objectName: "orderbellStoreTitle"
          Layout.fillWidth: true
          textFormat: Text.PlainText
          text: root.storeTitle(storeCard.storeState)
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: storeCard.selected
          elide: Text.ElideRight
        }

        Text {
          objectName: "orderbellStoreDomain"
          Layout.fillWidth: true
          textFormat: Text.PlainText
          text: storeCard.storeState ? String(storeCard.storeState.store || "") : ""
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WrapAnywhere
          maximumLineCount: 2
          elide: Text.ElideRight
        }

        Text {
          Layout.fillWidth: true
          textFormat: Text.PlainText
          text: Model.stateMeta(storeCard.storeState, root.nowMs)
          color: storeCard.hasProblem ? root.urgent : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      Text {
        visible: storeCard.storeState && storeCard.storeState.unreadCount > 0
        textFormat: Text.PlainText
        text: Model.countLabel(storeCard.storeState ? storeCard.storeState.unreadCount : 0, 9999)
        color: root.accent
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.bold: true
        Layout.alignment: Qt.AlignVCenter
      }
    }
  }

  component OrderRow: CursorSurface {
    id: orderRow
    property var order: null
    property int rowIndex: 0
    readonly property bool canOpen: order && String(order.url || "") !== ""
    readonly property string orderKey: String(order && order.store || "") + "|"
      + String(order && order.idHash || "")

    hasCursor: root.hasCursor("order", orderKey)
    foreground: root.foreground
    implicitHeight: orderLayout.implicitHeight + Style.spacing.rowPaddingX
    Accessible.role: Accessible.Link
    Accessible.name: Model.titleForOrder(order, root.service ? root.service.privacyMode : true)
      + ", " + Model.storeDisplayName(order ? order.displayName : null, order ? order.store : "")
      + ", " + Model.orderMeta(order, root.service ? root.service.privacyMode : true, root.nowMs)
    Accessible.description: canOpen ? "Open this order in Shopify Admin." : ""
    Accessible.focusable: canOpen
    Accessible.onPressAction: if (canOpen) root.openOrder(order)

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      enabled: orderRow.canOpen
      cursorShape: orderRow.canOpen ? Qt.PointingHandCursor : Qt.ArrowCursor
      onEntered: root.setCursor("order", orderRow.orderKey)
      onClicked: root.openOrder(orderRow.order)
    }

    RowLayout {
      id: orderLayout
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(9)
      anchors.rightMargin: Style.space(9)
      spacing: Style.space(9)

      Text {
        textFormat: Text.PlainText
        text: "\uf290"
        color: orderRow.order && orderRow.order.unread ? root.accent : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
        Layout.alignment: Qt.AlignVCenter
      }

      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(1)

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(6)

          Text {
            Layout.fillWidth: true
            textFormat: Text.PlainText
            text: Model.titleForOrder(orderRow.order, root.service ? root.service.privacyMode : true)
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            font.bold: orderRow.order && orderRow.order.unread
            elide: Text.ElideRight
          }

          Text {
            objectName: "orderbellOrderStoreTitle"
            Layout.maximumWidth: Math.max(Style.space(80), orderLayout.width * 0.34)
            textFormat: Text.PlainText
            text: Model.storeDisplayName(orderRow.order ? orderRow.order.displayName : null,
              orderRow.order ? orderRow.order.store : "")
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            Layout.alignment: Qt.AlignVCenter
            elide: Text.ElideRight
          }
        }

        Text {
          Layout.fillWidth: true
          textFormat: Text.PlainText
          text: Model.orderMeta(orderRow.order,
            root.service ? root.service.privacyMode : true, root.nowMs)
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      Text {
        visible: orderRow.canOpen
        textFormat: Text.PlainText
        text: "\uf054"
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        Layout.alignment: Qt.AlignVCenter
      }
    }
  }
}

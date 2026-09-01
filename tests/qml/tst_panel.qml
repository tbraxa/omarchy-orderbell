import QtQuick
import QtTest
import "../.." as OrderBell

TestCase {
  name: "OrderBellPanel"
  // Focus is a visual-window behavior. Qt Quick Test otherwise starts this
  // case before its host window is shown, which makes activeFocus dependent
  // on the Qt minor version rather than on OrderBell's focus request.
  when: windowShown
  property var panel: null

  QtObject {
    id: shellMock
    function updateEntryInline(moduleName, entry) { return true }
  }

  QtObject {
    id: barMock
    property string fontFamily: "sans-serif"
    property QtObject shell: shellMock
    function switchPanelFrom(owner, direction) { return true }
  }

  QtObject {
    id: serviceMock
    property bool configured: false
    property var configuredStores: []
    property var storeStates: []
    property var recentOrders: []
    property bool refreshing: false
    property bool authRequired: false
    property int errorCount: 0
    property bool catchingUp: false
    property int pendingCount: 0
    property int unreadCount: 0
    property string actionStatus: ""
    property bool actionStatusError: false
    property string lastError: ""
    property var invalidStores: []
    property double lastUpdatedMs: 0
    property bool busy: false
    property bool privacyMode: true

    function refreshIfStale() {}
    function refresh(force) {}
    function authenticate(store) {}
    function markRead(store) {}
    function testNotification(store) {}

    function reset() {
      configured = false
      configuredStores = []
      storeStates = []
      recentOrders = []
      refreshing = false
      authRequired = false
      errorCount = 0
      catchingUp = false
      pendingCount = 0
      unreadCount = 0
      actionStatus = ""
      actionStatusError = false
      lastError = ""
      invalidStores = []
      lastUpdatedMs = 0
      busy = false
      privacyMode = true
    }
  }

  Component {
    id: panelComponent
    OrderBell.Panel {}
  }

  function init() {
    serviceMock.reset()
    panel = panelComponent.createObject(this, {
      service: serviceMock,
      bar: barMock,
      settings: ({})
    })
    verify(panel !== null)
    wait(1)
  }

  function cleanup() {
    panel.destroy()
    panel = null
    wait(1)
  }

  function test_setup_shows_form_without_inert_toolbar_actions() {
    verify(panel.setupRequired)
    verify(panel.settingsSectionVisible)
    compare(panel.actionKeys, [])
    verify(!panel.actionEnabled("settings"))
    verify(!panel.actionEnabled("refresh"))

    panel.saveSettings()
    compare(panel.settingsError, "Add at least one canonical myshopify.com store domain.")

    // The hidden settings shortcut cannot toggle a second, indistinguishable
    // setup state. The visible setup form and Save button are the only path.
    panel.invokeAction("settings")
    verify(!panel.settingsOpen)
    verify(panel.settingsSectionVisible)

    panel.open()
    tryVerify(function() { return panel.settingsControlFocused }, 250)
    var storesField = findChild(panel, "orderbellStoresField")
    verify(storesField !== null)
    verify(storesField.activeFocus)
  }

  function test_configured_settings_action_toggles_the_form() {
    var store = "northwind.myshopify.com"
    serviceMock.configuredStores = [store]
    serviceMock.storeStates = [{
      store: store,
      displayName: "Northwind",
      status: "baseline",
      unreadCount: 0,
      pendingCount: 0,
      recentOrders: [],
      error: null,
      polling: false,
      lastSuccessfulPollAt: "2026-09-01T18:30:01Z"
    }]
    serviceMock.configured = true
    wait(1)

    verify(!panel.setupRequired)
    compare(panel.selectedStoreName, store)
    compare(panel.storeTitle(panel.selectedStore), "Northwind")
    var title = findChild(panel, "orderbellStoreTitle")
    var domain = findChild(panel, "orderbellStoreDomain")
    verify(title !== null)
    verify(domain !== null)
    compare(title.text, "Northwind")
    compare(domain.text, store)
    verify(!panel.settingsSectionVisible)
    compare(panel.actionKeys, ["settings", "refresh", "admin"])
    verify(panel.actionEnabled("settings"))

    panel.invokeAction("settings")
    verify(panel.settingsOpen)
    verify(panel.settingsSectionVisible)
    compare(panel.actionLabel("settings"), "Close settings")
    var testNotificationButton = findChild(panel, "orderbellTestNotificationButton")
    verify(testNotificationButton !== null)

    panel.invokeAction("settings")
    verify(!panel.settingsOpen)
    verify(!panel.settingsSectionVisible)
    compare(panel.actionLabel("settings"), "Settings")
  }

  function test_contextual_actions_show_only_when_needed() {
    var store = "northwind.myshopify.com"
    serviceMock.configuredStores = [store]
    serviceMock.storeStates = [{
      store: store,
      displayName: "Northwind",
      status: "error",
      unreadCount: 2,
      pendingCount: 0,
      recentOrders: [],
      error: { code: "authentication_required", message: "Sign in required", retryable: false },
      polling: false,
      lastSuccessfulPollAt: null
    }]
    serviceMock.authRequired = true
    serviceMock.errorCount = 1
    serviceMock.unreadCount = 2
    serviceMock.configured = true
    wait(1)

    compare(panel.actionKeys,
      ["settings", "refresh", "admin", "authenticate", "mark-read"])
    compare(panel.actionLabel("authenticate"), "Sign in")
  }

  function test_recent_order_uses_display_name_while_store_card_keeps_domain() {
    var store = "northwind.myshopify.com"
    var displayName = "<Northwind & Co>"
    var order = {
      store: store,
      displayName: displayName,
      idHash: "a".repeat(64),
      name: "#1",
      timestampMs: Date.now(),
      amount: "1.00",
      currency: "CZK",
      financialStatus: "PAID",
      fulfillmentStatus: null,
      test: false,
      url: "https://" + store + "/admin/orders/1",
      unread: true
    }
    serviceMock.configuredStores = [store]
    serviceMock.storeStates = [{
      store: store,
      displayName: displayName,
      status: "ok",
      unreadCount: 1,
      pendingCount: 0,
      recentOrders: [order],
      error: null,
      polling: false,
      lastSuccessfulPollAt: "2026-09-01T18:30:01Z"
    }]
    serviceMock.recentOrders = [order]
    serviceMock.unreadCount = 1
    serviceMock.configured = true
    wait(1)

    var title = findChild(panel, "orderbellStoreTitle")
    var domain = findChild(panel, "orderbellStoreDomain")
    var orderTitle = findChild(panel, "orderbellOrderStoreTitle")
    verify(title !== null)
    verify(domain !== null)
    verify(orderTitle !== null)
    compare(title.text, displayName)
    compare(title.textFormat, Text.PlainText)
    compare(domain.text, store)
    compare(orderTitle.text, displayName)
    compare(orderTitle.textFormat, Text.PlainText)
  }
}

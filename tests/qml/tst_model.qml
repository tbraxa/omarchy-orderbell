import QtQuick
import QtTest
import "../../Model.js" as Model

TestCase {
  name: "OrderBellModel"

  function hash(character) {
    var value = ""
    for (var i = 0; i < 64; i++) value += character
    return value
  }

  function response(overrides) {
    var value = {
      schemaVersion: 1,
      stateAuthoritative: true,
      status: "ok",
      store: "north-star.myshopify.com",
      displayName: "North Star",
      recentOrders: [{
        idHash: hash("a"),
        name: "#1042",
        createdAt: "2026-09-01T18:30:00Z",
        amount: "129.90",
        currency: "CZK",
        financialStatus: "PAID",
        fulfillmentStatus: "UNFULFILLED",
        test: false,
        url: "https://north-star.myshopify.com/admin/orders/987654321",
        unread: true
      }],
      unreadCount: 1,
      pendingCount: 0,
      error: null,
      nextPollSeconds: 60,
      lastSuccessfulPollAt: "2026-09-01T18:30:01Z"
    }
    var changes = overrides || {}
    for (var key in changes) value[key] = changes[key]
    return JSON.stringify(value)
  }

  function test_store_boundary() {
    compare(Model.normalizeStore("north-star.myshopify.com"), "north-star.myshopify.com")
    compare(Model.normalizeStore("North-Star.MyShopify.com"), "")
    compare(Model.normalizeStore("https://north-star.myshopify.com"), "")
    compare(Model.normalizeStore("north-star.myshopify.com/admin"), "")
  }

  function test_response_boundary() {
    var parsed = Model.parseWorkerResponse(response(), "north-star.myshopify.com")
    verify(parsed.ok)
    compare(parsed.value.displayName, "North Star")
    compare(parsed.value.recentOrders.length, 1)
    compare(parsed.value.recentOrders[0].url,
      "https://north-star.myshopify.com/admin/orders/987654321")

    var wrong = Model.parseWorkerResponse(response({ store: "other.myshopify.com" }),
      "north-star.myshopify.com")
    verify(!wrong.ok)

    var unknown = Model.parseWorkerResponse(response({ displayName: null }),
      "north-star.myshopify.com")
    verify(unknown.ok)
    compare(Model.storeDisplayName(unknown.value.displayName, unknown.value.store), "north-star")

    var unsafe = Model.parseWorkerResponse(response({ displayName: "Northwind\u202E" }),
      "north-star.myshopify.com")
    verify(!unsafe.ok)
    var emoji = ""
    for (var i = 0; i < 64; i++) emoji += "😀"
    verify(Model.parseWorkerResponse(response({ displayName: emoji }),
      "north-star.myshopify.com").ok)

    var missingAuthority = JSON.parse(response())
    delete missingAuthority.stateAuthoritative
    verify(!Model.parseWorkerResponse(JSON.stringify(missingAuthority),
      "north-star.myshopify.com").ok)
    verify(!Model.parseWorkerResponse(response({ stateAuthoritative: 1 }),
      "north-star.myshopify.com").ok)
  }

  function test_argv_never_uses_a_shell() {
    var command = Model.pollCommand("/plugin/bin/orderbell-worker",
      "north-star.myshopify.com", {
        notify: true,
        privacyMode: true,
        includeTestOrders: false,
        refreshIntervalSec: 60
      })
    compare(command[0], "/plugin/bin/orderbell-worker")
    compare(command[1], "poll")
    verify(command.indexOf("sh") === -1)
    verify(command.indexOf("bash") === -1)
    verify(command.indexOf("-c") === -1)
  }

  function test_privacy_copy() {
    var parsed = Model.parseWorkerResponse(response(), "north-star.myshopify.com")
    var order = parsed.value.recentOrders[0]
    compare(Model.titleForOrder(order, true), "New order")
    verify(Model.orderMeta(order, true, Date.parse("2026-09-01T18:31:00Z")).indexOf("129") === -1)
  }
}

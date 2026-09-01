import test from "node:test"
import assert from "node:assert/strict"
import Model from "../Model.js"

const HASH_A = "a".repeat(64)
const HASH_B = "b".repeat(64)
const HASH_C = "c".repeat(64)

function publicOrder(overrides = {}) {
  return {
    idHash: HASH_A,
    name: "#1042",
    createdAt: "2026-09-01T18:30:00Z",
    amount: "129.90",
    currency: "CZK",
    financialStatus: "PAID",
    fulfillmentStatus: "UNFULFILLED",
    test: false,
    url: "https://north-star.myshopify.com/admin/orders/987654321",
    unread: true,
    ...overrides
  }
}

function response(overrides = {}) {
  return JSON.stringify({
    schemaVersion: 1,
    stateAuthoritative: true,
    status: "ok",
    store: "north-star.myshopify.com",
    displayName: "North Star",
    recentOrders: [publicOrder()],
    unreadCount: 1,
    pendingCount: 0,
    error: null,
    nextPollSeconds: 60,
    lastSuccessfulPollAt: "2026-09-01T18:30:01Z",
    ...overrides
  })
}

const retryableError = {
  code: "notification_failed",
  message: "The notification could not be delivered.",
  retryable: true
}

test("store settings accept only canonical lowercase Shopify hosts", () => {
  assert.deepEqual(
    Model.parseStoreList(" north-star.myshopify.com,other.myshopify.com,north-star.myshopify.com "),
    {
      stores: ["north-star.myshopify.com", "other.myshopify.com"],
      invalid: [],
      tooMany: false,
      truncated: false
    }
  )

  for (const invalid of [
    "North-Star.MyShopify.com",
    " north-star.myshopify.com",
    "https://north-star.myshopify.com",
    "north-star.myshopify.com/admin",
    "user@north-star.myshopify.com",
    "north-star.myshopify.com:443",
    "north-star.myshopify.com.",
    "127.0.0.1",
    "evil.com"
  ]) assert.equal(Model.normalizeStore(invalid), "", invalid)

  const uppercase = Model.parseStoreList("North-Star.MyShopify.com")
  assert.deepEqual(uppercase.stores, [])
  assert.deepEqual(uppercase.invalid, ["North-Star.MyShopify.com"])
})

test("store setting work is bounded and too many valid stores fail closed", () => {
  const stores = Array.from({ length: Model.maximumStores + 1 }, (_, index) =>
    `store${index}.myshopify.com`).join(",")
  const tooMany = Model.parseStoreList(stores)
  assert.deepEqual(tooMany.stores, [])
  assert.equal(tooMany.tooMany, true)
  assert.equal(tooMany.truncated, false)

  const candidates = Array.from({ length: Model.maximumStoreCandidates + 1 }, () =>
    "a.myshopify.com").join(",")
  const candidateOverflow = Model.parseStoreList(candidates)
  assert.deepEqual(candidateOverflow.stores, [])
  assert.equal(candidateOverflow.tooMany, false)
  assert.equal(candidateOverflow.truncated, true)

  const oversized = Model.parseStoreList("x".repeat(Model.maximumStoreSettingBytes + 1))
  assert.deepEqual(oversized.stores, [])
  assert.equal(oversized.truncated, true)

  const invalid = Model.parseStoreList("bad0,bad1,bad2,bad3,bad4,bad5,bad6")
  assert.equal(invalid.invalid.length, Model.maximumInvalidStoreSamples)
  assert.equal(invalid.truncated, true)
})

test("one-character Shopify handles remain valid canonical hosts", () => {
  assert.equal(Model.normalizeStore("a.myshopify.com"), "a.myshopify.com")
})

test("store display names are strict normalized plain text with a safe domain fallback", () => {
  for (const accepted of ["Northwind", "Živé umění", "<Northwind & Co>", "🛍️".repeat(32)]) {
    const parsed = Model.parseWorkerResponse(response({ displayName: accepted }),
      "north-star.myshopify.com")
    assert.equal(parsed.ok, true, accepted)
    assert.equal(parsed.value.displayName, accepted)
  }

  const unknown = Model.parseWorkerResponse(response({ displayName: null }),
    "north-star.myshopify.com")
  assert.equal(unknown.ok, true)
  assert.equal(unknown.value.displayName, null)
  assert.equal(Model.storeDisplayName(null, "north-star.myshopify.com"), "north-star")
  assert.equal(Model.storeDisplayName("Northwind", "north-star.myshopify.com"), "Northwind")

  for (const invalid of [
    "", 7, " Northwind", "Northwind ", "Northwind  Shop", "Northwind\nShop",
    "Northwind\u202E", "Northwind\uE000", "Ｎｏｒｔｈｗｉｎｄ", "x".repeat(65), "😀".repeat(65)
  ]) {
    const parsed = Model.parseWorkerResponse(response({ displayName: invalid }),
      "north-star.myshopify.com")
    assert.equal(parsed.ok, false, String(invalid))
    assert.match(parsed.error, /display name/)
  }
  assert.equal(Model.unicodeCodePointLength("😀".repeat(64)), 64)
  assert.equal(Model.initialStoreState("north-star.myshopify.com", 0).displayName, null)

  const unknownResult = unknown.value
  const invalidPrior = { ...Model.initialStoreState("north-star.myshopify.com", 0),
    displayName: "" }
  assert.equal(Model.mergeStoreResult(invalidPrior, unknownResult, 1, 60).displayName, null)
  assert.equal(Model.processFailure(invalidPrior, "north-star.myshopify.com",
    "offline", 1, 60).displayName, null)
})

test("worker response is parsed, sanitized, and sorted", () => {
  const parsed = Model.parseWorkerResponse(response({
    recentOrders: [
      publicOrder({
        idHash: HASH_B,
        name: "<img src='https://tracker.test'> #1041\u202E",
        createdAt: "2026-09-01T17:30:00.123456Z",
        amount: "10.00",
        currency: "EUR",
        financialStatus: "PARTIALLY_PAID",
        fulfillmentStatus: null,
        test: true,
        url: "https://north-star.myshopify.com/admin/orders/123",
        unread: false
      }),
      publicOrder({ idHash: HASH_C })
    ]
  }), "north-star.myshopify.com")

  assert.equal(parsed.ok, true)
  assert.equal(parsed.value.displayName, "North Star")
  assert.equal(parsed.value.recentOrders[0].idHash, HASH_C)
  assert.equal(parsed.value.recentOrders[0].currency, "CZK")
  assert.equal(parsed.value.recentOrders[0].url,
    "https://north-star.myshopify.com/admin/orders/987654321")
  assert.equal(parsed.value.recentOrders[1].name, "#1041")
  assert.equal(parsed.value.recentOrders[1].fulfillmentStatus, null)
  assert.equal(parsed.value.recentOrders[1].url,
    "https://north-star.myshopify.com/admin/orders/123")
})

test("worker parser rejects wrong schemas, stores, statuses, shapes, and malformed JSON", () => {
  assert.equal(Model.parseWorkerResponse("not json", "north-star.myshopify.com").ok, false)
  assert.match(Model.parseWorkerResponse(response({ schemaVersion: 2 }),
    "north-star.myshopify.com").error, /schema/)
  assert.match(Model.parseWorkerResponse(response({ store: "other.myshopify.com" }),
    "north-star.myshopify.com").error, /different store/)
  assert.match(Model.parseWorkerResponse(response({ store: "North-Star.myshopify.com" }),
    "north-star.myshopify.com").error, /different store/)
  assert.match(Model.parseWorkerResponse(response({ status: "pwned" }),
    "north-star.myshopify.com").error, /unknown status/)

  const extra = JSON.parse(response())
  extra.unexpected = true
  assert.match(Model.parseWorkerResponse(JSON.stringify(extra),
    "north-star.myshopify.com").error, /shape/)
  delete extra.unexpected
  delete extra.pendingCount
  assert.match(Model.parseWorkerResponse(JSON.stringify(extra),
    "north-star.myshopify.com").error, /shape/)

  assert.match(Model.parseWorkerResponse(response({ stateAuthoritative: "true" }),
    "north-star.myshopify.com").error, /authority/)
  assert.match(Model.parseWorkerResponse(response({
    status: "busy", stateAuthoritative: true, error: retryableError
  }), "north-star.myshopify.com").error, /authority/)
  assert.match(Model.parseWorkerResponse(response({
    status: "ok", stateAuthoritative: false
  }), "north-star.myshopify.com").error, /authority/)

  const missingDisplayName = JSON.parse(response())
  delete missingDisplayName.displayName
  assert.match(Model.parseWorkerResponse(JSON.stringify(missingDisplayName),
    "north-star.myshopify.com").error, /shape/)
})

test("status and error objects have exact, consistent protocol types", () => {
  assert.equal(Model.parseWorkerResponse(response({ status: "ok", error: retryableError }),
    "north-star.myshopify.com").ok, false)
  assert.equal(Model.parseWorkerResponse(response({ status: "error", error: null }),
    "north-star.myshopify.com").ok, false)
  assert.equal(Model.parseWorkerResponse(response({ status: "degraded", error: retryableError }),
    "north-star.myshopify.com").ok, true)
  assert.equal(Model.parseWorkerResponse(response({ status: "catching_up", error: null }),
    "north-star.myshopify.com").ok, true)

  for (const error of [
    { ...retryableError, retryable: 1 },
    { ...retryableError, code: "NOTIFICATION_FAILED" },
    { ...retryableError, extra: "diagnostic" },
    { code: retryableError.code, message: "" }
  ]) {
    assert.equal(Model.parseWorkerResponse(response({ status: "error", error }),
      "north-star.myshopify.com").ok, false)
  }
})

test("worker parser requires canonical order scalar types and values", () => {
  const invalidValues = [
    ["idHash", "A".repeat(64)],
    ["idHash", "a".repeat(63)],
    ["name", 1042],
    ["createdAt", "2026-09-01T20:30:00+02:00"],
    ["amount", "-1.00"],
    ["amount", "01.00"],
    ["currency", "czk"],
    ["financialStatus", "paid"],
    ["fulfillmentStatus", 7],
    ["test", 0],
    ["unread", "true"],
    ["url", "https://north-star.myshopify.com/admin/orders/987654321?source=worker"],
    ["url", "https://admin.shopify.com/store/north-star/orders/987654321"]
  ]
  for (const [field, value] of invalidValues) {
    const parsed = Model.parseWorkerResponse(response({
      recentOrders: [publicOrder({ [field]: value })]
    }), "north-star.myshopify.com")
    assert.equal(parsed.ok, false, `${field}: ${String(value)}`)
    assert.match(parsed.error, /malformed order/)
  }

  const extraOrderField = publicOrder({ customerEmail: "private@example.com" })
  assert.equal(Model.parseWorkerResponse(response({ recentOrders: [extraOrderField] }),
    "north-star.myshopify.com").ok, false)
})

test("UTC timestamps are strict, canonical, calendar-valid, and timezone independent", () => {
  assert.equal(Model.safeTimestamp("2026-09-01T18:30:00Z"), "2026-09-01T18:30:00Z")
  assert.equal(Model.safeTimestamp("2024-02-29T23:59:59.123456Z"),
    "2024-02-29T23:59:59.123456Z")
  for (const invalid of [
    "2023-02-29T12:00:00Z",
    "2026-02-30T12:00:00Z",
    "2026-09-01T24:00:00Z",
    "2026-09-01T18:30:00.1Z",
    "2026-09-01T18:30:00+00:00",
    "2026-09-01 18:30:00Z",
    "1999-12-31T23:59:59Z"
  ]) assert.equal(Model.safeTimestamp(invalid), "", invalid)
})

test("worker parser enforces bounded integer counters, timing, and recent rows", () => {
  for (const overrides of [
    { unreadCount: "1" },
    { pendingCount: false },
    { pendingCount: 65 },
    { nextPollSeconds: 60.5 },
    { nextPollSeconds: 0 },
    { nextPollSeconds: 59 },
    { nextPollSeconds: 3601 },
    { unreadCount: 2147483648 },
    { unreadCount: 0 }
  ]) assert.equal(Model.parseWorkerResponse(response(overrides),
    "north-star.myshopify.com").ok, false)

  const maximum = Model.parseWorkerResponse(response({ unreadCount: 2147483647 }),
    "north-star.myshopify.com")
  assert.equal(maximum.ok, true)
  assert.equal(maximum.value.unreadCount, 2147483647)

  const orders = Array.from({ length: Model.maximumOrders }, (_, index) => publicOrder({
    idHash: (index + 1).toString(16).padStart(64, "0"),
    url: `https://north-star.myshopify.com/admin/orders/${index + 1}`,
    unread: false
  }))
  assert.equal(Model.parseWorkerResponse(response({ recentOrders: orders }),
    "north-star.myshopify.com").ok, true)
  assert.equal(Model.parseWorkerResponse(response({ recentOrders: [
    ...orders,
    publicOrder({ idHash: "f".repeat(64), url: "https://north-star.myshopify.com/admin/orders/999" })
  ] }), "north-star.myshopify.com").ok, false)

  const withoutSuccess = Model.parseWorkerResponse(response({ lastSuccessfulPollAt: null }),
    "north-star.myshopify.com")
  assert.equal(withoutSuccess.ok, true)
  assert.equal(withoutSuccess.value.lastSuccessfulPollAt, "")
  assert.equal(Model.parseWorkerResponse(response({
    lastSuccessfulPollAt: "2026-02-30T12:00:00Z"
  }), "north-star.myshopify.com").ok, false)
})

test("worker parser rejects duplicate IDs rather than double-counting", () => {
  const order = publicOrder()
  const parsed = Model.parseWorkerResponse(response({ recentOrders: [order, { ...order }] }),
    "north-star.myshopify.com")
  assert.equal(parsed.ok, false)
  assert.match(parsed.error, /duplicate/)
})

test("remote order URLs require the exact worker form before canonical reconstruction", () => {
  assert.equal(Model.adminOrdersUrl("north-star.myshopify.com"),
    "https://north-star.myshopify.com/admin/orders")
  assert.equal(Model.canonicalOrderUrl("north-star.myshopify.com",
    "https://north-star.myshopify.com/admin/orders/42"),
  "https://north-star.myshopify.com/admin/orders/42")
  for (const invalid of [
    "https://evil.myshopify.com/admin/orders/123",
    "https://north-starXmyshopifyXcom/admin/orders/42",
    "https://north-star.myshopify.com.evil.example/admin/orders/42",
    "https://north-star.myshopify.com@evil.example/admin/orders/42",
    "http://north-star.myshopify.com/admin/orders/42",
    "https://north-star.myshopify.com:443/admin/orders/42",
    "javascript:alert(1)",
    "https://admin.shopify.com/store/north-star/orders/42",
    "https://north-star.myshopify.com/admin/orders/42#anything",
    "https://north-star.myshopify.com/admin/orders/42?anything",
    "https://north-star.myshopify.com/admin/orders/42/",
    "https://north-star.myshopify.com/admin/orders/+42",
    "https://north-star.myshopify.com/admin/orders/%32",
    "https://north-star.myshopify.com/admin/orders/４２",
    "https://north-star.myshopify.com/admin/orders/042",
    "https://north-star.myshopify.com/admin/orders/42\nhttps://evil.example",
    "https://north-star.myshopify.com/admin/orders/42\u0000",
    `https://north-star.myshopify.com/admin/orders/${"1".repeat(31)}`
  ]) assert.equal(Model.canonicalOrderUrl("north-star.myshopify.com", invalid), "", invalid)
  for (const invalidStore of [
    "north-star\\.myshopify.com",
    "north.*.myshopify.com",
    "north|south.myshopify.com"
  ]) assert.equal(Model.canonicalOrderUrl(invalidStore,
    "https://north-star.myshopify.com/admin/orders/42"), "", invalidStore)
})

test("oversized output is rejected before JSON parsing", () => {
  const raw = "x".repeat(Model.workerResponseByteLimit + 1)
  const parsed = Model.parseWorkerResponse(raw, "north-star.myshopify.com")
  assert.equal(parsed.ok, false)
  assert.match(parsed.error, /size limit/)
  assert.equal(Model.exceedsUtf8ByteLimit("ž", 1), true)
})

test("poll command is an argv vector with the least-privilege options", () => {
  assert.deepEqual(Model.pollCommand("/opt/orderbell-worker", "north-star.myshopify.com", {
    notify: true,
    privacyMode: true,
    includeTestOrders: false,
    refreshIntervalSec: 1
  }), [
    "/opt/orderbell-worker", "poll", "--store", "north-star.myshopify.com",
    "--notify", "--privacy", "--timeout", "20", "--interval", "60"
  ])

  assert.deepEqual(Model.pollCommand("/opt/orderbell-worker", "north-star.myshopify.com", {
    notify: false,
    privacyMode: false,
    includeTestOrders: true,
    refreshIntervalSec: 99999
  }).slice(-5), ["--include-test-orders", "--timeout", "20", "--interval", "3600"])
  assert.deepEqual(Model.pollCommand("/opt/orderbell-worker", "bad; touch /tmp/pwn", {}), [])
  assert.deepEqual(Model.pollCommand("/opt/orderbell-worker", "North-Star.myshopify.com", {}), [])
})

test("all worker actions remain discrete argv and reject unknown actions", () => {
  assert.deepEqual(Model.workerActionCommand("/worker", "authenticate",
    "north-star.myshopify.com", true),
  ["/worker", "authenticate", "--store", "north-star.myshopify.com", "--timeout", "300"])
  assert.deepEqual(Model.workerActionCommand("/worker", "test-notification",
    "north-star.myshopify.com", false),
  ["/worker", "test-notification", "--store", "north-star.myshopify.com", "--show-details"])
  assert.deepEqual(Model.workerActionCommand("/worker", "rm", "north-star.myshopify.com", true), [])
})

test("bar status reports pending delivery instead of all caught up", () => {
  const pending = {
    configured: true,
    errorCount: 0,
    refreshing: false,
    catchingUp: false,
    pendingCount: 2,
    unreadCount: 0
  }
  assert.equal(Model.barNeedsAttention(pending), true)
  assert.equal(Model.barTooltip(pending), "OrderBell · 2 notifications queued")
  assert.equal(Model.barNeedsAttention({ ...pending, pendingCount: 0 }), false)
  assert.equal(Model.barTooltip({ ...pending, pendingCount: 0 }), "OrderBell · all caught up")
})

test("relative time reads naturally inside status sentences", () => {
  assert.equal(Model.relativeTime(1000000, 1030000), "just now")
  assert.equal(Model.relativeTime(Date.parse("2026-08-01T12:00:00Z"),
    Date.parse("2026-09-01T12:00:00Z")), "2026-08-01")
})

test("privacy formatting never exposes the order number or amount", () => {
  const order = {
    name: "#1042",
    amount: "129.90",
    currency: "CZK",
    financialStatus: "PAID",
    fulfillmentStatus: "UNFULFILLED",
    timestampMs: Date.parse("2026-09-01T18:30:00Z"),
    test: false
  }
  assert.equal(Model.titleForOrder(order, true), "New order")
  assert.equal(Model.formatMoney(order.amount, order.currency, true), "Amount hidden")
  assert.doesNotMatch(Model.orderMeta(order, true, Date.parse("2026-09-01T18:31:00Z")), /129|1042/)
  assert.match(Model.orderMeta(order, true, Date.parse("2026-09-01T18:31:00Z")), /Paid · Unfulfilled/)
  assert.equal(Model.titleForOrder(order, false), "#1042")
  assert.match(Model.orderMeta(order, false, Date.parse("2026-09-01T18:31:00Z")), /129\.90 CZK/)
})

test("store state merge honors valid worker backoff and caps local configuration", () => {
  const parsed = Model.parseWorkerResponse(response({ nextPollSeconds: 3600 }),
    "north-star.myshopify.com").value
  const merged = Model.mergeStoreResult(null, parsed, 1000, 99999)
  assert.equal(merged.displayName, "North Star")
  assert.equal(merged.nextPollSeconds, 3600)
  assert.equal(merged.nextPollAtMs, 3600000 + 1000)

  const failed = Model.processFailure(merged, merged.store, "network down", 2000, 60)
  assert.equal(failed.nextPollSeconds, 3600)
  assert.equal(failed.error.retryable, true)
  assert.equal(failed.displayName, "North Star")
})

test("worker progress and lock retry hints can be sooner than the configured cadence", () => {
  for (const [status, nextPollSeconds, error] of [
    ["catching_up", 60, null],
    ["busy", 60, retryableError]
  ]) {
    const parsed = Model.parseWorkerResponse(response({
      status,
      stateAuthoritative: status === "busy" ? false : true,
      error,
      nextPollSeconds
    }), "north-star.myshopify.com").value
    const merged = Model.mergeStoreResult(null, parsed, 1000, 3600)
    assert.equal(merged.nextPollSeconds, nextPollSeconds)
    assert.equal(merged.nextPollAtMs, 1000 + nextPollSeconds * 1000)
  }
})

test("only non-authoritative failures preserve known-good data", () => {
  const priorResult = Model.parseWorkerResponse(response({
    unreadCount: 7,
    pendingCount: 4
  }), "north-star.myshopify.com").value
  const prior = Model.mergeStoreResult(null, priorResult, 1000, 60)

  for (const status of ["error", "busy"]) {
    const result = Model.parseWorkerResponse(response({
      status,
      stateAuthoritative: false,
      recentOrders: [],
      unreadCount: 0,
      pendingCount: 0,
      displayName: "Untrusted replacement",
      error: retryableError,
      lastSuccessfulPollAt: null,
      nextPollSeconds: 60
    }), "north-star.myshopify.com").value
    const merged = Model.mergeStoreResult(prior, result, 2000, 60)
    assert.equal(merged.status, status)
    assert.equal(merged.recentOrders[0].idHash, HASH_A)
    assert.equal(merged.unreadCount, 7)
    assert.equal(merged.pendingCount, 4)
    assert.equal(merged.displayName, "North Star")
    assert.equal(merged.lastSuccessfulPollAt, prior.lastSuccessfulPollAt)
  }

  const authoritativeError = Model.parseWorkerResponse(response({
    status: "error",
    stateAuthoritative: true,
    recentOrders: [],
    unreadCount: 0,
    pendingCount: 0,
    displayName: null,
    error: retryableError,
    lastSuccessfulPollAt: null,
    nextPollSeconds: 300
  }), "north-star.myshopify.com").value
  const mergedAuthoritativeError = Model.mergeStoreResult(prior,
    authoritativeError, 2000, 60)
  assert.equal(mergedAuthoritativeError.status, "error")
  assert.equal(mergedAuthoritativeError.displayName, null)
  assert.deepEqual(mergedAuthoritativeError.recentOrders, [])
  assert.equal(mergedAuthoritativeError.unreadCount, 0)
  assert.equal(mergedAuthoritativeError.pendingCount, 0)
  assert.equal(mergedAuthoritativeError.lastSuccessfulPollAt, "")

  const catchingUp = Model.parseWorkerResponse(response({
    status: "catching_up",
    recentOrders: [],
    unreadCount: 0,
    pendingCount: 0,
    error: null,
    lastSuccessfulPollAt: "2026-09-01T18:31:00Z"
  }), "north-star.myshopify.com").value
  const mergedCatchUp = Model.mergeStoreResult(prior, catchingUp, 2000, 60)
  assert.deepEqual(mergedCatchUp.recentOrders, [])
  assert.equal(mergedCatchUp.unreadCount, 0)
  assert.equal(mergedCatchUp.pendingCount, 0)
  assert.equal(mergedCatchUp.lastSuccessfulPollAt, "2026-09-01T18:31:00Z")

  const degraded = Model.parseWorkerResponse(response({
    status: "degraded",
    recentOrders: [],
    unreadCount: 0,
    pendingCount: 1,
    error: retryableError
  }), "north-star.myshopify.com").value
  const mergedDegraded = Model.mergeStoreResult(prior, degraded, 2000, 60)
  assert.deepEqual(mergedDegraded.recentOrders, [])
  assert.equal(mergedDegraded.unreadCount, 0)
  assert.equal(mergedDegraded.pendingCount, 1)
})

test("aggregation keeps per-store state while exposing a sorted overview", () => {
  const first = Model.mergeStoreResult(null,
    Model.parseWorkerResponse(response(), "north-star.myshopify.com").value, 1000, 60)
  const secondResult = Model.parseWorkerResponse(response({
    status: "degraded",
    store: "other.myshopify.com",
    displayName: "Other Shop",
    recentOrders: [publicOrder({
      idHash: HASH_B,
      name: "#2",
      createdAt: "2026-09-01T19:00:00Z",
      amount: "1.00",
      currency: "EUR",
      financialStatus: "PAID",
      fulfillmentStatus: "FULFILLED",
      url: "https://other.myshopify.com/admin/orders/2"
    })],
    unreadCount: 3,
    pendingCount: 1,
    error: { code: "auth_required", message: "Please sign in", retryable: false }
  }), "other.myshopify.com").value
  const second = Model.mergeStoreResult(null, secondResult, 1000, 60)
  const aggregate = Model.aggregateStoreStates([first, second])

  assert.equal(aggregate.unreadCount, 4)
  assert.equal(aggregate.authRequired, true)
  assert.equal(aggregate.orders[0].store, "other.myshopify.com")
  assert.equal(aggregate.orders[0].displayName, "Other Shop")
  assert.equal(aggregate.orders[1].displayName, "North Star")
})

test("aggregation exposes durable catch-up progress to every UI surface", () => {
  const catchingUp = Model.mergeStoreResult(null,
    Model.parseWorkerResponse(response({ status: "catching_up" }),
      "north-star.myshopify.com").value, 1000, 3600)
  const aggregate = Model.aggregateStoreStates([catchingUp])
  assert.equal(aggregate.catchingUpCount, 1)
  assert.equal(aggregate.errorCount, 0)
})

test("large unread totals stay exact internally and are explicit when abbreviated", () => {
  const first = Model.parseWorkerResponse(response({ unreadCount: 2147483647 }),
    "north-star.myshopify.com").value
  const second = Model.parseWorkerResponse(response({
    store: "other.myshopify.com",
    recentOrders: [],
    unreadCount: 2147483647
  }), "other.myshopify.com").value
  const aggregate = Model.aggregateStoreStates([first, second])
  assert.equal(aggregate.unreadCount, 4294967294)
  assert.equal(Model.countLabel(9999, 9999), "9999")
  assert.equal(Model.countLabel(10000, 9999), "9999+")
})

test("navigation is deterministic across actions, stores, and orders", () => {
  const stores = [{ store: "north-star.myshopify.com" }]
  const orders = [
    { store: "north-star.myshopify.com", idHash: HASH_A },
    { store: "north-star.myshopify.com", idHash: HASH_B }
  ]
  assert.deepEqual(Model.navigationItems(["settings", "refresh", "admin"], stores,
    orders, "north-star.myshopify.com"), [
    { kind: "action", key: "settings", identity: "action:settings" },
    { kind: "action", key: "refresh", identity: "action:refresh" },
    { kind: "action", key: "admin", identity: "action:admin:north-star.myshopify.com" },
    { kind: "store", key: "north-star.myshopify.com",
      identity: "store:north-star.myshopify.com" },
    { kind: "order", key: `north-star.myshopify.com|${HASH_A}`,
      identity: `order:north-star.myshopify.com|${HASH_A}` },
    { kind: "order", key: `north-star.myshopify.com|${HASH_B}`,
      identity: `order:north-star.myshopify.com|${HASH_B}` }
  ])
})

// Pure data and security boundary for OrderBell's QML service and panel.
// Keep this file free of QML globals so the same code runs under Node tests.

var schemaVersion = 1
var maximumStores = 20
var maximumOrders = 20
var maximumStoreSettingBytes = 4 * 1024
var maximumStoreCandidates = 64
var maximumInvalidStoreSamples = 5
var maximumProtocolCount = 2147483647
var maximumPendingCount = 64
var workerResponseByteLimit = 128 * 1024
var workerErrorByteLimit = 4 * 1024
var remoteTextCharacterLimit = 160
var remoteErrorCharacterLimit = 512
var maximumDisplayNameCodePoints = 64
var maximumCount = 9999
var minimumPollSeconds = 60
var maximumPollSeconds = 60 * 60

function isObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value)
}

function hasExactKeys(value, expected) {
  if (!isObject(value)) return false
  var actual = Object.keys(value).sort()
  var wanted = expected.slice().sort()
  if (actual.length !== wanted.length) return false
  for (var i = 0; i < actual.length; i++) {
    if (actual[i] !== wanted[i]) return false
  }
  return true
}

function boundedString(value, limit) {
  var text = String(value === undefined || value === null ? "" : value)
  var maximum = Math.max(0, Number(limit || 0))
  return maximum > 0 && text.length > maximum ? text.substring(0, maximum) : text
}

function utf8ByteLength(value) {
  var text = String(value === undefined || value === null ? "" : value)
  var bytes = 0
  for (var i = 0; i < text.length; i++) {
    var code = text.charCodeAt(i)
    if (code <= 0x7f) bytes += 1
    else if (code <= 0x7ff) bytes += 2
    else if (code >= 0xd800 && code <= 0xdbff
        && i + 1 < text.length
        && text.charCodeAt(i + 1) >= 0xdc00
        && text.charCodeAt(i + 1) <= 0xdfff) {
      bytes += 4
      i++
    } else bytes += 3
  }
  return bytes
}

function exceedsUtf8ByteLimit(value, limit) {
  var text = String(value === undefined || value === null ? "" : value)
  var maximum = Math.max(0, Number(limit || 0))
  var bytes = 0
  for (var i = 0; i < text.length; i++) {
    var code = text.charCodeAt(i)
    if (code <= 0x7f) bytes += 1
    else if (code <= 0x7ff) bytes += 2
    else if (code >= 0xd800 && code <= 0xdbff
        && i + 1 < text.length
        && text.charCodeAt(i + 1) >= 0xdc00
        && text.charCodeAt(i + 1) <= 0xdfff) {
      bytes += 4
      i++
    } else bytes += 3
    if (bytes > maximum) return true
  }
  return false
}

function decodeEntity(entity) {
  switch (String(entity || "").toLowerCase()) {
    case "&amp;": return "&"
    case "&quot;": return "\""
    case "&#39;":
    case "&apos;": return "'"
    case "&nbsp;": return " "
    case "&lt;": return "<"
    case "&gt;": return ">"
    default: return " "
  }
}

function cleanText(value, limit) {
  var maximum = Math.max(1, Number(limit || remoteTextCharacterLimit))
  var text = boundedString(value, maximum * 4)
    .replace(/&(?:amp|quot|#39|apos|nbsp|lt|gt);/gi, decodeEntity)
    .replace(/<br\s*\/?\s*>/gi, " ")
    .replace(/<[^>]*>/g, " ")
    .replace(/[<>]/g, " ")
    // C0/C1 control characters and bidi isolates/overrides are never useful
    // in an order label and can make hostile content visually misleading.
    .replace(/[\u0000-\u001f\u007f-\u009f\u200b-\u200f\u202a-\u202e\u2060-\u206f\ufeff]/g, " ")
    .replace(/\s+/g, " ")
    .trim()
  return boundedString(text, maximum)
}

function clampInteger(value, fallback, minimum, maximum) {
  var parsed = NaN
  if (typeof value === "number") parsed = value
  else if (typeof value === "string" && /^-?(?:0|[1-9]\d*)$/.test(value)) parsed = Number(value)
  if (!isFinite(parsed) || Math.floor(parsed) !== parsed) parsed = fallback
  return Math.max(minimum, Math.min(maximum, parsed))
}

function strictInteger(value, minimum, maximum) {
  if (typeof value !== "number" || !isFinite(value) || Math.floor(value) !== value)
    return null
  if (value < minimum || value > maximum) return null
  return value
}

function boundedCount(value, fallback, maximum) {
  var upper = maximum === undefined ? maximumProtocolCount : maximum
  var parsed = strictInteger(value, 0, upper)
  return parsed === null ? fallback : parsed
}

function countLabel(value, cap) {
  var maximum = strictInteger(cap, 1, maximumProtocolCount)
  if (maximum === null) maximum = maximumCount
  var count = boundedCount(value, 0, maximumProtocolCount * maximumStores)
  return count > maximum ? String(maximum) + "+" : String(count)
}

function normalizeStore(value) {
  var store = String(value === undefined || value === null ? "" : value)
  if (store.length < 15 || store.length > 78) return ""
  if (store !== store.toLowerCase()) return ""
  // One canonical Shopify host only: no scheme, port, path, query, fragment,
  // user info, wildcard, Unicode lookalike, IP literal, or trailing dot.
  var match = store.match(/^([a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)\.myshopify\.com$/)
  if (!match || match[1].indexOf("--") === 0) return ""
  return store
}

function parseStoreList(value) {
  var source = String(value === undefined || value === null ? "" : value)
  var result = { stores: [], invalid: [], tooMany: false, truncated: false }
  if (exceedsUtf8ByteLimit(source, maximumStoreSettingBytes)) {
    result.invalid.push("Store setting exceeds its size limit")
    result.truncated = true
    return result
  }

  var pieces = source.split(",")
  if (pieces.length > maximumStoreCandidates) {
    result.invalid.push("Store setting contains too many entries")
    result.truncated = true
    return result
  }

  var stores = []
  var invalid = []
  var seen = {}
  for (var i = 0; i < pieces.length; i++) {
    var raw = pieces[i].trim()
    if (raw === "") continue
    var store = normalizeStore(raw)
    if (store === "") {
      if (invalid.length < maximumInvalidStoreSamples) invalid.push(cleanText(raw, 96))
      else result.truncated = true
      continue
    }
    if (!seen[store]) {
      seen[store] = true
      stores.push(store)
      if (stores.length > maximumStores) result.tooMany = true
    }
  }
  result.stores = result.tooMany ? [] : stores
  result.invalid = invalid
  return result
}

function storeHandle(store) {
  var valid = normalizeStore(store)
  return valid === "" ? "" : valid.substring(0, valid.length - ".myshopify.com".length)
}

function storeLabel(store) {
  var handle = storeHandle(store)
  return handle === "" ? "Store" : handle
}

function unicodeCodePointLength(value) {
  var text = String(value === undefined || value === null ? "" : value)
  var count = 0
  for (var i = 0; i < text.length; i++) {
    var first = text.charCodeAt(i)
    if (first >= 0xd800 && first <= 0xdbff) {
      if (i + 1 >= text.length) return -1
      var second = text.charCodeAt(i + 1)
      if (second < 0xdc00 || second > 0xdfff) return -1
      i++
    } else if (first >= 0xdc00 && first <= 0xdfff) return -1
    count++
  }
  return count
}

function displayNameHasUnsafeCodePoint(value) {
  var text = String(value || "")
  for (var i = 0; i < text.length; i++) {
    var point = text.charCodeAt(i)
    if (point >= 0xd800 && point <= 0xdbff) {
      var low = text.charCodeAt(++i)
      point = 0x10000 + ((point - 0xd800) << 10) + (low - 0xdc00)
    }

    // Reject Unicode control/format characters, private-use code points and
    // noncharacters. The worker removes every Unicode C* category; this
    // independently covers their display/security-relevant ranges at the UI
    // boundary without altering legitimate plain-text punctuation such as
    // `<`, `>` or `&`.
    if (point <= 0x001f || (point >= 0x007f && point <= 0x009f)
        || point === 0x00ad || (point >= 0x0600 && point <= 0x0605)
        || point === 0x061c || point === 0x06dd || point === 0x070f
        || (point >= 0x0890 && point <= 0x0891) || point === 0x08e2
        || point === 0x180e || (point >= 0x200b && point <= 0x200f)
        || (point >= 0x202a && point <= 0x202e)
        || (point >= 0x2060 && point <= 0x2064)
        || (point >= 0x2066 && point <= 0x206f) || point === 0xfeff
        || (point >= 0xfff9 && point <= 0xfffb) || point === 0x110bd
        || point === 0x110cd || (point >= 0x13430 && point <= 0x1343f)
        || (point >= 0x1bca0 && point <= 0x1bca3)
        || (point >= 0x1d173 && point <= 0x1d17a) || point === 0xe0001
        || (point >= 0xe0020 && point <= 0xe007f)
        || (point >= 0xe000 && point <= 0xf8ff)
        || (point >= 0xf0000 && point <= 0xffffd)
        || (point >= 0x100000 && point <= 0x10fffd)
        || (point >= 0xfdd0 && point <= 0xfdef)
        || (point & 0xffff) === 0xfffe || (point & 0xffff) === 0xffff)
      return true
  }
  return false
}

function safeDisplayName(value) {
  if (value === null) return null
  if (typeof value !== "string") return ""
  var length = unicodeCodePointLength(value)
  if (length < 1 || length > maximumDisplayNameCodePoints
      || displayNameHasUnsafeCodePoint(value)) return ""
  if (value.trim().replace(/\s+/g, " ") !== value) return ""
  // Qt 6's QML JavaScript engine and Node both implement String#normalize.
  // Fail closed if a future host does not: accepting a visually different
  // normalization than the worker's NFKC contract would be ambiguous.
  if (typeof value.normalize !== "function" || value.normalize("NFKC") !== value)
    return ""
  return value
}

function knownDisplayName(value) {
  var safe = safeDisplayName(value)
  return safe === "" ? null : safe
}

function storeDisplayName(displayName, store) {
  var known = knownDisplayName(displayName)
  return known === null ? storeLabel(store) : known
}

function adminUrl(store) {
  var valid = normalizeStore(store)
  return valid === "" ? "" : "https://" + valid + "/admin"
}

function adminOrdersUrl(store) {
  var base = adminUrl(store)
  return base === "" ? "" : base + "/orders"
}

function numericOrderIdFromUrl(store, value) {
  var validStore = normalizeStore(store)
  if (validStore === "" || typeof value !== "string" || value.length > 512)
    return ""

  var escapedStore = validStore.replace(/\./g, "\\.")
  var legacy = value.match(new RegExp("^https://" + escapedStore + "/admin/orders/([1-9][0-9]{0,29})$"))
  return legacy ? legacy[1] : ""
}

function canonicalOrderUrl(store, value) {
  var id = numericOrderIdFromUrl(store, value)
  var base = adminUrl(store)
  return id === "" || base === "" ? "" : base + "/orders/" + id
}

function safeTimestamp(value) {
  if (typeof value !== "string") return ""
  var match = value.match(/^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d{6}))?Z$/)
  if (!match) return ""
  var year = Number(match[1])
  var month = Number(match[2])
  var day = Number(match[3])
  var hour = Number(match[4])
  var minute = Number(match[5])
  var second = Number(match[6])
  var millisecond = match[7] ? Number(match[7].substring(0, 3)) : 0
  if (year < 2000 || year > 9998 || month < 1 || month > 12
      || day < 1 || day > 31 || hour > 23 || minute > 59 || second > 59)
    return ""
  var timestamp = Date.UTC(year, month - 1, day, hour, minute, second, millisecond)
  if (!isFinite(timestamp)) return ""
  var parsed = new Date(timestamp)
  if (parsed.getUTCFullYear() !== year || parsed.getUTCMonth() !== month - 1
      || parsed.getUTCDate() !== day || parsed.getUTCHours() !== hour
      || parsed.getUTCMinutes() !== minute || parsed.getUTCSeconds() !== second)
    return ""
  return value
}

function safeAmount(value) {
  if (typeof value !== "string") return ""
  return /^(?:0|[1-9][0-9]{0,14})(?:\.[0-9]{1,6})?$/.test(value) ? value : ""
}

function safeCurrency(value) {
  return typeof value === "string" && /^[A-Z]{3}$/.test(value) ? value : ""
}

function safeIdHash(value) {
  return typeof value === "string" && /^[0-9a-f]{64}$/.test(value) ? value : ""
}

function parseOrder(value, store) {
  var keys = ["idHash", "name", "createdAt", "amount", "currency",
    "financialStatus", "fulfillmentStatus", "test", "url", "unread"]
  if (!hasExactKeys(value, keys)) return null
  var idHash = safeIdHash(value.idHash)
  var createdAt = safeTimestamp(value.createdAt)
  var name = typeof value.name === "string" ? cleanText(value.name, 64) : ""
  var amount = safeAmount(value.amount)
  var currency = safeCurrency(value.currency)
  var financialStatus = value.financialStatus
  var fulfillmentStatus = value.fulfillmentStatus
  var statusPattern = /^[A-Z][A-Z0-9_]{0,39}$/
  var url = canonicalOrderUrl(store, value.url)
  if (idHash === "" || createdAt === "" || name === "" || amount === ""
      || currency === "" || url === "" || typeof value.test !== "boolean"
      || typeof value.unread !== "boolean") return null
  if (financialStatus !== null
      && (typeof financialStatus !== "string" || !statusPattern.test(financialStatus))) return null
  if (fulfillmentStatus !== null
      && (typeof fulfillmentStatus !== "string" || !statusPattern.test(fulfillmentStatus))) return null

  return {
    idHash: idHash,
    store: store,
    name: name,
    createdAt: createdAt,
    timestampMs: Date.parse(createdAt),
    amount: amount,
    currency: currency,
    financialStatus: financialStatus,
    fulfillmentStatus: fulfillmentStatus,
    test: value.test,
    url: url,
    unread: value.unread
  }
}

function parseProtocolError(value) {
  var keys = ["code", "message", "retryable"]
  if (!hasExactKeys(value, keys)) return null
  if (typeof value.code !== "string" || !/^[a-z][a-z0-9_]{0,47}$/.test(value.code)
      || typeof value.message !== "string" || value.message.length > remoteErrorCharacterLimit
      || typeof value.retryable !== "boolean") return null
  var message = cleanText(value.message, remoteErrorCharacterLimit)
  if (message === "") return null
  return { code: value.code, message: message, retryable: value.retryable }
}

function parseWorkerResponse(raw, expectedStore) {
  var expected = normalizeStore(expectedStore)
  var source = String(raw === undefined || raw === null ? "" : raw)
  if (expected === "") return { ok: false, error: "The configured store is invalid" }
  if (exceedsUtf8ByteLimit(source, workerResponseByteLimit))
    return { ok: false, error: "The worker response exceeded its size limit" }

  var value
  try { value = JSON.parse(source) } catch (e) {
    return { ok: false, error: "The worker returned malformed JSON" }
  }
  if (!isObject(value)) return { ok: false, error: "The worker response must be an object" }
  var responseKeys = ["schemaVersion", "stateAuthoritative", "status", "store", "displayName",
    "recentOrders", "unreadCount", "pendingCount", "error", "nextPollSeconds",
    "lastSuccessfulPollAt"]
  if (!hasExactKeys(value, responseKeys))
    return { ok: false, error: "The worker returned an unexpected response shape" }
  if (value.schemaVersion !== schemaVersion)
    return { ok: false, error: "Unsupported worker response schema" }
  if (typeof value.stateAuthoritative !== "boolean")
    return { ok: false, error: "The worker returned invalid state authority" }

  if (typeof value.store !== "string" || normalizeStore(value.store) !== value.store
      || value.store !== expected)
    return { ok: false, error: "The worker response targeted a different store" }
  var store = value.store

  var displayName = safeDisplayName(value.displayName)
  if (value.displayName !== null && displayName === "")
    return { ok: false, error: "The worker returned an invalid store display name" }

  var allowedStatuses = { ok: true, baseline: true, catching_up: true,
    degraded: true, error: true, busy: true }
  var status = value.status
  if (typeof status !== "string")
    return { ok: false, error: "The worker returned an unknown status" }
  if (allowedStatuses[status] !== true)
    return { ok: false, error: "The worker returned an unknown status" }
  if ((status === "busy" && value.stateAuthoritative)
      || (status !== "busy" && status !== "error" && !value.stateAuthoritative))
    return { ok: false, error: "The worker returned inconsistent state authority" }

  if (!Array.isArray(value.recentOrders) || value.recentOrders.length > maximumOrders)
    return { ok: false, error: "The worker returned an invalid order list" }

  var orders = []
  var observedUnread = 0
  var seenOrderIds = {}
  for (var i = 0; i < value.recentOrders.length; i++) {
    var order = parseOrder(value.recentOrders[i], store)
    if (!order) return { ok: false, error: "The worker returned a malformed order" }
    if (seenOrderIds[order.idHash])
      return { ok: false, error: "The worker returned duplicate orders" }
    seenOrderIds[order.idHash] = true
    orders.push(order)
    if (order.unread) observedUnread++
  }
  orders.sort(function(a, b) {
    var time = b.timestampMs - a.timestampMs
    if (time !== 0) return time
    return a.idHash < b.idHash ? -1 : (a.idHash > b.idHash ? 1 : 0)
  })

  var needsError = status === "degraded" || status === "error" || status === "busy"
  if ((needsError && value.error === null) || (!needsError && value.error !== null))
    return { ok: false, error: "The worker returned an inconsistent status and error" }
  var error = value.error === null ? null : parseProtocolError(value.error)
  if (value.error !== null && error === null)
    return { ok: false, error: "The worker returned a malformed error" }

  var unread = strictInteger(value.unreadCount, 0, maximumProtocolCount)
  var pending = strictInteger(value.pendingCount, 0, maximumPendingCount)
  var nextPoll = strictInteger(value.nextPollSeconds, minimumPollSeconds,
    maximumPollSeconds)
  if (unread === null || pending === null || nextPoll === null || unread < observedUnread)
    return { ok: false, error: "The worker returned invalid counters or timing" }

  var lastSuccessfulPollAt = ""
  if (value.lastSuccessfulPollAt !== null) {
    lastSuccessfulPollAt = safeTimestamp(value.lastSuccessfulPollAt)
    if (lastSuccessfulPollAt === "")
      return { ok: false, error: "The worker returned an invalid success timestamp" }
  }

  return {
    ok: true,
    value: {
      schemaVersion: schemaVersion,
      stateAuthoritative: value.stateAuthoritative,
      status: status,
      store: store,
      displayName: displayName,
      recentOrders: orders,
      unreadCount: unread,
      pendingCount: pending,
      error: error,
      nextPollSeconds: nextPoll,
      lastSuccessfulPollAt: lastSuccessfulPollAt
    }
  }
}

function initialStoreState(store, nowMs) {
  return {
    store: normalizeStore(store),
    displayName: null,
    status: "idle",
    recentOrders: [],
    unreadCount: 0,
    pendingCount: 0,
    error: null,
    lastSuccessfulPollAt: "",
    nextPollSeconds: minimumPollSeconds,
    nextPollAtMs: Number(nowMs || 0),
    polling: false
  }
}

function mergeStoreResult(previous, result, nowMs, configuredInterval) {
  var hasPrior = isObject(previous) && previous.store === result.store
  var prior = hasPrior ? previous : initialStoreState(result.store, nowMs)
  var preserveKnownGood = hasPrior && (result.status === "busy"
    || result.stateAuthoritative !== true)
  // The worker already folds the configured cadence, retry backoff and
  // progress urgency into this bounded protocol field. In particular, busy
  // locks and durable catch-up chunks intentionally retry sooner than the
  // normal user interval.
  var configuredFallback = clampInteger(configuredInterval, minimumPollSeconds,
    minimumPollSeconds, maximumPollSeconds)
  var interval = clampInteger(result.nextPollSeconds, configuredFallback,
    minimumPollSeconds, maximumPollSeconds)
  var priorDisplayName = knownDisplayName(prior.displayName)
  var resultDisplayName = knownDisplayName(result.displayName)
  var mergedDisplayName = preserveKnownGood ? priorDisplayName : resultDisplayName
  return {
    store: result.store,
    displayName: mergedDisplayName,
    status: result.status,
    recentOrders: preserveKnownGood && Array.isArray(prior.recentOrders)
      ? prior.recentOrders.slice() : result.recentOrders.slice(),
    unreadCount: preserveKnownGood
      ? boundedCount(prior.unreadCount, 0, maximumProtocolCount) : result.unreadCount,
    pendingCount: preserveKnownGood
      ? boundedCount(prior.pendingCount, 0, maximumPendingCount) : result.pendingCount,
    error: result.error,
    lastSuccessfulPollAt: preserveKnownGood
      ? safeTimestamp(prior.lastSuccessfulPollAt) : result.lastSuccessfulPollAt,
    nextPollSeconds: interval,
    nextPollAtMs: Number(nowMs || Date.now()) + interval * 1000,
    polling: false
  }
}

function processFailure(previous, store, message, nowMs, configuredInterval) {
  var prior = isObject(previous) ? previous : initialStoreState(store, nowMs)
  var interval = clampInteger(configuredInterval, minimumPollSeconds,
    minimumPollSeconds, maximumPollSeconds)
  var priorDelay = clampInteger(prior.nextPollSeconds, interval, minimumPollSeconds, maximumPollSeconds)
  var delay = Math.min(maximumPollSeconds, Math.max(interval, priorDelay * 2))
  return {
    store: normalizeStore(store),
    displayName: knownDisplayName(prior.displayName),
    status: "error",
    recentOrders: Array.isArray(prior.recentOrders) ? prior.recentOrders.slice() : [],
    unreadCount: boundedCount(prior.unreadCount, 0, maximumProtocolCount),
    pendingCount: boundedCount(prior.pendingCount, 0, maximumPendingCount),
    error: { code: "worker_failure", message: cleanText(message || "OrderBell worker failed", remoteErrorCharacterLimit), retryable: true },
    lastSuccessfulPollAt: safeTimestamp(prior.lastSuccessfulPollAt),
    nextPollSeconds: delay,
    nextPollAtMs: Number(nowMs || Date.now()) + delay * 1000,
    polling: false
  }
}

function isAuthError(error) {
  if (!isObject(error)) return false
  var code = String(error.code || "").toLowerCase()
  return code === "auth_required" || code === "authentication_required"
    || code === "unauthenticated" || code === "unauthorized"
    || code === "invalid_session" || code === "access_denied"
    || code === "forbidden"
}

function aggregateStoreStates(states) {
  var source = Array.isArray(states) ? states.slice(0, maximumStores) : []
  var orders = []
  var unread = 0
  var pending = 0
  var errors = 0
  var authRequired = false
  var polling = false
  var catchingUp = 0
  for (var i = 0; i < source.length; i++) {
    var state = source[i]
    unread += boundedCount(state.unreadCount, 0, maximumProtocolCount)
    pending += boundedCount(state.pendingCount, 0, maximumPendingCount)
    if (state.error) {
      errors++
      if (isAuthError(state.error)) authRequired = true
    }
    if (state.polling === true) polling = true
    if (state.status === "catching_up") catchingUp++
    var recent = Array.isArray(state.recentOrders) ? state.recentOrders : []
    var stateDisplayName = knownDisplayName(state.displayName)
    for (var j = 0; j < recent.length && orders.length < maximumOrders * maximumStores; j++) {
      var order = recent[j]
      if (!isObject(order)) continue
      orders.push({
        idHash: order.idHash,
        store: order.store,
        displayName: stateDisplayName,
        name: order.name,
        createdAt: order.createdAt,
        timestampMs: order.timestampMs,
        amount: order.amount,
        currency: order.currency,
        financialStatus: order.financialStatus,
        fulfillmentStatus: order.fulfillmentStatus,
        test: order.test,
        url: order.url,
        unread: order.unread
      })
    }
  }
  orders.sort(function(a, b) {
    var time = Number(b.timestampMs || 0) - Number(a.timestampMs || 0)
    if (time !== 0) return time
    var first = String(a.idHash || "")
    var second = String(b.idHash || "")
    return first < second ? -1 : (first > second ? 1 : 0)
  })
  return {
    orders: orders.slice(0, maximumOrders),
    unreadCount: unread,
    pendingCount: pending,
    errorCount: errors,
    authRequired: authRequired,
    polling: polling,
    catchingUpCount: catchingUp
  }
}

function validatedWorkerPath(value) {
  var path = String(value || "")
  return path.charAt(0) === "/" && path.indexOf("\u0000") === -1 ? path : ""
}

function pollCommand(workerPath, store, options) {
  var path = validatedWorkerPath(workerPath)
  var validStore = normalizeStore(store)
  if (path === "" || validStore === "") return []
  var config = isObject(options) ? options : {}
  var command = [path, "poll", "--store", validStore]
  command.push(config.notify === true ? "--notify" : "--no-notify")
  command.push(config.privacyMode === false ? "--show-details" : "--privacy")
  if (config.includeTestOrders === true) command.push("--include-test-orders")
  command.push("--timeout", "20")
  command.push("--interval", String(clampInteger(config.refreshIntervalSec,
    minimumPollSeconds, minimumPollSeconds, maximumPollSeconds)))
  return command
}

function workerActionCommand(workerPath, action, store, privacyMode) {
  var path = validatedWorkerPath(workerPath)
  var validStore = normalizeStore(store)
  var allowed = { status: true, "mark-read": true, authenticate: true, "test-notification": true }
  if (path === "" || validStore === "" || allowed[action] !== true) return []
  var command = [path, action, "--store", validStore]
  if (action === "authenticate") command.push("--timeout", "300")
  else if (action === "test-notification") command.push(privacyMode === false ? "--show-details" : "--privacy")
  return command
}

function formatMoney(amount, currency, privacyMode) {
  if (privacyMode !== false) return "Amount hidden"
  var safe = safeAmount(amount)
  var code = safeCurrency(currency)
  return safe === "" || code === "" ? "Amount unavailable" : safe + " " + code
}

function titleForOrder(order, privacyMode) {
  return privacyMode !== false ? "New order" : cleanText(order && order.name || "Order", 64)
}

function humanStatus(value) {
  var source = cleanText(value, 48).replace(/[_-]+/g, " ").toLowerCase()
  if (source === "") return ""
  return source.replace(/(^|\s)([a-z])/g, function(match, prefix, letter) {
    return prefix + letter.toUpperCase()
  })
}

function orderMeta(order, privacyMode, nowMs) {
  if (!order) return ""
  var parts = []
  var age = relativeTime(order.timestampMs, nowMs)
  if (age !== "") parts.push(age)
  if (privacyMode === false) {
    var money = formatMoney(order.amount, order.currency, false)
    if (money !== "Amount unavailable") parts.push(money)
  }
  var status = humanStatus(order.financialStatus)
  if (status !== "") parts.push(status)
  var fulfillment = humanStatus(order.fulfillmentStatus)
  if (fulfillment !== "" && fulfillment !== status) parts.push(fulfillment)
  if (order.test === true) parts.push("Test")
  return parts.join(" · ")
}

function relativeTime(timestampMs, nowMs) {
  var timestamp = Number(timestampMs || 0)
  var now = Number(nowMs === undefined ? Date.now() : nowMs)
  if (!isFinite(timestamp) || timestamp <= 0 || !isFinite(now)) return ""
  var seconds = Math.max(0, Math.floor((now - timestamp) / 1000))
  if (seconds < 60) return "just now"
  if (seconds < 3600) return Math.floor(seconds / 60) + "m ago"
  if (seconds < 86400) return Math.floor(seconds / 3600) + "h ago"
  if (seconds < 7 * 86400) return Math.floor(seconds / 86400) + "d ago"
  var date = new Date(timestamp)
  var month = String(date.getMonth() + 1).padStart(2, "0")
  var day = String(date.getDate()).padStart(2, "0")
  return date.getFullYear() + "-" + month + "-" + day
}

function barNeedsAttention(service) {
  return !!service && (Number(service.errorCount || 0) > 0
    || Number(service.unreadCount || 0) > 0
    || Number(service.pendingCount || 0) > 0
    || service.catchingUp === true)
}

function barTooltip(service) {
  if (!service) return "OrderBell · service unavailable"
  if (Number(service.errorCount || 0) > 0) return "OrderBell · sync needs attention"
  if (service.refreshing === true) return "OrderBell · checking for orders"
  if (service.catchingUp === true) return "OrderBell · catching up safely"
  var pending = Math.max(0, Math.floor(Number(service.pendingCount || 0)))
  if (pending === 1) return "OrderBell · 1 notification queued"
  if (pending > 1) return "OrderBell · " + countLabel(pending, 9999)
    + " notifications queued"
  var unread = Math.max(0, Math.floor(Number(service.unreadCount || 0)))
  if (unread === 1) return "OrderBell · 1 new order"
  if (unread > 1) return "OrderBell · " + countLabel(unread, 9999) + " new orders"
  return service.configured === true ? "OrderBell · all caught up" : "OrderBell · setup required"
}

function stateMeta(state, nowMs) {
  if (!state) return "Waiting for first sync"
  if (state.polling === true) return "Syncing…"
  if (state.error) return cleanText(state.error.message || "Sync failed", 140)
  if (state.status === "catching_up") return "Catching up…"
  if (state.status === "baseline") return "Ready · future orders will notify"
  var when = safeTimestamp(state.lastSuccessfulPollAt)
  return when === "" ? "Waiting for first sync" : "Synced " + relativeTime(Date.parse(when), nowMs)
}

function navigationItems(actionKeys, storeStates, orderRows, selectedStore) {
  var items = []
  var actions = Array.isArray(actionKeys) ? actionKeys.slice(0, 10) : []
  var selected = normalizeStore(selectedStore)
  for (var a = 0; a < actions.length; a++) {
    var action = String(actions[a] || "")
    if (action === "") continue
    var globalAction = action === "settings" || action === "refresh"
    items.push({
      kind: "action",
      key: action,
      identity: "action:" + action + (globalAction ? "" : ":" + selected)
    })
  }
  var stores = Array.isArray(storeStates) ? storeStates.slice(0, maximumStores) : []
  for (var s = 0; s < stores.length; s++) {
    var store = isObject(stores[s]) ? normalizeStore(stores[s].store) : ""
    if (store !== "") items.push({ kind: "store", key: store, identity: "store:" + store })
  }
  var orders = Array.isArray(orderRows) ? orderRows.slice(0, maximumOrders) : []
  for (var o = 0; o < orders.length; o++) {
    if (!isObject(orders[o])) continue
    var orderStore = normalizeStore(orders[o].store)
    var idHash = safeIdHash(orders[o].idHash)
    if (orderStore === "" || idHash === "") continue
    var orderKey = orderStore + "|" + idHash
    items.push({ kind: "order", key: orderKey, identity: "order:" + orderKey })
  }
  return items
}

if (typeof module !== "undefined") {
  module.exports = {
    schemaVersion: schemaVersion,
    maximumStores: maximumStores,
    maximumOrders: maximumOrders,
    maximumStoreSettingBytes: maximumStoreSettingBytes,
    maximumStoreCandidates: maximumStoreCandidates,
    maximumInvalidStoreSamples: maximumInvalidStoreSamples,
    maximumDisplayNameCodePoints: maximumDisplayNameCodePoints,
    workerResponseByteLimit: workerResponseByteLimit,
    workerErrorByteLimit: workerErrorByteLimit,
    minimumPollSeconds: minimumPollSeconds,
    maximumPollSeconds: maximumPollSeconds,
    boundedString: boundedString,
    utf8ByteLength: utf8ByteLength,
    exceedsUtf8ByteLimit: exceedsUtf8ByteLimit,
    cleanText: cleanText,
    countLabel: countLabel,
    clampInteger: clampInteger,
    normalizeStore: normalizeStore,
    parseStoreList: parseStoreList,
    storeHandle: storeHandle,
    storeLabel: storeLabel,
    unicodeCodePointLength: unicodeCodePointLength,
    safeDisplayName: safeDisplayName,
    storeDisplayName: storeDisplayName,
    adminUrl: adminUrl,
    adminOrdersUrl: adminOrdersUrl,
    canonicalOrderUrl: canonicalOrderUrl,
    safeTimestamp: safeTimestamp,
    parseOrder: parseOrder,
    parseWorkerResponse: parseWorkerResponse,
    initialStoreState: initialStoreState,
    mergeStoreResult: mergeStoreResult,
    processFailure: processFailure,
    isAuthError: isAuthError,
    aggregateStoreStates: aggregateStoreStates,
    pollCommand: pollCommand,
    workerActionCommand: workerActionCommand,
    formatMoney: formatMoney,
    titleForOrder: titleForOrder,
    humanStatus: humanStatus,
    orderMeta: orderMeta,
    relativeTime: relativeTime,
    stateMeta: stateMeta,
    barNeedsAttention: barNeedsAttention,
    barTooltip: barTooltip,
    navigationItems: navigationItems
  }
}

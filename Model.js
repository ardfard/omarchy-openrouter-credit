// Model helpers for the OpenRouter Credit bar widget.
//
// Pure JS on purpose: no QML imports, no side effects, so every function here
// can be exercised from plain node (see README "Testing the model") as well as
// from BarWidget.qml / Panel.qml.
//
// Two upstream endpoints are involved:
//   GET /api/v1/auth/key   -> the signed-in key's limit/usage (needs the key)
//   GET /api/v1/credits    -> account credits (total_credits/total_usage, needs the key — preferred for bar)
//   GET /api/v1/models     -> the public model catalogue (no key needed)

var AUTH_KEY_URL = "https://openrouter.ai/api/v1/auth/key"
var CREDITS_URL = "https://openrouter.ai/api/v1/credits"
var MODELS_URL = "https://openrouter.ai/api/v1/models"
var CREDITS_PAGE = "https://openrouter.ai/settings/credits"
var KEYS_PAGE = "https://openrouter.ai/settings/keys"

// The bar label never grows past these: balance only, like spoilheap's widget.
var BAR_ICON = "assets/openrouter.svg"
var BAR_EMPTY = "—"   // em dash: no key configured
var BAR_ERROR = "!"        // request failed
var BAR_LOADING = "◷" // first fetch in flight

function authKeyUrl() { return AUTH_KEY_URL }
function creditsUrl() { return CREDITS_URL }
function modelsUrl() { return MODELS_URL }
function creditsPage() { return CREDITS_PAGE }
function keysPage() { return KEYS_PAGE }

// ---------------------------------------------------------------- settings

function clampInt(raw, min, max, fallback) {
  var v = parseInt(String(raw === undefined || raw === null ? "" : raw), 10)
  if (isNaN(v)) return fallback
  if (v < min) return min
  if (v > max) return max
  return v
}

function refreshIntervalMinutes(raw, fallback) {
  return clampInt(raw, 1, 60, fallback === undefined ? 5 : fallback)
}

function listCount(raw, fallback) {
  return clampInt(raw, 4, 16, fallback === undefined ? 8 : fallback)
}

function normalizeApiKey(raw) {
  return String(raw === undefined || raw === null ? "" : raw).trim()
}

function maskApiKey(raw) {
  var k = normalizeApiKey(raw)
  if (!k) return ""
  if (k.length <= 10) return k.charAt(0) + "••••"
  return k.slice(0, 6) + "••••••" + k.slice(-4)
}

// ------------------------------------------------------------- formatting

function formatUsd(value, digits) {
  var n = Number(value)
  if (value === null || value === undefined || value === "" || isNaN(n)) return "—"
  var d = digits === undefined ? 2 : digits
  var sign = n < 0 ? "-" : ""
  var abs = Math.abs(n)
  if (abs > 0 && abs < 0.01 && d <= 2) return sign + "<$0.01"
  return sign + "$" + abs.toFixed(d)
}

// Prices arrive as USD-per-token strings; humans think in dollars per million.
function formatPerMillion(perMillion) {
  var n = Number(perMillion)
  if (perMillion === null || perMillion === undefined || isNaN(n)) return "—"
  if (n === 0) return "free"
  if (n < 0.01) return "$" + n.toFixed(4)
  if (n < 1) return "$" + n.toFixed(3)
  return "$" + n.toFixed(2)
}

function formatContext(tokens) {
  var n = Number(tokens)
  if (!n || isNaN(n) || n <= 0) return "—"
  if (n >= 1000000) {
    var m = n / 1000000
    return (m >= 10 ? Math.round(m) : Math.round(m * 10) / 10) + "M"
  }
  if (n >= 1000) return Math.round(n / 1000) + "K"
  return String(n)
}

// "anthropic/claude-sonnet-4.5" -> "claude-sonnet-4.5" for the tight rows.
function shortModelId(id) {
  var s = String(id || "")
  var slash = s.lastIndexOf("/")
  return slash >= 0 ? s.slice(slash + 1) : s
}

function modelVendor(id) {
  var s = String(id || "")
  var slash = s.indexOf("/")
  return slash > 0 ? s.slice(0, slash) : ""
}

// ------------------------------------------------------- /auth/key parsing

// Returns a stable shape whatever the wire gives us, so the QML never has to
// null-check three levels deep.
// Credits (account wallet) is the preferred source for "remaining" — auth/key is fallback.
function emptyCredit() {
  return {
    ok: false,
    label: "",
    usage: null,
    limit: null,
    limitRemaining: null,
    totalCredits: null,
    totalUsage: null,
    remaining: null,
    isFreeTier: false,
    rateLimit: null,
    error: ""
  }
}

function parseCreditsResponse(raw) {
  var out = emptyCredit()
  var text = String(raw === undefined || raw === null ? "" : raw).trim()
  if (!text) { out.error = "Empty response from OpenRouter"; return out }
  var body; try { body = JSON.parse(text) } catch (e) { out.error = "Could not parse OpenRouter response"; return out }
  if (body && body.error) {
    var msg = typeof body.error === "string" ? body.error : (body.error.message || body.error.type || "OpenRouter rejected the request")
    out.error = String(msg); return out
  }
  var d = body && body.data
  if (!d || typeof d !== "object") { out.error = "Unexpected OpenRouter response"; return out }
  out.ok = true
  // /credits shape: {data:{total_credits, total_usage}}
  var tc = numberOrNull(d.total_credits); var tu = numberOrNull(d.total_usage)
  if (tc !== null || tu !== null) {
    out.totalCredits = tc; out.totalUsage = tu
    if (tc !== null && tu !== null) out.remaining = Math.max(0, tc - tu)
    else if (tc !== null) out.remaining = tc
  }
  // Some keys also return /auth/key shape on /credits (fallback compat) — copy through
  var lr = numberOrNull(d.limit_remaining); if (lr !== null) { out.limitRemaining = lr; if (out.remaining === null) out.remaining = lr }
  if (d.label) out.label = String(d.label)
  if (d.usage !== undefined && out.totalUsage === null) out.usage = numberOrNull(d.usage)
  if (d.limit !== undefined) out.limit = numberOrNull(d.limit)
  out.isFreeTier = d.is_free_tier === true
  if (d.rate_limit && typeof d.rate_limit === "object") out.rateLimit = d.rate_limit
  return out
}

function parseAuthKeyResponse(raw) {
  var out = emptyCredit()
  var text = String(raw === undefined || raw === null ? "" : raw).trim()
  if (!text) {
    out.error = "Empty response from OpenRouter"
    return out
  }
  var body
  try {
    body = JSON.parse(text)
  } catch (e) {
    out.error = "Could not parse OpenRouter response"
    return out
  }
  if (body && body.error) {
    var msg = typeof body.error === "string"
      ? body.error
      : (body.error.message || body.error.type || "OpenRouter rejected the request")
    out.error = String(msg)
    return out
  }
  var d = body && body.data
  if (!d || typeof d !== "object") {
    out.error = "Unexpected OpenRouter response"
    return out
  }
  out.ok = true
  out.label = d.label ? String(d.label) : ""
  out.usage = numberOrNull(d.usage)
  out.limit = numberOrNull(d.limit)
  out.limitRemaining = numberOrNull(d.limit_remaining)
  out.isFreeTier = d.is_free_tier === true
  out.rateLimit = d.rate_limit && typeof d.rate_limit === "object" ? d.rate_limit : null
  return out
}

function numberOrNull(v) {
  if (v === null || v === undefined || v === "") return null
  var n = Number(v)
  return isNaN(n) ? null : n
}

// Bar shows remaining credits only — never "used". Prefers /credits (account wallet),
// falls back to /auth/key limit_remaining if credits is unavailable.
function barIconUrl() { return BAR_ICON }
function creditDisplay(credit, hasKey, loading) {
  if (!hasKey) return { text: BAR_EMPTY, kind: "no-key" }
  if (!credit || (!credit.ok && !credit.error)) {
    return { text: loading ? BAR_LOADING : BAR_EMPTY, kind: "loading" }
  }
  if (!credit.ok) return { text: BAR_ERROR, kind: "error" }
  // Prefer the unified remaining (covers /credits total_credits-total_usage
  // and /auth/key limit_remaining fallback).
  if (credit.remaining !== null) return { text: formatUsd(credit.remaining), kind: "remaining" }
  if (credit.limitRemaining !== null) return { text: formatUsd(credit.limitRemaining), kind: "remaining" }
  return { text: BAR_EMPTY, kind: "unknown" }
}

function creditTooltip(credit, hasKey) {
  if (!hasKey) return "OpenRouter: no API key set — click to configure"
  if (!credit) return "OpenRouter"
  if (!credit.ok) return "OpenRouter: " + (credit.error || "request failed")
  var parts = []
  if (credit.label) parts.push(credit.label)
  if (credit.remaining !== null) parts.push("remaining " + formatUsd(credit.remaining))
  else if (credit.limitRemaining !== null) parts.push("remaining " + formatUsd(credit.limitRemaining))
  if (credit.totalCredits !== null) parts.push("credits " + formatUsd(credit.totalCredits))
  if (credit.totalUsage !== null) parts.push("used " + formatUsd(credit.totalUsage))
  else if (credit.usage !== null) parts.push("used " + formatUsd(credit.usage))
  if (credit.limit !== null) parts.push("limit " + formatUsd(credit.limit))
  if (credit.isFreeTier) parts.push("free tier")
  return parts.length ? "OpenRouter • " + parts.join(" • ") : "OpenRouter"
}

// -------------------------------------------------------- /models parsing

function normalizeModel(m) {
  if (!m || typeof m !== "object" || !m.id) return null
  var pricing = m.pricing || {}
  var prompt = numberOrNull(pricing.prompt)
  var completion = numberOrNull(pricing.completion)
  if (prompt === null || completion === null) return null

  var arch = m.architecture || {}
  var outputs = Array.isArray(arch.output_modalities) ? arch.output_modalities : []
  var params = Array.isArray(m.supported_parameters) ? m.supported_parameters : []
  var context = numberOrNull(m.context_length)
    || numberOrNull(m.top_provider && m.top_provider.context_length)
    || 0

  var promptPerM = prompt * 1000000
  var completionPerM = completion * 1000000

  return {
    id: String(m.id),
    name: m.name ? String(m.name) : String(m.id),
    vendor: modelVendor(m.id),
    contextLength: context,
    promptPerM: promptPerM,
    completionPerM: completionPerM,
    blendedPerM: (promptPerM + completionPerM) / 2,
    supportsTools: params.indexOf("tools") !== -1,
    outputsText: outputs.length === 0 || outputs.indexOf("text") !== -1,
    isFree: prompt === 0 && completion === 0,
    // A negative price is OpenRouter's sentinel for meta-routers like
    // `openrouter/auto` whose real cost is whatever it picks. Not rankable.
    isRouter: prompt < 0 || completion < 0 || String(m.id).indexOf("openrouter/auto") === 0,
    expiresAt: m.expiration_date ? String(m.expiration_date) : "",
    valueScore: 0
  }
}

function parseModelsResponse(raw) {
  var text = String(raw === undefined || raw === null ? "" : raw).trim()
  if (!text) return []
  var body
  try {
    body = JSON.parse(text)
  } catch (e) {
    return []
  }
  var list = body && body.data
  if (!Array.isArray(list)) return []
  var out = []
  for (var i = 0; i < list.length; i++) {
    var n = normalizeModel(list[i])
    if (n) out.push(n)
  }
  return out
}

// ------------------------------------------------------------- ranking

// `expiration_date` in the past is OpenRouter's deprecation marker.
function isRetired(model, nowMs) {
  if (!model.expiresAt) return false
  var t = Date.parse(model.expiresAt)
  if (isNaN(t)) return false
  return t <= (nowMs === undefined ? Date.now() : nowMs)
}

// Shared floor for both lists: a real text model you can actually route to.
function isUsable(model, nowMs) {
  if (!model) return false
  if (model.isRouter) return false
  if (!model.outputsText) return false
  if (isRetired(model, nowMs)) return false
  return true
}

// Minimum context to qualify as "high-context capable" for the value list.
var VALUE_MIN_CONTEXT = 32000

// Value = how much context you get per dollar.
//
//   score = log10(context_length) / blended_$_per_1M_tokens
//   blended = (prompt + completion) / 2
//
// log10 is deliberate: context has sharply diminishing returns, so a 1M-token
// window is treated as roughly 20% better than a 128K one rather than 8x
// better. This is a *cheap quality proxy*, not a benchmark score -- OpenRouter
// publishes no quality metric on /models, and the panel says so out loud.
function valueScore(model) {
  if (!model || !(model.blendedPerM > 0)) return 0
  if (!(model.contextLength > 0)) return 0
  return (Math.log(model.contextLength) / Math.LN10) / model.blendedPerM
}

function rankByValue(models, count, nowMs) {
  var n = listCount(count, 8)
  var pool = []
  for (var i = 0; i < models.length; i++) {
    var m = models[i]
    if (!isUsable(m, nowMs)) continue
    // Free models have blendedPerM === 0, which makes the ratio unbounded.
    // They belong to "Best cheap"; this list is priced models only.
    if (!(m.blendedPerM > 0)) continue
    if (m.contextLength < VALUE_MIN_CONTEXT) continue
    var copy = shallowCopy(m)
    copy.valueScore = valueScore(m)
    pool.push(copy)
  }
  pool.sort(function (a, b) {
    if (b.valueScore !== a.valueScore) return b.valueScore - a.valueScore
    return a.blendedPerM - b.blendedPerM
  })
  return pool.slice(0, n)
}

// Cheapest models that are still worth routing to. Tool-calling support is a
// preference, not a hard filter: if too few tool-capable models exist we top
// the list up with the cheapest remaining ones rather than returning a stub.
//
// NOTE: this now returns *paid only* when used for the "Cheapest paid" section.
// The panel drives "Free" from rankFree() separately, so "Best cheap" no longer
// drowns under 20 × :free. The old all-in behaviour is kept via an explicit
// flag so existing callers/tests don't flip.
function rankByCheap(models, count, nowMs) {
  return rankCheapestPaid(models, count, nowMs)
}

function rankFree(models, count, nowMs) {
  var n = listCount(count, 8)
  var free = []
  for (var i = 0; i < models.length; i++) {
    var m = models[i]
    if (!isUsable(m, nowMs)) continue
    if (!m.isFree) continue
    var copy = shallowCopy(m)
    copy.valueScore = valueScore(m)
    free.push(copy)
  }
  free.sort(function (a, b) { return b.contextLength - a.contextLength })
  return free.slice(0, n)
}

function rankCheapestPaid(models, count, nowMs) {
  var n = listCount(count, 8)
  var withTools = []
  var withoutTools = []
  for (var i = 0; i < models.length; i++) {
    var m = models[i]
    if (!isUsable(m, nowMs)) continue
    if (m.isFree) continue
    var copy = shallowCopy(m)
    copy.valueScore = valueScore(m)
    if (m.supportsTools) withTools.push(copy)
    else withoutTools.push(copy)
  }
  var byPrice = function (a, b) {
    if (a.blendedPerM !== b.blendedPerM) return a.blendedPerM - b.blendedPerM
    return b.contextLength - a.contextLength
  }
  withTools.sort(byPrice)
  if (withTools.length >= n) return withTools.slice(0, n)
  withoutTools.sort(byPrice)
  return withTools.concat(withoutTools.slice(0, n - withTools.length))
}

function shallowCopy(o) {
  var out = {}
  for (var k in o) if (o.hasOwnProperty(k)) out[k] = o[k]
  return out
}

// Subtitles rendered under each section header, so the ranking method is
// visible in the UI rather than buried in the README.
function valueMethodText() {
  return "log₁₀(context) ÷ blended $/1M — context per dollar. Priced models with ≥"
    + formatContext(VALUE_MIN_CONTEXT) + " context; free models are listed below."
}

function cheapMethodText() {
  return "Free tier first (tap to copy), then cheapest paid blended $/1M."
}

function paidMethodText() {
  return "Cheapest paid — ascending blended $/1M, where blended = (prompt + completion) ÷ 2. Tool-calling models first."
}

function priceHint(model) {
  if (!model) return ""
  if (model.isFree) return "free"
  return formatPerMillion(model.blendedPerM) + "/1M"
}

function priceDetail(model) {
  if (!model) return ""
  return "in " + formatPerMillion(model.promptPerM) + " • out " + formatPerMillion(model.completionPerM)
}

// Node-only export; QML reads the functions directly off the .js import.
if (typeof module !== "undefined") {
  module.exports = {
    authKeyUrl: authKeyUrl,
    creditsUrl: creditsUrl,
    modelsUrl: modelsUrl,
    barIconUrl: barIconUrl,
    creditsPage: creditsPage,
    keysPage: keysPage,
    clampInt: clampInt,
    refreshIntervalMinutes: refreshIntervalMinutes,
    listCount: listCount,
    normalizeApiKey: normalizeApiKey,
    maskApiKey: maskApiKey,
    formatUsd: formatUsd,
    formatPerMillion: formatPerMillion,
    formatContext: formatContext,
    shortModelId: shortModelId,
    modelVendor: modelVendor,
    emptyCredit: emptyCredit,
    parseCreditsResponse: parseCreditsResponse,
    parseAuthKeyResponse: parseAuthKeyResponse,
    creditDisplay: creditDisplay,
    creditTooltip: creditTooltip,
    normalizeModel: normalizeModel,
    parseModelsResponse: parseModelsResponse,
    isRetired: isRetired,
    isUsable: isUsable,
    valueScore: valueScore,
    rankByValue: rankByValue,
    rankByCheap: rankByCheap,
    rankFree: rankFree,
    rankCheapestPaid: rankCheapestPaid,
    valueMethodText: valueMethodText,
    cheapMethodText: cheapMethodText,
    paidMethodText: paidMethodText,
    priceHint: priceHint,
    priceDetail: priceDetail,
    VALUE_MIN_CONTEXT: VALUE_MIN_CONTEXT
  }
}

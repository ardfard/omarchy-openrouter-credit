import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Bar widget: balance-only pill plus the loader for the detail panel.
//
// The pill deliberately shows nothing but the credit figure (matching the
// spoilheap OpenRouter widget). Model ranking lives entirely in Panel.qml.
BarWidget {
  id: root
  moduleName: "io.github.ardfard.openrouter-credit"

  // Settings live in shell.json under this widget's entry. The key can also
  // come from the environment, so people who already export it for the CLI
  // never have to paste it into a config file.
  readonly property string apiKey: {
    var configured = Model.normalizeApiKey(setting("apiKey", ""))
    return configured || Model.normalizeApiKey(Quickshell.env("OPENROUTER_API_KEY"))
  }
  readonly property bool hasKey: apiKey !== ""
  readonly property int refreshMinutes: Model.refreshIntervalMinutes(setting("refreshMinutes", 5), 5)
  readonly property int valueCount: Model.listCount(setting("valueCount", 8), 8)
  readonly property int cheapCount: Model.listCount(setting("cheapCount", 8), 8)

  property var credit: Model.emptyCredit()
  property bool loading: false
  property string lastUpdatedLabel: ""

  readonly property var display: Model.creditDisplay(credit, hasKey, loading)

  // Panel plumbing - mirrors the clock/weather widgets
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function toggle() { if (panelLoader.item) panelLoader.item.toggle() }
  function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch() }

  function refresh() {
    fetchCredit()
    if (panelLoader.item && panelLoader.item.refreshModels) panelLoader.item.refreshModels(true)
  }

  function injectPanel() {
    var t = panelLoader.item
    if (!t) return
    if ("bar" in t) t.bar = root.bar
    if ("settings" in t) t.settings = root.settings
    if ("anchorItem" in t) t.anchorItem = button
    if ("hostWidget" in t) t.hostWidget = root
  }

  onBarChanged: injectPanel()
  onSettingsChanged: {
    injectPanel()
    Qt.callLater(fetchCredit)
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Component.onCompleted: fetchCredit()

  Timer {
    id: creditTimer
    interval: Math.max(60000, root.refreshMinutes * 60 * 1000)
    running: true
    repeat: true
    triggeredOnStart: false
    onTriggered: root.fetchCredit()
  }
  onRefreshMinutesChanged: {
    creditTimer.interval = Math.max(60000, refreshMinutes * 60 * 1000)
    creditTimer.restart()
  }

  // Re-fetch as soon as a key appears (or changes) rather than waiting a tick.
  onApiKeyChanged: Qt.callLater(fetchCredit)

  function applyCredit(next) {
    root.credit = next
    root.lastUpdatedLabel = Qt.formatTime(new Date(), "HH:mm")
    if (panelLoader.item) {
      if ("credit" in panelLoader.item) panelLoader.item.credit = next
      if ("creditUpdated" in panelLoader.item) panelLoader.item.creditUpdated = root.lastUpdatedLabel
    }
  }

  function fetchCredit() {
    if (!hasKey) {
      root.credit = Model.emptyCredit()
      root.loading = false
      return
    }
    if (creditProc.running) return
    root.loading = true
    // /api/v1/credits is the account wallet (remaining = total_credits - total_usage).
    // Some keys (provisioning-gated) 401 on /credits — then we fall back to
    // /api/v1/auth/key (per-key limit_remaining) in fetchCreditViaAuthKey().
    creditProc.environment = ({ "OPENROUTER_KEY": root.apiKey })
    // The key travels in the environment, never in argv, so it stays out of
    // `ps` output and out of anything that scrapes the process table.
    creditProc.command = ["bash", "-lc",
      "curl -sS --max-time 10 -H \"Authorization: Bearer $OPENROUTER_KEY\" -H 'Accept: application/json' "
        + Model.creditsUrl()]
    creditProc.running = true
  }

  function fetchCreditViaAuthKey() {
    if (authKeyProc.running) return
    authKeyProc.environment = ({ "OPENROUTER_KEY": root.apiKey })
    authKeyProc.command = ["bash", "-lc",
      "curl -sS --max-time 10 -H \"Authorization: Bearer $OPENROUTER_KEY\" -H 'Accept: application/json' "
        + Model.authKeyUrl()]
    authKeyProc.running = true
  }

  Process {
    id: creditProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "").trim()
        var parsed = Model.parseCreditsResponse(raw)
        // 401/no-data → fall back to auth/key so the bar still shows something
        var isAuthFallback = !parsed.ok && (String(parsed.error || "").toLowerCase().indexOf("user not found") !== -1
          || String(parsed.error || "").toLowerCase().indexOf("no cookie") !== -1
          || raw.indexOf("total_credits") === -1)
        // Prefer credits when it has the wallet fields, otherwise auth fallback
        if (parsed.ok && (parsed.totalCredits !== null || parsed.totalUsage !== null || parsed.remaining !== null)) {
          root.loading = false
          root.applyCredit(parsed)
          return
        }
        // Credits didn't give us wallet data — try auth/key
        if (parsed.ok && parsed.remaining === null && parsed.totalCredits === null) {
          root.fetchCreditViaAuthKey()
          return
        }
        if (!parsed.ok && isAuthFallback) {
          root.fetchCreditViaAuthKey()
          return
        }
        root.loading = false
        if (!raw) return
        root.applyCredit(parsed)
        if (!root.credit.ok) retryTimer.restart()
      }
    }
    onExited: function (code) {
      if (code === 0) return // stdout handler deals with success
      // Credits failed at transport level — fall back to auth/key once
      root.fetchCreditViaAuthKey()
    }
  }

  Process {
    id: authKeyProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.loading = false
        var raw = String(text || "").trim()
        if (!raw) return
        // Reuse credits parser then auth parser — normalize through credits shape
        var viaCredits = Model.parseCreditsResponse(raw)
        var parsed = viaCredits.ok ? viaCredits : Model.parseAuthKeyResponse(raw)
        // Normalize auth response into unified remaining for the bar
        if (parsed.limitRemaining !== null && parsed.remaining === null) parsed.remaining = parsed.limitRemaining
        root.applyCredit(parsed)
        if (!root.credit.ok) retryTimer.restart()
      }
    }
    onExited: function (code) {
      root.loading = false
      if (code !== 0 && !root.credit.ok) {
        var failed = Model.emptyCredit()
        failed.error = "Could not reach openrouter.ai (curl exit " + code + ")"
        root.applyCredit(failed)
        retryTimer.restart()
      }
    }
  }

  Timer {
    id: retryTimer
    interval: 30000
    repeat: false
    onTriggered: root.fetchCredit()
  }

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      if ("credit" in item) item.credit = root.credit
      if ("creditUpdated" in item) item.creditUpdated = root.lastUpdatedLabel
      Qt.callLater(root.injectPanel)
    }
  }

  IpcHandler {
    target: "io.github.ardfard.openrouter-credit"
    function refresh() { root.refresh() }
    function open() { root.open() }
    function close() { root.close() }
    function toggle() { root.toggle() }
    function show() { root.open() }
    function hide() { root.close() }
  }

  // Glyph metrics. Kept on root so the button margins and the image itself
  // read the same numbers instead of drifting apart.
  readonly property int glyphSize: Style.space(13)

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "·"
    labelVisible: false
    dimmed: false
    // Pill is driven by the glyph alone - text is just a sentinel so
    // hasVisualContent stays true and WidgetButton doesn't zero its opacity.
    // Fixed width gives the pill room for the 13px glyph centered, instead of
    // the default label-width layout which would collapse without a real label.
    fixedWidth: root.glyphSize + 15  // 13 + 7.5*2
    horizontalMargin: 7.5
    tooltipText: Model.creditTooltip(root.credit, root.hasKey)
      + (root.lastUpdatedLabel ? " • " + root.lastUpdatedLabel : "")
    active: root.display.kind === "error"
    onPressed: function (b) {
      if (b === Qt.RightButton) root.fetchCredit()
      else if (b === Qt.MiddleButton && root.bar) root.bar.run("xdg-open " + Util.shellQuote(Model.creditsPage()))
      else root.toggle()
    }

    // The official mark carries its own squircle plate, so it stays legible on
    // light and dark themes without recolouring. Sitting inside the button
    // means the button's MouseArea still takes every click; an Image accepts
    // none itself.
    Image {
      id: glyph
      visible: status === Image.Ready
      width: root.glyphSize
      height: root.glyphSize
      anchors.centerIn: parent
      fillMode: Image.PreserveAspectFit
      // Decode at physical pixels so the mark stays sharp on HiDPI.
      sourceSize.width: Math.round(width * Screen.devicePixelRatio)
      sourceSize.height: Math.round(height * Screen.devicePixelRatio)
      source: Qt.resolvedUrl("assets/openrouter.svg")
    }
  }
}

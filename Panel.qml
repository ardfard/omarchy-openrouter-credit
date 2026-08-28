import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Detail panel: balance card on top, then the two ranked model lists.
//
// The balance comes from /auth/key (needs the key). The rankings come from the
// public /models catalogue, so they render even when no key is configured --
// which makes the panel useful as a price table on its own.
Panel {
  id: root
  moduleName: "io.github.ardfard.openrouter-credit"
  ipcTarget: "io.github.ardfard.openrouter-credit"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  // Pushed down from BarWidget so both surfaces agree on one fetch.
  property var credit: Model.emptyCredit()
  property string creditUpdated: ""

  property var models: []
  property real modelsFetchedAt: 0
  property bool modelsLoading: false
  property string modelsError: ""
  property string copiedId: ""

  // The catalogue moves on a scale of days, so it is fetched on open and then
  // held for MODELS_TTL_MS unless someone hits Refresh.
  readonly property real modelsTtlMs: 6 * 60 * 60 * 1000

  readonly property string apiKey: {
    var configured = Model.normalizeApiKey(setting("apiKey", ""))
    return configured || Model.normalizeApiKey(Quickshell.env("OPENROUTER_API_KEY"))
  }
  readonly property bool hasKey: apiKey !== ""
  readonly property bool keyFromEnv: hasKey && Model.normalizeApiKey(setting("apiKey", "")) === ""

  readonly property int refreshMinutes: Model.refreshIntervalMinutes(setting("refreshMinutes", 5), 5)
  readonly property int valueCount: Model.listCount(setting("valueCount", 8), 8)
  readonly property int cheapCount: Model.listCount(setting("cheapCount", 8), 8)

  readonly property var valueList: Model.rankByValue(models, valueCount)
  readonly property var freeList: Model.rankFree(models, Math.min(cheapCount, 6))
  readonly property var paidList: Model.rankCheapestPaid(models, cheapCount)

  property bool keyEditMode: false

  readonly property color neutralColor: bar ? bar.barForeground : Color.foreground
  readonly property color goodColor: "#22c55e"
  readonly property color badColor: bar ? bar.urgent : Color.urgent

  function open() {
    refreshModels(false)
    if (hostWidget && hostWidget.fetchCredit) hostWidget.fetchCredit()
    root.controller.show()
    Qt.callLater(function () {
      if (root.opened) setCenterHoverRevealSuppressed(true)
    })
  }
  function close() {
    setCenterHoverRevealSuppressed(false)
    root.controller.hide()
  }
  function toggle() { if (root.opened) close(); else open() }
  function closeForPopoutSwitch() { close() }
  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }
  function setCenterHoverRevealSuppressed(v) {
    if (root.bar && "centerHoverRevealSuppressed" in root.bar) root.bar.centerHoverRevealSuppressed = v
  }

  function refreshAll() {
    if (root.hostWidget && root.hostWidget.fetchCredit) root.hostWidget.fetchCredit()
    refreshModels(true)
  }

  function refreshModels(force) {
    if (modelsProc.running) return
    var age = Date.now() - root.modelsFetchedAt
    if (!force && root.models.length > 0 && age < root.modelsTtlMs) return
    root.modelsLoading = true
    root.modelsError = ""
    modelsProc.command = ["curl", "-fsS", "--max-time", "20",
      "-H", "Accept: application/json", Model.modelsUrl()]
    modelsProc.running = true
  }

  function copyModelId(id) {
    Util.execArgv(["wl-copy", "--", String(id)])
    root.copiedId = String(id)
    copiedTimer.restart()
  }

  // Writes one key into this widget's shell.json entry, preserving the rest.
  function persistSetting(key, value) {
    var entry = { id: root.moduleName }
    for (var k in root.settings) if (k !== "id") entry[k] = root.settings[k]
    entry[key] = value
    root.settings = entry
    if (root.hostWidget && "settings" in root.hostWidget) root.hostWidget.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  Process {
    id: modelsProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.modelsLoading = false
        var parsed = Model.parseModelsResponse(String(text || ""))
        if (parsed.length === 0) {
          root.modelsError = "Could not read the OpenRouter model catalogue"
          return
        }
        root.models = parsed
        root.modelsFetchedAt = Date.now()
        root.modelsError = ""
      }
    }
    onExited: function (code) {
      root.modelsLoading = false
      if (code !== 0 && root.models.length === 0)
        root.modelsError = "Could not reach openrouter.ai (curl exit " + code + ")"
    }
  }

  Timer { id: copiedTimer; interval: 1600; repeat: false; onTriggered: root.copiedId = "" }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(460))
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function (dir) { root.switchPanel(dir) }

      Flickable {
        anchors.fill: parent
        contentWidth: width
        contentHeight: content.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        Column {
          id: content
          width: parent.width
          spacing: Style.space(12)

          // ---------------------------------------------------------- header
          Item {
            width: parent.width
            height: Math.max(titleCol.implicitHeight, refreshBtn.height)

            Column {
              id: titleCol
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)
              Text {
                text: "OpenRouter"
                color: root.neutralColor
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.title
                font.bold: true
              }
              Text {
                text: root.modelsLoading
                  ? "loading catalogue…"
                  : (root.creditUpdated ? "updated " + root.creditUpdated : "credit + model value ranking")
                color: Util.alpha(root.neutralColor, 0.55)
                font.pixelSize: Style.font.caption
              }
            }

            Rectangle {
              id: refreshBtn
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              width: refreshTxt.implicitWidth + Style.space(20)
              height: Style.spacing.controlHeight
              radius: height / 2
              color: refreshMouse.pressed
                ? Util.alpha(Color.accent, 0.30)
                : (refreshMouse.containsMouse ? Util.alpha(Color.accent, 0.16) : Util.alpha(root.neutralColor, 0.07))
              border.color: Util.alpha(root.neutralColor, 0.12)
              Text {
                id: refreshTxt
                anchors.centerIn: parent
                text: root.modelsLoading ? "⟳ …" : "↻ Refresh"
                color: root.neutralColor
                font.pixelSize: Style.font.caption
                font.bold: true
              }
              MouseArea {
                id: refreshMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.refreshAll()
              }
            }
          }

          // ----------------------------------------------------- balance card
          Rectangle {
            width: parent.width
            height: balanceCol.implicitHeight + Style.space(24)
            radius: Style.space(12)
            color: Util.alpha(root.neutralColor, 0.06)
            border.color: root.credit.error
              ? Util.alpha(root.badColor, 0.35)
              : Util.alpha(root.neutralColor, 0.10)

            Column {
              id: balanceCol
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.margins: Style.space(12)
              spacing: Style.space(4)

              Row {
                width: parent.width
                spacing: Style.space(8)
                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  text: {
                    if (!root.hasKey) return "—"
                    if (root.credit.error) return "!"
                    if (root.credit.remaining !== null) return Model.formatUsd(root.credit.remaining)
                    if (root.credit.limitRemaining !== null) return Model.formatUsd(root.credit.limitRemaining)
                    return "—"
                  }
                  color: root.credit.error ? root.badColor : root.neutralColor
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.display
                  font.bold: true
                }
                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  text: {
                    if (!root.hasKey || root.credit.error) return ""
                    if (root.credit.remaining !== null || root.credit.limitRemaining !== null) return "remaining"
                    return ""
                  }
                  color: Util.alpha(root.neutralColor, 0.55)
                  font.pixelSize: Style.font.caption
                }
                // Free-tier badge, straight off is_free_tier.
                Rectangle {
                  anchors.verticalCenter: parent.verticalCenter
                  visible: root.credit.ok && root.credit.isFreeTier
                  width: freeTxt.implicitWidth + Style.space(12)
                  height: Style.space(18)
                  radius: height / 2
                  color: Util.alpha(root.goodColor, 0.16)
                  border.color: Util.alpha(root.goodColor, 0.32)
                  Text {
                    id: freeTxt
                    anchors.centerIn: parent
                    text: "FREE TIER"
                    color: root.goodColor
                    font.pixelSize: Style.font.caption
                    font.bold: true
                  }
                }
              }

              // Usage / limit line, only when the numbers exist.
              Text {
                width: parent.width
                visible: root.credit.ok && (root.credit.remaining !== null || root.credit.totalCredits !== null || root.credit.totalUsage !== null || root.credit.limit !== null)
                text: {
                  var parts = []
                  if (root.credit.remaining !== null) parts.push("remaining " + Model.formatUsd(root.credit.remaining))
                  else if (root.credit.limitRemaining !== null) parts.push("remaining " + Model.formatUsd(root.credit.limitRemaining))
                  if (root.credit.totalCredits !== null) parts.push("credits " + Model.formatUsd(root.credit.totalCredits))
                  if (root.credit.totalUsage !== null) parts.push("used " + Model.formatUsd(root.credit.totalUsage))
                  else if (root.credit.usage !== null) parts.push("used " + Model.formatUsd(root.credit.usage))
                  if (root.credit.limit !== null) parts.push("limit " + Model.formatUsd(root.credit.limit))
                  if (root.credit.label) parts.push(root.credit.label)
                  return parts.join("  •  ")
                }
                color: Util.alpha(root.neutralColor, 0.55)
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }

              // Error text, verbatim from OpenRouter where possible.
              Text {
                width: parent.width
                visible: root.credit.error !== ""
                text: root.credit.error
                color: root.badColor
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }

              // Setup hint: the only thing worth saying when there is no key.
              Text {
                width: parent.width
                visible: !root.hasKey
                text: "No API key yet. Add one in the Settings box below, or export OPENROUTER_API_KEY. "
                  + "Create a key at openrouter.ai/settings/keys — the rankings below work without one."
                color: Util.alpha(root.neutralColor, 0.60)
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }
            }
          }

          // -------------------------------------------------- catalogue error
          Rectangle {
            visible: root.modelsError !== ""
            width: parent.width
            height: visible ? modelsErrTxt.implicitHeight + Style.space(14) : 0
            radius: Style.space(8)
            color: Util.alpha(root.badColor, 0.12)
            border.color: Util.alpha(root.badColor, 0.25)
            Text {
              id: modelsErrTxt
              anchors.centerIn: parent
              width: parent.width - Style.space(20)
              text: root.modelsError
              color: root.badColor
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
              horizontalAlignment: Text.AlignHCenter
            }
          }

          // ------------------------------------------------- section A: value
          Column {
            width: parent.width
            spacing: Style.space(4)
            Text {
              text: "Best value"
              color: root.neutralColor
              font.pixelSize: Style.font.subtitle
              font.bold: true
            }
            Text {
              width: parent.width
              text: Model.valueMethodText()
              color: Util.alpha(root.neutralColor, 0.50)
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          Column {
            width: parent.width
            spacing: Style.space(4)
            Repeater {
              model: root.valueList
              delegate: modelRow
            }
            Text {
              visible: root.valueList.length === 0
              width: parent.width
              text: root.modelsLoading ? "Loading models…" : "No models yet — hit Refresh"
              color: Util.alpha(root.neutralColor, 0.50)
              font.pixelSize: Style.font.caption
              horizontalAlignment: Text.AlignHCenter
            }
          }

          // ------------------------------------------------- section B: cheap
          // Free tier badge row, then cheapest paid underneath (your "above + underneath")
          Column {
            width: parent.width
            spacing: Style.space(4)
            Text {
              text: "Best cheap"
              color: root.neutralColor
              font.pixelSize: Style.font.subtitle
              font.bold: true
            }
            Text {
              width: parent.width
              text: Model.cheapMethodText()
              color: Util.alpha(root.neutralColor, 0.50)
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          // Free models — compact chips, tap to copy
          Column {
            width: parent.width
            spacing: Style.space(4)
            visible: root.freeList.length > 0
            Text {
              text: "Free  •  " + root.freeList.length + " models"
              color: Util.alpha(root.goodColor, 0.85)
              font.pixelSize: Style.font.caption
              font.bold: true
            }
            Flow {
              width: parent.width
              spacing: Style.space(6)
              Repeater {
                model: root.freeList
                delegate: Rectangle {
                  width: freeChipTxt.implicitWidth + Style.space(14)
                  height: Style.space(22)
                  radius: height / 2
                  color: root.copiedId === modelData.id ? Util.alpha(root.goodColor, 0.22) : Util.alpha(root.goodColor, 0.12)
                  border.color: Util.alpha(root.goodColor, 0.28)
                  Text {
                    id: freeChipTxt
                    anchors.centerIn: parent
                    text: root.copiedId === modelData.id ? "✓ copied" : Model.shortModelId(modelData.id)
                    color: root.goodColor
                    font.pixelSize: Style.font.caption
                    font.bold: true
                  }
                  MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.copyModelId(modelData.id)
                  }
                }
              }
            }
          }

          Column {
            width: parent.width
            spacing: Style.space(4)
            Text {
              text: "Cheapest paid"
              color: Util.alpha(root.neutralColor, 0.75)
              font.pixelSize: Style.font.caption
              font.bold: true
            }
            Text {
              width: parent.width
              text: Model.paidMethodText()
              color: Util.alpha(root.neutralColor, 0.45)
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          Column {
            width: parent.width
            spacing: Style.space(4)
            Repeater {
              model: root.paidList
              delegate: modelRow
            }
            Text {
              visible: root.paidList.length === 0 && root.freeList.length === 0
              width: parent.width
              text: root.modelsLoading ? "Loading models…" : "No models yet — hit Refresh"
              color: Util.alpha(root.neutralColor, 0.50)
              font.pixelSize: Style.font.caption
              horizontalAlignment: Text.AlignHCenter
            }
          }

          // ------------------------------------------------------- settings
          Text {
            text: "Settings"
            color: Util.alpha(root.neutralColor, 0.60)
            font.pixelSize: Style.font.caption
            font.bold: true
          }

          Rectangle {
            width: parent.width
            height: settingsCol.implicitHeight + Style.space(16)
            radius: Style.space(10)
            color: Util.alpha(root.neutralColor, 0.04)
            border.color: Util.alpha(root.neutralColor, 0.08)

            Column {
              id: settingsCol
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.margins: Style.space(10)
              spacing: Style.space(6)

              Row {
                spacing: Style.space(6)
                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(78)
                  text: "Refresh"
                  color: Util.alpha(root.neutralColor, 0.70)
                  font.pixelSize: Style.font.caption
                }
                Repeater {
                  model: root.chipModel([1, 5, 15, 30, 60], "refreshMinutes", root.refreshMinutes, "m")
                  delegate: chip
                }
              }

              Row {
                spacing: Style.space(6)
                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(78)
                  text: "Best value"
                  color: Util.alpha(root.neutralColor, 0.70)
                  font.pixelSize: Style.font.caption
                }
                Repeater {
                  model: root.chipModel([4, 6, 8, 12, 16], "valueCount", root.valueCount, "")
                  delegate: chip
                }
              }

              Row {
                spacing: Style.space(6)
                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(78)
                  text: "Best cheap"
                  color: Util.alpha(root.neutralColor, 0.70)
                  font.pixelSize: Style.font.caption
                }
                Repeater {
                  model: root.chipModel([4, 6, 8, 12, 16], "cheapCount", root.cheapCount, "")
                  delegate: chip
                }
              }

              // API key lives in the same Settings card as the chip rows.
              Row {
                width: parent.width
                spacing: Style.space(6)
                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(78)
                  text: "API key"
                  color: Util.alpha(root.neutralColor, 0.70)
                  font.pixelSize: Style.font.caption
                }

                // Collapsed: masked badge + Edit / Clear
                Row {
                  visible: root.hasKey && !root.keyEditMode
                  spacing: Style.space(6)
                  Rectangle {
                    width: Style.space(150)
                    height: Style.space(22)
                    radius: Style.space(8)
                    color: Util.alpha(root.goodColor, 0.10)
                    border.color: Util.alpha(root.goodColor, 0.22)
                    Text {
                      anchors.verticalCenter: parent.verticalCenter
                      anchors.left: parent.left
                      anchors.leftMargin: Style.space(8)
                      anchors.right: parent.right
                      anchors.rightMargin: Style.space(8)
                      text: Model.maskApiKey(root.apiKey)
                      color: root.goodColor
                      font.pixelSize: Style.font.caption
                      font.family: root.bar ? root.bar.fontFamily : Style.font.family
                      elide: Text.ElideMiddle
                    }
                  }
                  Rectangle {
                    id: settingsEditBtn
                    width: Style.space(44)
                    height: Style.space(22)
                    radius: Style.space(8)
                    color: settingsEditMouse.containsMouse ? Color.accent : Util.alpha(Color.accent, 0.85)
                    Text {
                      anchors.centerIn: parent
                      text: "Edit"
                      color: Color.background
                      font.pixelSize: Style.font.caption
                      font.bold: true
                    }
                    MouseArea {
                      id: settingsEditMouse
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: { root.keyEditMode = true; settingsKeyInput.text = ""; settingsKeyInput.forceActiveFocus() }
                    }
                  }
                  Rectangle {
                    width: Style.space(44)
                    height: Style.space(22)
                    radius: Style.space(8)
                    color: settingsClearCollapsedMouse.containsMouse ? Util.alpha(root.badColor, 0.18) : Util.alpha(root.neutralColor, 0.08)
                    border.color: Util.alpha(root.neutralColor, 0.10)
                    Text {
                      anchors.centerIn: parent
                      text: "Clear"
                      color: settingsClearCollapsedMouse.containsMouse ? root.badColor : Util.alpha(root.neutralColor, 0.70)
                      font.pixelSize: Style.font.caption
                    }
                    MouseArea {
                      id: settingsClearCollapsedMouse
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: { settingsKeyInput.text = ""; root.keyEditMode = false; root.persistSetting("apiKey", "") }
                    }
                  }
                }

                // Expanded: input + Save / Cancel
                Row {
                  visible: !root.hasKey || root.keyEditMode
                  spacing: Style.space(6)
                  Rectangle {
                    width: Style.space(150)
                    height: Style.space(22)
                    radius: Style.space(8)
                    color: Util.alpha(root.neutralColor, 0.06)
                    border.color: settingsKeyInput.activeFocus ? Color.accent : Util.alpha(root.neutralColor, 0.10)
                    TextInput {
                      id: settingsKeyInput
                      anchors.fill: parent
                      anchors.margins: Style.space(5)
                      verticalAlignment: TextInput.AlignVCenter
                      color: root.neutralColor
                      font.pixelSize: Style.font.caption
                      font.family: root.bar ? root.bar.fontFamily : Style.font.family
                      echoMode: TextInput.Password
                      clip: true
                      onAccepted: { root.saveKeyFromInput(); root.keyEditMode = false }
                      Text {
                        visible: settingsKeyInput.text === "" && !settingsKeyInput.activeFocus
                        anchors.verticalCenter: parent.verticalCenter
                        text: "sk-or-v1-…"
                        color: Util.alpha(root.neutralColor, 0.35)
                        font.pixelSize: Style.font.caption
                      }
                    }
                  }
                  Rectangle {
                    id: settingsSaveBtn
                    width: Style.space(44)
                    height: Style.space(22)
                    radius: Style.space(8)
                    color: settingsSaveMouse.containsMouse ? Color.accent : Util.alpha(Color.accent, 0.85)
                    Text {
                      anchors.centerIn: parent
                      text: "Save"
                      color: Color.background
                      font.pixelSize: Style.font.caption
                      font.bold: true
                    }
                    MouseArea {
                      id: settingsSaveMouse
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: { root.saveKeyFromInput(); root.keyEditMode = false }
                    }
                  }
                  Rectangle {
                    width: Style.space(44)
                    height: Style.space(22)
                    radius: Style.space(8)
                    color: settingsCancelMouse.containsMouse ? Util.alpha(root.neutralColor, 0.14) : Util.alpha(root.neutralColor, 0.08)
                    border.color: Util.alpha(root.neutralColor, 0.10)
                    Text {
                      anchors.centerIn: parent
                      text: root.hasKey ? "Cancel" : "Clear"
                      color: Util.alpha(root.neutralColor, 0.70)
                      font.pixelSize: Style.font.caption
                    }
                    MouseArea {
                      id: settingsCancelMouse
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: { settingsKeyInput.text = ""; if (root.hasKey) root.keyEditMode = false; else root.persistSetting("apiKey", "") }
                    }
                  }
                }
              }
            }
          }

          // Footer
          Column {
            width: parent.width
            spacing: Style.space(2)
            Text {
              width: parent.width
              text: "Click a row to copy the model id • Left-click bar toggles • Right-click refreshes • Middle-click opens openrouter.ai credits"
              color: Util.alpha(root.neutralColor, 0.40)
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
            Text {
              width: parent.width
              text: "Balance from /api/v1/auth/key. Rankings from the public /api/v1/models catalogue, refreshed at most every 6 h. "
                + "Prices are OpenRouter list prices per 1M tokens; ranking is a price heuristic, not a benchmark."
              color: Util.alpha(root.neutralColor, 0.35)
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }
        }
      }
    }
  }

  // Chips are plain data so one Component can serve all three settings rows.
  // Rebuilt whenever `current` changes, which is what re-highlights the pill.
  function chipModel(values, key, current, suffix) {
    var out = []
    for (var i = 0; i < values.length; i++) {
      out.push({
        value: values[i],
        key: key,
        label: String(values[i]) + (suffix || ""),
        active: values[i] === current
      })
    }
    return out
  }

  Component {
    id: chip
    Rectangle {
      required property var modelData
      width: chipTxt.implicitWidth + Style.space(16)
      height: Style.space(22)
      radius: height / 2
      color: modelData.active ? Color.accent : Util.alpha(root.neutralColor, 0.08)
      border.color: Util.alpha(root.neutralColor, 0.10)
      Text {
        id: chipTxt
        anchors.centerIn: parent
        text: modelData.label
        color: modelData.active ? Color.background : root.neutralColor
        font.pixelSize: Style.font.caption
        font.bold: modelData.active
      }
      MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: root.persistSetting(modelData.key, modelData.value)
      }
    }
  }

  function saveKeyFromInput() {
    var v = Model.normalizeApiKey(settingsKeyInput.text)
    if (!v) return
    root.persistSetting("apiKey", v)
    settingsKeyInput.text = ""
    if (root.hostWidget && root.hostWidget.fetchCredit) Qt.callLater(root.hostWidget.fetchCredit)
  }

  // One row shared by both lists. `index` inside a Repeater gives the rank.
  Component {
    id: modelRow
    Rectangle {
      id: row
      required property var modelData
      required property int index
      readonly property bool copied: root.copiedId === modelData.id

      width: parent ? parent.width : 0
      height: Style.space(44)
      radius: Style.space(8)
      color: copied
        ? Util.alpha(root.goodColor, 0.16)
        : (rowMouse.containsMouse ? Util.alpha(root.neutralColor, 0.10) : Util.alpha(root.neutralColor, 0.05))
      border.color: copied ? Util.alpha(root.goodColor, 0.35) : Util.alpha(root.neutralColor, 0.08)

      Row {
        anchors.fill: parent
        anchors.leftMargin: Style.space(10)
        anchors.rightMargin: Style.space(10)
        spacing: Style.space(8)

        Text {
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(20)
          text: (index + 1) + "."
          color: Util.alpha(root.neutralColor, 0.45)
          font.pixelSize: Style.font.caption
          horizontalAlignment: Text.AlignRight
        }

        Column {
          anchors.verticalCenter: parent.verticalCenter
          width: parent.width - Style.space(20) - priceCol.width - Style.space(24)
          spacing: Style.space(2)
          Text {
            width: parent.width
            text: Model.shortModelId(row.modelData.id)
            color: root.neutralColor
            font.pixelSize: Style.font.bodySmall
            font.bold: true
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            elide: Text.ElideRight
          }
          Text {
            width: parent.width
            text: row.modelData.vendor
              + "  •  " + Model.formatContext(row.modelData.contextLength) + " ctx"
              + (row.modelData.supportsTools ? "  •  tools" : "")
            color: Util.alpha(root.neutralColor, 0.50)
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }

        Column {
          id: priceCol
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(96)
          spacing: Style.space(2)
          Text {
            width: parent.width
            text: row.copied ? "copied ✓" : Model.priceHint(row.modelData)
            color: row.copied
              ? root.goodColor
              : (row.modelData.isFree ? root.goodColor : root.neutralColor)
            font.pixelSize: Style.font.bodySmall
            font.bold: true
            horizontalAlignment: Text.AlignRight
          }
          Text {
            width: parent.width
            text: Model.priceDetail(row.modelData)
            color: Util.alpha(root.neutralColor, 0.45)
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignRight
            elide: Text.ElideRight
          }
        }
      }

      MouseArea {
        id: rowMouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.copyModelId(row.modelData.id)
      }
    }
  }
}

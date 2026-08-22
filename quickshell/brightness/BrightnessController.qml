import Quickshell
import Quickshell.Io
import QtQml

QtObject {
  id: root

  property string scriptPath: Quickshell.shellDir + "/brightness-control.py"
  property int pollIntervalMs: 5000

  property ListModel monitors: ListModel {}
  property int gammaValue: 100
  property bool gammaAvailable: true

  Process {
    id: process
    stdout: StdioCollector {
      onStreamFinished: root.parseOutput(this.text)
    }
    stderr: StdioCollector {
      onStreamFinished: console.log("brightness-control stderr:", this.text)
    }
  }

  function run(args) {
    process.exec(args)
  }

  function refresh() {
    run(["python3", root.scriptPath, "poll"])
  }

  function setGamma(value) {
    run(["python3", root.scriptPath, "set", "gamma", String(value)])
    refreshSoon()
  }

  function setMonitor(index, value) {
    const mon = root.monitors.get(index)
    if (mon.control === "backlight") {
      run(["python3", root.scriptPath, "set", "backlight", mon.device, String(value)])
    } else if (mon.control === "ddcutil") {
      run(["python3", root.scriptPath, "set", "ddcutil", String(mon.bus), String(value)])
    }
    refreshSoon()
  }

  function refreshSoon() {
    refreshTimer.restart()
  }

  function parseOutput(text) {
    text = text.trim()
    if (!text) return
    let data
    try {
      data = JSON.parse(text)
    } catch (err) {
      console.log("brightness-control parse error:", text)
      return
    }
    if (!data || !data.monitors) return
    root.gammaValue = data.gamma.value
    root.gammaAvailable = data.gamma.available
    root.monitors.clear()
    for (const m of data.monitors) {
      root.monitors.append({
        name: m.name,
        model: m.model,
        label: m.label,
        control: m.control,
        device: m.device,
        bus: m.bus,
        value: m.value,
        supported: m.supported
      })
    }
  }

  Timer {
    id: refreshTimer
    interval: 1200
    repeat: false
    onTriggered: root.refresh()
  }

  Timer {
    id: pollTimer
    interval: root.pollIntervalMs
    running: true
    repeat: true
    onTriggered: root.refresh()
  }

  Component.onCompleted: root.refresh()
}

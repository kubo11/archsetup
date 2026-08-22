import Quickshell
import QtQuick
import QtQuick.Layouts

BrightnessController {
  id: controller
}

FloatingWindow {
  id: window
  title: "Brightness"

  color: "#1e1e2e"
  implicitWidth: 360
  implicitHeight: 24 + (1 + controller.monitors.count) * 50

  ColumnLayout {
    anchors.fill: parent
    anchors.margins: 12
    spacing: 6

    SliderRow {
      Layout.fillWidth: true
      label: "Gamma (global)"
      value: controller.gammaValue
      enabled: controller.gammaAvailable
      onSet: controller.setGamma(value)
    }

    Repeater {
      model: controller.monitors

      SliderRow {
        Layout.fillWidth: true
        label: model.label
        value: model.value
        enabled: model.supported
        onSet: controller.setMonitor(index, value)
      }
    }
  }
}

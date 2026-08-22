import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Item {
  id: root

  property string label: ""
  property real value: 0
  property bool enabled: true

  signal set(real value)

  implicitWidth: 320
  implicitHeight: 44

  ColumnLayout {
    anchors.fill: parent
    spacing: 2

    RowLayout {
      Layout.fillWidth: true
      spacing: 8

      Text {
        Layout.fillWidth: true
        text: root.label
        color: root.enabled ? "#ffffff" : "#888888"
        font.pixelSize: 13
        elide: Text.ElideRight
      }

      Text {
        text: root.value >= 0 ? Math.round(root.value) + "%" : "—"
        color: root.enabled ? "#ffffff" : "#888888"
        font.pixelSize: 12
      }
    }

    Slider {
      id: slider
      Layout.fillWidth: true
      from: 0
      to: 100
      stepSize: 1
      enabled: root.enabled
      onMoved: applyTimer.restart()

      background: Rectangle {
        x: slider.leftPadding
        y: slider.topPadding + slider.availableHeight / 2 - height / 2
        implicitWidth: 200
        implicitHeight: 4
        width: slider.availableWidth
        height: implicitHeight
        radius: 2
        color: "#4d4d4d"

        Rectangle {
          width: slider.visualPosition * parent.width
          height: parent.height
          radius: 2
          color: "#00ff99"
        }
      }

      handle: Rectangle {
        x: slider.leftPadding + slider.visualPosition * (slider.availableWidth - width)
        y: slider.topPadding + slider.availableHeight / 2 - height / 2
        implicitWidth: 16
        implicitHeight: 16
        radius: 8
        color: root.enabled ? "#ffffff" : "#666666"
        border.color: "#000000"
        border.width: 1
      }
    }
  }

  Timer {
    id: applyTimer
    interval: 150
    repeat: false
    onTriggered: root.set(slider.value)
  }

  onValueChanged: {
    if (!slider.pressed) slider.value = root.value
  }
  Component.onCompleted: slider.value = root.value
}

import QtQuick

Item {
  property bool blocked: false
  signal moveRequested(int dx, int dy)
  signal activateRequested()
  signal closeRequested()
  signal tabRequested(int direction)
  signal textKey(string text)
}

// A long read-only text the keyboard can walk: doctor's full report and the Startup Report. Tab
// reaches it, arrows and Page Up and Down move a caret a screen reader can follow, and the view
// keeps that caret on screen. Text from outside is plain text here, never markup.
import QtQuick
import org.kde.plasma.components as PlasmaComponents

PlasmaComponents.ScrollView {
    id: view

    required property string name
    property alias text: area.text
    readonly property alias area: area

    PlasmaComponents.ScrollBar.horizontal.policy: PlasmaComponents.ScrollBar.AlwaysOff

    PlasmaComponents.TextArea {
        id: area
        readOnly: true
        selectByKeyboard: true
        cursorVisible: activeFocus
        textFormat: TextEdit.PlainText
        wrapMode: TextEdit.Wrap
        font.family: "monospace"
        Accessible.name: view.name
        Accessible.multiLine: true

        onCursorRectangleChanged: {
            const flick = view.contentItem;
            if (cursorRectangle.y < flick.contentY) flick.contentY = cursorRectangle.y;
            else if (cursorRectangle.y + cursorRectangle.height > flick.contentY + flick.height)
                flick.contentY = cursorRectangle.y + cursorRectangle.height - flick.height;
        }
        Keys.onPressed: event => {
            if (event.key !== Qt.Key_PageDown && event.key !== Qt.Key_PageUp) return;
            const page = event.key === Qt.Key_PageDown ? view.height : -view.height;
            const to = positionAt(cursorRectangle.x, cursorRectangle.y + page);
            if (event.modifiers & Qt.ShiftModifier) moveCursorSelection(to);
            else cursorPosition = to;
            event.accepted = true;
        }
    }
}

"""A minimal Smalltalk IDE built on PySide6.

Layout: a System Browser on the left (classes → methods → source, with
*Accept* to compile a method), and on the right a Workspace (with *Do it* /
*Print it*) above a shared Transcript. All panes talk to one live
:class:`~st.system.Smalltalk` image, so defining a class in the browser makes
it immediately usable in the workspace.
"""

from __future__ import annotations

from PySide6.QtCore import Qt
from PySide6.QtGui import QAction, QFont, QKeySequence
from PySide6.QtWidgets import (
    QApplication,
    QButtonGroup,
    QHBoxLayout,
    QInputDialog,
    QLabel,
    QListWidget,
    QMainWindow,
    QMessageBox,
    QPlainTextEdit,
    QPushButton,
    QRadioButton,
    QSplitter,
    QVBoxLayout,
    QWidget,
)

from ide.highlighter import SmalltalkHighlighter
from st.bytecode import CompiledMethod
from st.objects import STError
from st.parser import ParseError
from st.system import Smalltalk

_SAMPLE = """"Welcome to small Smalltalk. Select an expression and press Ctrl-P (Print it)
or Ctrl-D (Do it). Output from Transcript appears below."

Transcript showCr: 'Hello, Smalltalk!'.

| sum |
sum := (1 to: 100) inject: 0 into: [:a :b | a + b].
Transcript showCr: 'Sum 1..100 = ', sum printString.

#(3 1 4 1 5 9 2 6) select: [:x | x > 3]
"""


def _mono() -> QFont:
    f = QFont("monospace")
    f.setStyleHint(QFont.StyleHint.Monospace)
    f.setPointSize(11)
    return f


class Workspace(QWidget):
    def __init__(self, window: MainWindow):
        super().__init__()
        self.window = window
        layout = QVBoxLayout(self)
        layout.setContentsMargins(4, 4, 4, 4)

        bar = QHBoxLayout()
        bar.addWidget(QLabel("<b>Workspace</b>"))
        bar.addStretch()
        for text, slot in (
            ("Do it  (Ctrl-D)", self.do_it),
            ("Print it  (Ctrl-P)", self.print_it),
        ):
            btn = QPushButton(text)
            btn.clicked.connect(slot)
            bar.addWidget(btn)
        layout.addLayout(bar)

        self.editor = QPlainTextEdit()
        self.editor.setFont(_mono())
        self.editor.setPlainText(_SAMPLE)
        SmalltalkHighlighter(self.editor.document())
        layout.addWidget(self.editor)

    def _selected_source(self) -> str:
        cursor = self.editor.textCursor()
        text = cursor.selectedText().replace(" ", "\n")
        return text if text.strip() else self.editor.toPlainText()

    def do_it(self) -> None:
        src = self._selected_source()
        try:
            self.window.st.eval(src)
        except (STError, ParseError) as e:
            self.window.report_error(e)
        except Exception as e:  # noqa: BLE001
            self.window.report_error(e)

    def print_it(self) -> None:
        src = self._selected_source()
        try:
            result = self.window.st.eval_to_string(src)
        except (STError, ParseError) as e:
            self.window.report_error(e)
            return
        except Exception as e:  # noqa: BLE001
            self.window.report_error(e)
            return
        cursor = self.editor.textCursor()
        cursor.clearSelection()
        cursor.insertText(" " + result)


class SystemBrowser(QWidget):
    def __init__(self, window: MainWindow):
        super().__init__()
        self.window = window
        layout = QVBoxLayout(self)
        layout.setContentsMargins(4, 4, 4, 4)

        header = QHBoxLayout()
        header.addWidget(QLabel("<b>System Browser</b>"))
        header.addStretch()
        new_cls = QPushButton("New Class")
        new_cls.clicked.connect(self.new_class)
        header.addWidget(new_cls)
        layout.addLayout(header)

        cols = QHBoxLayout()
        self.class_list = QListWidget()
        self.class_list.currentTextChanged.connect(self._on_class_selected)
        cols.addWidget(self.class_list, 1)

        right = QVBoxLayout()
        side = QHBoxLayout()
        self.instance_side = QRadioButton("instance")
        self.class_side = QRadioButton("class")
        self.instance_side.setChecked(True)
        group = QButtonGroup(self)
        group.addButton(self.instance_side)
        group.addButton(self.class_side)
        self.instance_side.toggled.connect(self._refresh_methods)
        side.addWidget(self.instance_side)
        side.addWidget(self.class_side)
        side.addStretch()
        right.addLayout(side)

        self.method_list = QListWidget()
        self.method_list.currentTextChanged.connect(self._on_method_selected)
        right.addWidget(self.method_list, 1)
        cols.addLayout(right, 1)
        layout.addLayout(cols, 1)

        self.source = QPlainTextEdit()
        self.source.setFont(_mono())
        SmalltalkHighlighter(self.source.document())
        layout.addWidget(self.source, 1)

        accept = QPushButton("Accept  (Ctrl-S)")
        accept.clicked.connect(self.accept_method)
        layout.addWidget(accept)

        self.refresh_classes()

    # --- data refresh ---

    def refresh_classes(self) -> None:
        current = self.class_list.currentItem()
        name = current.text() if current else None
        self.class_list.blockSignals(True)
        self.class_list.clear()
        for cls_name in sorted(self.window.st.vm.classes):
            self.class_list.addItem(cls_name)
        self.class_list.blockSignals(False)
        if name:
            items = self.class_list.findItems(name, Qt.MatchFlag.MatchExactly)
            if items:
                self.class_list.setCurrentItem(items[0])
                return
        if self.class_list.count():
            self.class_list.setCurrentRow(0)

    def _current_class(self):
        item = self.class_list.currentItem()
        if item is None:
            return None
        return self.window.st.vm.classes.get(item.text())

    def _on_class_selected(self, _name: str) -> None:
        self._refresh_methods()
        cls = self._current_class()
        if cls is not None and self.method_list.count() == 0:
            self.source.setPlainText(self._method_template(cls))

    def _refresh_methods(self) -> None:
        cls = self._current_class()
        self.method_list.clear()
        if cls is None:
            return
        table = cls.class_methods if self.class_side.isChecked() else cls.methods
        for selector in sorted(table):
            self.method_list.addItem(selector)

    def _on_method_selected(self, selector: str) -> None:
        cls = self._current_class()
        if cls is None or not selector:
            return
        table = cls.class_methods if self.class_side.isChecked() else cls.methods
        method = table.get(selector)
        if isinstance(method, CompiledMethod) and method.source:
            self.source.setPlainText(method.source)
        elif isinstance(method, CompiledMethod):
            self.source.setPlainText(f'"{selector}"\n"(no stored source)"')
        else:
            self.source.setPlainText(
                f'"{selector} — primitive"\n"{disassemble_hint(method)}"'
            )

    def _method_template(self, cls) -> str:
        return (
            f'"Define a method on {cls.name}"\n'
            "exampleSelector\n"
            "    ^self"
        )

    # --- actions ---

    def new_class(self) -> None:
        name, ok = QInputDialog.getText(self, "New Class", "Class name:")
        if not ok or not name.strip():
            return
        superclass, ok = QInputDialog.getText(
            self, "New Class", "Superclass:", text="Object"
        )
        if not ok:
            return
        ivars, ok = QInputDialog.getText(
            self, "New Class", "Instance variables (space-separated):"
        )
        if not ok:
            return
        try:
            self.window.st.define_class(
                name.strip(),
                superclass.strip() or "Object",
                ivars.split(),
            )
        except ValueError as e:
            QMessageBox.warning(self, "New Class", str(e))
            return
        self.window.transcript.log(f'Defined class {name.strip()}')
        self.refresh_classes()
        items = self.class_list.findItems(
            name.strip(), Qt.MatchFlag.MatchExactly
        )
        if items:
            self.class_list.setCurrentItem(items[0])

    def accept_method(self) -> None:
        cls = self._current_class()
        if cls is None:
            QMessageBox.information(self, "Accept", "Select a class first.")
            return
        source = self.source.toPlainText()
        try:
            method = self.window.st.define_method(
                cls.name, source, class_side=self.class_side.isChecked()
            )
        except (ParseError, STError, ValueError) as e:
            self.window.report_error(e)
            return
        self.window.transcript.log(
            f"Compiled {cls.name}"
            f"{' class' if self.class_side.isChecked() else ''}>>"
            f"{method.selector}"
        )
        self._refresh_methods()
        items = self.method_list.findItems(
            method.selector, Qt.MatchFlag.MatchExactly
        )
        if items:
            self.method_list.setCurrentItem(items[0])


def disassemble_hint(method) -> str:
    return "primitive (implemented in Python)"


class Transcript(QWidget):
    def __init__(self):
        super().__init__()
        layout = QVBoxLayout(self)
        layout.setContentsMargins(4, 4, 4, 4)
        layout.addWidget(QLabel("<b>Transcript</b>"))
        self.view = QPlainTextEdit()
        self.view.setReadOnly(True)
        self.view.setFont(_mono())
        layout.addWidget(self.view)

    def write(self, text: str) -> None:
        self.view.moveCursor(self.view.textCursor().MoveOperation.End)
        self.view.insertPlainText(text)
        self.view.moveCursor(self.view.textCursor().MoveOperation.End)

    def log(self, text: str) -> None:
        self.write(f"[ide] {text}\n")


class MainWindow(QMainWindow):
    def __init__(self):
        super().__init__()
        self.setWindowTitle("small Smalltalk IDE")
        self.resize(1100, 720)
        self.st = Smalltalk()

        self.transcript = Transcript()
        self.st.vm.output = self.transcript.write  # route Transcript output

        self.browser = SystemBrowser(self)
        self.workspace = Workspace(self)

        right = QSplitter(Qt.Orientation.Vertical)
        right.addWidget(self.workspace)
        right.addWidget(self.transcript)
        right.setSizes([440, 240])

        main = QSplitter(Qt.Orientation.Horizontal)
        main.addWidget(self.browser)
        main.addWidget(right)
        main.setSizes([460, 640])
        self.setCentralWidget(main)

        self._make_shortcuts()
        self.statusBar().showMessage("Ready")

    def _make_shortcuts(self) -> None:
        specs = [
            ("Do it", "Ctrl+D", self.workspace.do_it),
            ("Print it", "Ctrl+P", self.workspace.print_it),
            ("Accept", "Ctrl+S", self.browser.accept_method),
        ]
        for name, key, slot in specs:
            act = QAction(name, self)
            act.setShortcut(QKeySequence(key))
            act.triggered.connect(slot)
            self.addAction(act)

    def report_error(self, err: Exception) -> None:
        msg = f"{type(err).__name__}: {err}"
        self.transcript.write(msg + "\n")
        self.statusBar().showMessage(msg, 8000)


def run_ide() -> None:
    app = QApplication.instance() or QApplication([])
    window = MainWindow()
    window.show()
    app.exec()


if __name__ == "__main__":
    run_ide()

#!/usr/bin/env python3
"""Test helper: a full-screen GTK 4 window on the Wayland test session.

Red until the file argv[2] exists, then green. Every pointer, button, scroll
and key event it receives is written to the log argv[1], one per line:
    motion X Y | press BUTTON X Y | release BUTTON X Y | scroll DX DY |
    key CHAR-OR-NAME
"""
import os
import sys

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Gdk", "4.0")
from gi.repository import Gdk, GLib, Gtk  # noqa: E402

log_path, signal_path = sys.argv[1], sys.argv[2]
log = open(log_path, "w", buffering=1)


def write(line):
    log.write(line + "\n")


css = Gtk.CssProvider()
css.load_from_data(
    b"window.red { background: #ff0000; } window.green { background: #00ff00; }", -1
)
Gtk.StyleContext.add_provider_for_display(
    Gdk.Display.get_default(), css, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
)


def on_activate(app):
    win = Gtk.ApplicationWindow(application=app, title="PairDesk test")
    win.add_css_class("red")
    win.set_decorated(False)

    motion = Gtk.EventControllerMotion()
    motion.connect("motion", lambda c, x, y: write(f"motion {round(x)} {round(y)}"))
    win.add_controller(motion)

    click = Gtk.GestureClick(button=0)
    click.connect(
        "pressed", lambda g, n, x, y: write(f"press {g.get_current_button()} {round(x)} {round(y)}")
    )
    click.connect(
        "released", lambda g, n, x, y: write(f"release {g.get_current_button()} {round(x)} {round(y)}")
    )
    win.add_controller(click)

    scroll = Gtk.EventControllerScroll(flags=Gtk.EventControllerScrollFlags.BOTH_AXES)
    scroll.connect("scroll", lambda c, dx, dy: write(f"scroll {round(dx)} {round(dy)}") or True)
    win.add_controller(scroll)

    keys = Gtk.EventControllerKey()

    def key(c, keyval, code, state):
        ch = chr(Gdk.keyval_to_unicode(keyval)) if Gdk.keyval_to_unicode(keyval) else ""
        name = Gdk.keyval_name(keyval) or "?"
        ctrl = "ctrl+" if state & Gdk.ModifierType.CONTROL_MASK else ""
        write(f"key {ctrl}{ch if ch.isprintable() and ch else name}")

    keys.connect("key-pressed", key)
    win.add_controller(keys)

    clipboard = Gdk.Display.get_default().get_clipboard()

    def got_text(cb, res):
        try:
            write(f"clipboard {cb.read_text_finish(res)}")
        except Exception as e:  # noqa: BLE001
            write(f"clipboard error {e}")

    clipboard.connect("changed", lambda cb: cb.read_text_async(None, got_text))
    copied = [False]

    def poll():
        if os.path.exists(signal_path) and win.has_css_class("red"):
            win.remove_css_class("red")
            win.add_css_class("green")
        if not copied[0] and os.path.exists(signal_path + ".clip"):
            copied[0] = True
            clipboard.set("copied in gtk")
        return True

    GLib.timeout_add(50, poll)
    win.fullscreen()
    win.present()
    write("ready")


app = Gtk.Application(application_id="me.madhushan.pairdesk.WaylandTest")
app.connect("activate", on_activate)
app.run([])

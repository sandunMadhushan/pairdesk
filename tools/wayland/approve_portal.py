#!/usr/bin/env python3
"""Test helper: answers GNOME's "Remote Desktop" portal dialog like a person
would (tick Allow Remote Interaction, pick the screen, Share), through the
accessibility bus. Exits 0 once it has clicked Share, 2 if no dialog showed
up within the timeout (used to check that a remembered session doesn't ask).

    approve_portal.py [timeout-seconds] [--cancel]
"""
import sys
import time

import gi
import gi.repository.GLib

gi.require_version("Atspi", "2.0")
from gi.repository import Atspi  # noqa: E402

timeout = float(sys.argv[1]) if len(sys.argv) > 1 and not sys.argv[1].startswith("-") else 30
cancel = "--cancel" in sys.argv


def walk(o):
    try:
        yield o
        for i in range(o.get_child_count()):
            c = o.get_child_at_index(i)
            if c is not None:
                yield from walk(c)
    except Exception:
        return


def dialog():
    desktop = Atspi.get_desktop(0)
    for i in range(desktop.get_child_count()):
        try:
            app = desktop.get_child_at_index(i)
            if app is None or app.get_name() != "xdg-desktop-portal-gnome":
                continue
            for o in walk(app):
                if o.get_role_name() == "frame" and o.get_name() == "Remote Desktop":
                    return o
        except Exception:  # noqa: BLE001 - an app that went away
            continue
    return None


def act(o, name):
    a = o.get_action_iface()
    for i in range(a.get_n_actions()):
        if a.get_action_name(i) == name:
            return a.do_action(i)
    return a.do_action(0)


def is_(o, state):
    return o.get_state_set().contains(state)


def step():
    """One look at the screen; returns True once the dialog is answered."""
    global clicked
    d = dialog()
    if d is None:
        if clicked:
            return True
        time.sleep(0.2)
        return False
    time.sleep(0.5)  # let it finish building
    items = list(walk(d))
    if cancel:
        act(next(o for o in items if o.get_role_name() == "push button" and o.get_name() == "Cancel"), "click")
        clicked = True
        time.sleep(0.5)
        return False
    for o in items:
        role, name = o.get_role_name(), o.get_name()
        checked = is_(o, Atspi.StateType.CHECKED) or is_(o, Atspi.StateType.PRESSED)
        if role == "check box" and name == "Allow Remote Interaction" and not checked:
            act(o, "toggle")
        elif role == "toggle button" and not checked:
            act(o, "click")  # the screen to share
    time.sleep(0.5)
    share = next(o for o in walk(d) if o.get_role_name() == "push button" and o.get_name() == "Share")
    if is_(share, Atspi.StateType.SENSITIVE):
        act(share, "click")
        clicked = True
    time.sleep(1)
    return False


deadline = time.time() + timeout
clicked = False
while time.time() < deadline:
    try:
        if step():
            print("cancelled the portal dialog" if cancel else "approved the portal dialog")
            sys.exit(0)
    except (gi.repository.GLib.Error, StopIteration):
        # The dialog went away while being read (e.g. just answered).
        time.sleep(0.2)
print("no portal dialog" if not clicked else "the portal dialog didn't close")
sys.exit(2)

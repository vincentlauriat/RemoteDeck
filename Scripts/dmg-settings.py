# dmgbuild settings for the release DMG, read by Scripts/release.sh.
#
# dmgbuild writes the Finder layout (.DS_Store) itself, so the DMG gets its
# background and icon positions without scripting Finder through AppleScript,
# which needs Apple Events and can silently produce a DMG without a layout.
#
# Values come in through `-D`: app (the signed .app) and background (the PNG
# made by make-dmg-background.swift, 540 x 380 like the window below).
import os

app = defines["app"]  # noqa: F821 — injected by dmgbuild
app_name = os.path.basename(app)

files = [app]
symlinks = {"Applications": "/Applications"}

format = "UDZO"
compression_level = 9
filesystem = "HFS+"

background = defines["background"]  # noqa: F821
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
window_rect = ((200, 100), (540, 380))
default_view = "icon-view"
arrange_by = None
icon_size = 128
icon_locations = {app_name: (140, 200), "Applications": (400, 200)}

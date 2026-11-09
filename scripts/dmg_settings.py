# dmgbuild settings for the AirDoxx installer window.
# Used by scripts/build_app.sh --release when dmgbuild is available (pip install dmgbuild).
import os

app = defines["app"]            # path to AirDoxx.app
background_path = defines["background"]

files = [app]
symlinks = {"Applications": "/Applications"}
icon_locations = {os.path.basename(app): (165, 190), "Applications": (495, 190)}

format = "UDZO"
filesystem = "HFS+"
background = background_path
# Finder counts the title bar in the window height: 400 pt of background + ~28 pt title bar.
window_rect = ((200, 160), (660, 428))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 112
text_size = 13
include_icon_view_settings = True

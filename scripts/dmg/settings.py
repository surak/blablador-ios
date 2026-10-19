# dmgbuild settings for the Blablador installer window.
# Usage (via scripts/make-dmg.sh): dmgbuild -s settings.py -D app=/path/Blablador.app -D background=bg.png Blablador out.dmg
import os

app = defines["app"]
app_name = os.path.basename(app)

format = "UDZO"
filesystem = "HFS+"
files = [app]
symlinks = {"Applications": "/Applications"}

icon = os.path.join(app, "Contents", "Resources", "AppIcon.icns")
background = defines["background"]

window_rect = ((200, 120), (640, 400))
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
default_view = "icon-view"
show_icon_preview = False
include_icon_view_settings = True

icon_size = 128
text_size = 13
arrange_by = None
icon_locations = {
    app_name: (170, 200),
    "Applications": (470, 200),
}
hide_extensions = [app_name]

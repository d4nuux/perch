# dmgbuild settings for the Perch installer window.
# Run via tools/release.sh: dmgbuild -s tools/dmg/settings.py -D app=build/Perch.app Perch out.dmg
import os

app = defines.get("app", "build/Perch.app")  # noqa: F821 (provided by dmgbuild)
here = os.path.abspath("tools/dmg")  # dmgbuild execs this file without __file__; run from the repo root

format = "UDZO"
filesystem = "HFS+"
files = [app]
symlinks = {"Applications": "/Applications"}
icon = os.path.join(here, "..", "..", "Resources", "AppIcon.icns")

background = defines.get("background", os.path.join(here, "build", "background.png"))  # noqa: F821
window_rect = ((200, 140), (640, 428))  # frame size: 400pt content + 28pt title bar
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False

icon_size = 104
text_size = 13
arrange_by = None
icon_locations = {
    "Perch.app": (160, 200),
    "Applications": (480, 200),
}
hide_extension = ["Perch.app"]

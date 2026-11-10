"""Finder layout written directly into the image, without automating Finder."""
import os

application = defines["app"]
files = [application, (defines["instructions"], "First Launch.txt")]
symlinks = {"Applications": "/Applications"}
format = "UDZO"
filesystem = "HFS+"
icon = os.path.join(application, "Contents", "Resources", "AppIcon.icns")
background = defines["background"]
window_rect = ((160, 160), (720, 470))
icon_locations = {
    "Kinara.app": (205, 218),
    "Applications": (515, 218),
    "First Launch.txt": (625, 373),
}
# Do not set FinderInfo on the app bundle: strict code-signature verification
# rejects that extended attribute. Finder handles application extensions itself.
hide_extensions = ["First Launch.txt"]
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
include_icon_view_settings = True
include_list_view_settings = False
arrange_by = None
grid_offset = (0, 0)
grid_spacing = 64
scroll_position = (0, 0)
label_pos = "bottom"
text_size = 13
icon_size = 96
show_icon_preview = False
show_item_info = False

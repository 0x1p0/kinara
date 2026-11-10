"""Check actual mounted Finder metadata, not just the source configuration."""
import pathlib
import plistlib
import sys

from ds_store import DSStore

volume = pathlib.Path(sys.argv[1])
with DSStore.open(str(volume / ".DS_Store"), "r") as store:
    window = store["."]["bwsp"]
    view = store["."]["icvp"]
    assert window["WindowBounds"] == "{{160, 160}, {720, 470}}", window
    for key in ("ShowStatusBar", "ShowTabView", "ShowToolbar", "ShowPathbar", "ShowSidebar"):
        assert not window[key], key
    assert view["backgroundType"] == 2
    assert view["backgroundImageAlias"]
    assert view["iconSize"] == 96
    assert view["arrangeBy"] == "none"
    for name, position in {"Kinara.app": (205, 218), "Applications": (515, 218),
                           "First Launch.txt": (625, 373)}.items():
        assert tuple(store[name]["Iloc"]) == position, name
    assert store["."]["icvl"] == (b"type", b"icnv")
assert (volume / ".background.tiff").stat().st_size > 0
assert (volume / ".VolumeIcon.icns").stat().st_size > 0
with (volume / "Kinara.app/Contents/Info.plist").open("rb") as file:
    assert plistlib.load(file)["CFBundleExecutable"] == "Kinara"
print("Verified Finder window, background, volume icon, and all three file positions.")

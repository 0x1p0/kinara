import importlib.util
from pathlib import Path
import stat
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("archive", ROOT / "scripts/safe-app-archive.py")
archive = importlib.util.module_from_spec(spec)
spec.loader.exec_module(archive)
checks = 0

with tempfile.TemporaryDirectory(prefix="sway-archive-tests.") as temporary:
    root = Path(temporary)

    def check(entries, accepted):
        global checks
        checks += 1
        path = root / f"{checks}.zip"
        with zipfile.ZipFile(path, "w") as output:
            for name, mode, content in entries:
                entry = zipfile.ZipInfo(name)
                entry.create_system = 3
                entry.external_attr = mode << 16
                output.writestr(entry, content)
        try:
            archive.extract(path, root / f"extracted-{checks}")
        except Exception:
            assert not accepted, "valid archive rejected"
        else:
            assert accepted, "unsafe archive accepted"

    file, directory, link = stat.S_IFREG | 0o644, stat.S_IFDIR | 0o755, stat.S_IFLNK | 0o777
    base = [("Kinara.app/", directory, ""), ("Kinara.app/Contents/file", file, "safe")]
    check(base, True)
    check(base + [("Kinara.app/alias", link, "Contents/file")], True)
    for entry in [
        ("../outside", file, "bad"), ("/absolute", file, "bad"), ("Other.app/file", file, "bad"),
        ("Kinara.app/../outside", file, "bad"), ("Kinara.app//duplicate", file, "bad"),
        ("Kinara.app/CONTENTS/FILE", file, "bad"), ("Kinara.app/pipe", stat.S_IFIFO | 0o644, "bad"),
        ("Kinara.app/setuid", file | stat.S_ISUID, "bad"), ("Kinara.app/link", link, "/Applications"),
        ("Kinara.app/link", link, "../../outside"), ("Kinara.app/link", link, "missing"),
    ]:
        check(base + [entry], False)
    check(base + [("Kinara.app/link", link, "Contents"), ("Kinara.app/link/file2", file, "bad")], False)
    check(base + [("Kinara.app/one", link, "two"), ("Kinara.app/two", link, "one")], False)
    check([("Kinara.app", link, "elsewhere")], False)
    check([], False)

print(f"{checks} bounded-archive assertions passed; no app code executed.")

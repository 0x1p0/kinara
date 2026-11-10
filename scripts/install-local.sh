#!/bin/bash
# Build, sign with the persistent identity, and replace /Applications/Kinara.app.
# The pinned designated requirement stays the same across builds, so macOS keeps
# the Accessibility permission. Reads the identity from the maintainer's login
# Keychain, never changes TCC, and moves the old copy to the Trash.
set -euo pipefail

script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_directory="$(cd -- "$script_directory/.." && pwd)"
cd "$project_directory"
installed=/Applications/Kinara.app

bash scripts/build.sh "$@"
python3 scripts/app-signing.py sign build/Kinara.app
codesign --verify --deep --strict build/Kinara.app

osascript -e 'tell application "Kinara" to quit' >/dev/null 2>&1 || true
for _ in $(seq 1 20); do
    pgrep -x Kinara >/dev/null || break
    sleep 0.5
done
if pgrep -x Kinara >/dev/null; then
    printf 'Kinara did not quit; nothing was replaced.\n' >&2
    exit 1
fi
# Finder may refuse automation, so move the old copy with mv rather than ditto
# over it: an in-place overwrite mixes old and new files.
if [[ -e "$installed" ]]; then
    mv "$installed" "$HOME/.Trash/Kinara $(date '+%Y-%m-%d %H.%M.%S').app"
fi
ditto build/Kinara.app "$installed"
python3 scripts/app-signing.py verify "$installed"
open "$installed"

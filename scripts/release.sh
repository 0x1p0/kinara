#!/bin/bash
# Cuts a Kinara release from main: sets the version, checks the release notes,
# builds, then commits, tags and pushes main and the tag together. Pushing the
# tag starts the Release workflow, which builds, signs and publishes the
# release after two approvals in GitHub.
#
#   bash scripts/release.sh 1.0.1             # prepare and push v1.0.1
#   bash scripts/release.sh 1.0.1 --dry-run   # every check and the build, then undo; nothing is committed or pushed
#
# The first run for a new version writes releases/v<version>.md from the
# changes since the last release and stops, so a person writes the notes.
set -euo pipefail
script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_directory="$(cd -- "$script_directory/.." && pwd)"
cd "$project_directory"

fail() { printf '%s\n' "$1" >&2; exit 2; }
version="${1:-}"
dry_run=false
[[ "${2:-}" == "--dry-run" ]] && dry_run=true
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "Usage: bash scripts/release.sh <major.minor.patch> [--dry-run]"
tag="v$version"
plist=Kinara/Info.plist
project=Kinara.xcodeproj/project.pbxproj
notes="releases/$tag.md"

# Only an up-to-date main, with nothing else uncommitted, becomes a release.
[[ "$(git rev-parse --abbrev-ref HEAD)" == main ]] || fail "Switch to main first."
[[ -z "$(git status --porcelain --untracked-files=no -- . ":!$notes")" ]] || fail "Commit or set aside your other changes first."
git fetch --quiet origin main --tags
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || fail "main isn't the same as origin/main. Pull or push first."
git rev-parse -q --verify "refs/tags/$tag" >/dev/null && fail "$tag already exists. A tag is never reused; choose a new version."
last="$(git tag --list 'v[0-9]*' --sort=-v:refname | head -n 1)"
current="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")"
# Never backwards: not below the last release, nor below the version main already has.
for floor in "${last#v}" "$current"; do
    [[ -z "$floor" ]] && continue
    newest="$(printf '%s\n%s\n' "$floor" "$version" | sort -V | tail -n 1)"
    [[ "$newest" == "$version" ]] || fail "$tag is older than $floor."
done
[[ -z "$last" || "${last#v}" != "$version" ]] || fail "$tag is already released."

# Release notes are written by a person: start them, and stop.
if [[ ! -s "$notes" ]]; then
    {
        printf '# Kinara %s\n\n- \n\n' "$version"
        printf '<!-- Changes since %s; delete this comment.\n' "${last:-the beginning}"
        git log --no-merges --format='  %s' "${last:+$last..}HEAD"
        printf -- '-->\n'
    } > "$notes"
    fail "Started $notes from the changes since ${last:-the beginning}. Write the notes there, then run this again."
fi
grep -qE '^- *$|<!-- Changes since' "$notes" && fail "$notes still has the starting template in it. Finish the notes first."

build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")"
[[ "$build" =~ ^[0-9]+$ ]] || fail "CFBundleVersion must be a whole number."
restore() { git checkout --quiet -- "$plist" "$project"; }
if [[ "$current" != "$version" ]]; then
    # Updates compare the build number, so every release raises it by one.
    # Edits only the two values, so the file keeps its formatting.
    VERSION="$version" BUILD="$((build + 1))" perl -0pi -e \
        's{(<key>CFBundleShortVersionString</key>\s*<string>)[^<]*}{$1$ENV{VERSION}}; s{(<key>CFBundleVersion</key>\s*<string>)[^<]*}{$1$ENV{BUILD}}' "$plist"
    sed -i '' "s/MARKETING_VERSION = $current;/MARKETING_VERSION = $version;/g" "$project"
    $dry_run && trap restore EXIT
fi
bash scripts/release-version.sh "$tag" > /dev/null
printf 'Building %s to check it compiles…\n' "$tag"
mkdir -p build
if ! bash scripts/build.sh > build/release-check.log 2>&1; then
    tail -n 20 build/release-check.log >&2
    fail "The build failed; nothing was committed or pushed. Full log: build/release-check.log"
fi

if $dry_run; then
    printf 'Dry run passed for %s. Nothing was committed, tagged or pushed.\n' "$tag"
    exit 0
fi
git add "$plist" "$project" "$notes"
git diff --cached --quiet || git commit --quiet -m "Kinara $version"
git tag -a "$tag" -m "Kinara $version"
git push --atomic origin main "$tag"
printf '\nPushed %s. In GitHub, open Actions → Release, and approve the two "release" steps\n' "$tag"
printf 'after looking over the run: first app signing, then signing the update and publishing.\n'

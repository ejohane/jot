#!/bin/sh
# Install the latest published Jot without developer tools or dependencies.
set -eu

fail() { printf '%s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = Darwin ] || fail 'Jot requires macOS.'
[ "$(sw_vers -productVersion | cut -d. -f1)" -ge 14 ] || fail 'Jot requires macOS 14 or newer.'

if [ -n "${JOT_INSTALL_DIR:-}" ]; then
    install_dir=$JOT_INSTALL_DIR
else
    [ -n "${HOME:-}" ] || fail 'HOME must be set to install Jot.'
    install_dir=$HOME/Applications
fi
case "$install_dir" in /*) ;; *) fail 'JOT_INSTALL_DIR must be an absolute path.' ;; esac
mkdir -p "$install_dir"
[ -w "$install_dir" ] || fail "Cannot write to $install_dir. Set JOT_INSTALL_DIR to a writable absolute path and run again."

work=$(mktemp -d)
stage=''
cleanup() {
    if [ -n "$stage" ]; then
        if [ -d "$stage/previous.app" ] && [ ! -e "$install_dir/Jot.app" ]; then
            mv "$stage/previous.app" "$install_dir/Jot.app"
        fi
        rm -rf "$stage"
    fi
    rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

# Resolve the release once so a concurrent publication cannot mix assets.
repo=https://github.com/ejohane/jot
release_url=$(curl -fsSL --proto '=https' --proto-redir '=https' --retry 3 -o /dev/null -w '%{url_effective}' "$repo/releases/latest")
case "$release_url" in "$repo"/releases/tag/v*) ;; *) fail 'Could not resolve the latest Jot release.' ;; esac
version=${release_url##*/}
case "$version" in *[!v0-9.]*|v) fail 'Unexpected release version.' ;; esac
printf 'Downloading Jot %s…\n' "$version"
for asset in Jot.zip Jot.zip.sha256; do
    curl -fsSL --proto '=https' --proto-redir '=https' --retry 3 "$repo/releases/download/$version/$asset" -o "$work/$asset"
done
(cd "$work" && shasum -a 256 -c Jot.zip.sha256)
ditto -x -k "$work/Jot.zip" "$work"
codesign --verify --deep --strict -R '=anchor apple generic and identifier "com.erikjohansson.Jot" and certificate leaf[subject.OU] = "TRA7965NM5"' "$work/Jot.app"
spctl --assess --type execute "$work/Jot.app"

# Let Jot flush its note normally instead of terminating a running session.
if pgrep -x Jot >/dev/null; then
    fail 'Quit Jot with Command-Q, then run this installer again. You can also use Jot → Check for Updates….'
fi
[ ! -L "$install_dir/Jot.app" ] || fail 'The existing Jot.app is a symbolic link; move it before installing.'
stage=$(mktemp -d "$install_dir/.jot-install.XXXXXX")
ditto "$work/Jot.app" "$stage/Jot.app"
if [ -e "$install_dir/Jot.app" ]; then
    mv "$install_dir/Jot.app" "$stage/previous.app"
fi
mv "$stage/Jot.app" "$install_dir/Jot.app"
printf 'Installed Jot %s in %s.\n' "$version" "$install_dir"
open "$install_dir/Jot.app"

#!/bin/zsh
set -eu
cd "${0:A:h}"
# Stage outside Documents: File Provider adds Finder metadata to .app directories there.
stage_dir=$(mktemp -d "${TMPDIR:-/tmp}/codex-accounts-build.XXXXXX")
trap 'rm -rf "$stage_dir"' EXIT
app_bundle="$stage_dir/Codex Accounts Switcher.app"
mkdir -p "$app_bundle/Contents/MacOS" "$app_bundle/Contents/Resources"
xcrun swiftc -swift-version 5 -typecheck Source/Core.swift Source/App.swift Source/Launcher.swift
xcrun swiftc -swift-version 5 -O -target arm64-apple-macosx14.0 Source/Core.swift Source/App.swift Source/Launcher.swift -o "$app_bundle/Contents/MacOS/CodexAccounts"
cp Info.plist "$app_bundle/Contents/Info.plist"
codesign --force --sign - --identifier local.eric.CodexAccounts "$app_bundle"
codesign --verify --strict "$app_bundle"
ditto --noextattr --norsrc -c -k --keepParent "$app_bundle" "$PWD/CodexAccountsSwitcher.zip"
echo "Created: $PWD/CodexAccountsSwitcher.zip"

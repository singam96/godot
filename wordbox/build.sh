#!/usr/bin/env bash
# Build the Wordbox 2 slim export templates into bin/. Usage: wordbox/build.sh linux|android|windows
# Android needs ANDROID_HOME (the NDK is fetched by scons on first use).
set -eu
cd "$(dirname "${BASH_SOURCE[0]}")/.."
P=profile=wordbox/profile.py
J="-j$(nproc)"
case "${1:-}" in
	linux)   scons platform=linuxbsd arch=x86_64 target=template_release $P $J ;;
	android) scons platform=android arch=arm64 target=template_release $P $J generate_android_binaries=yes ;;
	windows) scons platform=windows arch=x86_64 use_mingw=yes target=template_release $P $J ;;
	*) echo "usage: $0 linux|android|windows" >&2; exit 2 ;;
esac

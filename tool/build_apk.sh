#!/usr/bin/env bash
# Construit l'APK release et le copie sous build/trace_3d-v<version>.apk (version lue dans pubspec.yaml).
set -euo pipefail
cd "$(dirname "$0")/.."
version=$(grep '^version:' pubspec.yaml | awk '{print $2}' | cut -d+ -f1)
flutter build apk --release
cp build/app/outputs/flutter-apk/app-release.apk "build/trace_3d-v${version}.apk"
echo "APK : build/trace_3d-v${version}.apk"

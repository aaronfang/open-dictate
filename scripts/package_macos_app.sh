#!/usr/bin/env bash
# Build a runnable OpenDictate.app from the Swift package (ad-hoc signed).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MACOS_PKG="${ROOT_DIR}/apps/macos"
DIST_DIR="${ROOT_DIR}/dist"
APP_NAME="OpenDictate"
APP_BUNDLE="${DIST_DIR}/${APP_NAME}.app"
EXECUTABLE_NAME="OpenDictate"
CONFIGURATION="${CONFIGURATION:-release}"
WITH_MODELS=0
IDENTITY="${CODESIGN_IDENTITY:--}"

usage() {
  cat <<'EOF'
Usage: ./scripts/package_macos_app.sh [options]

Options:
  --debug           Build debug instead of release
  --with-models     Copy models/sensevoice into the app Resources (large)
  --identity ID     codesign identity (default: ad-hoc "-")
  -h, --help        Show this help

Output:
  dist/OpenDictate.app
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --debug) CONFIGURATION="debug"; shift ;;
    --with-models) WITH_MODELS=1; shift ;;
    --identity) IDENTITY="${2:?}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

echo "==> Building OpenDictateMac (${CONFIGURATION})…"
swift build -c "${CONFIGURATION}" --package-path "${MACOS_PKG}"

BIN="$(swift build -c "${CONFIGURATION}" --package-path "${MACOS_PKG}" --show-bin-path)/OpenDictateMac"
if [[ ! -x "${BIN}" ]]; then
  echo "error: built binary not found at ${BIN}" >&2
  exit 1
fi

echo "==> Assembling ${APP_BUNDLE}…"
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

cp "${BIN}" "${APP_BUNDLE}/Contents/MacOS/${EXECUTABLE_NAME}"
chmod +x "${APP_BUNDLE}/Contents/MacOS/${EXECUTABLE_NAME}"

# PkgInfo marks this as an application bundle.
printf 'APPL????' > "${APP_BUNDLE}/Contents/PkgInfo"

VERSION="$(git -C "${ROOT_DIR}" describe --tags --always --dirty 2>/dev/null || echo "0.1.0")"
# Prefer a simple marketing version when describe returns a hash-only string.
SHORT_VERSION="0.1.0"
if [[ "${VERSION}" =~ ^v?[0-9]+\.[0-9]+ ]]; then
  SHORT_VERSION="${VERSION#v}"
  SHORT_VERSION="${SHORT_VERSION%%-*}"
fi

cat > "${APP_BUNDLE}/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>zh-Hans</string>
	<key>CFBundleDisplayName</key>
	<string>OpenDictate</string>
	<key>CFBundleExecutable</key>
	<string>${EXECUTABLE_NAME}</string>
	<key>CFBundleIdentifier</key>
	<string>com.opendictate.macos</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>OpenDictate</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>${SHORT_VERSION}</string>
	<key>CFBundleVersion</key>
	<string>${VERSION}</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSMicrophoneUsageDescription</key>
	<string>OpenDictate 需要访问麦克风以进行语音输入与识别。</string>
	<key>NSAppleEventsUsageDescription</key>
	<string>OpenDictate 需要控制其他应用以便将听写结果上屏。</string>
</dict>
</plist>
EOF

MODELS_SRC="${ROOT_DIR}/models/sensevoice"
MODELS_DST="${APP_BUNDLE}/Contents/Resources/Models/SenseVoice"
if [[ "${WITH_MODELS}" -eq 1 ]]; then
  if [[ ! -d "${MODELS_SRC}/SenseVoiceSmall_int8.mlmodelc" ]]; then
    echo "error: --with-models requested but models missing at ${MODELS_SRC}" >&2
    echo "Run: ./scripts/download_sensevoice_models.sh" >&2
    exit 1
  fi
  echo "==> Copying SenseVoice models into Resources (this may take a while)…"
  mkdir -p "${MODELS_DST}"
  rsync -a --delete \
    --exclude '.cache' \
    --exclude '.gitattributes' \
    "${MODELS_SRC}/" "${MODELS_DST}/"
fi

echo "==> Ad-hoc codesign (${IDENTITY})…"
codesign --force --deep --sign "${IDENTITY}" "${APP_BUNDLE}"

echo
echo "Done: ${APP_BUNDLE}"
echo "Run:   open \"${APP_BUNDLE}\""
if [[ "${WITH_MODELS}" -eq 0 ]]; then
  echo
  echo "SenseVoice models are not bundled. Either:"
  echo "  • ./scripts/download_sensevoice_models.sh --app-support"
  echo "  • or rebuild with --with-models"
fi

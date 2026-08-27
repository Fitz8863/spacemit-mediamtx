#!/usr/bin/env bash
set -euo pipefail

VERSION="${MEDIAMTX_VERSION:-v1.20.1}"
GO_VERSION="${GO_VERSION:-1.26.0}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="${WORK_DIR:-$(mktemp -d /tmp/spacemit-mediamtx-build.XXXXXX)}"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/dist}"
PACKAGE_NAME="mediamtx_${VERSION}_linux_riscv64"
PACKAGE_DIR="$WORK_DIR/$PACKAGE_NAME"
GO_ROOT="$WORK_DIR/go-sdk"
SRC_DIR="$WORK_DIR/mediamtx-src"

cleanup() {
  if [[ "${KEEP_WORK_DIR:-0}" != "1" ]]; then
    rm -rf "$WORK_DIR"
  else
    echo "Keeping work directory: $WORK_DIR"
  fi
}
trap cleanup EXIT

mkdir -p "$GO_ROOT" "$OUT_DIR" "$PACKAGE_DIR"

echo "[1/6] Downloading Go $GO_VERSION for the x86-64 build host"
wget -q --show-progress -O "$WORK_DIR/go.tar.gz" \
  "https://dl.google.com/go/go${GO_VERSION}.linux-amd64.tar.gz"
tar -xzf "$WORK_DIR/go.tar.gz" -C "$GO_ROOT" --strip-components=1
"$GO_ROOT/bin/go" version

echo "[2/6] Cloning MediaMTX $VERSION"
git clone --depth 1 --branch "$VERSION" \
  https://github.com/bluenviron/mediamtx.git "$SRC_DIR"

cd "$SRC_DIR"
echo "[3/6] Generating embedded assets"
"$GO_ROOT/bin/go" generate ./...

echo "[4/6] Cross-compiling linux/riscv64"
CGO_ENABLED=0 GOOS=linux GOARCH=riscv64 \
  "$GO_ROOT/bin/go" build -trimpath -o "$PACKAGE_DIR/mediamtx" .

cp "$SRC_DIR/mediamtx.yml" "$PACKAGE_DIR/mediamtx.yml"
cp LICENSE "$PACKAGE_DIR/LICENSE"
chmod 0755 "$PACKAGE_DIR/mediamtx"

echo "[5/6] Verifying output architecture and version"
file "$PACKAGE_DIR/mediamtx"
if ! file "$PACKAGE_DIR/mediamtx" | grep -q 'UCB RISC-V'; then
  echo "error: output is not a RISC-V executable" >&2
  exit 1
fi

ARCHIVE="$OUT_DIR/${PACKAGE_NAME}.tar.gz"
tar -C "$WORK_DIR" -czf "$ARCHIVE" "$PACKAGE_NAME"
(cd "$OUT_DIR" && sha256sum "$(basename "$ARCHIVE")") > "$ARCHIVE.sha256"

echo "[6/6] Release artifacts"
ls -lh "$ARCHIVE" "$ARCHIVE.sha256"
cat "$ARCHIVE.sha256"

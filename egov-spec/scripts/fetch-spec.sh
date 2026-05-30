#!/usr/bin/env bash
# e-Gov Developer Portal から仕様書をダウンロード・展開するスクリプト
# Usage: bash fetch-spec.sh <project-root> [--all|--schema|--procedures|--social-insurance]
set -euo pipefail

PROJECT_ROOT="${1:-.}"
TARGET="${2:---all}"
BASE_URL="https://developer.e-gov.go.jp/sites/default/files/filebrowser/specification"

dl() {
  local url="$1" dest="$2"
  echo ">>> Downloading: $(basename "$url")"
  curl -sfL "$url" -o "$dest"
}

extract() {
  local zip="$1" dir="$2"
  echo ">>> Extracting to: $dir"
  mkdir -p "$dir"
  unzip -oq "$zip" -d "$dir"
  rm "$zip"
}

# 構成管理スキーマ
fetch_schema() {
  local zip="/tmp/kousei_schema.zip"
  dl "$BASE_URL/kousei_schema.zip" "$zip"
  extract "$zip" "$PROJECT_ROOT/spec/kousei_schema"
  echo "  => $PROJECT_ROOT/spec/kousei_schema/"
}

# 手続情報一覧・提出先一覧（最新版を自動検出）
fetch_procedures() {
  echo ">>> Fetching latest tetsuzuki version from specification page..."
  # ページHTMLから最新版のURLを抽出
  local page
  page=$(curl -sf "https://developer.e-gov.go.jp/contents/specification/document-api/specification.html")
  local latest
  latest=$(echo "$page" | grep -oP 'href="[^"]*tetsuzuki_[^"]*\.zip"' | head -1 | grep -oP 'href="\K[^"]+')
  if [ -z "$latest" ]; then
    echo "ERROR: Could not find tetsuzuki download URL"
    return 1
  fi
  local url="https://developer.e-gov.go.jp${latest}"
  local zip="/tmp/tetsuzuki.zip"
  dl "$url" "$zip"
  extract "$zip" "$PROJECT_ROOT/spec/tetsuzuki"
  echo "  => $PROJECT_ROOT/spec/tetsuzuki/"
}

# 社会保険関係手続（申請書様式構造仕様）
fetch_social_insurance() {
  echo ">>> Fetching latest social insurance spec..."
  local page
  page=$(curl -sf "https://developer.e-gov.go.jp/contents/specification/document-api/social-insurance.html")
  # 申請書様式構造仕様の最新ZIP
  local latest
  latest=$(echo "$page" | grep -oP 'href="[^"]*shakai[^"]*\.zip"' | head -1 | grep -oP 'href="\K[^"]+')
  if [ -z "$latest" ]; then
    echo "ERROR: Could not find shakai download URL"
    return 1
  fi
  local url="https://developer.e-gov.go.jp${latest}"
  local zip="/tmp/shakai.zip"
  dl "$url" "$zip"
  extract "$zip" "$PROJECT_ROOT/spec/shakai"
  echo "  => $PROJECT_ROOT/spec/shakai/"
}

case "$TARGET" in
  --schema)     fetch_schema ;;
  --procedures) fetch_procedures ;;
  --social-insurance) fetch_social_insurance ;;
  --all)
    fetch_schema
    fetch_procedures
    fetch_social_insurance
    ;;
  *)
    echo "Usage: bash fetch-spec.sh <project-root> [--all|--schema|--procedures|--social-insurance]"
    exit 1
    ;;
esac

echo "Done."

#!/bin/zsh
set -u

ARCHIVE_PATH="$1"
EXPECTED_ARCHIVE_HASH="$2"
TARGET_APP="$3"
EXPECTED_BUNDLE_ID="$4"
EXPECTED_BUILD="$5"
SUPPORT_DIR="$6"
WORK_DIR="$7"
RUNNING_PID="$8"

LOG_DIR="$SUPPORT_DIR/Logs"
BACKUP_DIR="$SUPPORT_DIR/Backups"
LOG_FILE="$LOG_DIR/local-update.log"
EXTRACT_DIR="$WORK_DIR/extracted"
TARGET_PARENT="${TARGET_APP:h}"
TARGET_NAME="${TARGET_APP:t}"
STAGED_APP="$TARGET_PARENT/.${TARGET_NAME}.updating.$RUNNING_PID"
PREVIOUS_APP="$TARGET_PARENT/.${TARGET_NAME}.previous.$RUNNING_PID"

/bin/mkdir -p "$LOG_DIR" "$BACKUP_DIR"
exec >> "$LOG_FILE" 2>&1

log() {
    /bin/echo "$(/bin/date '+%Y-%m-%d %H:%M:%S') $1"
}

relaunch_current() {
    if [[ -d "$TARGET_APP" ]]; then
        /usr/bin/open "$TARGET_APP" >/dev/null 2>&1 || true
    fi
}

fail() {
    log "更新失败：$1"
    relaunch_current
    exit 1
}

log "开始安装本地更新：$ARCHIVE_PATH"

ACTUAL_ARCHIVE_HASH=$(/usr/bin/shasum -a 256 "$ARCHIVE_PATH" 2>/dev/null | /usr/bin/awk '{print $1}') \
    || fail "无法再次校验更新包"
[[ "$ACTUAL_ARCHIVE_HASH" == "$EXPECTED_ARCHIVE_HASH" ]] || fail "更新包在安装前发生变化"

for _ in {1..120}; do
    if ! /bin/kill -0 "$RUNNING_PID" 2>/dev/null; then
        break
    fi
    /bin/sleep 0.25
done
if /bin/kill -0 "$RUNNING_PID" 2>/dev/null; then
    fail "旧版本未能在 30 秒内退出"
fi

/bin/mkdir -p "$EXTRACT_DIR" || fail "无法创建解压目录"
/usr/bin/ditto -x -k "$ARCHIVE_PATH" "$EXTRACT_DIR" || fail "无法解压更新包"

APP_CANDIDATES=("$EXTRACT_DIR"/*.app(N/))
if (( ${#APP_CANDIDATES[@]} != 1 )); then
    fail "更新包必须且只能包含一个 App"
fi
NEW_APP="${APP_CANDIDATES[1]}"

NEW_BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$NEW_APP/Contents/Info.plist" 2>/dev/null) \
    || fail "无法读取新版 Bundle ID"
NEW_BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$NEW_APP/Contents/Info.plist" 2>/dev/null) \
    || fail "无法读取新版构建号"

[[ "$NEW_BUNDLE_ID" == "$EXPECTED_BUNDLE_ID" ]] || fail "新版 Bundle ID 不一致"
[[ "$NEW_BUILD" == "$EXPECTED_BUILD" ]] || fail "新版构建号不一致"
/usr/bin/codesign --verify --deep --strict "$NEW_APP" || fail "新版代码签名无效"
[[ -w "$TARGET_PARENT" ]] || fail "应用所在目录不可写"

CURRENT_BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$TARGET_APP/Contents/Info.plist" 2>/dev/null || /bin/echo unknown)
TIMESTAMP=$(/bin/date '+%Y%m%d-%H%M%S')
BACKUP_APP="$BACKUP_DIR/柯基小小-build-${CURRENT_BUILD}-${TIMESTAMP}.app"
/usr/bin/ditto "$TARGET_APP" "$BACKUP_APP" || fail "无法备份旧版本"

/bin/rm -rf "$STAGED_APP" "$PREVIOUS_APP"
/usr/bin/ditto "$NEW_APP" "$STAGED_APP" || fail "无法暂存新版"
/usr/bin/xattr -cr "$STAGED_APP" || fail "无法清理新版扩展属性"
/usr/bin/codesign --verify --deep --strict "$STAGED_APP" || fail "暂存后的代码签名无效"

/bin/mv "$TARGET_APP" "$PREVIOUS_APP" || fail "无法移开旧版本"
if ! /bin/mv "$STAGED_APP" "$TARGET_APP"; then
    /bin/mv "$PREVIOUS_APP" "$TARGET_APP" >/dev/null 2>&1 || true
    fail "无法安装新版"
fi

if ! /usr/bin/open "$TARGET_APP"; then
    /bin/rm -rf "$TARGET_APP"
    /bin/mv "$PREVIOUS_APP" "$TARGET_APP" >/dev/null 2>&1 || true
    fail "新版无法启动，已恢复旧版本"
fi

/bin/rm -rf "$PREVIOUS_APP"
log "更新成功：build $EXPECTED_BUILD；旧版备份：$BACKUP_APP"
/bin/rm -rf "$WORK_DIR"
exit 0

#!/bin/bash
#
# bing_wallpaper.sh
# 自动获取 Bing 每日壁纸并设置为 macOS 桌面壁纸
#
# 用法：直接运行即可；配合 launchd 定时任务实现自动化。

set -euo pipefail

# ------------------- 可自行修改的配置 -------------------
# 地区代码：zh-CN（中国区）、en-US（美国区）、ja-JP（日本区）等
MARKET="zh-CN"

# 壁纸保存目录
SAVE_DIR="$HOME/Pictures/BingWallpapers"

# 记录上次已成功设置的图片 URL，用于避免重复下载
LAST_URL_FILE="$SAVE_DIR/.last_url"

# 日志文件
LOG_FILE="$SAVE_DIR/bing_wallpaper.log"

# macOS 壁纸统一配置文件，用于确认「在所有空间中显示」是否已启用
WALLPAPER_INDEX="$HOME/Library/Application Support/com.apple.wallpaper/Store/Index.plist"

# 把当日图片写入 macOS 的「所有空间共用」配置
SYNC_HELPER="$HOME/Library/Scripts/sync_all_spaces.py"
WALLPAPER_INDEX_BACKUP="$SAVE_DIR/.wallpaper_index_backup.plist"
# ---------------------------------------------------------

mkdir -p "$SAVE_DIR"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

# Index.plist 中的共用 Desktop，或全部 Space/Display 记录，都指向目标图片。
index_fully_synced() {
    [ -f "$SYNC_HELPER" ] || return 1
    /usr/bin/python3 "$SYNC_HELPER" --check "$1" "$WALLPAPER_INDEX" >> "$LOG_FILE" 2>&1
}

# 开关开启时，macOS 会在 AllSpacesAndDisplays 下保存统一的 Desktop 配置。
all_spaces_enabled() {
    [ -f "$WALLPAPER_INDEX" ] && \
        /usr/libexec/PlistBuddy -c 'Print :AllSpacesAndDisplays:Desktop' "$WALLPAPER_INDEX" >/dev/null 2>&1
}

# 按系统开关的数据结构统一所有空间，然后让 launchd 自动重启 WallpaperAgent 并读取配置。
# WallpaperAgent 重启后可能用内存态覆盖 Index，因此会多写一轮并复查。
sync_all_spaces() {
    [ -f "$SYNC_HELPER" ] || {
        log "缺少桌面空间同步工具：$SYNC_HELPER"
        return 1
    }

    local pass=0
    for pass in 1 2 3; do
        /usr/bin/python3 "$SYNC_HELPER" "$IMAGE_FILE" "$WALLPAPER_INDEX" "$WALLPAPER_INDEX_BACKUP" >> "$LOG_FILE" 2>&1 || return 1

        /usr/bin/killall WallpaperAgent >> "$LOG_FILE" 2>&1 || true

        local attempt=0
        for attempt in 1 2 3 4 5 6 7 8 9 10; do
            sleep 1
            if index_fully_synced "$IMAGE_FILE"; then
                return 0
            fi

            # Agent 重启后若把 Index 写回旧状态，立刻再写一次后再杀进程重试。
            if [ "$attempt" -eq 3 ] || [ "$attempt" -eq 6 ]; then
                /usr/bin/python3 "$SYNC_HELPER" "$IMAGE_FILE" "$WALLPAPER_INDEX" "$WALLPAPER_INDEX_BACKUP" >> "$LOG_FILE" 2>&1 || return 1
                /usr/bin/killall WallpaperAgent >> "$LOG_FILE" 2>&1 || true
            fi
        done
    done

    return 1
}

# 返回当前活动桌面的壁纸路径，每个显示器一行。
get_current_pictures() {
    osascript <<'APPLESCRIPT'
tell application "System Events"
    set picturePaths to picture of every desktop
end tell

set output to ""
repeat with picturePath in picturePaths
    set output to output & (picturePath as text) & linefeed
end repeat
return output
APPLESCRIPT
}

# 检查当前所有可见桌面是否都在使用目标图片。
wallpaper_matches() {
    local expected_file="$1"
    local current_pictures="$2"
    local current_picture=""
    local picture_count=0

    while IFS= read -r current_picture; do
        [ -z "$current_picture" ] && continue
        picture_count=$((picture_count + 1))
        [ "$current_picture" = "$expected_file" ] || return 1
    done <<< "$current_pictures"

    [ "$picture_count" -gt 0 ]
}

# 可见桌面与 Index 中的全部 Space 都已是当日图片。
wallpaper_fully_applied() {
    local expected_file="$1"
    local current_pictures=""

    current_pictures=$(get_current_pictures 2>> "$LOG_FILE") || return 1
    wallpaper_matches "$expected_file" "$current_pictures" || return 1
    index_fully_synced "$expected_file"
}

# 1. 获取当日壁纸信息（取分辨率最高的 UHD 版本）
API_URL="https://www.bing.com/HPImageArchive.aspx?format=js&idx=0&n=1&mkt=${MARKET}"

RESPONSE=$(curl -fsSL --retry 3 --connect-timeout 15 --max-time 120 "$API_URL") || {
    log "获取 Bing 每日图片信息失败"
    exit 1
}

IMAGE_BASE=$(printf '%s' "$RESPONSE" | grep -o '"urlbase":"[^"]*"' | head -1 | sed 's/"urlbase":"//;s/"$//') || true

if [ -z "$IMAGE_BASE" ]; then
    log "解析图片 URL 失败"
    exit 1
fi

# urlbase 不含分辨率和扩展名，直接组合成 Bing 的 UHD 图片地址。
IMAGE_URL="https://www.bing.com${IMAGE_BASE}_UHD.jpg"

# 2. 准备当日图片路径
LAST_URL=""
if [ -f "$LAST_URL_FILE" ]; then
    LAST_URL=$(cat "$LAST_URL_FILE")
fi

TODAY=$(date '+%Y-%m-%d')
IMAGE_FILE="$SAVE_DIR/bing_${TODAY}.jpg"
DOWNLOADED=false

# 3. URL 变化或本地图片不存在时才下载。先下载到临时文件，避免网络中断留下损坏图片。
if [ "$IMAGE_URL" != "$LAST_URL" ] || [ ! -s "$IMAGE_FILE" ]; then
    TEMP_FILE=$(mktemp "$SAVE_DIR/.bing_wallpaper.XXXXXX")
    trap 'rm -f "$TEMP_FILE"' EXIT

    curl -fsSL --retry 3 --connect-timeout 15 --max-time 120 "$IMAGE_URL" -o "$TEMP_FILE" || {
        log "下载图片失败：$IMAGE_URL"
        exit 1
    }

    if [ ! -s "$TEMP_FILE" ] || ! file "$TEMP_FILE" | grep -q 'JPEG image data'; then
        log "下载内容不是有效的 JPEG 图片：$IMAGE_URL"
        exit 1
    fi

    mv "$TEMP_FILE" "$IMAGE_FILE"
    trap - EXIT
    DOWNLOADED=true
fi

# 4. 即使 Bing URL 没变，也要检查当前桌面以及 Index 中全部 Space 的状态。
# System Events 只能看到当前可见桌面；未激活的「桌面 2」等只能靠 Index 校验。
CURRENT_PICTURES=""
CURRENT_MATCHES=false
INDEX_SYNCED=false
if CURRENT_PICTURES=$(get_current_pictures 2>> "$LOG_FILE") && wallpaper_matches "$IMAGE_FILE" "$CURRENT_PICTURES"; then
    CURRENT_MATCHES=true
fi
if index_fully_synced "$IMAGE_FILE"; then
    INDEX_SYNCED=true
fi

if [ "$CURRENT_MATCHES" = true ] && [ "$INDEX_SYNCED" = true ]; then
    printf '%s\n' "$IMAGE_URL" > "$LAST_URL_FILE"
    log "所有桌面空间已统一使用当日图片：$IMAGE_FILE"
else
    if [ "$CURRENT_MATCHES" != true ] && ! osascript - "$IMAGE_FILE" <<'APPLESCRIPT'
on run argv
    set imagePath to item 1 of argv
    tell application "System Events"
        tell every desktop
            set picture to imagePath
        end tell
    end tell
end run
APPLESCRIPT
    then
        log "设置壁纸失败：$IMAGE_FILE"
        exit 1
    fi

    # 无论「在所有空间中显示」当前是否开启，都写入 Index，避免桌面 2 等非当前 Space 漏更新。
    if ! sync_all_spaces; then
        log "无法同步所有桌面空间"
        exit 1
    fi

    # macOS 会异步更新壁纸状态；再给系统一点时间，并在必要时补写 Index。
    VERIFIED=false
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
        sleep 1
        if wallpaper_fully_applied "$IMAGE_FILE"; then
            VERIFIED=true
            break
        fi
        if [ "$attempt" -eq 5 ]; then
            /usr/bin/python3 "$SYNC_HELPER" "$IMAGE_FILE" "$WALLPAPER_INDEX" "$WALLPAPER_INDEX_BACKUP" >> "$LOG_FILE" 2>&1 || true
            /usr/bin/killall WallpaperAgent >> "$LOG_FILE" 2>&1 || true
        fi
    done

    if [ "$VERIFIED" != true ]; then
        CURRENT_PICTURES=$(get_current_pictures 2>> "$LOG_FILE") || CURRENT_PICTURES=""
        log "壁纸设置后验证失败（系统当前：$CURRENT_PICTURES）"
        exit 1
    fi

    printf '%s\n' "$IMAGE_URL" > "$LAST_URL_FILE"
    if [ "$DOWNLOADED" = true ]; then
        log "已下载 UHD 图片并同步到所有桌面空间：$IMAGE_FILE"
    elif [ "$CURRENT_MATCHES" = true ] && [ "$INDEX_SYNCED" != true ]; then
        log "检测到桌面空间壁纸不统一，已全部同步：$IMAGE_FILE"
    else
        log "检测到壁纸被替换，已恢复并同步所有桌面空间：$IMAGE_FILE"
    fi
fi

# 5. 清理 7 天前的旧壁纸文件，避免占用空间
find "$SAVE_DIR" -type f -name "bing_*.jpg" -mtime +7 -delete

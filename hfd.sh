#!/usr/bin/env bash
# Color definitions
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m' # No Color

# 结束时暂停窗口防止闪退的函数
pause_exit() {
    echo -e "${YELLOW}\n--------------------------------------------------"
    read -p "程序已运行结束，请按 [Enter] 回车键退出窗口..." temp
    exit $1
}

# 捕获中断信号（Ctrl+C）
trap 'printf "${YELLOW}\n下载被动中断。重新运行此脚本可以继续断点续传。\n${NC}"; pause_exit 1' INT

# ======================= 【只需修改这里】 =======================
# 想换别的模型，直接改下面这一行的名字即可
REPO_ID="dealignai/Gemma-4-31B-JANG_4M-CRACK"
# ===============================================================

# ======================= 固定高级配置 =======================
TOOL="aria2c"
THREADS=8       # 既然配好了 aria2c，线程直接拉到 8 释放网速
CONCURRENT=5
HF_ENDPOINT=${HF_ENDPOINT:-"https://hf-mirror.com"} # 默认走国内高速镜像
REVISION="main"
# ===========================================================

# 检查依赖工具
check_command() {
    if ! command -v "$1" &>/dev/null; then
        printf "%b[错误] 系统未安装 %s，或者没有配置好环境变量。%b\n" "$RED" "$1" "$NC"
        pause_exit 1
    fi
}

echo -e "${GREEN}正在准备下载模型: ${REPO_ID}${NC}"
check_command curl
check_command "$TOOL"

# 自动处理本地下载目录名：如果是 "org/repo" 则取 "repo"；如果是单个名字就直接用
if [[ "$REPO_ID" == *"/"* ]]; then
    LOCAL_DIR="${REPO_ID#*/}"
else
    LOCAL_DIR="$REPO_ID"
fi

mkdir -p "$LOCAL_DIR/.hfd"

METADATA_API_PATH="models/$REPO_ID"
DOWNLOAD_API_PATH="$REPO_ID"

if [[ "$REVISION" != "main" ]]; then
    METADATA_API_PATH="$METADATA_API_PATH/revision/$REVISION"
fi
API_URL="$HF_ENDPOINT/api/$METADATA_API_PATH"
METADATA_FILE="$LOCAL_DIR/.hfd/repo_metadata.json"

# 获取模型元数据
fetch_and_save_metadata() {
    status_code=$(curl -L -s -w "%{http_code}" -o "$METADATA_FILE" "$API_URL")
    RESPONSE=$(cat "$METADATA_FILE")
    if [ "$status_code" -eq 200 ]; then
        printf "%s\n" "$RESPONSE"
    else
        printf "%b[错误] 无法从 API 获取模型信息。HTTP 状态码: $status_code.%b\n$RESPONSE\n" "${RED}" "${NC}" >&2
        rm -f "$METADATA_FILE"
        pause_exit 1
    fi
}

if [[ ! -f "$METADATA_FILE" ]]; then
    printf "%b正在从镜像站获取模型文件列表...%b\n" "$YELLOW" "$NC"
    RESPONSE=$(fetch_and_save_metadata) || pause_exit 1
else
    printf "%b发现本地缓存的文件列表: $METADATA_FILE%b\n" "$GREEN" "$NC"
    RESPONSE=$(cat "$METADATA_FILE")
fi

fileslist_file=".hfd/${TOOL}_urls.txt"

# 生成下载链接列表
if [[ ! -f "$LOCAL_DIR/$fileslist_file" ]]; then
    printf "%b正在生成下载任务列表...%b\n" "$YELLOW" "$NC"
    
    if command -v jq &>/dev/null; then
        result=$(printf "%s" "$RESPONSE" | jq -r \
            --arg endpoint "$HF_ENDPOINT" \
            --arg repo_id "$DOWNLOAD_API_PATH" \
            --arg revision "$REVISION" \
            '.siblings[] | select(.rfilename != null) | [($endpoint + "/" + $repo_id + "/resolve/" + $revision + "/" + .rfilename), " dir=" + (.rfilename | split("/")[:-1] | join("/")), " out=" + (.rfilename | split("/")[-1]), ""]')
        printf "%s\n" "$result" > "$LOCAL_DIR/$fileslist_file"
    else
        # 无 jq 时的备用纯文本解析
        files=$(printf '%s' "$RESPONSE" | grep -o '"rfilename":"[^"]*"' | awk -F'"' '{print $4}')
        output=""
        while IFS= read -r file; do
            if [[ -n "$file" ]]; then
                output+="$HF_ENDPOINT/$DOWNLOAD_API_PATH/resolve/$REVISION/$file"$'\n'
                output+=" dir=$(dirname "$file")"$'\n'
                output+=" out=$(basename "$file")"$'\n'$'\n'
            fi
        done <<< "$files"
        printf '%s' "$output" > "$LOCAL_DIR/$fileslist_file"
    fi
else
    printf "%b正在检测上次未完成的进度，准备断点续传...%b\n" "$GREEN" "$NC"
fi

# 开始下载
printf "${YELLOW}正在调用 $TOOL 启动多线程下载...\n${NC}"

cd "$LOCAL_DIR" || pause_exit 1
aria2c --console-log-level=warn --file-allocation=none -x "$THREADS" -j "$CONCURRENT" -s "$THREADS" -k 1M -c -i "$fileslist_file" --save-session="$fileslist_file"

if [[ $? -eq 0 ]]; then
    printf "${GREEN}🎉 下载成功完成！模型保存在当前目录下的: $PWD\n${NC}"
    pause_exit 0
else
    printf "${RED}❌ 下载过程中遇到网络波动或错误。不用担心，直接重新运行此脚本即可继续断点续传。\n${NC}"
    pause_exit 1
fi
# ======================= 工具致谢 =======================
#本工具改自hf-mirror.com的工具hfd.sh
#旨在为了换一种方式解决Windows会出现找不到官方hub或无法运行原版hdf工具的问题
#感谢hf-mirror.com，希望有能力的Coder多多打赏
# ====================================================
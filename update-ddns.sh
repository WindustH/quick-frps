#!/bin/bash

# --- 配置 ---
# 安全凭证文件的路径
CRED_FILE="$HOME/.ddns-credentials"

# 日志文件，用于记录更新状态
LOG_FILE="/var/log/ddns_update.log"

# --- 脚本开始 ---

# 检查凭证文件是否存在
if [ ! -f "$CRED_FILE" ]; then
    echo "$(date): 错误 - 凭证文件未找到: $CRED_FILE" | sudo tee -a $LOG_FILE
    exit 1
fi

# 从文件中加载凭证 (source 命令会将其中的变量导入当前 shell)
source "$CRED_FILE"

# 获取当前的公网 IP 地址
# 我们尝试多个服务以增加可靠性
CURRENT_IP=$(curl -s https://ifconfig.me/ip || curl -s https://api.ipify.org || curl -s https://icanhazip.com)

if [ -z "$CURRENT_IP" ]; then
    echo "$(date): 错误 - 无法获取公网 IP 地址。" | sudo tee -a $LOG_FILE
    exit 1
fi

# DDNSKEY.COM 的更新 URL
# 这是基于通用 DDNS API 的标准格式。
UPDATE_URL="https://ddnskey.com/nic/update"

# 发送更新请求
echo "$(date): 正在使用 IP [$CURRENT_IP] 更新主机 [$DDNS_HOST]..." | sudo tee -a $LOG_FILE

RESPONSE=$(curl -s --user "${DDNS_USER}:${DDNS_PASS}" "${UPDATE_URL}?hostname=${DDNS_HOST}&myip=${CURRENT_IP}")

# 将服务商的响应记录到日志
echo "$(date): DDNS 服务器响应: $RESPONSE" | sudo tee -a $LOG_FILE
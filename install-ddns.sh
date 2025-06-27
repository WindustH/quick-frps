#!/bin/bash

# ==============================================================================
# DDNS 自动更新服务安装脚本 for No-IP
#
# 功能:
# 1. 引导用户输入 No-IP 凭证信息。
# 2. 创建一个安全的凭证文件。
# 3. 安装 DDNS 更新脚本。
# 4. 创建一个 systemd 服务以实现开机自启和定时更新。
# ==============================================================================

# --- 脚本设置 ---
# set -e: 如果任何命令执行失败，脚本将立即退出。
set -e

# --- 脚本变量 ---
UPDATE_SCRIPT_PATH="/usr/local/bin/update-ddns.sh"
SERVICE_PATH="/etc/systemd/system/update-ddns.service"
TIMER_PATH="/etc/systemd/system/update-ddns.timer"
LOG_FILE="/var/log/noip_update.log"

# --- 预检查 ---

# 1. 检查是否以 root 用户身份运行
if [ "$EUID" -ne 0 ]; then
  echo "错误：请使用 'sudo' 来运行此安装脚本。"
  echo "用法: sudo bash install_ddns.sh"
  exit 1
fi

# 2. 获取运行 sudo 的普通用户名，这是为了将凭证文件放在正确的用户主目录下。
if [ -n "$SUDO_USER" ]; then
    REGULAR_USER="$SUDO_USER"
else
    echo "警告：无法确定原始用户，将使用 root 用户的主目录。"
    REGULAR_USER="root"
fi

USER_HOME=$(getent passwd "$REGULAR_USER" | cut -d: -f6)

if [ -z "$USER_HOME" ]; then
    echo "错误：无法确定用户 '$REGULAR_USER' 的主目录。"
    exit 1
fi

CRED_FILE_PATH="$USER_HOME/.noip-credentials"

# --- 主程序 ---

echo "============================================="
echo "    No-IP DDNS 自动更新服务安装脚本    "
echo "============================================="
echo
echo "此脚本将执行以下操作:"
echo " 1. 提示您输入 No-IP 凭证信息。"
echo " 2. 创建一个安全的凭证文件在: $CRED_FILE_PATH"
echo " 3. 安装 DDNS 更新脚本到: $UPDATE_SCRIPT_PATH"
echo " 4. 创建一个 systemd 服务和定时器，实现开机自启和周期性更新。"
echo

# --- 1. 获取用户凭证 ---
read -p "请输入您的 No-IP 用户名或邮箱 (Username/Email): " DDNS_USER
# -s 选项可以隐藏密码输入
read -sp "请输入您的 No-IP 密码 (Password): " DDNS_PASS
echo
read -p "请输入您要更新的完整主机名 (e.g., yourhost.ddns.net): " DDNS_HOST

# --- 2. 创建并保护凭证文件 ---
echo
echo "-> 正在创建安全的凭证文件..."
# 使用 cat 和 EOF 来创建文件内容
cat > "$CRED_FILE_PATH" << EOF
# No-IP Credentials
DDNS_USER="$DDNS_USER"
DDNS_PASS="$DDNS_PASS"
DDNS_HOST="$DDNS_HOST"
EOF

# 更改文件的所有者和权限
chown "$REGULAR_USER:$REGULAR_USER" "$CRED_FILE_PATH"
chmod 600 "$CRED_FILE_PATH"
echo "   凭证文件已创建并设置权限 (600)。"

# --- 3. 创建更新脚本 ---
echo "-> 正在安装 DDNS 更新脚本..."
# 使用 cat 和 'EOF' (注意单引号) 来创建脚本文件。
# 单引号可以防止 'EOF' 内部的变量被当前 shell 解析。
cat > "$UPDATE_SCRIPT_PATH" << 'EOF'
#!/bin/bash

# 此脚本由安装程序自动生成

# 找到运行此脚本的用户的主目录，以定位凭证文件
OWNER_USER=$(stat -c '%U' "$0")
OWNER_HOME=$(getent passwd "$OWNER_USER" | cut -d: -f6)
CRED_FILE_PATH_IN_SCRIPT="$OWNER_HOME/.noip-credentials"
LOG_FILE="/var/log/noip_update.log"

# 加载凭证
if [ ! -f "$CRED_FILE_PATH_IN_SCRIPT" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S'): 错误 - 凭证文件未找到: $CRED_FILE_PATH_IN_SCRIPT" >> "$LOG_FILE"
    exit 1
fi
source "$CRED_FILE_PATH_IN_SCRIPT"

# 获取公网 IP，尝试多个源以确保可靠性
CURRENT_IP=$(curl -s --fail https://ifconfig.me/ip || curl -s --fail https://api.ipify.org || curl -s --fail https://icanhazip.com)

if [ -z "$CURRENT_IP" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S'): 错误 - 无法获取公网 IP 地址。" >> "$LOG_FILE"
    exit 1
fi

# 获取上次记录的IP，以避免不必要的更新
LAST_IP_FILE="/tmp/noip_last_ip.txt"
if [ -f "$LAST_IP_FILE" ] && [ "$(cat "$LAST_IP_FILE")" == "$CURRENT_IP" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S'): IP 未变化 ($CURRENT_IP)，无需更新。" >> "$LOG_FILE"
    exit 0
fi

# 更新 DDNS
echo "$(date '+%Y-%m-%d %H:%M:%S'): IP 地址已变化。新 IP: $CURRENT_IP. 正在更新主机: $DDNS_HOST" >> "$LOG_FILE"
# No-IP 的更新 URL
UPDATE_URL="https://dynupdate.no-ip.com/nic/update"

# 使用 curl 发送更新请求
# No-IP 需要一个 User-Agent
RESPONSE=$(curl -s --user-agent "Personal DDNS-Client/1.0 me@example.com" --user "${DDNS_USER}:${DDNS_PASS}" "${UPDATE_URL}?hostname=${DDNS_HOST}&myip=${CURRENT_IP}")

echo "$(date '+%Y-%m-%d %H:%M:%S'): 服务器响应: $RESPONSE" >> "$LOG_FILE"

# 如果更新成功 (响应中通常包含 'good' 或 'nochg')，则记录本次的IP
if [[ "$RESPONSE" == *"good"* ]] || [[ "$RESPONSE" == *"nochg"* ]]; then
    echo "$CURRENT_IP" > "$LAST_IP_FILE"
fi
EOF

chmod +x "$UPDATE_SCRIPT_PATH"
echo "   更新脚本已安装并设为可执行。"

# --- 4. 创建 systemd 服务 ---
echo "-> 正在创建 systemd 服务单元..."
cat > "$SERVICE_PATH" << EOF
[Unit]
Description=Dynamic DNS Update Service for No-IP
After=network.target

[Service]
Type=oneshot
User=$REGULAR_USER
ExecStart=$UPDATE_SCRIPT_PATH

[Install]
WantedBy=multi-user.target
EOF
echo "   systemd 服务文件已创建。"

# --- 5. 创建 systemd 定时器 ---
echo "-> 正在创建 systemd 定时器（每15分钟检查一次）..."
cat > "$TIMER_PATH" << EOF
[Unit]
Description=Run No-IP DDNS update script periodically

[Timer]
OnBootSec=2min
OnUnitActiveSec=15min
Unit=update-ddns.service

[Install]
WantedBy=timers.target
EOF
echo "   systemd 定时器文件已创建。"

# --- 6. 启用并启动服务和定时器 ---
echo "-> 正在重载 systemd、启用并启动定时器..."
# 创建或清空日志文件，并设置权限
touch "$LOG_FILE"
chown "$REGULAR_USER:$REGULAR_USER" "$LOG_FILE"

systemctl daemon-reload
systemctl enable update-ddns.timer
systemctl start update-ddns.timer
# 立即运行一次更新，而不是等待定时器
systemctl start update-ddns.service

echo "   服务和定时器已启用并成功启动。"
echo

# --- 完成 ---
echo "============================================="
echo " ✅ 安装完成！"
echo "============================================="
echo
echo "服务现在会开机自启，并每 15 分钟自动检查和更新 IP 地址。"
echo "您可以运行以下命令来检查其状态："
echo " sudo systemctl status update-ddns.timer"
echo " sudo systemctl status update-ddns.service"
echo
echo "您可以查看详细的更新日志："
echo " tail -f /var/log/noip_update.log"
echo

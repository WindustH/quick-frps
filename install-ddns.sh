#!/bin/bash

# --- 脚本设置 ---
# set -e: 如果任何命令失败，脚本将立即退出
set -e

# --- 脚本变量 ---
UPDATE_SCRIPT_PATH="/usr/local/bin/update-ddns.sh"
SERVICE_PATH="/etc/systemd/system/update-ddns.service"
LOG_FILE="/var/log/ddns_update.log"

# --- 预检查 ---

# 1. 检查是否以 root 用户身份运行
if [ "$EUID" -ne 0 ]; then
  echo "错误：请使用 'sudo' 来运行此安装脚本。"
  echo "用法: sudo bash install_ddns.sh"
  exit 1
fi

# 2. 获取运行 sudo 的普通用户名
# 这是为了将凭证文件放在正确的用户主目录下
REGULAR_USER="${SUDO_USER:-$(whoami)}"
USER_HOME=$(getent passwd "$REGULAR_USER" | cut -d: -f6)

if [ -z "$USER_HOME" ]; then
    echo "错误：无法确定用户 '$REGULAR_USER' 的主目录。"
    exit 1
fi

CRED_FILE_PATH="$USER_HOME/.ddns-credentials"

# --- 主程序 ---

echo "============================================="
echo " DDNS 自动更新服务安装脚本 for ddnskey.com "
echo "============================================="
echo
echo "此脚本将执行以下操作:"
echo " 1. 提示您输入 DDNS 凭证信息。"
echo " 2. 创建一个安全的凭证文件在: $CRED_FILE_PATH"
echo " 3. 安装 DDNS 更新脚本到: $UPDATE_SCRIPT_PATH"
echo " 4. 创建一个 systemd 服务实现开机自启。"
echo

# --- 1. 获取用户凭证 ---
read -p "请输入您的 DDNS 用户名 (Username): " DDNS_USER
read -sp "请输入您的 DDNS 密码 (Password): " DDNS_PASS
echo
read -p "请输入您要更新的完整主机名 (Hostname): " DDNS_HOST

# --- 2. 创建并保护凭证文件 ---
echo
echo "-> 正在创建安全的凭证文件..."
cat > "$CRED_FILE_PATH" << EOF
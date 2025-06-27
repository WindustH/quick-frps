#!/bin/bash

#================================================================================
# FRP 和 DDNS 集成安装脚本
#
# 功能:
# - 提供菜单选择安装 FRP 服务端、No-IP DDNS 客户端或两者。
# - FRP 安装:
#   - 使用本地提供的 frp tar 包进行安装。
#   - 交互式配置 frps 端口和 token。
#   - 创建 systemd 服务实现开机自启。
#   - (可选) 自动配置 ufw 防火墙。
# - DDNS 安装:
#   - 引导用户输入 No-IP 凭证。
#   - 创建更新脚本和安全的凭证文件。
#   - 创建 systemd 服务和定时器，实现开机自启和周期性更新。
#
# 使用方法:
# 1. 将此脚本与 frp 本地安装包 (例如 frp_0.63.0_linux_amd64.tar.gz) 放在同一目录下。
# 2. chmod +x all-in-one.sh
# 3. sudo ./all-in-one.sh
#================================================================================

# --- 输出颜色定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # 无颜色

#================================================================================
# 通用函数
#================================================================================

# 检查是否以 root 权限运行
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${RED}错误：此脚本必须以 root 权限运行。${NC}"
        echo -e "请尝试使用 'sudo ./<script_name>.sh' 命令运行。"
        exit 1
    fi
}

# 检查并安装依赖 (curl, wget)
check_dependencies() {
    if ! command -v curl &> /dev/null || ! command -v wget &> /dev/null; then
        echo -e "${BLUE}正在安装依赖 (curl, wget)...${NC}"
        apt-get update
        apt-get install -y curl wget
    fi
}

#================================================================================
# FRP 安装部分
#================================================================================

# --- FRP 全局变量 ---
FRP_INSTALL_DIR="/usr/local/frp"
FRP_CONFIG_FILE="/etc/frp/frps.toml"
FRP_SYSTEMD_SERVICE_FILE="/etc/systemd/system/frps.service"
# !!! 重要: 请确保此文件名与您本地的 frp 安装包版本匹配 !!!
FRP_FILENAME="frp_0.63.0_linux_amd64"
FRP_TAR_FILE="${FRP_FILENAME}.tar.gz"

# 下载并安装 frp (从本地文件)
install_frp() {
    echo -e "${BLUE}开始从本地文件 ${FRP_TAR_FILE} 安装 frp...${NC}"

    if [ ! -f "${FRP_TAR_FILE}" ]; then
        echo -e "${RED}错误：未在当前目录下找到 frp 安装包 '${FRP_TAR_FILE}'！${NC}"
        exit 1
    fi

    # 解压
    tar -zxvf "${FRP_TAR_FILE}" -C /tmp
    if [ $? -ne 0 ]; then
        echo -e "${RED}错误：解压 frp 失败。${NC}"
        exit 1
    fi

    # 安装
    sudo mkdir -p "${FRP_INSTALL_DIR}"
    sudo cp "/tmp/${FRP_FILENAME}/frps" "${FRP_INSTALL_DIR}/frps"
    sudo chmod +x "${FRP_INSTALL_DIR}/frps"

    rm -rf "/tmp/${FRP_FILENAME}"

    echo -e "${GREEN}frp 主程序安装成功！路径: ${FRP_INSTALL_DIR}/frps${NC}"
}

# 配置 frps
configure_frps() {
    echo -e "${BLUE}开始配置 frps...${NC}"
    sudo mkdir -p "$(dirname ${FRP_CONFIG_FILE})"

    # 交互式配置
    read -p "请输入 frps 的绑定端口 (默认为 7000): " BIND_PORT
    BIND_PORT=${BIND_PORT:-7000}

    read -p "请输入 frps 的认证令牌 (token，建议设置一个复杂的密码): " AUTH_TOKEN
    if [ -z "${AUTH_TOKEN}" ]; then
        echo -e "${RED}错误：认证令牌不能为空！${NC}"
        exit 1
    fi

    # 创建配置文件
    sudo bash -c "cat > ${FRP_CONFIG_FILE}" <<EOF
bindPort = ${BIND_PORT}
auth.token = "${AUTH_TOKEN}"
EOF

    echo -e "${GREEN}配置文件创建成功！路径: ${FRP_CONFIG_FILE}${NC}"
}

# 创建 frps 的 systemd 服务
setup_frp_systemd() {
    echo -e "${BLUE}正在为 frps 创建 systemd 服务...${NC}"

    sudo bash -c "cat > ${FRP_SYSTEMD_SERVICE_FILE}" <<EOF
[Unit]
Description=FRP Server Service
After=network.target

[Service]
Type=simple
User=nobody
Restart=on-failure
RestartSec=5s
ExecStart=${FRP_INSTALL_DIR}/frps -c ${FRP_CONFIG_FILE}

[Install]
WantedBy=multi-user.target
EOF

    echo -e "${GREEN}frps 的 systemd 服务文件创建成功！路径: ${FRP_SYSTEMD_SERVICE_FILE}${NC}"
}

# 配置防火墙
configure_frp_firewall() {
    echo -e "${BLUE}正在为 frps 配置防火墙...${NC}"
    if ! command -v ufw &> /dev/null; then
        echo -e "${YELLOW}未检测到 ufw，请手动开放所需端口。${NC}"
        return
    fi

    if ! ufw status | grep -q "Status: active"; then
        echo -e "${YELLOW}ufw 防火墙未激活，请手动开放所需端口或激活 ufw。${NC}"
        return
    fi

    read -p "是否需要使用 ufw 自动为 frps 开放端口? (y/n, 默认 y): " AUTO_OPEN_PORTS
    if [[ "$AUTO_OPEN_PORTS" == "n" || "$AUTO_OPEN_PORTS" == "N" ]]; then
        echo -e "${YELLOW}已跳过 frps 的自动防火墙配置。${NC}"
        return
    fi

    echo -e "正在开放端口: ${BIND_PORT}"
    sudo ufw allow ${BIND_PORT}/tcp

    sudo ufw reload
    echo -e "${GREEN}frps 防火墙配置完成！${NC}"
}

# FRP 安装主流程
run_frp_install() {
    echo -e "${GREEN}--- 开始部署 FRP 服务端 (frps) ---${NC}"

    # 如果 frps 服务已存在，则停止
    if systemctl is-active --quiet frps; then
        echo -e "${YELLOW}检测到正在运行的 frps 服务，将停止并重新安装...${NC}"
        systemctl stop frps
    fi

    install_frp
    configure_frps
    setup_frp_systemd
    configure_frp_firewall

    # 重载、启用并启动服务
    echo -e "${BLUE}正在重载 systemd 并启动 frps 服务...${NC}"
    sudo systemctl daemon-reload
    sudo systemctl enable frps
    sudo systemctl start frps

    # 最终状态检查
    echo -e "\n${BLUE}--- FRP 部署完成 ---${NC}"
    echo -e "检查 frps 服务状态:"
    sleep 2 # 等待服务启动
    systemctl status frps --no-pager -l

    echo -e "\n${GREEN}恭喜！frps 服务已成功部署并正在运行。${NC}"
    echo -e "\n--- ${YELLOW}客户端 (frpc) 配置信息${NC} ---"
    # 使用 curl 获取公网 IP
    PUBLIC_IP=$(curl -s ip.sb || curl -s ifconfig.me)
    echo -e "服务器地址 (serverAddr): ${YELLOW}${PUBLIC_IP}${NC}"
    echo -e "绑定端口 (serverPort): ${YELLOW}${BIND_PORT}${NC}"
    echo -e "认证令牌 (token): ${YELLOW}${AUTH_TOKEN}${NC}"
    echo -e "------------------------------------"
    echo -e "请确保在您的云服务商安全组中也开放了端口 ${BIND_PORT}。"
}


#================================================================================
# DDNS 安装部分
#================================================================================

# --- DDNS 全局变量 ---
DDNS_UPDATE_SCRIPT_PATH="/usr/local/bin/update-ddns.sh"
DDNS_SERVICE_PATH="/etc/systemd/system/update-ddns.service"
DDNS_TIMER_PATH="/etc/systemd/system/update-ddns.timer"
DDNS_LOG_FILE="/var/log/noip_update.log"

# DDNS 安装主流程
run_ddns_install() {
    echo -e "${GREEN}--- 开始安装 No-IP DDNS 自动更新服务 ---${NC}"
    set -e # 在此函数内，任何错误都会导致退出

    # 获取运行 sudo 的普通用户名
    if [ -n "$SUDO_USER" ]; then
        REGULAR_USER="$SUDO_USER"
    else
        echo -e "${YELLOW}警告：无法确定原始用户，将使用 root 用户的主目录。${NC}"
        REGULAR_USER="root"
    fi
    USER_HOME=$(getent passwd "$REGULAR_USER" | cut -d: -f6)
    if [ -z "$USER_HOME" ]; then
        echo -e "${RED}错误：无法确定用户 '$REGULAR_USER' 的主目录。${NC}"
        exit 1
    fi
    CRED_FILE_PATH="$USER_HOME/.noip-credentials"

    # --- 1. 获取用户凭证 ---
    read -p "请输入您的 No-IP 用户名或邮箱 (Username/Email): " DDNS_USER
    read -sp "请输入您的 No-IP 密码 (Password): " DDNS_PASS
    echo
    read -p "请输入您要更新的完整主机名 (e.g., yourhost.ddns.net): " DDNS_HOST

    # --- 2. 创建并保护凭证文件 ---
    echo -e "${BLUE}-> 正在创建安全的凭证文件...${NC}"
    cat > "$CRED_FILE_PATH" << EOF
# No-IP Credentials
DDNS_USER="$DDNS_USER"
DDNS_PASS="$DDNS_PASS"
DDNS_HOST="$DDNS_HOST"
EOF
    chown "$REGULAR_USER:$REGULAR_USER" "$CRED_FILE_PATH"
    chmod 600 "$CRED_FILE_PATH"
    echo "   凭证文件已创建: $CRED_FILE_PATH"

    # --- 3. 创建更新脚本 ---
    echo -e "${BLUE}-> 正在安装 DDNS 更新脚本...${NC}"
    cat > "$DDNS_UPDATE_SCRIPT_PATH" << 'EOF'
#!/bin/bash
CRED_FILE_PATH_IN_SCRIPT=""
# 找到 sudo 用户的家目录来定位凭证文件
if [ -n "$SUDO_USER" ]; then
    USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    CRED_FILE_PATH_IN_SCRIPT="$USER_HOME/.noip-credentials"
else
    # Fallback for root or direct execution
    CRED_FILE_PATH_IN_SCRIPT="/root/.noip-credentials"
fi
LOG_FILE="/var/log/noip_update.log"
if [ ! -f "$CRED_FILE_PATH_IN_SCRIPT" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S'): 错误 - 凭证文件未找到: $CRED_FILE_PATH_IN_SCRIPT" >> "$LOG_FILE"
    exit 1
fi
source "$CRED_FILE_PATH_IN_SCRIPT"
CURRENT_IP=$(curl -s --fail https://ifconfig.me/ip || curl -s --fail https://api.ipify.org || curl -s --fail https://icanhazip.com)
if [ -z "$CURRENT_IP" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S'): 错误 - 无法获取公网 IP 地址。" >> "$LOG_FILE"
    exit 1
fi
LAST_IP_FILE="/tmp/noip_last_ip.txt"
if [ -f "$LAST_IP_FILE" ] && [ "$(cat "$LAST_IP_FILE")" == "$CURRENT_IP" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S'): IP 未变化 ($CURRENT_IP)，无需更新。" >> "$LOG_FILE"
    exit 0
fi
echo "$(date '+%Y-%m-%d %H:%M:%S'): IP 地址已变化。新 IP: $CURRENT_IP. 正在更新主机: $DDNS_HOST" >> "$LOG_FILE"
UPDATE_URL="https://dynupdate.no-ip.com/nic/update"
RESPONSE=$(curl -s --user-agent "Personal DDNS-Client/1.0 me@example.com" --user "${DDNS_USER}:${DDNS_PASS}" "${UPDATE_URL}?hostname=${DDNS_HOST}&myip=${CURRENT_IP}")
echo "$(date '+%Y-%m-%d %H:%M:%S'): 服务器响应: $RESPONSE" >> "$LOG_FILE"
if [[ "$RESPONSE" == *"good"* ]] || [[ "$RESPONSE" == *"nochg"* ]]; then
    echo "$CURRENT_IP" > "$LAST_IP_FILE"
fi
EOF
    chmod +x "$DDNS_UPDATE_SCRIPT_PATH"
    echo "   更新脚本已安装: $DDNS_UPDATE_SCRIPT_PATH"

    # --- 4. 创建 systemd 服务和定时器 ---
    echo -e "${BLUE}-> 正在创建 systemd 服务和定时器...${NC}"
    cat > "$DDNS_SERVICE_PATH" << EOF
[Unit]
Description=Dynamic DNS Update Service for No-IP
After=network.target
[Service]
Type=oneshot
User=$REGULAR_USER
ExecStart=$DDNS_UPDATE_SCRIPT_PATH
[Install]
WantedBy=multi-user.target
EOF
    cat > "$DDNS_TIMER_PATH" << EOF
[Unit]
Description=Run No-IP DDNS update script periodically
[Timer]
OnBootSec=2min
OnUnitActiveSec=15min
Unit=update-ddns.service
[Install]
WantedBy=timers.target
EOF
    echo "   systemd 文件已创建。"

    # --- 5. 启用并启动服务 ---
    echo -e "${BLUE}-> 正在启用并启动 DDNS 服务...${NC}"
    touch "$DDNS_LOG_FILE"
    chown "$REGULAR_USER:$REGULAR_USER" "$DDNS_LOG_FILE"
    systemctl daemon-reload
    systemctl enable update-ddns.timer
    systemctl start update-ddns.timer
    # 立即运行一次更新
    systemctl start update-ddns.service

    set +e # 恢复默认的错误处理
    echo -e "\n${BLUE}--- DDNS 安装完成 ---${NC}"
    echo -e "服务现在会开机自启，并每 15 分钟自动检查和更新 IP 地址。"
    echo -e "您可以运行以下命令来检查其状态："
    echo -e " ${YELLOW}sudo systemctl status update-ddns.timer${NC}"
    echo -e " ${YELLOW}sudo systemctl status update-ddns.service${NC}"
    echo -e "您可以查看详细的更新日志："
    echo -e " ${YELLOW}tail -f /var/log/noip_update.log${NC}"
}


#================================================================================
# 主菜单和执行逻辑
#================================================================================
main_menu() {
    clear
    echo -e "${GREEN}=======================================================${NC}"
    echo -e "${GREEN}         FRP 和 DDNS 集成安装脚本 V1.0             ${NC}"
    echo -e "${GREEN}=======================================================${NC}"
    echo -e "请选择要执行的操作:"
    echo -e "  ${YELLOW}1)${NC} 安装 FRP 服务端 (frps)"
    echo -e "  ${YELLOW}2)${NC} 安装 No-IP DDNS 自动更新服务"
    echo -e "  ${YELLOW}3)${NC} 安装以上全部 (FRP + DDNS)"
    echo -e "  ${YELLOW}4)${NC} 退出脚本"
    echo -e "-------------------------------------------------------"
    read -p "请输入选项 [1-4]: " choice

    case $choice in
        1)
            run_frp_install
            ;;
        2)
            run_ddns_install
            ;;
        3)
            echo -e "${BLUE}--- 将依次安装 FRP 和 DDNS ---${NC}\n"
            run_frp_install
            echo -e "\n${GREEN}--- FRP 安装流程结束 ---${NC}\n"
            read -p "按任意键继续安装 DDNS..."
            run_ddns_install
            ;;
        4)
            echo "脚本退出。"
            exit 0
            ;;
        *)
            echo -e "${RED}无效选项，请输入 1-4 之间的数字。${NC}"
            sleep 2
            main_menu
            ;;
    esac
}

# --- 脚本入口 ---
check_root
check_dependencies
main_menu

echo -e "\n${GREEN}所有选定任务已完成。${NC}"


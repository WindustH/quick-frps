#!/bin/bash

#================================================================================
# FRP Server (frps) Quick Install Script for Ubuntu
#
# Description: This script automates the installation and configuration of the
#              latest version of FRP server (frps) on Ubuntu systems.
# Features:
#   - Auto-detects system architecture (amd64, arm64).
#   - Fetches the latest version of frp from GitHub.
#   - Sets up frps as a systemd service for auto-start.
#   - Interactive configuration for ports, token, and dashboard.
#   - Optional firewall configuration (ufw).
#
# Usage:
#   wget -N --no-check-certificate https://<URL_TO_THIS_SCRIPT>/frps_install.sh
#   chmod +x frps_install.sh
#   ./frps_install.sh
#================================================================================

# --- Colors for output ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# --- Global Variables ---
FRP_INSTALL_DIR="/usr/local/frp"
FRP_CONFIG_FILE="/etc/frp/frps.toml"
SYSTEMD_SERVICE_FILE="/etc/systemd/system/frps.service"

# --- Functions ---

# Function to check if running as root
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${RED}错误：此脚本必须以 root 权限运行。${NC}"
        echo -e "请尝试使用 'sudo ./frps_install.sh' 命令运行。"
        exit 1
    fi
}

# Function to get system architecture
get_arch() {
    ARCH=$(uname -m)
    case $ARCH in
        x86_64)
            FRP_ARCH="amd64"
            ;;
        aarch64)
            FRP_ARCH="arm64"
            ;;
        *)
            echo -e "${RED}错误：不支持的系统架构: $ARCH ${NC}"
            exit 1
            ;;
    esac
    echo -e "${GREEN}检测到系统架构: ${FRP_ARCH}${NC}"
}
# Function to download and install frp
install_frp() {
    echo -e "${BLUE}开始下载并安装 frp...${NC}"
    FRP_FILENAME="frp_0.63.0_linux_amd64"

    # Extract
    tar -zxvf "${FRP_FILENAME}.tar.gz" -C /tmp
    if [ $? -ne 0 ]; then
        echo -e "${RED}错误：解压 frp 失败。${NC}"
        exit 1
    fi

    # Install
    sudo mkdir -p "${FRP_INSTALL_DIR}"
    sudo cp "/tmp/${FRP_FILENAME}/frps" "${FRP_INSTALL_DIR}/frps"
    sudo chmod +x "${FRP_INSTALL_DIR}/frps"

    rm -rf "/tmp/${FRP_FILENAME}"

    echo -e "${GREEN}frp 主程序安装成功！路径: ${FRP_INSTALL_DIR}/frps${NC}"
}

# Function to configure frps
configure_frps() {
    echo -e "${BLUE}开始配置 frps...${NC}"
    sudo mkdir -p "$(dirname ${FRP_CONFIG_FILE})"

    # Interactive configuration
    read -p "请输入 frps 的绑定端口 (默认为 7000): " BIND_PORT
    BIND_PORT=${BIND_PORT:-7000}

    read -p "请输入 frps 的认证令牌 (token，建议设置一个复杂的密码): " AUTH_TOKEN
    if [ -z "${AUTH_TOKEN}" ]; then
        echo -e "${RED}错误：认证令牌不能为空！${NC}"
        exit 1
    fi

    read -p "是否需要启用 Web 仪表盘? (y/n, 默认 n): " ENABLE_DASHBOARD
    if [[ "$ENABLE_DASHBOARD" == "y" || "$ENABLE_DASHBOARD" == "Y" ]]; then
        read -p "请输入仪表盘端口 (默认为 7500): " DASHBOARD_PORT
        DASHBOARD_PORT=${DASHBOARD_PORT:-7500}
        read -p "请输入仪表盘登录用户名 (默认为 admin): " DASHBOARD_USER
        DASHBOARD_USER=${DASHBOARD_USER:-admin}
        read -p "请输入仪表盘登录密码 (建议设置一个复杂的密码): " DASHBOARD_PWD
        if [ -z "${DASHBOARD_PWD}" ]; then
            echo -e "${RED}错误：仪表盘密码不能为空！${NC}"
            exit 1
        fi
        DASHBOARD_CONFIG="
[dashboard]
port = ${DASHBOARD_PORT}
user = \"${DASHBOARD_USER}\"
password = \"${DASHBOARD_PWD}\"
"
    else
        DASHBOARD_CONFIG=""
    fi

    # Create config file
    sudo bash -c "cat > ${FRP_CONFIG_FILE}" <<EOF
bindPort = ${BIND_PORT}
auth.token = "${AUTH_TOKEN}"
${DASHBOARD_CONFIG}
EOF

    echo -e "${GREEN}配置文件创建成功！路径: ${FRP_CONFIG_FILE}${NC}"
}

# Function to create systemd service
setup_systemd() {
    echo -e "${BLUE}正在创建 systemd 服务...${NC}"

    sudo bash -c "cat > ${SYSTEMD_SERVICE_FILE}" <<EOF
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

    echo -e "${GREEN}systemd 服务文件创建成功！路径: ${SYSTEMD_SERVICE_FILE}${NC}"

    # Reload, enable and start service
    echo -e "${BLUE}正在重载 systemd 并启动 frps 服务...${NC}"
    sudo systemctl daemon-reload
    sudo systemctl enable frps
    sudo systemctl start frps
}

# Function to configure firewall
configure_firewall() {
    echo -e "${BLUE}正在配置防火墙...${NC}"
    if ! command -v ufw &> /dev/null; then
        echo -e "${YELLOW}未检测到 ufw，请手动开放所需端口。${NC}"
        return
    fi

    if ! ufw status | grep -q "Status: active"; then
        echo -e "${YELLOW}ufw 防火墙未激活，请手动开放所需端口或激活 ufw。${NC}"
        return
    fi

    read -p "是否需要使用 ufw 自动开放端口? (y/n, 默认 y): " AUTO_OPEN_PORTS
    if [[ "$AUTO_OPEN_PORTS" == "n" || "$AUTO_OPEN_PORTS" == "N" ]]; then
        echo -e "${YELLOW}已跳过自动防火墙配置。${NC}"
        return
    fi

    echo -e "正在开放端口: ${BIND_PORT}"
    sudo ufw allow ${BIND_PORT}/tcp

    if [[ "$ENABLE_DASHBOARD" == "y" || "$ENABLE_DASHBOARD" == "Y" ]]; then
        echo -e "正在开放仪表盘端口: ${DASHBOARD_PORT}"
        sudo ufw allow ${DASHBOARD_PORT}/tcp
    fi

    sudo ufw reload
    echo -e "${GREEN}防火墙配置完成！${NC}"
}


# --- Main script execution ---

main() {
    check_root
    echo -e "${GREEN}--- 开始部署 FRP 服务端 (frps) ---${NC}"

    # Check for dependencies
    if ! command -v curl &> /dev/null || ! command -v wget &> /dev/null; then
        echo -e "${BLUE}正在安装依赖 (curl, wget)...${NC}"
        apt-get update
        apt-get install -y curl wget
    fi

    get_arch
    get_latest_version

    # Stop existing service if it exists
    if systemctl is-active --quiet frps; then
        echo -e "${YELLOW}检测到正在运行的 frps 服务，将停止并进行更新...${NC}"
        systemctl stop frps
    fi

    install_frp
    configure_frps
    setup_systemd
    configure_firewall

    # Final status check
    echo -e "${BLUE}--- 部署完成 ---${NC}"
    echo -e "检查 frps 服务状态:"
    sleep 2 # wait a bit for service to start
    systemctl status frps --no-pager -l

    echo -e "\n${GREEN}恭喜！frps 服务已成功部署并正在运行。${NC}"
    echo -e "\n--- ${YELLOW}客户端 (frpc) 配置信息${NC} ---"
    echo -e "服务器地址: ${YELLOW}$(curl -s ip.sb)${NC}"
    echo -e "绑定端口 (serverPort): ${YELLOW}${BIND_PORT}${NC}"
    echo -e "认证令牌 (token): ${YELLOW}${AUTH_TOKEN}${NC}"
    if [[ "$ENABLE_DASHBOARD" == "y" || "$ENABLE_DASHBOARD" == "Y" ]]; then
        echo -e "仪表盘地址: ${YELLOW}http://$(curl -s ip.sb):${DASHBOARD_PORT}${NC}"
        echo -e "仪表盘用户: ${YELLOW}${DASHBOARD_USER}${NC}"
        echo -e "仪表盘密码: ${YELLOW}${DASHBOARD_PWD}${NC}"
    fi
    echo -e "------------------------------------"
    echo -e "请确保在您的云服务商安全组中也开放了相应端口。"
}

# Run the main function
main
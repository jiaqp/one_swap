#!/bin/bash

SCRIPT_DIR=$(pwd)
BASE_DIR="$SCRIPT_DIR/sniproxy"

INSTALL_DIR="$BASE_DIR"
CONFIG_DIR="$BASE_DIR"
CONFIG_FILE="$CONFIG_DIR/config.yaml"
ALLOWLIST_FILE="$CONFIG_DIR/allowed_client_ips.txt"
SERVICE_FILE="/etc/systemd/system/sniproxy.service"
BINARY_NAME="sniproxy"
FIREWALL_CHAIN="SNIPROXY_CLIENT_ALLOWLIST"
LISTEN_PORT="443"

print_info() {
    echo "[INFO] $1"
}

print_error() {
    echo "[ERROR] $1" >&2
}

print_warning() {
    echo "[WARNING] $1"
}

check_command() {
    if ! command -v "$1" &> /dev/null; then
        print_error "命令 '$1' 未找到。请先安装它 (例如: apt update && apt install -y $1)"
        exit 1
    fi
}

validate_ip() {
    local ip=$1
    if [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        local IFS='.'
        local -a octets=($ip)
        local octet
        for octet in "${octets[@]}"; do
            if ((octet > 255)); then
                return 1
            fi
        done
        return 0
    fi
    return 1
}

validate_ip_or_cidr() {
    local value=$1
    local ip="${value%/*}"
    local cidr=""

    if [[ "$value" == */* ]]; then
        cidr="${value#*/}"
        if ! [[ "$cidr" =~ ^[0-9]+$ ]] || ((cidr < 0 || cidr > 32)); then
            return 1
        fi
    fi

    validate_ip "$ip"
}

read_user_input() {
    local var_name=$1
    if [ -t 0 ] && [ -e /dev/tty ]; then
        read -r "$var_name" </dev/tty 2>/dev/null || read -r "$var_name"
    else
        read -r "$var_name"
    fi
}

ensure_root() {
    if [ "$(id -u)" -ne 0 ]; then
        print_error "此脚本需要 root 权限运行。请使用 sudo 或以 root 用户身份运行。"
        exit 1
    fi
}

install_dependency() {
    local package_name=$1

    if command -v "$package_name" &> /dev/null; then
        return 0
    fi

    print_info "正在安装 $package_name..."
    if command -v apt-get &> /dev/null; then
        apt-get update -qq && apt-get install -y "$package_name"
    elif command -v yum &> /dev/null; then
        yum install -y "$package_name"
    else
        print_error "无法自动安装 $package_name，请手动安装后重试。"
        exit 1
    fi
}

restart_sniproxy() {
    if systemctl list-unit-files | grep -q "^sniproxy\.service"; then

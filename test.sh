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
        print_info "正在重启 SNIProxy 服务..."
        if systemctl restart sniproxy; then
            print_info "SNIProxy 服务已重启。"
        else
            print_error "SNIProxy 服务重启失败，请检查: journalctl -u sniproxy -n 50 --no-pager"
            return 1
        fi
    else
        print_warning "sniproxy.service 尚不存在，跳过服务重启。"
    fi
}

persist_firewall_rules() {
    if command -v netfilter-persistent &> /dev/null; then
        netfilter-persistent save >/dev/null 2>&1 && print_info "防火墙规则已持久化。"
    elif command -v iptables-save &> /dev/null && [ -d /etc/iptables ]; then
        iptables-save > /etc/iptables/rules.v4 2>/dev/null && print_info "iptables 规则已保存到 /etc/iptables/rules.v4。"
    else
        print_warning "未检测到 iptables 持久化工具，系统重启后白名单规则可能失效。"
        print_warning "Debian/Ubuntu 可安装: apt-get install -y iptables-persistent"
    fi
}

clear_client_allowlist() {
    print_info "正在清空客户端 IP 白名单，恢复为允许所有 IP 访问..."

    if command -v iptables &> /dev/null; then
        while iptables -C INPUT -p tcp --dport "$LISTEN_PORT" -j "$FIREWALL_CHAIN" 2>/dev/null; do
            iptables -D INPUT -p tcp --dport "$LISTEN_PORT" -j "$FIREWALL_CHAIN"
        done
        iptables -F "$FIREWALL_CHAIN" 2>/dev/null || true
        iptables -X "$FIREWALL_CHAIN" 2>/dev/null || true
    else
        print_warning "未找到 iptables，无法清理防火墙规则。"
    fi

    rm -f "$ALLOWLIST_FILE"
    persist_firewall_rules
    restart_sniproxy
    print_info "已恢复为允许所有 IP 访问 SNIProxy。"
}

apply_client_allowlist() {
    local allowed_ips=("$@")
    local ip

    check_command "iptables"

    print_info "正在应用客户端 IP 白名单..."
    iptables -N "$FIREWALL_CHAIN" 2>/dev/null || true
    iptables -F "$FIREWALL_CHAIN"

    for ip in "${allowed_ips[@]}"; do
        iptables -A "$FIREWALL_CHAIN" -p tcp --dport "$LISTEN_PORT" -s "$ip" -j ACCEPT
    done
    iptables -A "$FIREWALL_CHAIN" -p tcp --dport "$LISTEN_PORT" -j DROP

    if ! iptables -C INPUT -p tcp --dport "$LISTEN_PORT" -j "$FIREWALL_CHAIN" 2>/dev/null; then
        iptables -I INPUT -p tcp --dport "$LISTEN_PORT" -j "$FIREWALL_CHAIN"
    fi

    mkdir -p "$CONFIG_DIR"
    {
        echo "# 允许访问 SNIProxy 的客户端 IP/CIDR"
        echo "# 留空或删除此文件表示允许所有 IP"
        printf '%s\n' "${allowed_ips[@]}"
    } > "$ALLOWLIST_FILE"

    persist_firewall_rules
    restart_sniproxy
    print_info "白名单已生效，仅允许指定 IP/CIDR 访问 SNIProxy 的 $LISTEN_PORT 端口。"
}

get_saved_allowlist() {
    if [ -f "$ALLOWLIST_FILE" ]; then
        grep -v '^[[:space:]]*#' "$ALLOWLIST_FILE" | sed '/^[[:space:]]*$/d'
    fi
}

manage_client_allowlist() {
    ensure_root

    echo "========================================"
    echo "    SNIProxy 客户端 IP 白名单"
    echo "========================================"
    echo ""
    print_info "初次安装默认允许所有 IP 访问。"
    print_info "设置指定 IP 后，将只允许白名单访问 $LISTEN_PORT 端口，并自动重启 SNIProxy。"
    echo ""

    local current_allowed
    current_allowed=$(get_saved_allowlist)
    if [ -n "$current_allowed" ]; then
        print_info "当前允许访问的 IP/CIDR:"
        echo "$current_allowed" | sed 's/^/  - /'
    else
        print_info "当前状态: 未设置白名单，允许所有 IP 访问。"
    fi

    echo ""
    echo "请选择操作："
    echo "  1) 设置/覆盖允许 IP 白名单"
    echo "  2) 追加允许 IP 到白名单"
    echo "  3) 清空白名单（允许所有 IP）"
    echo "  0) 取消"
    echo ""
    echo -n "请输入选项 [0-3]: "

    local action
    read_user_input action
    action=$(echo "$action" | xargs 2>/dev/null || echo "")

    case "$action" in
        1|2)
            echo ""
            print_info "请输入允许访问的客户端 IP/CIDR，多个用空格或逗号分隔。"
            print_info "示例: 1.2.3.4 5.6.7.0/24"
            echo -n "允许 IP/CIDR: "

            local input_ips
            read_user_input input_ips
            input_ips=$(echo "$input_ips" | tr ',' ' ')

            local allowed_ips=()
            local ip

            if [ "$action" = "2" ] && [ -n "$current_allowed" ]; then
                while IFS= read -r ip; do
                    [ -n "$ip" ] && allowed_ips+=("$ip")
                done <<< "$current_allowed"
            fi

            for ip in $input_ips; do
                ip=$(echo "$ip" | tr -d '\r\n' | sed 's/[[:space:]]//g')
                [ -z "$ip" ] && continue
                if validate_ip_or_cidr "$ip"; then
                    allowed_ips+=("$ip")
                else
                    print_error "无效的 IP/CIDR 格式: $ip"
                    print_error "格式示例: 192.168.1.10 或 203.0.113.0/24"
                    exit 1
                fi
            done

            if [ "${#allowed_ips[@]}" -eq 0 ]; then
                print_warning "未输入任何 IP，保持当前配置不变。"
                return 0
            fi

            mapfile -t allowed_ips < <(printf '%s\n' "${allowed_ips[@]}" | awk '!seen[$0]++')
            apply_client_allowlist "${allowed_ips[@]}"
            ;;
        3)
            clear_client_allowlist
            ;;
        0)
            print_info "已取消。"
            ;;
        *)
            print_error "无效选项: $action"
            exit 1
            ;;
    esac
}

ask_initial_allowlist() {
    echo ""
    print_info "客户端 IP 访问限制配置"
    local current_allowed
    current_allowed=$(get_saved_allowlist)

    if [ -n "$current_allowed" ]; then
        print_info "检测到已保存的客户端 IP 白名单:"
        echo "$current_allowed" | sed 's/^/  - /'
        echo -n "是否继续应用此白名单？(Y/n): "

        local keep_answer
        read_user_input keep_answer
        keep_answer=$(echo "$keep_answer" | xargs 2>/dev/null || echo "")

        if [[ "$keep_answer" =~ ^[Nn]$ ]]; then
            clear_client_allowlist
        else
            local allowed_ips=()
            local ip
            while IFS= read -r ip; do
                [ -n "$ip" ] && allowed_ips+=("$ip")
            done <<< "$current_allowed"
            apply_client_allowlist "${allowed_ips[@]}"
        fi
        return 0
    fi

    print_info "初次安装可保持默认：允许所有 IP 访问。"
    echo -n "是否现在设置指定允许 IP？(y/N): "

    local answer
    read_user_input answer
    answer=$(echo "$answer" | xargs 2>/dev/null || echo "")

    if [[ "$answer" =~ ^[Yy]$ ]]; then
        manage_client_allowlist
    else
        print_info "保持默认：允许所有 IP 访问。"
    fi
}

install_or_update_sniproxy() {
    print_info "开始 SNIProxy 安装和配置..."

    ensure_root
    print_info "Root 权限检查通过。"

    print_info "检查依赖项 (curl)..."
    install_dependency "curl"
    check_command "curl"

    print_info "检查依赖项 (jq)..."
    install_dependency "jq"
    check_command "jq"

    print_info "所有依赖项已找到。"

    print_info "创建工作目录 $BASE_DIR..."
    mkdir -p "$BASE_DIR"
    if [ $? -ne 0 ]; then
        print_error "创建目录 $BASE_DIR 失败。"
        exit 1
    fi

    print_info "正在从 GitHub API 获取最新的 SNIProxy 版本..."
    SNIPROXY_VERSION=$(curl -sSL "https://api.github.com/repos/XIU2/SNIProxy/releases/latest" | jq -r '.tag_name')

    if [ -z "$SNIPROXY_VERSION" ] || [ "$SNIPROXY_VERSION" = "null" ]; then
        print_error "无法从 GitHub API 获取最新版本号。请检查网络或 API 状态。"
        exit 1
    fi
    print_info "获取到最新版本: $SNIPROXY_VERSION"

    print_info "检查现有的 SNIProxy 服务状态..."
    if systemctl is-active --quiet sniproxy.service; then
        print_info "SNIProxy 服务正在运行。正在停止服务以便更新..."
        if ! systemctl stop sniproxy.service; then
            print_error "停止 SNIProxy 服务失败。请手动检查服务状态。"
            exit 1
        fi
        print_info "SNIProxy 服务已停止。"
    else
        print_info "SNIProxy 服务未运行或不存在，无需停止。"
    fi

    ARCH=$(dpkg --print-architecture)
    if [ "$ARCH" = "amd64" ] || [ "$ARCH" = "arm64" ]; then
        print_info "检测到系统架构: $ARCH"
    else
        print_error "不支持的系统架构: $ARCH。仅支持 amd64 和 arm64。"
        exit 1
    fi

    TAR_FILENAME="sniproxy_linux_${ARCH}.tar.gz"
    DOWNLOAD_URL="https://github.com/XIU2/SNIProxy/releases/download/${SNIPROXY_VERSION}/${TAR_FILENAME}"
    TAR_FILE="/tmp/${TAR_FILENAME}"

    print_info "正在从 $DOWNLOAD_URL 下载 SNIProxy ${SNIPROXY_VERSION}..."
    if ! curl -fL "$DOWNLOAD_URL" -o "$TAR_FILE"; then
        print_error "下载 SNIProxy 失败。请检查网络连接、URL 是否有效或 GitHub Releases 状态。"
        exit 1
    fi
    print_info "下载完成。正在验证文件..."

    if ! tar -tzf "$TAR_FILE" > /dev/null; then
        print_error "下载的文件 $TAR_FILE 无效或已损坏。请尝试重新运行脚本。"
        rm -f "$TAR_FILE"
        exit 1
    fi
    print_info "文件验证成功。"

    print_info "正在解压 $TAR_FILE 到 /tmp..."
    EXTRACT_TMP_DIR="/tmp/sniproxy_extract_$$"
    mkdir -p "$EXTRACT_TMP_DIR"
    if ! tar -xzf "$TAR_FILE" -C "$EXTRACT_TMP_DIR"; then
        print_error "解压 SNIProxy 失败。"
        rm -f "$TAR_FILE"
        rm -rf "$EXTRACT_TMP_DIR"
        exit 1
    fi

    SNIPROXY_BINARY_PATH=$(find "$EXTRACT_TMP_DIR" -type f -name "$BINARY_NAME" | head -n 1)

    if [ -z "$SNIPROXY_BINARY_PATH" ]; then
        print_error "在解压的文件中未找到 $BINARY_NAME 可执行文件。"
        rm -f "$TAR_FILE"
        rm -rf "$EXTRACT_TMP_DIR"
        exit 1
    fi

    print_info "正在安装 $BINARY_NAME 到 $INSTALL_DIR..."
    mkdir -p "$INSTALL_DIR"
    if ! mv "$SNIPROXY_BINARY_PATH" "$INSTALL_DIR/$BINARY_NAME"; then
        print_error "移动 $BINARY_NAME 到 $INSTALL_DIR 失败。"
        rm -f "$TAR_FILE"
        rm -rf "$EXTRACT_TMP_DIR"
        exit 1
    fi

    print_info "设置执行权限..."
    chmod +x "$INSTALL_DIR/$BINARY_NAME"

    print_info "清理临时文件..."
    rm -f "$TAR_FILE"
    rm -rf "$EXTRACT_TMP_DIR"

    print_info "SNIProxy 安装成功。"

    print_info "配置目录为 $CONFIG_DIR"
    mkdir -p "$CONFIG_DIR"

    print_info "正在生成配置文件..."

    print_info "正在写入配置文件 $CONFIG_FILE..."
    cat <<EOF > "$CONFIG_FILE"
listen_addr: ":$LISTEN_PORT"
allow_all_hosts: true
EOF
    if [ $? -ne 0 ]; then
        print_error "写入配置文件 $CONFIG_FILE 失败。"
        exit 1
    fi
    print_info "配置文件写入成功。"

    print_info "创建 systemd 服务文件 $SERVICE_FILE..."
    cat << EOF > "$SERVICE_FILE"
[Unit]
Description=SNI Proxy
After=network.target

[Service]
ExecStart=$INSTALL_DIR/$BINARY_NAME -c $CONFIG_FILE
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

    if [ $? -ne 0 ]; then
        print_error "创建 systemd 服务文件失败。"
        exit 1
    fi
    print_info "Systemd 服务文件创建成功。"

    print_info "重新加载 systemd 配置..."
    systemctl daemon-reload

    print_info "设置 SNIProxy 服务开机自启..."
    systemctl enable sniproxy

    print_info "启动 SNIProxy 服务..."
    systemctl start sniproxy

    print_info "检查 SNIProxy 服务状态:"
    sleep 2
    systemctl status sniproxy --no-pager -l

    if [ $? -eq 0 ]; then
        print_info "SNIProxy 安装和配置完成！服务正在运行。"
    else
        print_error "SNIProxy 服务启动失败或状态异常。请检查上面的日志输出。"
        exit 1
    fi

    ask_initial_allowlist
}

show_menu() {
    echo "========================================"
    echo "    SNIProxy 安装和管理脚本"
    echo "========================================"
    echo "  1) 安装/更新 SNIProxy"
    echo "  2) 管理客户端 IP 白名单"
    echo "  0) 退出"
    echo "========================================"
    echo -n "请输入选项 [0-2]: "
}

while true; do
    show_menu
    read_user_input choice
    choice=$(echo "$choice" | xargs 2>/dev/null || echo "")

    case "$choice" in
        1)
            install_or_update_sniproxy
            break
            ;;
        2)
            manage_client_allowlist
            break
            ;;
        0)
            print_info "已退出。"
            exit 0
            ;;
        *)
            print_error "无效选项: $choice"
            echo ""
            ;;
    esac
done

exit 0

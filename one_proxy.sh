#!/bin/bash

# 透明代理管理脚本
# 使用 redsocks + iptables 实现真正的全局代理（支持 Docker、apt 等所有 TCP 流量）

# 检查 root 权限
if [ "$EUID" -ne 0 ]; then 
    echo -e "\033[0;31m错误: 此脚本需要 root 权限运行\033[0m"
    echo "请使用: sudo $0 $@"
    exit 1
fi

# 配置文件路径
CONFIG_FILE="/etc/transparent_proxy_config"
REDSOCKS_CONF="/etc/redsocks.conf"
REDSOCKS_PORT=12345

# 颜色定义
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# 显示使用说明
show_usage() {
    echo -e "${BLUE}================================${NC}"
    echo -e "${BOLD}${BLUE}透明代理管理脚本${NC}"
    echo -e "${BLUE}================================${NC}"
    echo "使用方法: $0 [选项]"
    echo ""
    echo "选项:"
    echo "  0 - 安装依赖（redsocks、iptables）"
    echo "  1 - 配置代理服务器"
    echo "  2 - 启用透明代理"
    echo "  3 - 禁用透明代理"
    echo "  4 - 查看代理状态"
    echo "  5 - 测试代理连接"
    echo "  status - 查看代理状态"
    echo "  help - 显示帮助信息"
    echo -e "${BLUE}================================${NC}"
}

# 安装依赖
install_dependencies() {
    echo -e "${BLUE}================================${NC}"
    echo -e "${BOLD}${BLUE}安装依赖${NC}"
    echo -e "${BLUE}================================${NC}"
    
    # 检测系统类型
    if [ -f /etc/debian_version ]; then
        echo "检测到 Debian/Ubuntu 系统"
        apt update
        apt install -y redsocks iptables iptables-persistent
    elif [ -f /etc/redhat-release ]; then
        echo "检测到 RHEL/CentOS 系统"
        yum install -y epel-release
        yum install -y redsocks iptables-services
    else
        echo -e "${RED}错误: 不支持的系统类型${NC}"
        return 1
    fi
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ 依赖安装成功${NC}"
    else
        echo -e "${RED}✗ 依赖安装失败${NC}"
        return 1
    fi
}

# 配置代理服务器
configure_proxy() {
    echo -e "${BLUE}================================${NC}"
    echo -e "${BOLD}${BLUE}配置代理服务器${NC}"
    echo -e "${BLUE}================================${NC}"
    
    # 如果配置文件存在，显示当前配置
    if [ -f "$CONFIG_FILE" ]; then
        echo "检测到已有配置:"
        cat "$CONFIG_FILE"
        echo ""
        read -p "是否覆盖现有配置? (y/n): " confirm
        if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
            echo "取消配置"
            return
        fi
    fi
    
    # 输入代理服务器信息
    read -p "请输入代理服务器地址 (例如: 43.139.51.236): " proxy_host
    read -p "请输入代理服务器端口 (例如: 59002): " proxy_port
    
    # 验证输入
    if [ -z "$proxy_host" ] || [ -z "$proxy_port" ]; then
        echo -e "${RED}错误: 代理地址和端口不能为空${NC}"
        return 1
    fi
    
    # 选择协议类型
    echo ""
    echo "请选择代理协议类型:"
    echo "  1 - SOCKS5 (推荐)"
    echo "  2 - HTTP CONNECT"
    read -p "请输入选择 [1/2] (默认: 1): " protocol_choice
    
    protocol_choice=${protocol_choice:-1}
    
    case "$protocol_choice" in
        1)
            proxy_type="socks5"
            ;;
        2)
            proxy_type="http-connect"
            ;;
        *)
            echo -e "${YELLOW}无效的选择，使用默认值 SOCKS5${NC}"
            proxy_type="socks5"
            ;;
    esac
    
    # 保存配置
    echo "PROXY_HOST=$proxy_host" > "$CONFIG_FILE"
    echo "PROXY_PORT=$proxy_port" >> "$CONFIG_FILE"
    echo "PROXY_TYPE=$proxy_type" >> "$CONFIG_FILE"
    
    echo ""
    echo -e "${GREEN}✓ 配置已保存到: $CONFIG_FILE${NC}"
    echo -e "  ${CYAN}代理地址: $proxy_host:$proxy_port${NC}"
    echo -e "  ${CYAN}协议类型: $proxy_type${NC}"
    echo ""
}

# 生成 redsocks 配置文件
generate_redsocks_conf() {
    # 读取配置
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${RED}错误: 未找到配置文件，请先运行 '$0 1' 配置代理${NC}"
        return 1
    fi
    
    source "$CONFIG_FILE"
    
    cat > "$REDSOCKS_CONF" << EOF
base {
    log_debug = off;
    log_info = on;
    log = "file:/var/log/redsocks.log";
    daemon = on;
    redirector = iptables;
}

redsocks {
    local_ip = 127.0.0.1;
    local_port = $REDSOCKS_PORT;
    ip = $PROXY_HOST;
    port = $PROXY_PORT;
    type = $PROXY_TYPE;
}
EOF
    
    echo -e "${GREEN}✓ 已生成 redsocks 配置文件${NC}"
}

# 设置 iptables 规则
setup_iptables() {
    source "$CONFIG_FILE"
    
    echo "正在设置 iptables 规则..."
    
    # 创建 REDSOCKS 链
    iptables -t nat -N REDSOCKS 2>/dev/null || iptables -t nat -F REDSOCKS
    
    # 【安全保护】排除 SSH 端口 22，确保即使代理失效也能 SSH 登录
    iptables -t nat -A REDSOCKS -p tcp --dport 22 -j RETURN
    
    # 排除本地网络
    iptables -t nat -A REDSOCKS -d 0.0.0.0/8 -j RETURN
    iptables -t nat -A REDSOCKS -d 10.0.0.0/8 -j RETURN
    iptables -t nat -A REDSOCKS -d 127.0.0.0/8 -j RETURN
    iptables -t nat -A REDSOCKS -d 169.254.0.0/16 -j RETURN
    iptables -t nat -A REDSOCKS -d 172.16.0.0/12 -j RETURN
    iptables -t nat -A REDSOCKS -d 192.168.0.0/16 -j RETURN
    iptables -t nat -A REDSOCKS -d 224.0.0.0/4 -j RETURN
    iptables -t nat -A REDSOCKS -d 240.0.0.0/4 -j RETURN
    
    # 排除代理服务器本身（避免死循环）
    iptables -t nat -A REDSOCKS -d $PROXY_HOST -j RETURN
    
    # 重定向所有 TCP 流量到 redsocks
    iptables -t nat -A REDSOCKS -p tcp -j REDIRECT --to-ports $REDSOCKS_PORT
    
    # 应用到 OUTPUT 链
    iptables -t nat -A OUTPUT -p tcp -j REDSOCKS
    
    echo -e "${GREEN}✓ iptables 规则设置完成${NC}"
    echo -e "  ${CYAN}✓ SSH 端口 (22) 已排除，确保远程访问安全${NC}"
}

# 清理 iptables 规则
cleanup_iptables() {
    echo "正在清理 iptables 规则..."
    
    # 从 OUTPUT 链删除 REDSOCKS 跳转
    iptables -t nat -D OUTPUT -p tcp -j REDSOCKS 2>/dev/null
    
    # 清空并删除 REDSOCKS 链
    iptables -t nat -F REDSOCKS 2>/dev/null
    iptables -t nat -X REDSOCKS 2>/dev/null
    
    echo -e "${GREEN}✓ iptables 规则已清理${NC}"
}

# 启用透明代理
enable_proxy() {
    echo -e "${BLUE}================================${NC}"
    echo -e "${BOLD}${BLUE}启用透明代理${NC}"
    echo -e "${BLUE}================================${NC}"
    
    # 检查配置文件
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${RED}错误: 未找到配置文件${NC}"
        echo "请先运行 '$0 1' 配置代理服务器"
        return 1
    fi
    
    # 生成 redsocks 配置
    generate_redsocks_conf || return 1
    
    # 启动 redsocks
    echo "正在启动 redsocks..."
    pkill redsocks 2>/dev/null
    redsocks -c "$REDSOCKS_CONF"
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ redsocks 已启动${NC}"
    else
        echo -e "${RED}✗ redsocks 启动失败${NC}"
        return 1
    fi
    
    # 等待 redsocks 完全启动
    sleep 1
    
    # 设置 iptables 规则
    setup_iptables
    
    source "$CONFIG_FILE"
    
    echo ""
    echo -e "${GREEN}✓ 透明代理已启用${NC}"
    echo -e "  ${CYAN}代理服务器: $PROXY_HOST:$PROXY_PORT${NC}"
    echo -e "  ${CYAN}协议类型: $PROXY_TYPE${NC}"
    echo ""
    echo "说明:"
    echo "  - 所有 TCP 流量将通过代理"
    echo "  - Docker、apt、curl 等所有程序自动生效"
    echo -e "  - ${GREEN}SSH 端口 (22) 已排除，即使代理失效也能正常 SSH 连接${NC}"
    echo "  - 使用 '$0 3' 可以禁用透明代理"
    echo ""
}

# 禁用透明代理
disable_proxy() {
    echo -e "${BLUE}================================${NC}"
    echo -e "${BOLD}${BLUE}禁用透明代理${NC}"
    echo -e "${BLUE}================================${NC}"
    
    # 清理 iptables 规则
    cleanup_iptables
    
    # 停止 redsocks
    echo "正在停止 redsocks..."
    pkill redsocks
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ redsocks 已停止${NC}"
    fi
    
    echo ""
    echo -e "${GREEN}✓ 透明代理已禁用${NC}"
    echo ""
}

# 查看代理状态
show_status() {
    echo -e "${BLUE}================================${NC}"
    echo -e "${BOLD}${BLUE}透明代理状态${NC}"
    echo -e "${BLUE}================================${NC}"
    
    # 显示配置信息
    if [ -f "$CONFIG_FILE" ]; then
        echo "配置文件: $CONFIG_FILE"
        source "$CONFIG_FILE"
        echo -e "${CYAN}代理服务器: $PROXY_HOST:$PROXY_PORT${NC}"
        echo -e "${CYAN}协议类型: $PROXY_TYPE${NC}"
    else
        echo "配置文件: 未配置"
    fi
    
    echo ""
    
    # 检查 redsocks 运行状态
    if pgrep redsocks > /dev/null; then
        echo -e "${GREEN}redsocks 状态: ✓ 运行中${NC}"
    else
        echo -e "${RED}redsocks 状态: ✗ 未运行${NC}"
    fi
    
    echo ""
    
    # 显示 iptables 规则
    echo "iptables 规则:"
    if iptables -t nat -L REDSOCKS -n 2>/dev/null | grep -q "REDIRECT"; then
        echo -e "${GREEN}  ✓ 透明代理规则已启用${NC}"
        echo ""
        iptables -t nat -L REDSOCKS -n --line-numbers | head -15
    else
        echo -e "${YELLOW}  ✗ 透明代理规则未启用${NC}"
    fi
    
    echo -e "${BLUE}================================${NC}"
}

# 测试代理连接
test_proxy() {
    echo -e "${BLUE}================================${NC}"
    echo -e "${BOLD}${BLUE}测试代理连接${NC}"
    echo -e "${BLUE}================================${NC}"
    
    echo "正在测试出口 IP..."
    echo ""
    
    # 测试 IP
    IP=$(curl -s --max-time 10 https://api.ip.sb/ip)
    
    if [ -n "$IP" ]; then
        echo -e "${GREEN}✓ 连接成功${NC}"
        echo -e "  ${CYAN}当前出口 IP: $IP${NC}"
        
        if [ -f "$CONFIG_FILE" ]; then
            source "$CONFIG_FILE"
            if [ "$IP" == "$PROXY_HOST" ]; then
                echo -e "  ${GREEN}✓ 正在使用代理${NC}"
            else
                echo -e "  ${YELLOW}⚠ 出口 IP 与代理服务器不同${NC}"
            fi
        fi
    else
        echo -e "${RED}✗ 连接失败${NC}"
    fi
    
    echo ""
    
    # 测试 Google
    echo "正在测试 Google 连接..."
    if curl -s --max-time 10 https://www.google.com > /dev/null 2>&1; then
        echo -e "${GREEN}✓ Google 可访问${NC}"
    else
        echo -e "${RED}✗ Google 不可访问${NC}"
    fi
    
    echo -e "${BLUE}================================${NC}"
}

# 交互式菜单
interactive_menu() {
    while true; do
        echo ""
        echo -e "${BLUE}================================${NC}"
        echo -e "${BOLD}${BLUE}透明代理管理脚本${NC}"
        echo -e "${BLUE}================================${NC}"
        echo "请选择操作:"
        echo "  0 - 安装依赖（首次使用）"
        echo "  1 - 配置代理服务器"
        echo "  2 - 启用透明代理"
        echo "  3 - 禁用透明代理"
        echo "  4 - 查看代理状态"
        echo "  5 - 测试代理连接"
        echo "  q - 退出脚本"
        echo -e "${BLUE}================================${NC}"
        echo -n "请输入选项 [0/1/2/3/4/5/q]: "
        
        read choice
        
        case "$choice" in
            0)
                install_dependencies
                ;;
            1)
                configure_proxy
                ;;
            2)
                enable_proxy
                ;;
            3)
                disable_proxy
                ;;
            4)
                show_status
                ;;
            5)
                test_proxy
                ;;
            q|Q)
                echo ""
                echo "退出脚本"
                exit 0
                ;;
            *)
                echo ""
                echo -e "${RED}错误: 无效的选项 '$choice'${NC}"
                ;;
        esac
    done
}

# 主程序
main() {
    if [ $# -gt 0 ]; then
        case "$1" in
            0)
                install_dependencies
                ;;
            1)
                configure_proxy
                ;;
            2)
                enable_proxy
                ;;
            3)
                disable_proxy
                ;;
            4|status)
                show_status
                ;;
            5|test)
                test_proxy
                ;;
            help|--help|-h)
                show_usage
                ;;
            *)
                echo -e "${RED}错误: 未知选项 '$1'${NC}"
                echo ""
                show_usage
                exit 1
                ;;
        esac
    else
        interactive_menu
    fi
}

# 执行主程序
main "$@"

#!/bin/bash

# 代理管理脚本
# 用于管理Linux/macOS系统的全局代理（支持 HTTP/HTTPS 和 SOCKS5）

# 配置文件路径
CONFIG_FILE="$HOME/.proxy_config"

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
    echo -e "${BOLD}${BLUE}代理管理脚本${NC}"
    echo -e "${BLUE}================================${NC}"
    echo "使用方法: $0 [选项]"
    echo ""
    echo "选项:"
    echo "  0 - 配置代理服务器"
    echo "  1 - 启用全局代理"
    echo "  2 - 禁用全局代理"
    echo "  status - 查看当前代理状态"
    echo "  help - 显示帮助信息"
    echo -e "${BLUE}================================${NC}"
}

# 配置代理
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
    read -p "请输入代理服务器地址 (例如: 127.0.0.1): " proxy_host
    read -p "请输入代理服务器端口 (例如: 1080): " proxy_port
    
    # 验证输入
    if [ -z "$proxy_host" ] || [ -z "$proxy_port" ]; then
        echo -e "${RED}错误: 代理地址和端口不能为空${NC}"
        return 1
    fi
    
    # 选择协议类型
    echo ""
    echo "请选择代理协议类型:"
    echo "  1 - HTTP/HTTPS (适用于只支持 HTTP 代理的应用)"
    echo "  2 - SOCKS5 (适用于只支持 SOCKS5 代理的应用)"
    echo "  3 - Mixed (推荐：同时支持 HTTP 和 SOCKS5，适用于 Xray mixed 端口)"
    read -p "请输入选择 [1/2/3] (默认: 3): " protocol_choice
    
    # 默认值处理
    protocol_choice=${protocol_choice:-3}
    
    case "$protocol_choice" in
        1)
            proxy_protocol="http"
            protocol_desc="HTTP/HTTPS"
            ;;
        2)
            proxy_protocol="socks5"
            protocol_desc="SOCKS5"
            ;;
        3)
            proxy_protocol="mixed"
            protocol_desc="Mixed (HTTP + SOCKS5)"
            ;;
        *)
            echo -e "${YELLOW}错误: 无效的选择，使用默认值 Mixed${NC}"
            proxy_protocol="mixed"
            protocol_desc="Mixed (HTTP + SOCKS5)"
            ;;
    esac
    
    # 保存配置
    echo "PROXY_HOST=$proxy_host" > "$CONFIG_FILE"
    echo "PROXY_PORT=$proxy_port" >> "$CONFIG_FILE"
    echo "PROXY_PROTOCOL=$proxy_protocol" >> "$CONFIG_FILE"
    
    echo ""
    echo -e "${GREEN}✓ 配置已保存到: $CONFIG_FILE${NC}"
    echo -e "  ${CYAN}代理地址: $proxy_host:$proxy_port${NC}"
    echo -e "  ${CYAN}协议类型: $protocol_desc${NC}"
    echo ""
}

# 启用全局代理（写入 ~/.zshrc）
enable_proxy_persistent() {
    echo -e "${BLUE}================================${NC}"
    echo -e "${BOLD}${BLUE}启用全局代理${NC}"
    echo -e "${BLUE}================================${NC}"
    
    # 检查配置文件是否存在
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${RED}错误: 未找到代理配置文件${NC}"
        echo "请先运行 '$0 0' 配置代理服务器"
        return 1
    fi
    
    # 读取配置
    source "$CONFIG_FILE"
    
    if [ -z "$PROXY_HOST" ] || [ -z "$PROXY_PORT" ]; then
        echo -e "${RED}错误: 配置文件格式错误${NC}"
        return 1
    fi
    
    # 向后兼容：如果没有 PROXY_PROTOCOL，默认使用 mixed
    PROXY_PROTOCOL=${PROXY_PROTOCOL:-mixed}
    
    # 准备代理 URL
    HTTP_PROXY_URL="http://${PROXY_HOST}:${PROXY_PORT}"
    SOCKS_PROXY_URL="socks5://${PROXY_HOST}:${PROXY_PORT}"
    
    # 确定Shell配置文件
    SHELL_CONFIG="$HOME/.zshrc"
    if [ ! -f "$SHELL_CONFIG" ]; then
        touch "$SHELL_CONFIG"
    fi
    
    # 检查是否已经存在代理配置
    if grep -q ">>> SOCKS_PROXY_AUTO_CONFIG >>>" "$SHELL_CONFIG"; then
        echo -e "${YELLOW}⚠ 检测到 $SHELL_CONFIG 中已存在代理配置${NC}"
        read -p "是否覆盖现有配置? (y/n): " confirm
        if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
            echo "取消操作"
            return
        fi
        # 删除旧配置
        sed -i.bak '/>>> SOCKS_PROXY_AUTO_CONFIG >>>/,/<<< SOCKS_PROXY_AUTO_CONFIG <<</d' "$SHELL_CONFIG"
    fi
    
    # 添加代理配置到 ~/.zshrc
    cat >> "$SHELL_CONFIG" << 'EOF_HEADER'

# >>> SOCKS_PROXY_AUTO_CONFIG >>>
# 由 socks5_proxy.sh 自动生成，请勿手动编辑
EOF_HEADER
    
    # 根据协议类型添加相应的配置
    case "$PROXY_PROTOCOL" in
        http)
            cat >> "$SHELL_CONFIG" << EOF
export http_proxy="$HTTP_PROXY_URL"
export https_proxy="$HTTP_PROXY_URL"
export HTTP_PROXY="$HTTP_PROXY_URL"
export HTTPS_PROXY="$HTTP_PROXY_URL"
export no_proxy="localhost,127.0.0.1,::1"
export NO_PROXY="localhost,127.0.0.1,::1"
EOF
            ;;
        socks5)
            cat >> "$SHELL_CONFIG" << EOF
export all_proxy="$SOCKS_PROXY_URL"
export ALL_PROXY="$SOCKS_PROXY_URL"
export no_proxy="localhost,127.0.0.1,::1"
export NO_PROXY="localhost,127.0.0.1,::1"
EOF
            ;;
        mixed)
            cat >> "$SHELL_CONFIG" << EOF
export http_proxy="$HTTP_PROXY_URL"
export https_proxy="$HTTP_PROXY_URL"
export HTTP_PROXY="$HTTP_PROXY_URL"
export HTTPS_PROXY="$HTTP_PROXY_URL"
export all_proxy="$SOCKS_PROXY_URL"
export ALL_PROXY="$SOCKS_PROXY_URL"
export no_proxy="localhost,127.0.0.1,::1"
export NO_PROXY="localhost,127.0.0.1,::1"
EOF
            ;;
    esac
    
    cat >> "$SHELL_CONFIG" << 'EOF_FOOTER'
# <<< SOCKS_PROXY_AUTO_CONFIG <<<
EOF_FOOTER
    
    # 在当前Shell中也启用代理
    case "$PROXY_PROTOCOL" in
        http)
            export http_proxy="$HTTP_PROXY_URL"
            export https_proxy="$HTTP_PROXY_URL"
            export HTTP_PROXY="$HTTP_PROXY_URL"
            export HTTPS_PROXY="$HTTP_PROXY_URL"
            export no_proxy="localhost,127.0.0.1,::1"
            export NO_PROXY="localhost,127.0.0.1,::1"
            ;;
        socks5)
            export all_proxy="$SOCKS_PROXY_URL"
            export ALL_PROXY="$SOCKS_PROXY_URL"
            export no_proxy="localhost,127.0.0.1,::1"
            export NO_PROXY="localhost,127.0.0.1,::1"
            ;;
        mixed)
            export http_proxy="$HTTP_PROXY_URL"
            export https_proxy="$HTTP_PROXY_URL"
            export HTTP_PROXY="$HTTP_PROXY_URL"
            export HTTPS_PROXY="$HTTP_PROXY_URL"
            export all_proxy="$SOCKS_PROXY_URL"
            export ALL_PROXY="$SOCKS_PROXY_URL"
            export no_proxy="localhost,127.0.0.1,::1"
            export NO_PROXY="localhost,127.0.0.1,::1"
            ;;
    esac
    
    echo ""
    echo -e "${GREEN}✓ 全局代理已启用${NC}"
    case "$PROXY_PROTOCOL" in
        http)
            echo -e "  ${CYAN}协议类型: HTTP/HTTPS${NC}"
            echo -e "  ${CYAN}代理地址: $HTTP_PROXY_URL${NC}"
            ;;
        socks5)
            echo -e "  ${CYAN}协议类型: SOCKS5${NC}"
            echo -e "  ${CYAN}代理地址: $SOCKS_PROXY_URL${NC}"
            ;;
        mixed)
            echo -e "  ${CYAN}协议类型: Mixed (HTTP + SOCKS5)${NC}"
            echo -e "  ${CYAN}HTTP/HTTPS: $HTTP_PROXY_URL${NC}"
            echo -e "  ${CYAN}SOCKS5: $SOCKS_PROXY_URL${NC}"
            ;;
    esac
    echo "  配置文件: $SHELL_CONFIG"
    echo ""
    echo "说明:"
    echo "  - 当前Shell会话中代理已生效"
    echo "  - 所有新打开的终端都会自动启用此代理"
    echo "  - 使用 '$0 2' 可以禁用代理"
    echo ""
}

# 禁用全局代理（从 ~/.zshrc 中移除）
disable_proxy_persistent() {
    echo -e "${BLUE}================================${NC}"
    echo -e "${BOLD}${BLUE}禁用全局代理${NC}"
    echo -e "${BLUE}================================${NC}"
    
    # 确定Shell配置文件
    SHELL_CONFIG="$HOME/.zshrc"
    
    # 检查是否存在代理配置
    if ! grep -q ">>> SOCKS_PROXY_AUTO_CONFIG >>>" "$SHELL_CONFIG" 2>/dev/null; then
        echo -e "${YELLOW}⚠ 未检测到代理配置${NC}"
    else
        # 删除配置块
        sed -i.bak '/>>> SOCKS_PROXY_AUTO_CONFIG >>>/,/<<< SOCKS_PROXY_AUTO_CONFIG <<</d' "$SHELL_CONFIG"
        echo -e "${GREEN}✓ 已从 $SHELL_CONFIG 中移除代理配置${NC}"
    fi
    
    # 在当前Shell中也禁用代理
    unset http_proxy https_proxy ftp_proxy all_proxy
    unset HTTP_PROXY HTTPS_PROXY FTP_PROXY ALL_PROXY
    unset no_proxy NO_PROXY
    
    echo ""
    echo -e "${GREEN}✓ 全局代理已禁用${NC}"
    echo ""
    echo "说明:"
    echo "  - 当前Shell会话中代理已禁用"
    echo "  - 新打开的终端将不会自动启用代理"
    echo "  - 已打开的其他终端需要手动执行 'source ~/.zshrc' 刷新配置"
    echo ""
}

# 查看代理状态
show_status() {
    echo -e "${BLUE}================================${NC}"
    echo -e "${BOLD}${BLUE}当前代理状态${NC}"
    echo -e "${BLUE}================================${NC}"
    
    # 显示配置信息
    if [ -f "$CONFIG_FILE" ]; then
        echo "配置文件: $CONFIG_FILE"
        source "$CONFIG_FILE"
        echo "配置的代理: $PROXY_HOST:$PROXY_PORT"
        
        # 显示协议类型
        PROXY_PROTOCOL=${PROXY_PROTOCOL:-mixed}
        case "$PROXY_PROTOCOL" in
            http)
                echo "协议类型: HTTP/HTTPS"
                ;;
            socks5)
                echo "协议类型: SOCKS5"
                ;;
            mixed)
                echo "协议类型: Mixed (HTTP + SOCKS5)"
                ;;
            *)
                echo "协议类型: 未知 ($PROXY_PROTOCOL)"
                ;;
        esac
    else
        echo "配置文件: 未配置"
    fi
    
    echo ""
    echo "当前Shell环境变量:"
    
    # 检查是否有代理变量被设置
    has_http_proxy=false
    has_socks_proxy=false
    
    if [ -n "$http_proxy" ] || [ -n "$https_proxy" ]; then
        has_http_proxy=true
        echo "  http_proxy   = ${http_proxy:-未设置}"
        echo "  https_proxy  = ${https_proxy:-未设置}"
    fi
    
    if [ -n "$all_proxy" ]; then
        has_socks_proxy=true
        echo "  all_proxy    = ${all_proxy:-未设置}"
    fi
    
    if [ -n "$no_proxy" ]; then
        echo "  no_proxy     = ${no_proxy:-未设置}"
    fi
    
    echo ""
    if $has_http_proxy || $has_socks_proxy; then
        if $has_http_proxy && $has_socks_proxy; then
        echo -e "${GREEN}状态: ✓ Mixed 代理已启用 (HTTP + SOCKS5)${NC}"
        elif $has_http_proxy; then
            echo -e "${GREEN}状态: ✓ HTTP/HTTPS 代理已启用${NC}"
        elif $has_socks_proxy; then
            echo -e "${GREEN}状态: ✓ SOCKS5 代理已启用${NC}"
        fi
    else
        echo -e "${RED}状态: ✗ 代理未启用${NC}"
    fi
    
    # 检查配置文件状态
    echo ""
    echo "配置文件状态:"
    SHELL_CONFIG="$HOME/.zshrc"
    if grep -q ">>> SOCKS_PROXY_AUTO_CONFIG >>>" "$SHELL_CONFIG" 2>/dev/null; then
        echo -e "  ${GREEN}✓ 代理配置已写入配置文件${NC}"
        echo "  配置文件: $SHELL_CONFIG"
        echo "  说明: 所有新终端都会自动启用代理"
    else
        echo -e "  ${YELLOW}✗ 配置文件中无代理配置${NC}"
        echo "  说明: 代理仅在当前Shell中生效（如果已启用）"
    fi
    
    echo "================================"
}

# 交互式菜单
interactive_menu() {
    while true; do
        echo ""
        echo -e "${BLUE}================================${NC}"
        echo -e "${BOLD}${BLUE}代理管理脚本${NC}"
        echo -e "${BLUE}================================${NC}"
        echo "请选择操作:"
        echo "  0 - 配置代理服务器"
        echo "  1 - 启用全局代理"
        echo "  2 - 禁用全局代理"
        echo "  3 - 查看当前代理状态"
        echo "  q - 退出脚本"
        echo "================================"
        echo -n "请输入选项 [0/1/2/3/q]: "
        
        read choice
        
        case "$choice" in
            0)
                configure_proxy
                ;;
            1)
                enable_proxy_persistent
                ;;
            2)
                disable_proxy_persistent
                ;;
            3)
                show_status
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
    # 如果提供了命令行参数，使用命令行模式
    if [ $# -gt 0 ]; then
        case "$1" in
            0)
                configure_proxy
                ;;
            1|enable-persistent)
                enable_proxy_persistent
                ;;
            2|disable-persistent)
                disable_proxy_persistent
                ;;
            status)
                show_status
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
        # 没有参数时使用交互式菜单
        interactive_menu
    fi
}

# 执行主程序
main "$@"

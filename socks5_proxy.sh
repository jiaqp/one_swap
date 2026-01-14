#!/bin/bash

# SOCKS5代理管理脚本
# 用于管理Linux系统的全局临时SOCKS5代理

# 配置文件路径
CONFIG_FILE="$HOME/.socks5_proxy_config"

# 显示使用说明
show_usage() {
    echo "================================"
    echo "SOCKS5代理管理脚本"
    echo "================================"
    echo "使用方法: $0 [选项]"
    echo ""
    echo "选项:"
    echo "  0 - 配置SOCKS5代理服务器"
    echo "  1 - 启用全局代理"
    echo "  2 - 禁用全局代理"
    echo "  status - 查看当前代理状态"
    echo "  help - 显示帮助信息"
    echo "================================"
}

# 配置SOCKS5代理
configure_proxy() {
    echo "================================"
    echo "配置SOCKS5代理服务器"
    echo "================================"
    
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
    read -p "请输入SOCKS5代理服务器地址 (例如: 127.0.0.1): " proxy_host
    read -p "请输入SOCKS5代理服务器端口 (例如: 1080): " proxy_port
    
    # 验证输入
    if [ -z "$proxy_host" ] || [ -z "$proxy_port" ]; then
        echo "错误: 代理地址和端口不能为空"
        return 1
    fi
    
    # 保存配置
    echo "PROXY_HOST=$proxy_host" > "$CONFIG_FILE"
    echo "PROXY_PORT=$proxy_port" >> "$CONFIG_FILE"
    
    echo ""
    echo "✓ 配置已保存到: $CONFIG_FILE"
    echo "  代理地址: $proxy_host:$proxy_port"
    echo ""
}

# 启用全局代理
enable_proxy() {
    echo "================================"
    echo "启用全局代理"
    echo "================================"
    
    # 检查配置文件是否存在
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "错误: 未找到代理配置文件"
        echo "请先运行 '$0 0' 配置代理服务器"
        return 1
    fi
    
    # 读取配置
    source "$CONFIG_FILE"
    
    if [ -z "$PROXY_HOST" ] || [ -z "$PROXY_PORT" ]; then
        echo "错误: 配置文件格式错误"
        return 1
    fi
    
    # 设置代理环境变量
    PROXY_URL="socks5://${PROXY_HOST}:${PROXY_PORT}"
    
    export http_proxy="$PROXY_URL"
    export https_proxy="$PROXY_URL"
    export ftp_proxy="$PROXY_URL"
    export all_proxy="$PROXY_URL"
    export HTTP_PROXY="$PROXY_URL"
    export HTTPS_PROXY="$PROXY_URL"
    export FTP_PROXY="$PROXY_URL"
    export ALL_PROXY="$PROXY_URL"
    
    # 不代理本地地址
    export no_proxy="localhost,127.0.0.1,::1"
    export NO_PROXY="localhost,127.0.0.1,::1"
    
    echo "✓ 全局代理已启用"
    echo "  代理地址: $PROXY_URL"
    echo ""
    echo "提示: 此配置仅在当前Shell会话中有效"
    echo "如需永久生效，请将以下内容添加到 ~/.bashrc 或 ~/.zshrc:"
    echo ""
    echo "export http_proxy=\"$PROXY_URL\""
    echo "export https_proxy=\"$PROXY_URL\""
    echo "export all_proxy=\"$PROXY_URL\""
    echo "export no_proxy=\"localhost,127.0.0.1,::1\""
    echo ""
    
    # 创建临时激活脚本，方便在其他终端中使用
    ACTIVATE_SCRIPT="/tmp/socks5_proxy_activate.sh"
    cat > "$ACTIVATE_SCRIPT" << EOF
#!/bin/bash
# 自动生成的SOCKS5代理激活脚本
export http_proxy="$PROXY_URL"
export https_proxy="$PROXY_URL"
export ftp_proxy="$PROXY_URL"
export all_proxy="$PROXY_URL"
export HTTP_PROXY="$PROXY_URL"
export HTTPS_PROXY="$PROXY_URL"
export FTP_PROXY="$PROXY_URL"
export ALL_PROXY="$PROXY_URL"
export no_proxy="localhost,127.0.0.1,::1"
export NO_PROXY="localhost,127.0.0.1,::1"
echo "✓ SOCKS5代理已在当前Shell中启用: $PROXY_URL"
EOF
    chmod +x "$ACTIVATE_SCRIPT"
    
    echo "在新的终端中启用代理，请运行:"
    echo "source $ACTIVATE_SCRIPT"
    echo ""
}

# 禁用全局代理
disable_proxy() {
    echo "================================"
    echo "禁用全局代理"
    echo "================================"
    
    unset http_proxy
    unset https_proxy
    unset ftp_proxy
    unset all_proxy
    unset HTTP_PROXY
    unset HTTPS_PROXY
    unset FTP_PROXY
    unset ALL_PROXY
    unset no_proxy
    unset NO_PROXY
    
    echo "✓ 全局代理已禁用"
    echo ""
    echo "提示: 此操作仅影响当前Shell会话"
    echo "如需在新终端中禁用代理，请运行:"
    echo "source /tmp/socks5_proxy_deactivate.sh"
    echo ""
    
    # 创建临时禁用脚本
    DEACTIVATE_SCRIPT="/tmp/socks5_proxy_deactivate.sh"
    cat > "$DEACTIVATE_SCRIPT" << 'EOF'
#!/bin/bash
# 自动生成的SOCKS5代理禁用脚本
unset http_proxy https_proxy ftp_proxy all_proxy
unset HTTP_PROXY HTTPS_PROXY FTP_PROXY ALL_PROXY
unset no_proxy NO_PROXY
echo "✓ SOCKS5代理已在当前Shell中禁用"
EOF
    chmod +x "$DEACTIVATE_SCRIPT"
}

# 查看代理状态
show_status() {
    echo "================================"
    echo "当前代理状态"
    echo "================================"
    
    # 显示配置信息
    if [ -f "$CONFIG_FILE" ]; then
        echo "配置文件: $CONFIG_FILE"
        source "$CONFIG_FILE"
        echo "配置的代理: $PROXY_HOST:$PROXY_PORT"
    else
        echo "配置文件: 未配置"
    fi
    
    echo ""
    echo "当前Shell环境变量:"
    
    if [ -n "$http_proxy" ] || [ -n "$https_proxy" ] || [ -n "$all_proxy" ]; then
        echo "  http_proxy   = ${http_proxy:-未设置}"
        echo "  https_proxy  = ${https_proxy:-未设置}"
        echo "  all_proxy    = ${all_proxy:-未设置}"
        echo "  no_proxy     = ${no_proxy:-未设置}"
        echo ""
        echo "状态: ✓ 代理已启用"
    else
        echo "  http_proxy   = 未设置"
        echo "  https_proxy  = 未设置"
        echo "  all_proxy    = 未设置"
        echo ""
        echo "状态: ✗ 代理未启用"
    fi
    
    echo "================================"
}

# 主程序
main() {
    case "$1" in
        0)
            configure_proxy
            ;;
        1)
            enable_proxy
            ;;
        2)
            disable_proxy
            ;;
        status)
            show_status
            ;;
        help|--help|-h|"")
            show_usage
            ;;
        *)
            echo "错误: 未知选项 '$1'"
            echo ""
            show_usage
            exit 1
            ;;
    esac
}

# 执行主程序
main "$@"

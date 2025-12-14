#!/bin/bash
# SmartDNS 管理脚本
# 功能：安装/配置SmartDNS 或 恢复systemd-resolved

# 配置参数
SMARTDNS_CONF_URL="https://raw.githubusercontent.com/pymumu/smartdns/master/etc/smartdns/smartdns.conf"
DOMAIN_LIST_URL="https://raw.githubusercontent.com/1-stream/1stream-public-utils/refs/heads/main/stream.text.list"
UNLOCK_IP=""  # 解锁机IP，运行时由用户输入
OUTPUT_FILE="smartdns.conf"
TEMP_DOMAIN_FILE="/tmp/domain_list.txt"
RESOLV_BACKUP_DIR="/etc/systemd/resolved.conf.d"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # 无颜色

# 打印函数
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# 验证IP地址格式
validate_ip() {
    local ip=$1
    # 正则表达式验证IPv4地址
    if [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        # 检查每个数字是否在0-255范围内
        local IFS='.'
        local -a octets=($ip)
        for octet in "${octets[@]}"; do
            if ((octet > 255)); then
                return 1
            fi
        done
        return 0
    else
        return 1
    fi
}

# 获取解锁机IP
get_unlock_ip() {
    echo ""
    print_info "请输入解锁机IP地址"
    print_info "（这是流媒体解锁服务器的IP地址）"
    echo ""
    
    local max_attempts=5
    local attempt=0
    
    while [ $attempt -lt $max_attempts ]; do
        echo -n "解锁机IP [例如: 203.0.113.100]: "
        
        # 尝试从/dev/tty读取，如果失败则从stdin读取
        if [ -e /dev/tty ]; then
            read -r input_ip </dev/tty 2>/dev/null || read -r input_ip
        else
            read -r input_ip
        fi
        
        ((attempt++))
        
        # 如果用户直接回车，提示重新输入
        if [ -z "$input_ip" ]; then
            print_warning "未输入IP地址，请输入有效的IP (尝试 $attempt/$max_attempts)"
            continue
        fi
        
        # 验证IP格式
        if validate_ip "$input_ip"; then
            # 清理IP地址，去除任何空白和换行符
            UNLOCK_IP=$(echo "$input_ip" | tr -d '\r\n' | sed 's/[[:space:]]//g')
            print_success "解锁机IP已设置为: $UNLOCK_IP"
            
            # 确认
            echo ""
            echo -n "确认使用此IP？(y/n): "
            if [ -e /dev/tty ]; then
                read -r -n 1 confirm </dev/tty 2>/dev/null || read -r -n 1 confirm
            else
                read -r -n 1 confirm
            fi
            echo ""
            if [[ $confirm =~ ^[Yy]$ ]]; then
                # 导出变量确保在所有地方可用
                export UNLOCK_IP
                print_info "解锁IP已确认并设置"
                break
            else
                print_info "请重新输入"
                attempt=$((attempt - 1))  # 不计入尝试次数
            fi
        else
            print_error "无效的IP地址格式，请重新输入"
            print_info "IP地址格式示例: 192.168.1.1 或 203.0.113.100"
        fi
    done
    
    # 验证UNLOCK_IP是否成功设置
    if [ -z "$UNLOCK_IP" ]; then
        print_error "未能成功设置解锁机IP"
        print_error "已达到最大尝试次数或输入被中断"
        exit 1
    fi
    
    echo ""
}

# 检查命令是否存在
check_command() {
    if ! command -v $1 &> /dev/null; then
        print_error "缺少必要命令: $1"
        print_info "请安装: apt-get install $1 (Debian/Ubuntu) 或 yum install $1 (CentOS/RHEL)"
        exit 1
    fi
}

# 显示菜单
show_menu() {
    clear
    echo "========================================"
    echo "    SmartDNS 管理脚本 v1.2"
    echo "========================================"
    echo ""
    echo "请选择操作："
    echo ""
    echo "  1) 安装/配置 SmartDNS（流媒体解锁）"
    echo "     - 自动检测并安装SmartDNS"
    echo "     - 自动处理端口冲突"
    echo "     - 配置流媒体解锁规则"
    echo ""
    echo "  2) 恢复 systemd-resolved（系统默认）"
    echo "     - 停止SmartDNS服务"
    echo "     - 恢复systemd-resolved"
    echo "     - 恢复或重建DNS配置"
    echo ""
    echo "  0) 退出"
    echo ""
    echo "========================================"
    echo -n "请输入选项 [0-2]: "
}

# 恢复systemd-resolved的函数
restore_systemd_resolved() {
    echo ""
    echo "========================================"
    echo "    恢复 systemd-resolved"
    echo "========================================"
    echo ""
    
    # 检查root权限
    if [ "$EUID" -ne 0 ]; then 
        print_error "需要root权限来恢复systemd-resolved"
        print_info "请使用 sudo 运行此脚本"
        exit 1
    fi
    
    # 步骤1: 停止SmartDNS
    print_info "步骤1/5: 停止SmartDNS服务..."
    if systemctl is-active --quiet smartdns 2>/dev/null; then
        systemctl stop smartdns
        print_success "SmartDNS服务已停止"
    else
        print_info "SmartDNS服务未运行"
    fi
    
    # 禁用SmartDNS开机自启
    if systemctl is-enabled --quiet smartdns 2>/dev/null; then
        systemctl disable smartdns
        print_success "SmartDNS开机自启已禁用"
    fi
    
    echo ""
    
    # 步骤2: 恢复systemd-resolved
    print_info "步骤2/5: 恢复systemd-resolved服务..."
    
    # 检查systemd-resolved是否存在
    if ! systemctl list-unit-files | grep -q systemd-resolved; then
        print_warning "systemd-resolved服务不存在，跳过"
    else
        # 启用并启动systemd-resolved
        systemctl enable systemd-resolved 2>/dev/null || true
        systemctl start systemd-resolved 2>/dev/null || true
        
        if systemctl is-active --quiet systemd-resolved; then
            print_success "systemd-resolved服务已启动"
        else
            print_warning "systemd-resolved启动失败，将使用静态配置"
        fi
    fi
    
    echo ""
    
    # 步骤3: 恢复resolv.conf
    print_info "步骤3/5: 恢复DNS配置..."
    
    # 解锁resolv.conf（如果被锁定）
    chattr -i /etc/resolv.conf 2>/dev/null || true
    
    # 检查是否有备份文件
    backup_files=$(find /etc -maxdepth 1 -name "resolv.conf.backup*" 2>/dev/null | sort -r)
    
    if [ -n "$backup_files" ]; then
        latest_backup=$(echo "$backup_files" | head -1)
        print_info "找到备份文件: $latest_backup"
        
        print_info "自动恢复最新备份: $latest_backup"
        rm -f /etc/resolv.conf
        cp "$latest_backup" /etc/resolv.conf
        print_success "已从备份恢复resolv.conf"
    else
        print_warning "未找到备份文件"
        create_new_resolv_conf
    fi
    
    echo ""
    
    # 步骤4: 配置systemd-resolved（如果需要）
    print_info "步骤4/5: 配置systemd-resolved..."
    
    if systemctl is-active --quiet systemd-resolved; then
        # 配置systemd-resolved使用指定的上游DNS
        mkdir -p "$RESOLV_BACKUP_DIR"
        
        cat > "${RESOLV_BACKUP_DIR}/custom-dns.conf" << 'EOF'
[Resolve]
DNS=1.1.1.1 8.8.8.8
FallbackDNS=1.0.0.1 8.8.4.4
#DNSOverTLS=no
#DNSSEC=no
EOF
        
        # 创建或更新resolv.conf符号链接
        rm -f /etc/resolv.conf
        ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
        
        # 重启systemd-resolved使配置生效
        systemctl restart systemd-resolved
        
        print_success "systemd-resolved已配置上游DNS: 1.1.1.1, 8.8.8.8"
    else
        print_info "systemd-resolved未运行，使用静态配置"
    fi
    
    echo ""
    
    # 步骤5: 验证DNS解析
    print_info "步骤5/5: 验证DNS解析..."
    sleep 2
    
    if command -v dig &> /dev/null; then
        if dig google.com +short +time=3 &> /dev/null; then
            print_success "DNS解析测试通过"
            echo "测试结果: $(dig google.com +short | head -1)"
        else
            print_warning "DNS解析测试失败"
        fi
    elif command -v nslookup &> /dev/null; then
        if nslookup google.com &> /dev/null; then
            print_success "DNS解析测试通过"
        else
            print_warning "DNS解析测试失败"
        fi
    fi
    
    echo ""
    
    # 显示当前DNS配置
    print_info "当前DNS配置:"
    cat /etc/resolv.conf
    
    echo ""
    print_success "systemd-resolved恢复完成！"
    echo ""
    print_info "如果DNS解析有问题，请尝试："
    echo "  1. 重启网络: systemctl restart NetworkManager"
    echo "  2. 重启系统: reboot"
}

# 创建新的resolv.conf配置
create_new_resolv_conf() {
    print_info "创建新的resolv.conf配置..."
    
    cat > /etc/resolv.conf << 'EOF'
# DNS配置
# 由SmartDNS管理脚本生成

nameserver 1.1.1.1
nameserver 8.8.8.8
nameserver 1.0.0.1

options timeout:2
options attempts:2
EOF
    
    print_success "已创建新的resolv.conf，使用上游DNS: 1.1.1.1, 8.8.8.8"
}

# 检查必要命令（仅模式1需要）
check_required_commands() {
    print_info "检查必要命令..."
    check_command wget
    check_command curl
}

# 检测系统类型
detect_system() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        VER=$VERSION_ID
    elif [ -f /etc/redhat-release ]; then
        OS="centos"
    else
        OS="unknown"
    fi
    echo $OS
}

# 安装SmartDNS
install_smartdns() {
    local os_type=$(detect_system)
    print_info "检测到系统类型: ${os_type}"
    
    case "$os_type" in
        ubuntu|debian)
            print_info "使用APT包管理器安装SmartDNS..."
            
            # 获取系统架构
            local arch=$(dpkg --print-architecture)
            local download_url=""
            
            # 获取最新版本信息
            print_info "获取最新版本信息..."
            local latest_release=$(curl -s https://api.github.com/repos/pymumu/smartdns/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
            
            if [ -z "$latest_release" ]; then
                print_warning "无法获取最新版本，使用默认版本"
                latest_release="Release47"
            fi
            
            print_info "最新版本: ${latest_release}"
            
            # 根据架构选择下载链接
            case "$arch" in
                amd64|x86_64)
                    download_url="https://github.com/pymumu/smartdns/releases/download/${latest_release}/smartdns.1.2024.12.14-1010.x86_64-linux-all.tar.gz"
                    ;;
                arm64|aarch64)
                    download_url="https://github.com/pymumu/smartdns/releases/download/${latest_release}/smartdns.1.2024.12.14-1010.aarch64-linux-all.tar.gz"
                    ;;
                armhf|armv7l)
                    download_url="https://github.com/pymumu/smartdns/releases/download/${latest_release}/smartdns.1.2024.12.14-1010.armv7l-linux-all.tar.gz"
                    ;;
                *)
                    print_error "不支持的架构: ${arch}"
                    return 1
                    ;;
            esac
            
            print_info "下载SmartDNS安装包..."
            cd /tmp
            if wget -q --show-progress "${download_url}" -O smartdns.tar.gz; then
                print_success "下载成功"
            else
                print_error "下载失败，尝试备用方法..."
                # 尝试通过包管理器安装
                if apt-cache search smartdns | grep -q smartdns; then
                    print_info "从软件源安装SmartDNS..."
                    apt-get update
                    apt-get install -y smartdns
                    return $?
                else
                    print_error "无法安装SmartDNS"
                    return 1
                fi
            fi
            
            # 解压并安装
            print_info "解压安装包..."
            tar xzf smartdns.tar.gz
            cd smartdns
            
            print_info "安装SmartDNS..."
            chmod +x ./install
            ./install -i
            
            # 清理临时文件
            cd /tmp
            rm -rf smartdns smartdns.tar.gz
            
            print_success "SmartDNS安装完成"
            ;;
            
        centos|rhel|fedora)
            print_info "使用YUM/DNF包管理器安装SmartDNS..."
            
            # 获取系统架构
            local arch=$(uname -m)
            
            # 获取最新版本
            local latest_release=$(curl -s https://api.github.com/repos/pymumu/smartdns/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
            
            if [ -z "$latest_release" ]; then
                latest_release="Release47"
            fi
            
            print_info "下载SmartDNS安装包..."
            cd /tmp
            wget -q --show-progress "https://github.com/pymumu/smartdns/releases/download/${latest_release}/smartdns.1.2024.12.14-1010.${arch}-linux-all.tar.gz" -O smartdns.tar.gz
            
            tar xzf smartdns.tar.gz
            cd smartdns
            chmod +x ./install
            ./install -i
            
            cd /tmp
            rm -rf smartdns smartdns.tar.gz
            
            print_success "SmartDNS安装完成"
            ;;
            
        *)
            print_error "不支持的系统类型: ${os_type}"
            print_info "请手动安装SmartDNS: https://github.com/pymumu/smartdns"
            return 1
            ;;
    esac
    
    return 0
}

# 安装和配置SmartDNS的主函数
install_and_configure_smartdns() {
    echo ""
    echo "========================================"
    echo "    安装/配置 SmartDNS"
    echo "========================================"
    echo ""
    
    # 获取解锁机IP
    get_unlock_ip
    
    # 检查必要命令
    check_required_commands
    
    # 检查SmartDNS是否已安装
    print_info "检查SmartDNS安装状态..."
if command -v smartdns &> /dev/null; then
    smartdns_version=$(smartdns -v 2>&1 | head -1 || echo "未知版本")
    print_success "SmartDNS已安装: ${smartdns_version}"
else
    print_warning "SmartDNS未安装"
    
    # 检查是否有root权限
    if [ "$EUID" -ne 0 ]; then 
        print_error "安装SmartDNS需要root权限"
        print_info "请使用 sudo 运行此脚本"
        exit 1
    fi
    
    print_info "自动安装SmartDNS..."
    if install_smartdns; then
        print_success "SmartDNS安装成功"
        
        # 启用并启动服务
        systemctl enable smartdns
        print_success "SmartDNS已设置为开机自启"
    else
        print_error "SmartDNS安装失败"
        exit 1
    fi
fi

echo ""

# 检查并处理端口53冲突
check_and_fix_port_conflict() {
    print_info "检查端口53占用情况..."
    
    # 检查端口53是否被占用
    if command -v lsof &> /dev/null; then
        port_usage=$(lsof -i :53 2>/dev/null)
    elif command -v ss &> /dev/null; then
        port_usage=$(ss -tulnp | grep :53 2>/dev/null)
    else
        print_warning "无法检查端口占用（缺少lsof或ss命令）"
        return 0
    fi
    
    # 如果端口53未被占用，直接返回
    if [ -z "$port_usage" ]; then
        print_success "端口53未被占用"
        return 0
    fi
    
    # 检查是否是systemd-resolved占用
    if echo "$port_usage" | grep -q "systemd-resolve"; then
        print_warning "检测到systemd-resolved正在占用端口53"
        print_info "端口53详情："
        lsof -i :53 2>/dev/null | head -5
        echo ""
        
        # 检查root权限
        if [ "$EUID" -ne 0 ]; then 
            print_error "需要root权限来禁用systemd-resolved"
            print_info "请使用 sudo 运行此脚本"
            return 1
        fi
        
        print_info "自动禁用systemd-resolved并配置DNS..."
        print_info "停止systemd-resolved服务..."
        systemctl stop systemd-resolved
        
        print_info "禁用systemd-resolved开机自启..."
        systemctl disable systemd-resolved
        
        # 备份并配置resolv.conf
        if [ -L /etc/resolv.conf ]; then
            print_info "删除resolv.conf符号链接..."
            rm /etc/resolv.conf
        elif [ -f /etc/resolv.conf ]; then
            print_info "备份原resolv.conf..."
            mv /etc/resolv.conf /etc/resolv.conf.backup.$(date +%Y%m%d_%H%M%S)
        fi
        
        # 创建新的resolv.conf
        print_info "配置新的DNS解析..."
        cat > /etc/resolv.conf << 'RESOLVEOF'
# SmartDNS配置
nameserver 127.0.0.1
# 备用DNS（用于SmartDNS启动前）
nameserver 1.1.1.1
nameserver 8.8.8.8
RESOLVEOF
        
        # 防止resolv.conf被自动修改
        chattr +i /etc/resolv.conf 2>/dev/null || print_warning "无法锁定resolv.conf（可能不影响使用）"
        
        print_success "systemd-resolved已禁用"
        print_success "DNS已配置为使用SmartDNS（127.0.0.1）"
        
        # 验证端口是否已释放
        sleep 2
        if lsof -i :53 2>/dev/null | grep -q ":53"; then
            print_warning "端口53仍被占用，可能需要重启系统"
        else
            print_success "端口53已释放"
        fi
        
        return 0
    else
        # 其他进程占用端口53
        print_warning "端口53被其他进程占用："
        lsof -i :53 2>/dev/null || ss -tulnp | grep :53
        echo ""
        print_info "请手动停止占用端口53的服务，然后重新运行此脚本"
        return 1
    fi
}

    # 执行端口冲突检查
    if ! check_and_fix_port_conflict; then
        print_error "端口冲突未解决，无法继续"
        print_info "解决后请重新运行脚本"
        exit 1
    fi

    echo ""

    # 步骤1: 下载SmartDNS官方配置文件
    print_info "步骤1/5: 从官方仓库下载SmartDNS配置文件..."
    if wget -q --show-progress -O "${OUTPUT_FILE}" "${SMARTDNS_CONF_URL}"; then
        print_success "配置文件下载成功"
    else
        print_error "下载配置文件失败"
        exit 1
    fi

    # 步骤2: 修改上游DNS服务器
    print_info "步骤2/5: 修改上游DNS服务器..."

    # 删除原有的server和bind配置（避免冲突）
    sed -i '/^server /d' "${OUTPUT_FILE}"
    sed -i '/^bind /d' "${OUTPUT_FILE}"
    
    print_info "已清理原配置中的server和bind配置"

    # 在配置文件开头添加新的DNS服务器配置
    cat > "${OUTPUT_FILE}.tmp" << 'EOF'
# ===== 自动生成的配置 =====
# 上游DNS服务器
server 1.1.1.1
server 8.8.8.8

# 基本配置
bind :53
cache-size 32768
prefetch-domain yes
serve-expired yes

EOF

    # 将原配置文件内容追加到临时文件
    cat "${OUTPUT_FILE}" >> "${OUTPUT_FILE}.tmp"
    mv "${OUTPUT_FILE}.tmp" "${OUTPUT_FILE}"

    # 验证配置
    local bind_count=$(grep -c "^bind " "${OUTPUT_FILE}")
    local server_count=$(grep -c "^server " "${OUTPUT_FILE}")
    
    print_success "上游DNS服务器已设置为 1.1.1.1 和 8.8.8.8"
    print_info "配置验证: bind配置数=${bind_count}, server配置数=${server_count}"
    
    if [ "$bind_count" -gt 1 ]; then
        print_warning "检测到多个bind配置，可能导致冲突"
    fi

    # 步骤3: 下载并处理域名列表
    print_info "步骤3/5: 从URL下载域名列表并转换..."

    if curl -s "${DOMAIN_LIST_URL}" -o "${TEMP_DOMAIN_FILE}"; then
        print_success "域名列表下载成功"
    else
        print_error "下载域名列表失败"
        exit 1
    fi

    # 统计域名数量
    total_domains=$(grep -v "^#" "${TEMP_DOMAIN_FILE}" | grep -v "^$" | wc -l)
    print_info "共找到 ${total_domains} 个域名"

    # 步骤4: 将域名转换为address格式并追加到配置文件
    print_info "步骤4/5: 生成SmartDNS address规则..."

    # 验证并清理UNLOCK_IP
    UNLOCK_IP=$(echo "$UNLOCK_IP" | tr -d '\r\n' | sed 's/[[:space:]]//g')
    
    if [ -z "$UNLOCK_IP" ]; then
        print_error "解锁机IP未设置！"
        print_error "这是一个脚本错误，UNLOCK_IP变量为空"
        print_info "当前UNLOCK_IP值: '${UNLOCK_IP}'"
        exit 1
    fi

    print_info "使用解锁IP: ${UNLOCK_IP}"
    print_info "IP长度: ${#UNLOCK_IP} 字符"
    
    # 再次验证IP格式
    if ! validate_ip "$UNLOCK_IP"; then
        print_error "解锁机IP格式无效: $UNLOCK_IP"
        exit 1
    fi
    
    print_success "IP格式验证通过"

    # 添加分隔注释
    cat >> "${OUTPUT_FILE}" << EOF

# ===== 流媒体解锁域名规则 =====
# 自动生成，请勿手动修改此部分
# 解锁IP: ${UNLOCK_IP}
EOF

    # 处理域名列表并追加到配置文件
    processed_count=0
    while IFS= read -r line || [ -n "$line" ]; do
        # 去除首尾空白和换行符
        line=$(echo "$line" | tr -d '\r\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        
        # 跳过空行
        if [ -z "$line" ]; then
            continue
        fi
        
        # 处理注释行
        if [[ "$line" =~ ^# ]]; then
            echo "$line" >> "${OUTPUT_FILE}"
            continue
        fi
        
        # 生成address规则（最简单直接的方式）
        address_line="address /${line}/${UNLOCK_IP}"
        echo "${address_line}" >> "${OUTPUT_FILE}"
        ((processed_count++))
    done < "${TEMP_DOMAIN_FILE}"

    print_success "已生成 ${processed_count} 条address规则"

    # 清理临时文件
    rm -f "${TEMP_DOMAIN_FILE}"

    # 显示配置文件信息
    print_success "配置文件生成完成: ${OUTPUT_FILE}"
    echo ""
    print_info "配置文件统计:"
    echo "  - 总行数: $(wc -l < ${OUTPUT_FILE})"
    echo "  - address规则数: $(grep -c "^address " ${OUTPUT_FILE})"
    echo "  - 上游DNS: 1.1.1.1, 8.8.8.8"
    echo "  - 解锁IP: ${UNLOCK_IP}"
    echo ""

    # 显示前几条示例
    print_info "前5条address规则示例:"
    grep "^address " "${OUTPUT_FILE}" | head -5
    echo ""

    # 步骤5: 安装配置文件到系统
    print_info "步骤5/5: 安装配置文件..."
    
    if [ "$EUID" -ne 0 ]; then 
        print_error "需要root权限来安装配置文件"
        print_info "请使用 sudo 运行此脚本，或手动复制: sudo cp ${OUTPUT_FILE} /etc/smartdns/smartdns.conf"
        exit 1
    fi
    
    # 备份原配置
    if [ -f /etc/smartdns/smartdns.conf ]; then
        backup_file="/etc/smartdns/smartdns.conf.backup.$(date +%Y%m%d_%H%M%S)"
        cp /etc/smartdns/smartdns.conf "${backup_file}"
        print_success "原配置已备份到: ${backup_file}"
    fi
    
    # 创建目录（如果不存在）
    mkdir -p /etc/smartdns
    
    # 复制配置文件
    cp "${OUTPUT_FILE}" /etc/smartdns/smartdns.conf
    print_success "配置文件已安装到: /etc/smartdns/smartdns.conf"
    
    # 自动重启服务
    print_info "自动重启SmartDNS服务..."
    # 启动前再次检查端口
    print_info "启动前端口检查..."
    if lsof -i :53 2>/dev/null | grep -v smartdns | grep -q ":53"; then
        print_warning "端口53仍被其他进程占用，尝试自动处理..."
        lsof -i :53 2>/dev/null | grep -v smartdns
        # 自动停止占用进程
        systemctl stop systemd-resolved 2>/dev/null || true
        sleep 1
    fi
    
    print_info "正在重启SmartDNS服务..."
    if systemctl restart smartdns; then
        print_success "SmartDNS服务已重启"
        sleep 2
        
        # 显示服务状态
        systemctl status smartdns --no-pager
        echo ""
        
        # 验证端口监听
        print_info "验证SmartDNS监听状态..."
        sleep 1
        if ss -tulnp 2>/dev/null | grep smartdns | grep -q ":53"; then
            print_success "SmartDNS正在监听端口53"
            ss -tulnp 2>/dev/null | grep smartdns | grep ":53"
        else
            print_warning "SmartDNS可能未正常监听端口53"
            print_info "请检查日志: journalctl -u smartdns -n 20"
        fi
        
        echo ""
        print_info "测试DNS解析..."
        if command -v dig &> /dev/null; then
            if dig @127.0.0.1 google.com +short +time=2 &> /dev/null; then
                print_success "DNS解析测试通过"
                echo "测试结果: $(dig @127.0.0.1 google.com +short | head -1)"
            else
                print_warning "DNS解析测试失败，请检查配置"
            fi
        elif command -v nslookup &> /dev/null; then
            if nslookup google.com 127.0.0.1 &> /dev/null; then
                print_success "DNS解析测试通过"
            else
                print_warning "DNS解析测试失败，请检查配置"
            fi
        else
            print_info "建议安装dig工具测试: apt-get install dnsutils"
        fi
    else
        print_error "SmartDNS服务重启失败"
        echo ""
        print_info "查看错误日志:"
        journalctl -u smartdns -n 20 --no-pager
        echo ""
        print_info "故障排查建议："
        echo "  1. 检查配置文件: cat /etc/smartdns/smartdns.conf"
        echo "  2. 手动运行测试: smartdns -f -c /etc/smartdns/smartdns.conf"
        echo "  3. 检查端口占用: lsof -i :53"
    fi

    print_success "脚本执行完成！"
}

# ==================== 主程序入口 ====================

# 显示菜单并获取用户选择
while true; do
    show_menu
    read -r choice </dev/tty
    
    # 去除前后空格
    choice=$(echo "$choice" | xargs 2>/dev/null || echo "")
    
    # 处理空输入
    if [ -z "$choice" ]; then
        echo ""
        print_warning "您没有输入任何内容"
        print_info "请输入 1（安装SmartDNS）、2（恢复系统默认）或 0（退出）"
        echo ""
        sleep 2
        continue
    fi
    
    # 处理用户选择
    case $choice in
        1)
            echo ""
            install_and_configure_smartdns
            break
            ;;
        2)
            echo ""
            restore_systemd_resolved
            break
            ;;
        0)
            echo ""
            print_info "已退出"
            exit 0
            ;;
        *)
            echo ""
            print_error "无效的选项: '$choice'"
            print_warning "请输入数字 0、1 或 2"
            echo ""
            sleep 2
            continue
            ;;
    esac
done

echo ""
echo "========================================"
echo "    操作完成"
echo "========================================"


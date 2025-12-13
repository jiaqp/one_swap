#!/bin/bash

################################################################################
# Linux虚拟内存自动优化脚本
# 功能：根据系统CPU、内存、硬盘性能自动计算并设置最优虚拟内存参数
# 作者：系统性能优化脚本
# 版本：2.0
################################################################################

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # 无颜色

# 日志函数
log_info() {
    echo -e "${GREEN}[信息]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[警告]${NC} $1"
}

log_error() {
    echo -e "${RED}[错误]${NC} $1"
}

log_header() {
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================${NC}"
}

# 检查是否以root权限运行
check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "请使用root权限运行此脚本（使用sudo）"
        exit 1
    fi
}

# 安装必要的工具
install_dependencies() {
    log_info "检查并安装必要的工具..."
    
    local tools=("hdparm" "dmidecode" "bc" "sysstat")
    local missing_tools=()
    
    for tool in "${tools[@]}"; do
        if ! command -v $tool &> /dev/null; then
            missing_tools+=($tool)
        fi
    done
    
    if [ ${#missing_tools[@]} -gt 0 ]; then
        log_warn "缺少工具: ${missing_tools[*]}"
        log_info "正在安装缺失工具..."
        
        if command -v apt-get &> /dev/null; then
            apt-get update -qq
            apt-get install -y ${missing_tools[@]} 2>/dev/null
        elif command -v yum &> /dev/null; then
            yum install -y ${missing_tools[@]} 2>/dev/null
        elif command -v dnf &> /dev/null; then
            dnf install -y ${missing_tools[@]} 2>/dev/null
        else
            log_error "无法识别的包管理器，请手动安装: ${missing_tools[*]}"
            exit 1
        fi
    fi
    
    log_info "所有依赖工具已就绪"
}

# 获取CPU信息
get_cpu_info() {
    log_header "正在检测CPU性能"
    
    # CPU核心数
    CPU_CORES=$(nproc)
    log_info "CPU核心数: ${CPU_CORES}"
    
    # CPU型号
    CPU_MODEL=$(grep "model name" /proc/cpuinfo | head -n1 | cut -d':' -f2 | xargs)
    log_info "CPU型号: ${CPU_MODEL}"
    
    # CPU频率（MHz）
    CPU_FREQ=$(grep "cpu MHz" /proc/cpuinfo | head -n1 | cut -d':' -f2 | xargs | cut -d'.' -f1)
    if [ -z "$CPU_FREQ" ]; then
        # 如果无法从cpuinfo获取，尝试从最大频率获取
        CPU_FREQ=$(cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq 2>/dev/null)
        if [ ! -z "$CPU_FREQ" ]; then
            CPU_FREQ=$((CPU_FREQ / 1000))
        else
            CPU_FREQ=2000  # 默认值
        fi
    fi
    log_info "CPU频率: ${CPU_FREQ} MHz"
    
    # 计算CPU性能分数（基于核心数和频率的综合指标）
    CPU_SCORE=$(echo "scale=2; ($CPU_CORES * $CPU_FREQ) / 1000" | bc)
    log_info "CPU性能分数: ${CPU_SCORE}"
    
    # CPU缓存大小
    CPU_CACHE=$(grep "cache size" /proc/cpuinfo | head -n1 | awk '{print $4}')
    log_info "CPU缓存: ${CPU_CACHE} KB"
}

# 获取内存信息
get_memory_info() {
    log_header "正在检测内存配置"
    
    # 总内存（MB）
    TOTAL_RAM=$(free -m | awk '/^Mem:/{print $2}')
    log_info "总内存: ${TOTAL_RAM} MB ($(echo "scale=2; $TOTAL_RAM/1024" | bc) GB)"
    
    # 可用内存
    AVAILABLE_RAM=$(free -m | awk '/^Mem:/{print $7}')
    log_info "可用内存: ${AVAILABLE_RAM} MB"
    
    # 当前swap大小
    CURRENT_SWAP=$(free -m | awk '/^Swap:/{print $2}')
    log_info "当前Swap大小: ${CURRENT_SWAP} MB"
    
    # 内存类型和速度
    if command -v dmidecode &> /dev/null; then
        MEM_TYPE=$(dmidecode -t memory 2>/dev/null | grep "Type:" | grep -v "Error" | head -n1 | awk '{print $2}')
        MEM_SPEED=$(dmidecode -t memory 2>/dev/null | grep "Speed:" | grep -v "Unknown" | head -n1 | awk '{print $2}')
        if [ ! -z "$MEM_TYPE" ]; then
            log_info "内存类型: ${MEM_TYPE}"
        fi
        if [ ! -z "$MEM_SPEED" ]; then
            log_info "内存速度: ${MEM_SPEED} MHz"
        fi
    fi
}

# 获取硬盘信息和性能
get_disk_info() {
    log_header "正在检测硬盘性能"
    
    # 获取根分区所在的磁盘设备
    ROOT_DEVICE=$(df / | tail -1 | awk '{print $1}' | sed 's/[0-9]*$//' | sed 's/p$//')
    log_info "根分区设备: ${ROOT_DEVICE}"
    
    # 判断是否为SSD
    DISK_NAME=$(basename $ROOT_DEVICE)
    IS_SSD=0
    
    # 方法1：检查rotational标志
    if [ -f "/sys/block/${DISK_NAME}/queue/rotational" ]; then
        ROTATIONAL=$(cat /sys/block/${DISK_NAME}/queue/rotational)
        if [ "$ROTATIONAL" -eq 0 ]; then
            IS_SSD=1
            log_info "磁盘类型: SSD（固态硬盘）"
        else
            log_info "磁盘类型: HDD（机械硬盘）"
        fi
    fi
    
    # 获取磁盘读取速度（使用hdparm）
    if command -v hdparm &> /dev/null; then
        log_info "正在测试磁盘读取速度（这可能需要几秒钟）..."
        DISK_READ_SPEED=$(hdparm -t $ROOT_DEVICE 2>/dev/null | grep "Timing buffered disk reads" | awk '{print $(NF-1)}')
        if [ ! -z "$DISK_READ_SPEED" ]; then
            log_info "磁盘读取速度: ${DISK_READ_SPEED} MB/s"
        else
            DISK_READ_SPEED=100  # 默认值
            log_warn "无法测试磁盘速度，使用默认值: ${DISK_READ_SPEED} MB/s"
        fi
    else
        DISK_READ_SPEED=100
        log_warn "hdparm未安装，使用默认磁盘速度: ${DISK_READ_SPEED} MB/s"
    fi
    
    # 使用dd测试写入速度
    log_info "正在测试磁盘写入速度..."
    TEMP_FILE="/tmp/disk_test_$$"
    DISK_WRITE_SPEED=$(dd if=/dev/zero of=$TEMP_FILE bs=1M count=512 oflag=direct 2>&1 | grep -oP '\d+\.?\d* MB/s' | grep -oP '\d+\.?\d*' | head -1)
    rm -f $TEMP_FILE
    
    if [ ! -z "$DISK_WRITE_SPEED" ]; then
        log_info "磁盘写入速度: ${DISK_WRITE_SPEED} MB/s"
    else
        DISK_WRITE_SPEED=80  # 默认值
        log_warn "无法测试写入速度，使用默认值: ${DISK_WRITE_SPEED} MB/s"
    fi
    
    # 计算磁盘性能分数
    DISK_SCORE=$(echo "scale=2; ($DISK_READ_SPEED + $DISK_WRITE_SPEED) / 2" | bc)
    log_info "磁盘性能分数: ${DISK_SCORE}"
}

# 计算最优Swap大小
calculate_optimal_swap() {
    log_header "计算最优Swap大小"
    
    # 商业级算法：根据内存大小、CPU性能、磁盘类型综合计算
    # 基础规则：
    # - 内存 <= 2GB: swap = 内存 * 2
    # - 2GB < 内存 <= 8GB: swap = 内存 * 1.5
    # - 8GB < 内存 <= 16GB: swap = 内存
    # - 16GB < 内存 <= 32GB: swap = 内存 * 0.5
    # - 内存 > 32GB: swap = 16GB（但考虑是否需要休眠）
    
    TOTAL_RAM_GB=$(echo "scale=2; $TOTAL_RAM / 1024" | bc)
    
    # 基础swap计算
    if (( $(echo "$TOTAL_RAM_GB <= 2" | bc -l) )); then
        BASE_SWAP=$(echo "scale=0; $TOTAL_RAM * 2" | bc)
    elif (( $(echo "$TOTAL_RAM_GB <= 8" | bc -l) )); then
        BASE_SWAP=$(echo "scale=0; $TOTAL_RAM * 1.5" | bc)
    elif (( $(echo "$TOTAL_RAM_GB <= 16" | bc -l) )); then
        BASE_SWAP=$TOTAL_RAM
    elif (( $(echo "$TOTAL_RAM_GB <= 32" | bc -l) )); then
        BASE_SWAP=$(echo "scale=0; $TOTAL_RAM * 0.5" | bc)
    else
        BASE_SWAP=16384  # 16GB
    fi
    
    # 根据磁盘类型调整
    # SSD：可以适当减少swap（因为速度快，不需要预留太多）
    # HDD：保持或增加swap（因为速度慢，需要更多缓冲）
    if [ $IS_SSD -eq 1 ]; then
        # SSD：减少20%
        OPTIMAL_SWAP=$(echo "scale=0; $BASE_SWAP * 0.8" | bc | cut -d'.' -f1)
        log_info "检测到SSD，减少Swap大小以延长SSD寿命"
    else
        # HDD：保持不变或根据性能分数微调
        if (( $(echo "$DISK_SCORE < 50" | bc -l) )); then
            # 低性能磁盘，增加10%
            OPTIMAL_SWAP=$(echo "scale=0; $BASE_SWAP * 1.1" | bc | cut -d'.' -f1)
            log_info "检测到低性能HDD，增加Swap大小以提高性能"
        else
            OPTIMAL_SWAP=$BASE_SWAP
        fi
    fi
    
    # 检查是否需要休眠功能（swap需要大于等于RAM）
    log_warn "注意：如果需要休眠(hibernate)功能，Swap大小应至少等于物理内存"
    
    log_info "推荐Swap大小: ${OPTIMAL_SWAP} MB ($(echo "scale=2; $OPTIMAL_SWAP/1024" | bc) GB)"
}

# 计算最优swappiness值
calculate_optimal_swappiness() {
    log_header "计算最优Swappiness值"
    
    # Swappiness值范围：0-100
    # 0: 只在必要时使用swap
    # 100: 积极使用swap
    
    # 商业级算法：
    # - 高内存系统（>16GB）：降低swappiness（10-30）
    # - 中等内存（4-16GB）：中等swappiness（30-60）
    # - 低内存（<4GB）：较高swappiness（60-80）
    # - SSD：可以稍微提高（因为速度快）
    # - HDD：应该降低（避免频繁swap导致性能下降）
    
    TOTAL_RAM_GB=$(echo "scale=2; $TOTAL_RAM / 1024" | bc)
    
    if (( $(echo "$TOTAL_RAM_GB >= 16" | bc -l) )); then
        # 高内存系统
        if [ $IS_SSD -eq 1 ]; then
            OPTIMAL_SWAPPINESS=20
        else
            OPTIMAL_SWAPPINESS=10
        fi
    elif (( $(echo "$TOTAL_RAM_GB >= 4" | bc -l) )); then
        # 中等内存系统
        if [ $IS_SSD -eq 1 ]; then
            OPTIMAL_SWAPPINESS=40
        else
            OPTIMAL_SWAPPINESS=30
        fi
    else
        # 低内存系统
        if [ $IS_SSD -eq 1 ]; then
            OPTIMAL_SWAPPINESS=70
        else
            OPTIMAL_SWAPPINESS=60
        fi
    fi
    
    # 根据CPU性能微调
    # 高性能CPU可以更好地处理内存压缩，减少swap依赖
    if (( $(echo "$CPU_SCORE > 10" | bc -l) )); then
        OPTIMAL_SWAPPINESS=$((OPTIMAL_SWAPPINESS - 5))
    fi
    
    # 确保在合理范围内
    if [ $OPTIMAL_SWAPPINESS -lt 1 ]; then
        OPTIMAL_SWAPPINESS=1
    elif [ $OPTIMAL_SWAPPINESS -gt 100 ]; then
        OPTIMAL_SWAPPINESS=100
    fi
    
    log_info "推荐Swappiness值: ${OPTIMAL_SWAPPINESS}"
}

# 计算其他虚拟内存参数
calculate_vm_parameters() {
    log_header "计算其他虚拟内存参数"
    
    # 1. vm.vfs_cache_pressure (VFS缓存压力)
    # 默认值：100
    # 较低值：系统倾向于保留dentry和inode缓存
    # 较高值：系统倾向于回收dentry和inode缓存
    
    if [ $IS_SSD -eq 1 ]; then
        # SSD速度快，可以稍微增加压力
        OPTIMAL_VFS_CACHE_PRESSURE=110
    else
        # HDD速度慢，减少压力以保留更多缓存
        OPTIMAL_VFS_CACHE_PRESSURE=50
    fi
    log_info "推荐vm.vfs_cache_pressure: ${OPTIMAL_VFS_CACHE_PRESSURE}"
    
    # 2. vm.dirty_ratio (脏页比例)
    # 默认值：20
    # 当脏页达到内存的这个百分比时，强制写回磁盘
    
    if [ $IS_SSD -eq 1 ]; then
        # SSD写入快，可以设置较高值
        OPTIMAL_DIRTY_RATIO=40
    else
        # HDD写入慢，设置较低值避免大量积压
        if (( $(echo "$DISK_SCORE < 50" | bc -l) )); then
            OPTIMAL_DIRTY_RATIO=10
        else
            OPTIMAL_DIRTY_RATIO=15
        fi
    fi
    log_info "推荐vm.dirty_ratio: ${OPTIMAL_DIRTY_RATIO}"
    
    # 3. vm.dirty_background_ratio (后台脏页比例)
    # 默认值：10
    # 当脏页达到这个百分比时，后台开始写回
    
    OPTIMAL_DIRTY_BG_RATIO=$((OPTIMAL_DIRTY_RATIO / 4))
    if [ $OPTIMAL_DIRTY_BG_RATIO -lt 3 ]; then
        OPTIMAL_DIRTY_BG_RATIO=3
    fi
    log_info "推荐vm.dirty_background_ratio: ${OPTIMAL_DIRTY_BG_RATIO}"
    
    # 4. vm.dirty_expire_centisecs (脏页过期时间，单位：百分之一秒)
    # 默认值：3000 (30秒)
    
    if [ $IS_SSD -eq 1 ]; then
        OPTIMAL_DIRTY_EXPIRE=1500  # 15秒
    else
        OPTIMAL_DIRTY_EXPIRE=3000  # 30秒
    fi
    log_info "推荐vm.dirty_expire_centisecs: ${OPTIMAL_DIRTY_EXPIRE}"
    
    # 5. vm.dirty_writeback_centisecs (写回间隔时间)
    # 默认值：500 (5秒)
    
    if [ $IS_SSD -eq 1 ]; then
        OPTIMAL_DIRTY_WRITEBACK=300  # 3秒
    else
        OPTIMAL_DIRTY_WRITEBACK=500  # 5秒
    fi
    log_info "推荐vm.dirty_writeback_centisecs: ${OPTIMAL_DIRTY_WRITEBACK}"
    
    # 6. vm.min_free_kbytes (最小空闲内存)
    # 确保系统始终保持一定的空闲内存
    
    # 基于总内存的0.5%到1%
    OPTIMAL_MIN_FREE=$(echo "scale=0; $TOTAL_RAM * 1024 * 0.008" | bc | cut -d'.' -f1)
    # 限制在合理范围内（64MB到1GB）
    if [ $OPTIMAL_MIN_FREE -lt 65536 ]; then
        OPTIMAL_MIN_FREE=65536
    elif [ $OPTIMAL_MIN_FREE -gt 1048576 ]; then
        OPTIMAL_MIN_FREE=1048576
    fi
    log_info "推荐vm.min_free_kbytes: ${OPTIMAL_MIN_FREE}"
}

# 显示建议摘要
show_recommendations() {
    log_header "优化建议摘要"
    
    echo ""
    echo "========== 系统配置 =========="
    echo "CPU核心数: ${CPU_CORES}"
    echo "CPU性能分数: ${CPU_SCORE}"
    echo "总内存: ${TOTAL_RAM} MB"
    echo "磁盘类型: $([ $IS_SSD -eq 1 ] && echo 'SSD' || echo 'HDD')"
    echo "磁盘性能分数: ${DISK_SCORE}"
    echo ""
    echo "========== 当前设置 =========="
    echo "当前Swap大小: ${CURRENT_SWAP} MB"
    echo "当前Swappiness: $(cat /proc/sys/vm/swappiness)"
    echo "当前VFS Cache Pressure: $(cat /proc/sys/vm/vfs_cache_pressure)"
    echo "当前Dirty Ratio: $(cat /proc/sys/vm/dirty_ratio)"
    echo ""
    echo "========== 推荐设置 =========="
    echo "推荐Swap大小: ${OPTIMAL_SWAP} MB"
    echo "推荐Swappiness: ${OPTIMAL_SWAPPINESS}"
    echo "推荐VFS Cache Pressure: ${OPTIMAL_VFS_CACHE_PRESSURE}"
    echo "推荐Dirty Ratio: ${OPTIMAL_DIRTY_RATIO}"
    echo "推荐Dirty Background Ratio: ${OPTIMAL_DIRTY_BG_RATIO}"
    echo "推荐Dirty Expire: ${OPTIMAL_DIRTY_EXPIRE}"
    echo "推荐Dirty Writeback: ${OPTIMAL_DIRTY_WRITEBACK}"
    echo "推荐Min Free KBytes: ${OPTIMAL_MIN_FREE}"
    echo ""
}

# 应用虚拟内存设置
apply_vm_settings() {
    log_header "应用虚拟内存设置"
    
    # 备份当前sysctl配置
    BACKUP_FILE="/etc/sysctl.conf.backup.$(date +%Y%m%d_%H%M%S)"
    if [ -f /etc/sysctl.conf ]; then
        cp /etc/sysctl.conf $BACKUP_FILE
        log_info "已备份当前配置到: ${BACKUP_FILE}"
    fi
    
    # 应用swappiness
    log_info "设置vm.swappiness = ${OPTIMAL_SWAPPINESS}"
    sysctl -w vm.swappiness=$OPTIMAL_SWAPPINESS > /dev/null
    
    # 应用vfs_cache_pressure
    log_info "设置vm.vfs_cache_pressure = ${OPTIMAL_VFS_CACHE_PRESSURE}"
    sysctl -w vm.vfs_cache_pressure=$OPTIMAL_VFS_CACHE_PRESSURE > /dev/null
    
    # 应用dirty_ratio
    log_info "设置vm.dirty_ratio = ${OPTIMAL_DIRTY_RATIO}"
    sysctl -w vm.dirty_ratio=$OPTIMAL_DIRTY_RATIO > /dev/null
    
    # 应用dirty_background_ratio
    log_info "设置vm.dirty_background_ratio = ${OPTIMAL_DIRTY_BG_RATIO}"
    sysctl -w vm.dirty_background_ratio=$OPTIMAL_DIRTY_BG_RATIO > /dev/null
    
    # 应用dirty_expire_centisecs
    log_info "设置vm.dirty_expire_centisecs = ${OPTIMAL_DIRTY_EXPIRE}"
    sysctl -w vm.dirty_expire_centisecs=$OPTIMAL_DIRTY_EXPIRE > /dev/null
    
    # 应用dirty_writeback_centisecs
    log_info "设置vm.dirty_writeback_centisecs = ${OPTIMAL_DIRTY_WRITEBACK}"
    sysctl -w vm.dirty_writeback_centisecs=$OPTIMAL_DIRTY_WRITEBACK > /dev/null
    
    # 应用min_free_kbytes
    log_info "设置vm.min_free_kbytes = ${OPTIMAL_MIN_FREE}"
    sysctl -w vm.min_free_kbytes=$OPTIMAL_MIN_FREE > /dev/null
    
    # 写入/etc/sysctl.conf使设置永久生效
    log_info "将设置写入/etc/sysctl.conf以便开机自动加载"
    
    # 移除旧的vm相关配置
    if [ -f /etc/sysctl.conf ]; then
        sed -i '/^vm\./d' /etc/sysctl.conf
    fi
    
    # 添加新配置
    cat >> /etc/sysctl.conf << EOF

# ========== 虚拟内存优化配置 ==========
# 由优化脚本生成于 $(date)
# 系统配置: ${CPU_CORES}核CPU, ${TOTAL_RAM}MB内存, $([ $IS_SSD -eq 1 ] && echo 'SSD' || echo 'HDD')

# Swappiness: 控制系统使用swap的倾向 (0-100)
vm.swappiness = ${OPTIMAL_SWAPPINESS}

# VFS Cache Pressure: 控制VFS缓存回收的倾向
vm.vfs_cache_pressure = ${OPTIMAL_VFS_CACHE_PRESSURE}

# Dirty Ratio: 脏页达到此百分比时强制写回
vm.dirty_ratio = ${OPTIMAL_DIRTY_RATIO}

# Dirty Background Ratio: 脏页达到此百分比时后台写回
vm.dirty_background_ratio = ${OPTIMAL_DIRTY_BG_RATIO}

# Dirty Expire: 脏页过期时间（百分之一秒）
vm.dirty_expire_centisecs = ${OPTIMAL_DIRTY_EXPIRE}

# Dirty Writeback: 写回间隔时间（百分之一秒）
vm.dirty_writeback_centisecs = ${OPTIMAL_DIRTY_WRITEBACK}

# Min Free KBytes: 最小空闲内存（KB）
vm.min_free_kbytes = ${OPTIMAL_MIN_FREE}

EOF
    
    log_info "虚拟内存参数已成功应用并设置为永久生效"
}

# 管理Swap文件
manage_swap() {
    log_header "管理Swap空间"
    
    # 检查当前swap设备
    SWAP_DEVICES=$(swapon --show=NAME --noheadings)
    
    if [ -z "$SWAP_DEVICES" ]; then
        log_warn "系统当前没有启用Swap"
        CREATE_NEW_SWAP=1
    else
        log_info "当前Swap设备:"
        swapon --show
        echo ""
        
        # 计算是否需要调整
        SWAP_DIFF=$((OPTIMAL_SWAP - CURRENT_SWAP))
        SWAP_DIFF_ABS=${SWAP_DIFF#-}
        
        # 如果差异超过20%，建议调整
        THRESHOLD=$((OPTIMAL_SWAP / 5))
        
        if [ $SWAP_DIFF_ABS -gt $THRESHOLD ]; then
            log_warn "当前Swap大小 (${CURRENT_SWAP}MB) 与推荐值 (${OPTIMAL_SWAP}MB) 差异较大"
            read -p "是否要重新创建Swap? (y/n): " RECREATE
            if [ "$RECREATE" = "y" ] || [ "$RECREATE" = "Y" ]; then
                CREATE_NEW_SWAP=1
                # 关闭现有swap
                log_info "正在关闭现有Swap..."
                swapoff -a
            else
                CREATE_NEW_SWAP=0
            fi
        else
            log_info "当前Swap大小合理，无需调整"
            CREATE_NEW_SWAP=0
        fi
    fi
    
    # 创建新的swap文件
    if [ $CREATE_NEW_SWAP -eq 1 ]; then
        SWAPFILE="/swapfile"
        
        # 如果旧的swapfile存在，删除它
        if [ -f $SWAPFILE ]; then
            log_info "删除旧的Swap文件..."
            swapoff $SWAPFILE 2>/dev/null
            rm -f $SWAPFILE
        fi
        
        log_info "正在创建新的Swap文件 (${OPTIMAL_SWAP}MB)，这可能需要几分钟..."
        
        # 使用fallocate（更快）或dd创建swap文件
        if command -v fallocate &> /dev/null; then
            fallocate -l ${OPTIMAL_SWAP}M $SWAPFILE
        else
            dd if=/dev/zero of=$SWAPFILE bs=1M count=$OPTIMAL_SWAP status=progress
        fi
        
        # 设置正确的权限
        chmod 600 $SWAPFILE
        log_info "设置Swap文件权限"
        
        # 格式化为swap
        log_info "格式化Swap文件"
        mkswap $SWAPFILE > /dev/null
        
        # 启用swap
        log_info "启用Swap文件"
        swapon $SWAPFILE
        
        # 添加到fstab使其永久生效
        if ! grep -q "$SWAPFILE" /etc/fstab; then
            echo "$SWAPFILE none swap sw 0 0" >> /etc/fstab
            log_info "已将Swap文件添加到/etc/fstab"
        fi
        
        log_info "Swap文件创建成功"
        swapon --show
    fi
}

# 生成性能测试报告
generate_report() {
    log_header "生成优化报告"
    
    REPORT_FILE="/tmp/vm_optimization_report_$(date +%Y%m%d_%H%M%S).txt"
    
    cat > $REPORT_FILE << EOF
=================================================================
         Linux虚拟内存优化报告
=================================================================
生成时间: $(date)

-----------------------------------------------------------------
系统配置信息
-----------------------------------------------------------------
CPU型号:        ${CPU_MODEL}
CPU核心数:      ${CPU_CORES}
CPU频率:        ${CPU_FREQ} MHz
CPU性能分数:    ${CPU_SCORE}

总内存:         ${TOTAL_RAM} MB ($(echo "scale=2; $TOTAL_RAM/1024" | bc) GB)
可用内存:       ${AVAILABLE_RAM} MB

磁盘类型:       $([ $IS_SSD -eq 1 ] && echo 'SSD（固态硬盘）' || echo 'HDD（机械硬盘）')
磁盘设备:       ${ROOT_DEVICE}
读取速度:       ${DISK_READ_SPEED} MB/s
写入速度:       ${DISK_WRITE_SPEED} MB/s
磁盘性能分数:   ${DISK_SCORE}

-----------------------------------------------------------------
优化前配置
-----------------------------------------------------------------
Swap大小:                    ${CURRENT_SWAP} MB
vm.swappiness:               $(cat /proc/sys/vm/swappiness 2>/dev/null || echo 'N/A')
vm.vfs_cache_pressure:       $(cat /proc/sys/vm/vfs_cache_pressure 2>/dev/null || echo 'N/A')
vm.dirty_ratio:              $(cat /proc/sys/vm/dirty_ratio 2>/dev/null || echo 'N/A')
vm.dirty_background_ratio:   $(cat /proc/sys/vm/dirty_background_ratio 2>/dev/null || echo 'N/A')

-----------------------------------------------------------------
优化后配置（推荐值）
-----------------------------------------------------------------
Swap大小:                    ${OPTIMAL_SWAP} MB
vm.swappiness:               ${OPTIMAL_SWAPPINESS}
vm.vfs_cache_pressure:       ${OPTIMAL_VFS_CACHE_PRESSURE}
vm.dirty_ratio:              ${OPTIMAL_DIRTY_RATIO}
vm.dirty_background_ratio:   ${OPTIMAL_DIRTY_BG_RATIO}
vm.dirty_expire_centisecs:   ${OPTIMAL_DIRTY_EXPIRE}
vm.dirty_writeback_centisecs: ${OPTIMAL_DIRTY_WRITEBACK}
vm.min_free_kbytes:          ${OPTIMAL_MIN_FREE}

-----------------------------------------------------------------
优化说明
-----------------------------------------------------------------

1. Swappiness (${OPTIMAL_SWAPPINESS}):
   $(if (( OPTIMAL_SWAPPINESS <= 20 )); then
       echo "   设置为较低值，适合高内存系统，减少swap使用"
   elif (( OPTIMAL_SWAPPINESS <= 60 )); then
       echo "   设置为中等值，平衡内存和swap使用"
   else
       echo "   设置为较高值，适合低内存系统，更积极地使用swap"
   fi)

2. VFS Cache Pressure (${OPTIMAL_VFS_CACHE_PRESSURE}):
   $(if (( OPTIMAL_VFS_CACHE_PRESSURE <= 70 )); then
       echo "   设置为较低值，保留更多目录和inode缓存"
   else
       echo "   设置为较高值，更积极地回收缓存"
   fi)

3. Dirty Ratio (${OPTIMAL_DIRTY_RATIO}):
   $(if [ $IS_SSD -eq 1 ]; then
       echo "   SSD系统可设置较高值，允许更多脏页积累再写入"
   else
       echo "   HDD系统设置较低值，避免大量脏页积压影响性能"
   fi)

4. 其他参数:
   所有参数都已根据您的硬件配置进行了优化调整。

-----------------------------------------------------------------
建议
-----------------------------------------------------------------
1. 重启系统后，所有设置将自动生效
2. 可以使用以下命令查看当前虚拟内存使用情况:
   - free -h               (查看内存和swap使用)
   - swapon --show         (查看swap设备)
   - vmstat 1              (查看虚拟内存统计)
   - cat /proc/meminfo     (详细内存信息)

3. 如需恢复原设置，可使用备份文件:
   $(ls -t /etc/sysctl.conf.backup.* 2>/dev/null | head -1 || echo '   无备份文件')

4. 监控系统性能变化:
   - 使用 'htop' 或 'top' 监控内存使用
   - 使用 'iostat' 监控磁盘IO
   - 使用 'sar' 查看历史性能数据

=================================================================
EOF
    
    log_info "优化报告已生成: ${REPORT_FILE}"
    echo ""
    cat $REPORT_FILE
}

# 主函数
main() {
    clear
    echo ""
    log_header "Linux虚拟内存自动优化脚本 v2.0"
    echo ""
    
    # 检查root权限
    check_root
    
    # 安装依赖
    install_dependencies
    
    # 收集系统信息
    get_cpu_info
    get_memory_info
    get_disk_info
    
    # 计算最优参数
    calculate_optimal_swap
    calculate_optimal_swappiness
    calculate_vm_parameters
    
    # 显示建议
    show_recommendations
    
    # 询问是否应用设置
    echo ""
    read -p "是否要应用这些优化设置? (y/n): " APPLY
    
    if [ "$APPLY" = "y" ] || [ "$APPLY" = "Y" ]; then
        # 应用设置
        apply_vm_settings
        
        # 管理swap
        read -p "是否要调整Swap大小? (y/n): " MANAGE_SWAP_CHOICE
        if [ "$MANAGE_SWAP_CHOICE" = "y" ] || [ "$MANAGE_SWAP_CHOICE" = "Y" ]; then
            manage_swap
        fi
        
        # 生成报告
        generate_report
        
        log_info "优化完成！建议重启系统以确保所有设置生效。"
    else
        log_warn "未应用任何设置"
        generate_report
    fi
    
    echo ""
}

# 运行主函数
main


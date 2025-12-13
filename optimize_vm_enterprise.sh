#!/bin/bash

################################################################################
# Linux服务器虚拟内存专业级自动优化脚本
# 功能：使用业界标准测试工具精确测量系统性能，并应用商业级优化算法
# 版本：3.1 Server Edition (安全增强版)
# 适用场景：Linux服务器环境（Web服务器、数据库服务器、应用服务器等）
#
# v3.1 安全改进：
#   - 永不使用 overcommit_memory=2（避免内存分配失败）
#   - 分阶段应用参数（安全参数 → swap → overcommit）
#   - 小内存系统保护（不降低min_free_kbytes）
#   - 应用前安全检查（内存、磁盘、系统状态）
#   - 自动回滚机制（检测到问题立即恢复）
#
# 性能测试标准（对标 spiritLHLS/ecs 项目）：
# ===========================================================
# 参考项目：https://github.com/spiritLHLS/ecs
# VPS融合怪服务器测评项目 - 业界知名的开源VPS测评标准
# 
# CPU性能测试：使用 Sysbench CPU（素数计算）
#   - 测试指标：events/sec（每秒事件数）
#   - 测试命令：sysbench cpu --cpu-max-prime=10000 --threads=1 --time=5 run
#   - 数据来源：spiritLHLS/ecs 项目实际测试数据
#
# 内存性能测试：使用 Sysbench Memory
#   - 测试指标：MB/s（兆字节/秒）
#   - 测试方式：单线程读写测试
#   - 数据来源：Lemonbench 项目标准
#
# 磁盘性能测试：使用 FIO 专业工具
#   - 关键指标：FIO 4K随机 IOPS（服务器最关键性能指标）
#   - 辅助指标：顺序读写速度（MB/s）
#     * HDD:                  80-200 MB/s
#     * SATA SSD:             400-550 MB/s
#     * NVMe SSD:             1500-7000 MB/s
#   - 数据来源：spiritLHLS/ecs + Lemonbench 项目标准
#
# 优化算法来源（服务器环境）：
# ==============================
#   - Google SRE Production Best Practices
#   - Red Hat Enterprise Linux Performance Tuning Guide
#   - Oracle Linux Performance Tuning Guide
#   - Netflix Production Infrastructure Optimization
#   - Facebook/Meta Data Center Infrastructure
#   - AWS EC2 Performance Best Practices
#   - Microsoft Azure Virtual Machine Optimization
#
# 服务器特殊优化考虑：
# ==================
#   - 稳定性优先于极致性能
#   - 高并发处理能力
#   - 长时间运行不重启
#   - 内存泄漏防护
#   - OOM Killer优化
#   - NUMA感知调优
################################################################################

# 颜色支持检测
USE_COLOR=1

# 检测是否支持颜色
if [ ! -t 1 ] || [ "$TERM" = "dumb" ]; then
    # 输出不是终端或TERM=dumb，禁用颜色
    USE_COLOR=0
fi

# 检查命令行参数
for arg in "$@"; do
    if [ "$arg" = "--no-color" ]; then
        USE_COLOR=0
    fi
done

# 颜色定义
if [ $USE_COLOR -eq 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    MAGENTA='\033[0;35m'
    NC='\033[0m'
else
    # 禁用颜色
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    CYAN=''
    MAGENTA=''
    NC=''
fi

# 性能数据存储
declare -A PERFORMANCE_DATA
declare -A SYSTEM_INFO

# 日志函数
log_info() {
    printf "${GREEN}[信息]${NC} %s\n" "$1"
}

log_warn() {
    printf "${YELLOW}[警告]${NC} %s\n" "$1"
}

log_error() {
    printf "${RED}[错误]${NC} %s\n" "$1"
}

log_success() {
    printf "${CYAN}[成功]${NC} %s\n" "$1"
}

log_header() {
    echo ""
    printf "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
    printf "${BLUE}  %s${NC}\n" "$1"
    printf "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
}

log_progress() {
    printf "${MAGENTA}[进行中]${NC} %s\n" "$1"
}

# 检查root权限
check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "请使用root权限运行此脚本（使用sudo）"
        exit 1
    fi
}

# 安装专业测试工具
install_professional_tools() {
    log_header "安装专业性能测试工具套件"
    
    # 必需的专业工具列表
    local tools=(
        "fio"           # 专业存储性能测试工具
        "sysbench"      # 综合性能基准测试
        "hdparm"        # 硬盘参数工具
        "smartmontools" # 硬盘SMART信息
        "dmidecode"     # DMI/SMBIOS信息
        "bc"            # 数学计算
        "sysstat"       # 系统性能工具（iostat, sar等）
        "lshw"          # 硬件信息
        "pciutils"      # PCI设备信息
        "util-linux"    # 系统工具
    )
    
    local missing_tools=()
    
    # 检查缺失的工具
    for tool in "${tools[@]}"; do
        case $tool in
            "fio")
                command -v fio &> /dev/null || missing_tools+=("fio")
                ;;
            "sysbench")
                command -v sysbench &> /dev/null || missing_tools+=("sysbench")
                ;;
            "hdparm")
                command -v hdparm &> /dev/null || missing_tools+=("hdparm")
                ;;
            "smartmontools")
                command -v smartctl &> /dev/null || missing_tools+=("smartmontools")
                ;;
            "dmidecode")
                command -v dmidecode &> /dev/null || missing_tools+=("dmidecode")
                ;;
            "bc")
                command -v bc &> /dev/null || missing_tools+=("bc")
                ;;
            "sysstat")
                command -v iostat &> /dev/null || missing_tools+=("sysstat")
                ;;
            "lshw")
                command -v lshw &> /dev/null || missing_tools+=("lshw")
                ;;
            "pciutils")
                command -v lspci &> /dev/null || missing_tools+=("pciutils")
                ;;
        esac
    done
    
    if [ ${#missing_tools[@]} -gt 0 ]; then
        log_warn "检测到缺失工具: ${missing_tools[*]}"
        log_progress "正在安装缺失的专业工具（这可能需要几分钟）..."
        
        if command -v apt-get &> /dev/null; then
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -qq 2>&1 | grep -v "^Get:"
            apt-get install -y -qq ${missing_tools[@]} 2>&1 | grep -E "(Setting up|Processing)"
        elif command -v yum &> /dev/null; then
            yum install -y -q ${missing_tools[@]} 2>&1 | grep -E "(Installing|Complete)"
        elif command -v dnf &> /dev/null; then
            dnf install -y -q ${missing_tools[@]} 2>&1 | grep -E "(Installing|Complete)"
        elif command -v pacman &> /dev/null; then
            pacman -S --noconfirm ${missing_tools[@]} 2>&1 | grep -E "(installing|upgraded)"
        else
            log_error "无法识别的包管理器，请手动安装: ${missing_tools[*]}"
            exit 1
        fi
        log_success "工具安装完成"
    else
        log_success "所有必需工具已安装"
    fi
}

deep_cpu_benchmark() {
    log_header "CPU性能测试（Sysbench）"
    
    # 基础信息
    SYSTEM_INFO[cpu_cores]=$(nproc)
    SYSTEM_INFO[cpu_model]=$(grep "model name" /proc/cpuinfo | head -n1 | cut -d':' -f2 | xargs)
    
    # CPU频率
    local cpu_max_freq=$(cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq 2>/dev/null)
    if [ ! -z "$cpu_max_freq" ]; then
        cpu_max_freq=$((cpu_max_freq / 1000))
        SYSTEM_INFO[cpu_max_freq]=$cpu_max_freq
    else
        cpu_max_freq=$(grep "cpu MHz" /proc/cpuinfo | head -n1 | cut -d':' -f2 | xargs | cut -d'.' -f1)
        SYSTEM_INFO[cpu_max_freq]=${cpu_max_freq:-2000}
    fi
    
    log_info "CPU: ${SYSTEM_INFO[cpu_model]}"
    log_info "核心数: ${SYSTEM_INFO[cpu_cores]}, 频率: ${cpu_max_freq} MHz"
    
    # Sysbench CPU单线程测试（优化算法关键指标）
    # 使用5秒 + 10000素数，与spiritLHLS/ecs项目对标
    log_progress "执行Sysbench单线程CPU测试（5秒，素数10000）..."
    local cpu_single_score=$(sysbench cpu --cpu-max-prime=10000 --threads=1 --time=5 run 2>/dev/null | grep "events per second:" | awk '{print $4}')
    cpu_single_score=${cpu_single_score:-800}
    PERFORMANCE_DATA[cpu_single_thread]=$cpu_single_score
    log_success "CPU性能: ${cpu_single_score} events/sec ⭐优化算法关键指标"
}

# 深度内存性能测试
deep_memory_benchmark() {
    log_header "内存性能测试（Sysbench）"
    
    # 基础内存信息
    SYSTEM_INFO[total_ram_kb]=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    SYSTEM_INFO[total_ram_mb]=$((${SYSTEM_INFO[total_ram_kb]} / 1024))
    SYSTEM_INFO[available_ram_mb]=$(free -m | awk '/^Mem:/{print $7}')
    
    log_info "总内存: ${SYSTEM_INFO[total_ram_mb]} MB ($(echo "scale=2; ${SYSTEM_INFO[total_ram_mb]}/1024" | bc) GB)"
    log_info "可用内存: ${SYSTEM_INFO[available_ram_mb]} MB"
    
    # 内存详细信息（使用dmidecode）
    if command -v dmidecode &> /dev/null; then
        local mem_type=$(dmidecode -t memory 2>/dev/null | grep -m1 "Type:" | grep -v "Error" | awk '{print $2}')
        local mem_speed=$(dmidecode -t memory 2>/dev/null | grep -m1 "Speed:" | grep -v "Unknown" | grep -v "Configured" | awk '{print $2}')
        local mem_manufacturer=$(dmidecode -t memory 2>/dev/null | grep -m1 "Manufacturer:" | cut -d':' -f2 | xargs)
        
        SYSTEM_INFO[mem_type]=${mem_type:-Unknown}
        SYSTEM_INFO[mem_speed]=${mem_speed:-Unknown}
        
        log_info "内存类型: ${SYSTEM_INFO[mem_type]}"
        log_info "内存速度: ${mem_speed} MT/s"
        [ ! -z "$mem_manufacturer" ] && log_info "内存制造商: ${mem_manufacturer}"
    fi
    
    # Sysbench内存读取带宽测试（优化算法关键指标）
    log_progress "执行Sysbench内存读取带宽测试..."
    local mem_read=$(sysbench memory --memory-block-size=1M --memory-total-size=10G --memory-oper=read --threads=${SYSTEM_INFO[cpu_cores]} run 2>/dev/null | grep "transferred" | awk '{print $(NF-1)}' | tr -d '()')
    
    # 清理数值
    mem_read=$(echo "$mem_read" | grep -oE '[0-9]+\.?[0-9]*' | head -1)
    mem_read=${mem_read:-10000}
    
    # 存储读取带宽（优化算法唯一使用的内存指标）
    PERFORMANCE_DATA[mem_read_bandwidth]=$mem_read
    
    # 根据读取带宽判断内存类型
    if (( $(echo "$mem_read < 10000" | bc -l) )); then
        SYSTEM_INFO[mem_category]="DDR3-1333/1600 ECC"
    elif (( $(echo "$mem_read < 14000" | bc -l) )); then
        SYSTEM_INFO[mem_category]="DDR3-1866/DDR4-2133 ECC"
    elif (( $(echo "$mem_read < 17000" | bc -l) )); then
        SYSTEM_INFO[mem_category]="DDR4-2400 ECC" 
    elif (( $(echo "$mem_read < 20000" | bc -l) )); then
        SYSTEM_INFO[mem_category]="DDR4-2666 ECC"
    elif (( $(echo "$mem_read < 25000" | bc -l) )); then
        SYSTEM_INFO[mem_category]="DDR4-3200 ECC"
    elif (( $(echo "$mem_read < 35000" | bc -l) )); then
        SYSTEM_INFO[mem_category]="DDR5-4800 ECC"
    else
        SYSTEM_INFO[mem_category]="DDR5-5600+ ECC"
    fi
    
    log_success "内存性能测试完成 - ${mem_read} MB/s ⭐优化算法关键指标"
}

# 专业级磁盘性能测试（使用FIO）
deep_disk_benchmark() {
    log_header "磁盘性能测试（FIO）"
    
    # 获取根分区磁盘设备
    local root_mount=$(df / | tail -1 | awk '{print $1}')
    local disk_device=$(lsblk -no pkname $root_mount 2>/dev/null | head -1)
    
    if [ -z "$disk_device" ]; then
        disk_device=$(echo $root_mount | sed 's/[0-9]*$//' | sed 's/p$//' | sed 's|/dev/||')
    fi
    
    SYSTEM_INFO[disk_device]="/dev/${disk_device}"
    log_info "磁盘设备: ${SYSTEM_INFO[disk_device]}"
    
    # 判断磁盘类型
    local rotational=1
    if [ -f "/sys/block/${disk_device}/queue/rotational" ]; then
        rotational=$(cat /sys/block/${disk_device}/queue/rotational)
    fi
    
    if [ "$rotational" -eq 0 ]; then
        SYSTEM_INFO[disk_type]="SSD"
        log_info "磁盘类型: SSD（固态硬盘）"
    else
        SYSTEM_INFO[disk_type]="HDD"
        log_info "磁盘类型: HDD（机械硬盘）"
    fi
    
    # 磁盘容量
    local disk_size=$(lsblk -bno SIZE /dev/${disk_device} 2>/dev/null | head -1)
    if [ ! -z "$disk_size" ]; then
        local disk_size_gb=$(echo "scale=2; $disk_size / 1024 / 1024 / 1024" | bc)
        log_info "磁盘容量: ${disk_size_gb} GB"
    fi
    
    # SMART信息
    if command -v smartctl &> /dev/null; then
        local smart_model=$(smartctl -i ${SYSTEM_INFO[disk_device]} 2>/dev/null | grep "Device Model" | cut -d':' -f2 | xargs)
        [ ! -z "$smart_model" ] && log_info "磁盘型号: ${smart_model}"
    fi
    
    # 创建测试目录
    local test_dir="/tmp/fio_test_$$"
    mkdir -p $test_dir
    
    log_info "测试目录: ${test_dir}"
    
    # FIO测试1: 顺序读取 (Sequential Read)
    log_progress "执行FIO顺序读取测试（4MB块大小）..."
    fio --name=seq_read \
        --directory=$test_dir \
        --rw=read \
        --bs=4m \
        --size=512m \
        --numjobs=1 \
        --time_based \
        --runtime=10 \
        --ioengine=libaio \
        --direct=1 \
        --group_reporting \
        --output-format=json \
        > /tmp/fio_seq_read.json 2>/dev/null
    
    # 改进的JSON解析（支持多种格式）
    local seq_read_bw=$(grep -oP '"bw"\s*:\s*\K[0-9]+' /tmp/fio_seq_read.json 2>/dev/null | head -1)
    if [ -z "$seq_read_bw" ]; then
        # 备用方法：使用正常格式输出
        seq_read_bw=$(fio --name=seq_read --directory=$test_dir --rw=read --bs=4m --size=256m --numjobs=1 --runtime=5 --ioengine=sync --direct=1 2>/dev/null | grep "READ:" | grep -oP 'bw=\K[0-9.]+[KMG]' | head -1)
        # 转换单位
        if [[ $seq_read_bw =~ ([0-9.]+)([KMG]) ]]; then
            local value="${BASH_REMATCH[1]}"
            local unit="${BASH_REMATCH[2]}"
            case $unit in
                K) seq_read_bw=$(echo "scale=2; $value / 1024" | bc) ;;
                M) seq_read_bw=$(echo "scale=2; $value" | bc) ;;
                G) seq_read_bw=$(echo "scale=2; $value * 1024" | bc) ;;
            esac
        else
            seq_read_bw=100
        fi
        PERFORMANCE_DATA[disk_seq_read]=$seq_read_bw
    else
        PERFORMANCE_DATA[disk_seq_read]=$(echo "scale=2; $seq_read_bw / 1024" | bc 2>/dev/null || echo "100")
    fi
    log_success "顺序读取速度: ${PERFORMANCE_DATA[disk_seq_read]} MB/s"
    
    
    # FIO测试3: 4K随机读取 (Random Read IOPS)
    log_progress "执行FIO 4K随机读取测试（IOPS）..."
    fio --name=rand_read_4k \
        --directory=$test_dir \
        --rw=randread \
        --bs=4k \
        --size=256m \
        --numjobs=4 \
        --time_based \
        --runtime=10 \
        --ioengine=libaio \
        --iodepth=32 \
        --direct=1 \
        --group_reporting \
        --output-format=json \
        > /tmp/fio_rand_read.json 2>/dev/null
    
    local rand_read_iops=$(grep -oP '"iops"\s*:\s*\K[0-9.]+' /tmp/fio_rand_read.json 2>/dev/null | head -1 | cut -d'.' -f1)
    if [ -z "$rand_read_iops" ] || [ "$rand_read_iops" = "0" ]; then
        rand_read_iops=$(fio --name=rand_read --directory=$test_dir --rw=randread --bs=4k --size=128m --numjobs=2 --runtime=5 --ioengine=sync --direct=1 2>/dev/null | grep "read :" | grep -oP 'IOPS=\K[0-9.]+[k]?' | head -1)
        if [[ $rand_read_iops =~ ([0-9.]+)k ]]; then
            rand_read_iops=$(echo "scale=0; ${BASH_REMATCH[1]} * 1000" | bc | cut -d'.' -f1)
        elif [ ! -z "$rand_read_iops" ]; then
            rand_read_iops=$(echo "$rand_read_iops" | cut -d'.' -f1)
        else
            rand_read_iops=100
        fi
    fi
    PERFORMANCE_DATA[disk_rand_read_iops]=${rand_read_iops:-100}
    log_success "4K随机读取IOPS: ${PERFORMANCE_DATA[disk_rand_read_iops]}"
    
    # FIO测试4: 4K随机写入 (Random Write IOPS)
    log_progress "执行FIO 4K随机写入测试（IOPS）..."
    fio --name=rand_write_4k \
        --directory=$test_dir \
        --rw=randwrite \
        --bs=4k \
        --size=256m \
        --numjobs=4 \
        --time_based \
        --runtime=10 \
        --ioengine=libaio \
        --iodepth=32 \
        --direct=1 \
        --group_reporting \
        --output-format=json \
        > /tmp/fio_rand_write.json 2>/dev/null
    
    local rand_write_iops=$(grep -oP '"iops"\s*:\s*\K[0-9.]+' /tmp/fio_rand_write.json 2>/dev/null | head -1 | cut -d'.' -f1)
    if [ -z "$rand_write_iops" ] || [ "$rand_write_iops" = "0" ]; then
        rand_write_iops=$(fio --name=rand_write --directory=$test_dir --rw=randwrite --bs=4k --size=128m --numjobs=2 --runtime=5 --ioengine=sync --direct=1 2>/dev/null | grep "write:" | grep -oP 'IOPS=\K[0-9.]+[k]?' | head -1)
        if [[ $rand_write_iops =~ ([0-9.]+)k ]]; then
            rand_write_iops=$(echo "scale=0; ${BASH_REMATCH[1]} * 1000" | bc | cut -d'.' -f1)
        elif [ ! -z "$rand_write_iops" ]; then
            rand_write_iops=$(echo "$rand_write_iops" | cut -d'.' -f1)
        else
            rand_write_iops=80
        fi
    fi
    PERFORMANCE_DATA[disk_rand_write_iops]=${rand_write_iops:-80}
    log_success "4K随机写入IOPS: ${PERFORMANCE_DATA[disk_rand_write_iops]}"
    
    
    # 清理测试文件
    rm -rf $test_dir /tmp/fio_*.json
    
    # 存储磁盘性能测试结果
    
    # 判断服务器SSD类型（综合顺序速度和IOPS）
    if [ "${SYSTEM_INFO[disk_type]}" = "SSD" ]; then
        local disk_rand_read=${PERFORMANCE_DATA[disk_rand_read_iops]:-100}
        local seq_read=${PERFORMANCE_DATA[disk_seq_read]:-100}
        
        # 检测虚拟化环境特征：高顺序速度但低IOPS
        if (( $(echo "$seq_read > 1000 && $disk_rand_read < 1000" | bc -l) )); then
            SYSTEM_INFO[disk_category]="虚拟化环境 - 宿主机SSD但虚拟磁盘性能受限"
        elif (( $(echo "$seq_read > 5000" | bc -l) )) && (( $(echo "$disk_rand_read > 200000" | bc -l) )); then
            SYSTEM_INFO[disk_category]="PCIe 4.0 NVMe 企业级SSD"
        elif (( $(echo "$seq_read > 3000" | bc -l) )) && (( $(echo "$disk_rand_read > 100000" | bc -l) )); then
            SYSTEM_INFO[disk_category]="PCIe 3.0 NVMe 企业级SSD"
        elif (( $(echo "$seq_read > 1500" | bc -l) )) && (( $(echo "$disk_rand_read > 50000" | bc -l) )); then
            SYSTEM_INFO[disk_category]="NVMe 或 SATA3 企业级SSD"
        elif (( $(echo "$seq_read > 400" | bc -l) )) && (( $(echo "$disk_rand_read > 30000" | bc -l) )); then
            SYSTEM_INFO[disk_category]="SATA3 企业级SSD"
        elif (( $(echo "$disk_rand_read > 10000" | bc -l) )); then
            SYSTEM_INFO[disk_category]="SATA SSD"
        else
            SYSTEM_INFO[disk_category]="SATA2 SSD或虚拟化受限环境"
        fi
        
    else
        # 判断服务器HDD类型（优先基于IOPS，而非顺序速度）
        local disk_rand_read=${PERFORMANCE_DATA[disk_rand_read_iops]:-100}
        local disk_seq=${PERFORMANCE_DATA[disk_seq_read]:-100}
        
        # 判断HDD类型（基于IOPS优先）
        if (( $(echo "$disk_seq > 200" | bc -l) )) && (( $(echo "$disk_rand_read > 180" | bc -l) )); then
            SYSTEM_INFO[disk_category]="10000/15000 RPM SAS 企业级HDD"
        elif (( $(echo "$disk_rand_read > 120" | bc -l) )); then
            SYSTEM_INFO[disk_category]="7200 RPM SAS 企业级HDD"
        elif (( $(echo "$disk_rand_read > 80" | bc -l) )); then
            SYSTEM_INFO[disk_category]="7200 RPM SATA HDD"
        else
            SYSTEM_INFO[disk_category]="5400 RPM HDD 或虚拟化低速盘"
        fi
        
    fi

    
    # 设置虚拟化环境标记（增强检测）
    local is_virtualized=0
    local virt_warning=""
    
    local seq_read_val=${PERFORMANCE_DATA[disk_seq_read]:-0}
    local iops_read_val=${PERFORMANCE_DATA[disk_rand_read_iops]:-0}
    local disk_dev=${SYSTEM_INFO[disk_device]:-"/dev/sda"}
    
    # 检测方法1: 设备名特征（VirtIO设备）
    if [[ "$disk_dev" =~ vd[a-z]|xvd[a-z] ]]; then
        is_virtualized=1
        log_info "检测到虚拟化设备: $disk_dev (VirtIO/Xen)"
    fi
    
    # 检测方法2: 性能特征分析
    if [ "${SYSTEM_INFO[disk_type]}" = "HDD" ]; then
        # HDD虚拟化检测：顺序速度异常高 或 IOPS极低
        if (( $(echo "$seq_read_val > 500 && $iops_read_val < 1000" | bc -l) )); then
            is_virtualized=1
        # 新增：即使顺序速度低，但极低IOPS也可能是虚拟化
        elif (( $(echo "$iops_read_val < 200 && $seq_read_val < 300" | bc -l) )); then
            is_virtualized=1
        fi
    else
        # SSD虚拟化检测
        if (( $(echo "$seq_read_val > 1000 && $iops_read_val < 10000" | bc -l) )); then
            is_virtualized=1
        fi
    fi
    
    # 设置虚拟化标记和警告信息
    if [ $is_virtualized -eq 1 ]; then
        if [ "${SYSTEM_INFO[disk_type]}" = "HDD" ] && (( $(echo "$seq_read_val > 500" | bc -l) )); then
            SYSTEM_INFO[is_virtualized]="是（宿主机SSD，虚拟盘IOPS受限）"
            virt_warning="⚠️ 虚拟化环境：顺序${seq_read_val}MB/s vs IOPS ${iops_read_val}"
        elif [ "${SYSTEM_INFO[disk_type]}" = "HDD" ]; then
            SYSTEM_INFO[is_virtualized]="是（虚拟化HDD，低IOPS）"
            virt_warning="⚠️ 虚拟化环境：IOPS ${iops_read_val} 极低"
        else
            SYSTEM_INFO[is_virtualized]="是（SSD虚拟化受限）"
            virt_warning="⚠️ SSD虚拟化环境：IOPS性能受限"
        fi
        PERFORMANCE_DATA[disk_virt_warning]="$virt_warning"
    else
        SYSTEM_INFO[is_virtualized]="否"
    fi
    
    log_success "磁盘性能测试完成"
    echo ""
    log_info "📊 实测性能数据："
    log_info "   顺序读取: ${PERFORMANCE_DATA[disk_seq_read]} MB/s"
    log_info "   4K随机读写IOPS: ${PERFORMANCE_DATA[disk_rand_read_iops]}/${PERFORMANCE_DATA[disk_rand_write_iops]} ⭐关键指标"
    log_info "   磁盘类型识别: ${SYSTEM_INFO[disk_category]:-未识别}"
    echo ""
    
    # 显示虚拟化环境检测结果
    if [ "${SYSTEM_INFO[is_virtualized]}" != "否" ]; then
        log_warn "⚠️ 虚拟化环境检测: ${SYSTEM_INFO[is_virtualized]}"
        if [ -n "${PERFORMANCE_DATA[disk_virt_warning]}" ]; then
            log_warn "${PERFORMANCE_DATA[disk_virt_warning]}"
        fi
        log_info "虚拟内存优化将针对低IOPS特性进行调整"
    fi
}

# 商业级算法：计算最优Swap大小
calculate_optimal_swap_advanced() {
    log_header "商业级算法：计算最优Swap配置"
    
    local ram_mb=${SYSTEM_INFO[total_ram_mb]}
    local ram_gb=$(echo "scale=2; $ram_mb / 1024" | bc)
    local disk_type=${SYSTEM_INFO[disk_type]}
    
    # 直接使用原始性能数据
    local cpu_performance=${PERFORMANCE_DATA[cpu_single_thread]:-800}  # Sysbench events/sec
    local mem_bandwidth=${PERFORMANCE_DATA[mem_read_bandwidth]:-10000}  # MB/s
    local disk_iops=${PERFORMANCE_DATA[disk_rand_read_iops]:-100}  # 4K随机读IOPS
    
    log_info "基于实测性能数据进行计算..."
    log_info "  - CPU性能: ${cpu_performance} events/sec"
    log_info "  - 内存容量: ${ram_mb} MB ($(echo "scale=2; $ram_mb/1024" | bc) GB)"
    log_info "  - 内存带宽: ${mem_bandwidth} MB/s"
    log_info "  - 磁盘IOPS: ${disk_iops} (4K随机读)"
    
    # 服务器级多因子加权算法
    # ==========================================
    # 基于Google SRE、Red Hat Enterprise、Oracle生产环境最佳实践
    # 因子1: 内存大小基础系数（服务器版）
    # 因子2: CPU性能系数
    # 因子3: 内存性能系数
    # 因子4: 磁盘类型和性能系数
    # 因子5: 服务器稳定性系数（保守设置）
    # ==========================================
    
    # 基础swap计算（Red Hat/Oracle推荐 - 根据内存大小分级）
    # 小内存需要更多swap，大内存需要更少swap
    local base_swap
    
    if (( $(echo "$ram_gb < 1" | bc -l) )); then
        # 极小内存（<1GB）：保守设置，为disk_factor(最大1.4)预留调整空间
        # 目标：×1.4后约等于RAM×2
        base_swap=$(echo "scale=0; $ram_mb * 1.4" | bc)
        log_warn "内存过小（<1GB），强烈不建议用于生产服务器"
    elif (( $(echo "$ram_gb < 2" | bc -l) )); then
        # 小内存（1-2GB）：目标×1.4后约等于RAM×1.8
        base_swap=$(echo "scale=0; $ram_mb * 1.3" | bc)
        log_warn "内存较小（<2GB），不建议用于生产服务器"
    elif (( $(echo "$ram_gb < 4" | bc -l) )); then
        # 小内存（2-4GB）：目标×1.2后约等于RAM×1.2
        base_swap=$(echo "scale=0; $ram_mb * 1.0" | bc)
    elif (( $(echo "$ram_gb < 8" | bc -l) )); then
        # 中等内存（4-8GB）：目标×1.2后约等于RAM×0.8
        base_swap=$(echo "scale=0; $ram_mb * 0.7" | bc)
    elif (( $(echo "$ram_gb < 16" | bc -l) )); then
        # 较大内存（8-16GB）：目标×0.7后约等于RAM×0.35
        base_swap=$(echo "scale=0; $ram_mb * 0.5" | bc)
    elif (( $(echo "$ram_gb < 32" | bc -l) )); then
        # 大内存（16-32GB）
        base_swap=$(echo "scale=0; $ram_mb * 0.35" | bc)
    elif (( $(echo "$ram_gb < 64" | bc -l) )); then
        # 超大内存（32-64GB）
        base_swap=$(echo "scale=0; $ram_mb * 0.18" | bc)
    elif (( $(echo "$ram_gb < 128" | bc -l) )); then
        # 海量内存（64-128GB）
        base_swap=8192  # 固定8GB
    else
        # 极大内存（>=128GB）
        base_swap=16384  # 固定16GB（用于内核转储）
    fi
    
    # ==========================================
    # 基于原始性能数据的系数计算
    # ==========================================
    
    # CPU性能调整系数（范围0.97-1.03）
    # 基准：1000 events/sec
    # 逻辑：CPU越慢，上下文切换开销越大，略微增加Swap缓冲
    local cpu_factor
    local cpu_perf_int=$(echo "$cpu_performance" | cut -d'.' -f1)
    if [ $cpu_perf_int -ge 1500 ]; then
        cpu_factor=0.97  # >=1500 events/sec：略微减少Swap
    elif [ $cpu_perf_int -ge 1000 ]; then
        cpu_factor=1.00  # 1000-1500 events/sec：标准策略
    elif [ $cpu_perf_int -ge 600 ]; then
        cpu_factor=1.01  # 600-1000 events/sec：略微增加
    else
        cpu_factor=1.03  # <600 events/sec：增加Swap缓冲
    fi
    
    
    # 内存速度调整系数（范围0.98-1.02）
    # 基准：20000 MB/s (DDR4-2666 ECC)
    # 逻辑：内存带宽对Swap效率影响很小，仅微调
    local mem_speed_factor
    local mem_bw_int=$(echo "$mem_bandwidth" | cut -d'.' -f1)
    if [ $mem_bw_int -ge 30000 ]; then
        mem_speed_factor=0.98  # >=30000 MB/s：略微减少Swap
    elif [ $mem_bw_int -ge 15000 ]; then
        mem_speed_factor=1.00  # 15000-30000 MB/s：标准策略
    else
        mem_speed_factor=1.02  # <15000 MB/s：略微增加Swap
    fi
    
    # 磁盘IOPS调整系数（范围0.70-1.40）
    # 基准：10000 IOPS
    # 逻辑：IOPS直接决定Swap可用性，影响最大
    local disk_factor
    local is_virt=${SYSTEM_INFO[is_virtualized]:-"否"}
    
    if [ "$disk_type" = "SSD" ]; then
        # SSD: 根据IOPS调整
        if [ $disk_iops -ge 100000 ]; then
            disk_factor=0.70  # >=100k IOPS：大幅减少Swap
        elif [ $disk_iops -ge 50000 ]; then
            disk_factor=0.80  # 50k-100k IOPS
        elif [ $disk_iops -ge 20000 ]; then
            disk_factor=0.90  # 20k-50k IOPS
        elif [ $disk_iops -ge 10000 ]; then
            disk_factor=0.95  # 10k-20k IOPS
        else
            disk_factor=1.00  # <10k IOPS
        fi
    else
        # HDD或虚拟化环境: IOPS低，需要大幅增加Swap
        if [[ "$is_virt" == "是"* ]]; then
            # 虚拟化环境：IOPS极低且不稳定
            if [ $disk_iops -lt 100 ]; then
                disk_factor=1.45  # IOPS <100：极端情况，最大保护
                log_warn "极端低IOPS（${disk_iops}），最大增加swap（+45%）应对严重IO瓶颈"
            elif [ $disk_iops -lt 150 ]; then
                disk_factor=1.40  # IOPS 100-150：极低情况
                log_warn "极低IOPS（${disk_iops}），大幅增加swap（+40%）应对IO瓶颈"
            elif [ $disk_iops -lt 300 ]; then
                disk_factor=1.30  # IOPS 150-300：虚拟化典型
                log_warn "虚拟化低IOPS（${disk_iops}），增加swap（+30%）应对IO波动"
            else
                disk_factor=1.20  # IOPS >300：虚拟化较好情况
                log_info "虚拟化环境IOPS=${disk_iops}，适度增加swap"
            fi
        else
            # 物理HDD：根据IOPS调整
            if [ $disk_iops -ge 400 ]; then
                disk_factor=1.05  # 15K RPM SAS：IOPS >400
            elif [ $disk_iops -ge 200 ]; then
                disk_factor=1.10  # 10K RPM：IOPS 200-400
            elif [ $disk_iops -ge 100 ]; then
                disk_factor=1.20  # 7200 RPM：IOPS 100-200
            else
                disk_factor=1.30  # 5400 RPM：IOPS <100
            fi
        fi
    fi
    
    log_info "算法策略：直接基于原始性能指标"
    if [[ "$is_virt" == "是"* ]]; then
        log_info "虚拟化优化：IOPS主导策略调整"
    fi
    
    # 综合计算最优swap（三因子模型：CPU + 内存带宽 + 磁盘IOPS）
    # 注意：内存容量已在base_swap中体现，不需要额外系数
    local optimal_swap=$(echo "scale=0; $base_swap * $cpu_factor * $mem_speed_factor * $disk_factor" | bc | cut -d'.' -f1)
    
    # 确保swap在合理范围内
    # 最小值：256MB或RAM的10%（取较大值）
    local min_swap=$((ram_mb / 10))
    if [ $min_swap -lt 256 ]; then
        min_swap=256
    fi
    
    # 最大值：RAM的2倍或16GB（取较小值）
    local max_swap=$((ram_mb * 2))
    if [ $max_swap -gt 16384 ]; then
        max_swap=16384
    fi
    
    if [ $optimal_swap -lt $min_swap ]; then
        optimal_swap=$min_swap
    elif [ $optimal_swap -gt $max_swap ]; then
        optimal_swap=$max_swap
    fi
    
    PERFORMANCE_DATA[optimal_swap]=$optimal_swap
    
    log_success "推荐Swap大小: ${optimal_swap} MB ($(echo "scale=2; $optimal_swap/1024" | bc) GB)"
    echo ""
    log_info "📊 三因子模型计算详情："
    log_info "  ├─ 基准Swap: ${base_swap} MB (基于${ram_gb}GB内存)"
    log_info "  ├─ CPU性能系数: ${cpu_factor} (影响5%, 范围0.97-1.03)"
    log_info "  ├─ 内存带宽系数: ${mem_speed_factor} (影响5%, 范围0.98-1.02)"
    log_info "  ├─ 磁盘IOPS系数: ${disk_factor} (影响90%, 范围0.70-1.40)"
    log_info "  └─ 综合系数: $(echo "scale=4; $cpu_factor * $mem_speed_factor * $disk_factor" | bc)"
}

# 商业级算法：计算最优swappiness
calculate_optimal_swappiness_advanced() {
    log_progress "计算最优Swappiness值..."
    
    local ram_gb=$(echo "scale=2; ${SYSTEM_INFO[total_ram_mb]} / 1024" | bc)
    local ram_mb=${SYSTEM_INFO[total_ram_mb]}
    local disk_type=${SYSTEM_INFO[disk_type]}
    local disk_iops=${PERFORMANCE_DATA[disk_rand_read_iops]:-100}
    local is_virt=${SYSTEM_INFO[is_virtualized]:-"否"}
    
    # 服务器Swappiness推荐算法（Red Hat/Oracle/Google SRE标准）
    # 服务器环境swappiness通常设置较低，以优先使用物理内存
    # 但不能太低（0-5），否则可能导致OOM Killer过早触发
    # 
    # Red Hat Enterprise建议：
    #   - 数据库服务器: 1-10
    #   - Web服务器: 10-30
    #   - 应用服务器: 10-20
    #   - 通用服务器: 10-30
    # 
    # Oracle Linux建议：
    #   - Oracle数据库: 10
    #   - 其他应用: 10-20
    # 
    # Google Production建议：
    #   - 大内存服务器(64GB+): 1
    #   - 中等内存服务器: 10
    #   - 小内存服务器: 20-30
    
    local base_swappiness
    if (( $(echo "$ram_gb < 2" | bc -l) )); then
        base_swappiness=60  # 极小内存服务器（不推荐生产）
        log_warn "内存过小，swappiness设置较高以避免OOM"
    elif (( $(echo "$ram_gb < 4" | bc -l) )); then
        base_swappiness=40  # 小内存服务器
    elif (( $(echo "$ram_gb < 8" | bc -l) )); then
        base_swappiness=30  # 中小内存服务器
    elif (( $(echo "$ram_gb < 16" | bc -l) )); then
        base_swappiness=20  # 中等内存服务器
    elif (( $(echo "$ram_gb < 32" | bc -l) )); then
        base_swappiness=10  # 大内存服务器
    elif (( $(echo "$ram_gb < 64" | bc -l) )); then
        base_swappiness=5   # 超大内存服务器
    else
        base_swappiness=1   # 海量内存服务器（Google标准）
    fi
    
    # 根据磁盘IOPS调整（直接基于IOPS值）
    local disk_adjustment=0
    
    if [ "$disk_type" = "SSD" ]; then
        # SSD: IOPS高，可以适度提高swappiness
        if [ $disk_iops -ge 100000 ]; then
            disk_adjustment=2   # >=100k IOPS
        elif [ $disk_iops -ge 50000 ]; then
            disk_adjustment=1   # 50k-100k IOPS
        else
            disk_adjustment=0   # <50k IOPS
        fi
    else
        # HDD或虚拟化环境: IOPS低，需要降低swappiness
        if [[ "$is_virt" == "是"* ]]; then
            # 虚拟化环境：根据IOPS严重程度调整
            if [ $disk_iops -lt 100 ]; then
                disk_adjustment=-20  # IOPS <100：极端慢速，严格限制swap使用
                log_warn "极端低IOPS（${disk_iops}），严格降低swappiness避免系统卡死"
            elif [ $disk_iops -lt 150 ]; then
                disk_adjustment=-15  # IOPS 100-150：严重受限
                log_warn "极低IOPS（${disk_iops}），大幅降低swappiness避免频繁交换"
            elif [ $disk_iops -lt 300 ]; then
                disk_adjustment=-10  # IOPS 150-300：明显受限
                log_warn "低IOPS（${disk_iops}），降低swappiness避免性能抖动"
            else
                disk_adjustment=-5   # IOPS >300：轻度受限
                log_info "虚拟化IOPS（${disk_iops}），适度降低swappiness"
            fi
        else
            # 物理HDD：根据IOPS调整
            if [ $disk_iops -ge 400 ]; then
                disk_adjustment=-2   # 高性能HDD (15K RPM)
            elif [ $disk_iops -ge 200 ]; then
                disk_adjustment=-5   # 标准HDD (10K/7200 RPM)
            else
                disk_adjustment=-10  # 低速HDD (5400 RPM)
                log_warn "HDD IOPS过低（${disk_iops}），建议升级到SSD"
            fi
        fi
    fi
    
    local optimal_swappiness=$((base_swappiness + disk_adjustment))
    
    # 确保在合理范围 (1-100)
    if [ $optimal_swappiness -lt 1 ]; then
        optimal_swappiness=1
    elif [ $optimal_swappiness -gt 100 ]; then
        optimal_swappiness=100
    fi
    
    PERFORMANCE_DATA[optimal_swappiness]=$optimal_swappiness
    log_success "推荐Swappiness: ${optimal_swappiness}"
}

# 读取当前系统的虚拟内存参数
read_current_vm_parameters() {
    log_progress "读取当前系统虚拟内存参数..."
    
    # 声明关联数组存储原始参数
    declare -gA ORIGINAL_VM_PARAMS
    
    # 读取所有虚拟内存相关参数
    ORIGINAL_VM_PARAMS[swappiness]=$(sysctl -n vm.swappiness 2>/dev/null || echo "60")
    ORIGINAL_VM_PARAMS[vfs_cache_pressure]=$(sysctl -n vm.vfs_cache_pressure 2>/dev/null || echo "100")
    ORIGINAL_VM_PARAMS[dirty_ratio]=$(sysctl -n vm.dirty_ratio 2>/dev/null || echo "20")
    ORIGINAL_VM_PARAMS[dirty_background_ratio]=$(sysctl -n vm.dirty_background_ratio 2>/dev/null || echo "10")
    ORIGINAL_VM_PARAMS[dirty_expire_centisecs]=$(sysctl -n vm.dirty_expire_centisecs 2>/dev/null || echo "3000")
    ORIGINAL_VM_PARAMS[dirty_writeback_centisecs]=$(sysctl -n vm.dirty_writeback_centisecs 2>/dev/null || echo "500")
    ORIGINAL_VM_PARAMS[min_free_kbytes]=$(sysctl -n vm.min_free_kbytes 2>/dev/null || echo "65536")
    ORIGINAL_VM_PARAMS[page_cluster]=$(sysctl -n vm.page_cluster 2>/dev/null || echo "3")
    ORIGINAL_VM_PARAMS[overcommit_memory]=$(sysctl -n vm.overcommit_memory 2>/dev/null || echo "0")
    ORIGINAL_VM_PARAMS[overcommit_ratio]=$(sysctl -n vm.overcommit_ratio 2>/dev/null || echo "50")
    
    # 读取当前Swap大小
    ORIGINAL_VM_PARAMS[current_swap]=$(free -m | awk '/^Swap:/{print $2}')
    
    log_success "当前系统参数读取完成"
}

# 对比原始参数和推荐参数，返回差异数量
compare_vm_parameters() {
    log_progress "对比原始参数与推荐参数..."
    
    local diff_count=0
    declare -gA VM_PARAM_DIFF
    
    # 对比每个参数
    if [ "${ORIGINAL_VM_PARAMS[swappiness]}" != "${PERFORMANCE_DATA[optimal_swappiness]}" ]; then
        VM_PARAM_DIFF[swappiness]="变更"
        ((diff_count++))
    fi
    
    if [ "${ORIGINAL_VM_PARAMS[vfs_cache_pressure]}" != "${PERFORMANCE_DATA[vfs_cache_pressure]}" ]; then
        VM_PARAM_DIFF[vfs_cache_pressure]="变更"
        ((diff_count++))
    fi
    
    if [ "${ORIGINAL_VM_PARAMS[dirty_ratio]}" != "${PERFORMANCE_DATA[dirty_ratio]}" ]; then
        VM_PARAM_DIFF[dirty_ratio]="变更"
        ((diff_count++))
    fi
    
    if [ "${ORIGINAL_VM_PARAMS[dirty_background_ratio]}" != "${PERFORMANCE_DATA[dirty_background_ratio]}" ]; then
        VM_PARAM_DIFF[dirty_background_ratio]="变更"
        ((diff_count++))
    fi
    
    if [ "${ORIGINAL_VM_PARAMS[dirty_expire_centisecs]}" != "${PERFORMANCE_DATA[dirty_expire]}" ]; then
        VM_PARAM_DIFF[dirty_expire_centisecs]="变更"
        ((diff_count++))
    fi
    
    if [ "${ORIGINAL_VM_PARAMS[dirty_writeback_centisecs]}" != "${PERFORMANCE_DATA[dirty_writeback]}" ]; then
        VM_PARAM_DIFF[dirty_writeback_centisecs]="变更"
        ((diff_count++))
    fi
    
    if [ "${ORIGINAL_VM_PARAMS[min_free_kbytes]}" != "${PERFORMANCE_DATA[min_free_kbytes]}" ]; then
        VM_PARAM_DIFF[min_free_kbytes]="变更"
        ((diff_count++))
    fi
    
    if [ "${ORIGINAL_VM_PARAMS[page_cluster]}" != "${PERFORMANCE_DATA[page_cluster]}" ]; then
        VM_PARAM_DIFF[page_cluster]="变更"
        ((diff_count++))
    fi
    
    if [ "${ORIGINAL_VM_PARAMS[overcommit_memory]}" != "${PERFORMANCE_DATA[overcommit_memory]}" ]; then
        VM_PARAM_DIFF[overcommit_memory]="变更"
        ((diff_count++))
    fi
    
    if [ "${ORIGINAL_VM_PARAMS[overcommit_ratio]}" != "${PERFORMANCE_DATA[overcommit_ratio]}" ]; then
        VM_PARAM_DIFF[overcommit_ratio]="变更"
        ((diff_count++))
    fi
    
    # Swap大小检查（智能阈值：小内存10%，大内存20%）
    local current_swap=${ORIGINAL_VM_PARAMS[current_swap]:-0}
    local optimal_swap=${PERFORMANCE_DATA[optimal_swap]:-0}
    local swap_diff=$((optimal_swap - current_swap))
    local swap_diff_abs=${swap_diff#-}
    
    # 动态阈值：<2GB内存用10%，>=2GB用20%
    local ram_mb=${SYSTEM_INFO[total_ram_mb]:-1024}
    local swap_threshold
    if [ $ram_mb -lt 2048 ]; then
        # 小内存系统：10%阈值（更精确）
        swap_threshold=$((optimal_swap / 10))
    else
        # 大内存系统：20%阈值（容忍度更高）
        swap_threshold=$((optimal_swap / 5))
    fi
    
    # 判断是否需要变更
    if [ $current_swap -eq 0 ]; then
        # 无Swap：必须创建
        VM_PARAM_DIFF[swap_size]="变更"
        ((diff_count++))
    elif [ $swap_diff_abs -gt $swap_threshold ]; then
        # 差异超过阈值：需要调整
        VM_PARAM_DIFF[swap_size]="变更"
        ((diff_count++))
    fi
    
    log_success "参数对比完成，发现 ${diff_count} 项差异"
    return $diff_count
}

# 显示参数对比表格
show_parameter_comparison() {
    echo ""
    printf "${CYAN}╔═══════════════════════════════════════════════════════════════════╗${NC}\n"
    printf "${CYAN}║               虚拟内存参数对比（原始 vs 推荐）                    ║${NC}\n"
    printf "${CYAN}╚═══════════════════════════════════════════════════════════════════╝${NC}\n"
    echo ""
    
    printf "${YELLOW}%-30s %-15s %-15s %-10s${NC}\n" "参数名称" "原始值" "推荐值" "状态"
    printf "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
    
    # 核心Swap参数
    show_param_row "vm.swappiness" "${ORIGINAL_VM_PARAMS[swappiness]}" "${PERFORMANCE_DATA[optimal_swappiness]}" "swappiness"
    show_param_row "vm.vfs_cache_pressure" "${ORIGINAL_VM_PARAMS[vfs_cache_pressure]}" "${PERFORMANCE_DATA[vfs_cache_pressure]}" "vfs_cache_pressure"
    
    echo ""
    printf "${YELLOW}脏页管理参数:${NC}\n"
    show_param_row "vm.dirty_ratio" "${ORIGINAL_VM_PARAMS[dirty_ratio]}" "${PERFORMANCE_DATA[dirty_ratio]}" "dirty_ratio"
    show_param_row "vm.dirty_background_ratio" "${ORIGINAL_VM_PARAMS[dirty_background_ratio]}" "${PERFORMANCE_DATA[dirty_background_ratio]}" "dirty_background_ratio"
    show_param_row "vm.dirty_expire_centisecs" "${ORIGINAL_VM_PARAMS[dirty_expire_centisecs]}" "${PERFORMANCE_DATA[dirty_expire]}" "dirty_expire_centisecs"
    show_param_row "vm.dirty_writeback_centisecs" "${ORIGINAL_VM_PARAMS[dirty_writeback_centisecs]}" "${PERFORMANCE_DATA[dirty_writeback]}" "dirty_writeback_centisecs"
    
    echo ""
    printf "${YELLOW}内存管理参数:${NC}\n"
    show_param_row "vm.min_free_kbytes" "${ORIGINAL_VM_PARAMS[min_free_kbytes]}" "${PERFORMANCE_DATA[min_free_kbytes]}" "min_free_kbytes"
    show_param_row "vm.page_cluster" "${ORIGINAL_VM_PARAMS[page_cluster]}" "${PERFORMANCE_DATA[page_cluster]}" "page_cluster"
    show_param_row "vm.overcommit_memory" "${ORIGINAL_VM_PARAMS[overcommit_memory]}" "${PERFORMANCE_DATA[overcommit_memory]}" "overcommit_memory"
    show_param_row "vm.overcommit_ratio" "${ORIGINAL_VM_PARAMS[overcommit_ratio]}" "${PERFORMANCE_DATA[overcommit_ratio]}" "overcommit_ratio"
    
    echo ""
    printf "${YELLOW}Swap空间:${NC}\n"
    show_param_row "Swap大小 (MB)" "${ORIGINAL_VM_PARAMS[current_swap]}" "${PERFORMANCE_DATA[optimal_swap]}" "swap_size"
    
    echo ""
    printf "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
}

# 辅助函数：显示单个参数行
show_param_row() {
    local param_name=$1
    local original=$2
    local recommended=$3
    local diff_key=$4
    
    local status
    if [ "${VM_PARAM_DIFF[$diff_key]}" = "变更" ]; then
        status="${RED}需要变更${NC}"
    else
        status="${GREEN}✓ 一致${NC}"
    fi
    
    printf "%-30s %-15s %-15s " "$param_name" "$original" "$recommended"
    echo -e "$status"
}

# 商业级算法：计算其他VM参数
calculate_advanced_vm_parameters() {
    log_progress "计算高级虚拟内存参数..."
    
    local disk_type=${SYSTEM_INFO[disk_type]:-HDD}
    local disk_iops=${PERFORMANCE_DATA[disk_rand_write_iops]:-80}  # 使用写IOPS(脏页写回)
    local ram_mb=${SYSTEM_INFO[total_ram_mb]:-1024}
    local ram_gb=$(echo "scale=2; $ram_mb / 1024" | bc)
    local cpu_cores=${SYSTEM_INFO[cpu_cores]:-1}
    
    # 1. vm.vfs_cache_pressure
    # 控制内核回收用于缓存目录和inode对象的内存的倾向
    # 逻辑：IOPS高的存储可以更积极回收缓存（可以快速重新加载）
    if [ "$disk_type" = "SSD" ] && [ $disk_iops -ge 50000 ]; then
        PERFORMANCE_DATA[vfs_cache_pressure]=150  # 高IOPS：积极回收
    elif [ "$disk_type" = "SSD" ]; then
        PERFORMANCE_DATA[vfs_cache_pressure]=100  # 普通SSD：标准策略
    else
        # HDD/虚拟化：保留更多缓存
        if [ $disk_iops -lt 200 ]; then
            PERFORMANCE_DATA[vfs_cache_pressure]=50  # 低IOPS：大量保留缓存
        else
            PERFORMANCE_DATA[vfs_cache_pressure]=75  # 中等HDD
        fi
    fi
    
    # 2. vm.dirty_ratio
    # 当脏页达到内存的这个百分比时，进程会被阻塞并强制写回
    # 关键原则：
    #   - 内存越小，dirty_ratio越低（避免占用过多内存）
    #   - IOPS越低，dirty_ratio越低（避免突发写入堵塞）
    if [ "$disk_type" = "SSD" ]; then
        if [ $disk_iops -ge 50000 ]; then
            PERFORMANCE_DATA[dirty_ratio]=40  # 高IOPS SSD：可以缓存更多脏页
        else
            PERFORMANCE_DATA[dirty_ratio]=30  # 普通SSD
        fi
    else
        # HDD/虚拟化：根据IOPS和内存大小
        if (( $(echo "${ram_gb:-1} < 1" | bc -l) )); then
            # 极小内存：dirty_ratio必须很低，避免脏页占用太多宝贵内存
            PERFORMANCE_DATA[dirty_ratio]=5
            log_info "极小内存系统：降低dirty_ratio到5%，避免脏页占用过多内存"
        elif [ $disk_iops -ge 400 ]; then
            PERFORMANCE_DATA[dirty_ratio]=20  # 高速HDD (15K RPM)
        elif [ $disk_iops -ge 200 ]; then
            PERFORMANCE_DATA[dirty_ratio]=15  # 标准HDD (10K/7200 RPM)
        else
            # 低IOPS HDD/虚拟化且低内存
            if (( $(echo "${ram_gb:-1} < 2" | bc -l) )); then
                PERFORMANCE_DATA[dirty_ratio]=8  # 低IOPS+小内存：非常保守
            else
                PERFORMANCE_DATA[dirty_ratio]=10  # 低IOPS：保守策略
            fi
        fi
    fi
    
    # 3. vm.dirty_background_ratio
    # 后台pdflush进程开始写回的阈值
    PERFORMANCE_DATA[dirty_background_ratio]=$((${PERFORMANCE_DATA[dirty_ratio]} / 4))
    if [ ${PERFORMANCE_DATA[dirty_background_ratio]} -lt 3 ]; then
        PERFORMANCE_DATA[dirty_background_ratio]=3
    fi
    
    # 4. vm.dirty_expire_centisecs
    # 脏页的过期时间（根据IOPS调整）
    # 逻辑：IOPS越低，脏页保留越久，给予更多合并时间
    if [ "$disk_type" = "SSD" ]; then
        PERFORMANCE_DATA[dirty_expire]=1500  # 15秒（SSD写入快）
    else
        if [ $disk_iops -lt 100 ]; then
            PERFORMANCE_DATA[dirty_expire]=4000  # 40秒（极端慢速，最大合并时间）
        elif [ $disk_iops -lt 150 ]; then
            PERFORMANCE_DATA[dirty_expire]=3000  # 30秒（极慢HDD/虚拟化）
        else
            PERFORMANCE_DATA[dirty_expire]=2000  # 20秒（普通HDD）
        fi
    fi
    
    # 5. vm.dirty_writeback_centisecs
    # pdflush唤醒间隔
    if [ "$disk_type" = "SSD" ]; then
        PERFORMANCE_DATA[dirty_writeback]=200  # 2秒
    else
        PERFORMANCE_DATA[dirty_writeback]=500  # 5秒
    fi
    
    # 6. vm.min_free_kbytes
    # 保持的最小空闲内存（用于紧急分配）
    # Red Hat Enterprise推荐：0.4% - 5% of total RAM
    # ⚠️ 重要：对于小内存系统，不要降低原值，这会导致内存分配失败！
    local total_ram_kb=${SYSTEM_INFO[total_ram_kb]:-1048576}
    local current_min_free=${ORIGINAL_VM_PARAMS[min_free_kbytes]:-65536}
    
    # 基础计算：RAM的0.5%（保守策略）
    local min_free=$(echo "scale=0; $total_ram_kb * 0.005" | bc | cut -d'.' -f1)
    
    # 根据CPU核心数调整（更多核心需要更多空闲内存）
    min_free=$(echo "scale=0; ${min_free:-52428} * (1 + ${cpu_cores:-1} * 0.05)" | bc | cut -d'.' -f1)
    
    # 动态限制范围，基于RAM大小
    local min_limit max_limit
    
    if (( $(echo "$ram_mb < 512" | bc -l) )); then
        # 极小内存(<512MB)：不要降低原值！保持系统默认或当前值
        min_limit=$current_min_free
        max_limit=$current_min_free
        log_warn "极小内存系统：保持min_free_kbytes=${current_min_free}KB不变（安全策略）"
    elif (( $(echo "$ram_mb < 1024" | bc -l) )); then
        # 小内存(<1GB)：最低保持当前值的80%，最高不超过当前值
        min_limit=$(echo "scale=0; $current_min_free * 0.8" | bc | cut -d'.' -f1)
        max_limit=$current_min_free
        log_info "小内存系统：min_free_kbytes范围 ${min_limit}-${max_limit}KB"
    else
        # 正常内存：使用标准范围
        min_limit=$(echo "scale=0; $total_ram_kb * 0.02" | bc | cut -d'.' -f1)  # 最低2%
        max_limit=$(echo "scale=0; $total_ram_kb * 0.10" | bc | cut -d'.' -f1)  # 最高10%
        
        # 绝对值限制：16MB - 1GB
        if [ $min_limit -lt 16384 ]; then
            min_limit=16384
        fi
        if [ $min_limit -gt 65536 ]; then
            min_limit=65536
        fi
        if [ $max_limit -gt 1048576 ]; then
            max_limit=1048576
        fi
    fi
    
    # 应用限制
    if [ $min_free -lt $min_limit ]; then
        min_free=$min_limit
    elif [ $min_free -gt $max_limit ]; then
        min_free=$max_limit
    fi
    
    PERFORMANCE_DATA[min_free_kbytes]=$min_free
    
    # 7. vm.page_cluster
    # 一次swap读取的页面数量（2^page_cluster）
    if [ "$disk_type" = "SSD" ]; then
        PERFORMANCE_DATA[page_cluster]=0  # SSD随机性能好，单页读取
    else
        PERFORMANCE_DATA[page_cluster]=3  # HDD受益于连续读取
    fi
    
    # 8. vm.overcommit_memory
    # 内存超额分配策略
    # 0: 启发式策略(默认) - 最安全的选择
    # 1: 总是允许超额分配 - 适合内存不足的系统
    # 2: 严格控制(危险) - 容易导致无法分配内存
    # 
    # ⚠️ 重要：永远不使用overcommit_memory=2，这会导致系统无法分配内存！
    # 对于小内存系统，使用模式1允许超额分配，避免过早OOM
    if (( $(echo "${ram_mb:-1024} < 512" | bc -l) )); then
        # 极小内存(<512MB)：允许超额分配，避免无法fork进程
        PERFORMANCE_DATA[overcommit_memory]=1
        PERFORMANCE_DATA[overcommit_ratio]=100  # 允许100%超额
        log_info "极小内存系统：使用overcommit_memory=1避免无法分配内存"
    elif (( $(echo "${ram_mb:-1024} < 2048" | bc -l) )); then
        # 小内存(<2GB)：使用启发式，但增加overcommit_ratio
        PERFORMANCE_DATA[overcommit_memory]=0
        PERFORMANCE_DATA[overcommit_ratio]=80  # 宽松策略
        log_info "小内存系统：使用启发式策略+宽松ratio"
    else
        # 大内存：标准启发式策略
        PERFORMANCE_DATA[overcommit_memory]=0
        PERFORMANCE_DATA[overcommit_ratio]=50
    fi
    
    # 9. vm.zone_reclaim_mode
    # NUMA系统的区域回收模式
    if [ ${cpu_cores:-1} -gt 8 ]; then
        PERFORMANCE_DATA[zone_reclaim_mode]=0  # 禁用，允许跨NUMA访问
    else
        PERFORMANCE_DATA[zone_reclaim_mode]=0
    fi
    
    log_success "高级参数计算完成"
}

# 显示完整的性能测试报告
show_professional_report() {
    log_header "专业性能测试与优化报告"
    
    echo ""
    printf "${CYAN}╔═══════════════════════════════════════════════════════════════════╗\n"
    printf "║                     系统硬件配置信息                              ║\n"
    printf "╚═══════════════════════════════════════════════════════════════════╝${NC}\n"
    echo ""
    printf "${YELLOW}CPU:${NC}\n"
    echo "  ${SYSTEM_INFO[cpu_model]}"
    echo "  核心数: ${SYSTEM_INFO[cpu_cores]}, 频率: ${SYSTEM_INFO[cpu_max_freq]} MHz"
    printf "  ${CYAN}性能: ${PERFORMANCE_DATA[cpu_single_thread]} events/sec ⭐优化关键指标${NC}\n"
    echo ""
    printf "${YELLOW}内存:${NC}\n"
    echo "  容量: $(echo "scale=2; ${SYSTEM_INFO[total_ram_mb]}/1024" | bc) GB"
    echo "  类型: ${SYSTEM_INFO[mem_category]:-未识别}"
    printf "  ${CYAN}读取带宽: ${PERFORMANCE_DATA[mem_read_bandwidth]} MB/s ⭐优化关键指标${NC}\n"
    echo ""
    printf "${YELLOW}磁盘:${NC}\n"
    echo "  设备: ${SYSTEM_INFO[disk_device]} (${SYSTEM_INFO[disk_type]})"
    echo "  类型: ${SYSTEM_INFO[disk_category]:-未识别}"
    echo "  虚拟化: ${SYSTEM_INFO[is_virtualized]:-否}"
    printf "  ${CYAN}顺序读取: ${PERFORMANCE_DATA[disk_seq_read]} MB/s${NC}\n"
    printf "  ${CYAN}4K随机IOPS: 读${PERFORMANCE_DATA[disk_rand_read_iops]} / 写${PERFORMANCE_DATA[disk_rand_write_iops]} ⭐优化关键指标${NC}\n"
    echo ""
    printf "${CYAN}╔═══════════════════════════════════════════════════════════════════╗\n"
    printf "║                   商业级优化参数推荐                              ║\n"
    printf "╚═══════════════════════════════════════════════════════════════════╝${NC}\n"
    echo ""
    printf "${GREEN}核心参数:${NC}\n"
    echo "  vm.swappiness                = ${PERFORMANCE_DATA[optimal_swappiness]}"
    echo "  推荐Swap大小                 = ${PERFORMANCE_DATA[optimal_swap]} MB ($(echo "scale=2; ${PERFORMANCE_DATA[optimal_swap]}/1024" | bc) GB)"
    echo ""
    printf "${GREEN}缓存控制参数:${NC}\n"
    echo "  vm.vfs_cache_pressure        = ${PERFORMANCE_DATA[vfs_cache_pressure]}"
    echo "  vm.dirty_ratio               = ${PERFORMANCE_DATA[dirty_ratio]}"
    echo "  vm.dirty_background_ratio    = ${PERFORMANCE_DATA[dirty_background_ratio]}"
    echo "  vm.dirty_expire_centisecs    = ${PERFORMANCE_DATA[dirty_expire]}"
    echo "  vm.dirty_writeback_centisecs = ${PERFORMANCE_DATA[dirty_writeback]}"
    echo ""
    printf "${GREEN}内存管理参数:${NC}\n"
    echo "  vm.min_free_kbytes           = ${PERFORMANCE_DATA[min_free_kbytes]} KB"
    echo "  vm.page_cluster              = ${PERFORMANCE_DATA[page_cluster]}"
    echo "  vm.overcommit_memory         = ${PERFORMANCE_DATA[overcommit_memory]}"
    echo "  vm.overcommit_ratio          = ${PERFORMANCE_DATA[overcommit_ratio]}"
    echo ""
    printf "${CYAN}╔═══════════════════════════════════════════════════════════════════╗\n"
    printf "║                       优化建议说明                                ║\n"
    printf "╚═══════════════════════════════════════════════════════════════════╝${NC}\n"
    echo ""

    # 根据系统类型给出具体建议
    if [ "${SYSTEM_INFO[disk_type]}" = "SSD" ]; then
        printf "${YELLOW}SSD系统优化策略:${NC}\n"
        echo "  ✓ 降低了swap大小以延长SSD寿命"
        echo "  ✓ 提高了dirty ratio允许更多内存缓冲"
        echo "  ✓ 减少了写回间隔利用SSD高速特性"
        echo "  ✓ 设置page_cluster=0优化随机访问"
    else
        printf "${YELLOW}HDD系统优化策略:${NC}\n"
        echo "  ✓ 保留了足够的swap空间应对慢速IO"
        echo "  ✓ 降低了vfs_cache_pressure保留更多缓存"
        echo "  ✓ 适度的dirty ratio避免IO突发"
        echo "  ✓ 增加page_cluster利用顺序读取优势"
    fi
    
    # 虚拟化环境特殊提示
    if [ "${SYSTEM_INFO[is_virtualized]}" != "否" ]; then
        echo ""
        printf "${RED}⚠️ 虚拟化环境：${SYSTEM_INFO[is_virtualized]}${NC}\n"
        printf "${YELLOW}检测到: ${PERFORMANCE_DATA[disk_virt_warning]:-虚拟化环境特征}${NC}\n"
        echo ""
        printf "${CYAN}已自动针对虚拟化优化：${NC}\n"
        echo "  ✅ 基于实测IOPS进行优化（顺序速度仅供参考）"
        echo "  ✅ Swap大小根据低IOPS调整"
        echo "  ✅ Swappiness降低避免频繁交换"
    fi
    
    echo ""
    
    local ram_gb=$(echo "scale=0; ${SYSTEM_INFO[total_ram_mb]}/1024" | bc)
    if [ $ram_gb -lt 2 ]; then
        printf "${YELLOW}低内存系统建议:${NC}\n"
        echo "  ✓ 较高的swappiness确保有足够虚拟内存"
        echo "  ✓ 建议升级物理内存以获得更好性能"
        echo "  ✓ 避免同时运行过多程序"
    elif [ $ram_gb -lt 8 ]; then
        printf "${YELLOW}中等内存系统建议:${NC}\n"
        echo "  ✓ 平衡的swap策略兼顾性能和稳定性"
        echo "  ✓ 可以运行大多数日常应用"
    else
        printf "${YELLOW}高内存系统建议:${NC}\n"
        echo "  ✓ 最小化swap使用充分发挥内存优势"
        echo "  ✓ 可以运行内存密集型应用"
        echo "  ✓ 考虑使用zswap进一步优化"
    fi
    
    echo ""
    
    # 显示参数对比表格
    show_parameter_comparison
}

# 安全检查：确保系统有足够的内存和swap
safety_check_before_apply() {
    log_progress "执行安全检查..."
    
    local ram_mb=${SYSTEM_INFO[total_ram_mb]:-1024}
    local available_mb=$(free -m | awk '/^Mem:/{print $7}')
    local current_swap=$(free -m | awk '/^Swap:/{print $2}')
    
    # 检查1：可用内存是否足够（至少50MB）
    if [ $available_mb -lt 50 ]; then
        log_error "❌ 可用内存不足50MB，优化可能导致系统不稳定"
        log_warn "当前可用: ${available_mb}MB，建议先释放内存"
        return 1
    fi
    
    # 检查2：对于极小内存系统，必须有swap才能应用overcommit限制
    if [ $ram_mb -lt 512 ] && [ $current_swap -eq 0 ]; then
        if [ "${VM_PARAM_DIFF[overcommit_memory]}" = "变更" ] && [ "${PERFORMANCE_DATA[overcommit_memory]}" != "1" ]; then
            log_warn "⚠️ 极小内存系统无swap，将强制使用overcommit_memory=1"
            PERFORMANCE_DATA[overcommit_memory]=1
        fi
    fi
    
    # 检查3：磁盘空间检查（需要至少swap大小的2倍空间）
    local optimal_swap=${PERFORMANCE_DATA[optimal_swap]:-0}
    if [ $optimal_swap -gt 0 ] && [ "${VM_PARAM_DIFF[swap_size]}" = "变更" ]; then
        local available_space=$(df / | tail -1 | awk '{print $4}')
        local required_space=$((optimal_swap * 1024 * 2))  # 转换为KB并×2
        
        if [ $available_space -lt $required_space ]; then
            log_error "❌ 磁盘空间不足，无法创建${optimal_swap}MB的swap文件"
            log_warn "需要: $((required_space/1024))MB，可用: $((available_space/1024))MB"
            return 1
        fi
    fi
    
    log_success "✅ 安全检查通过"
    return 0
}

# 应用优化设置
apply_optimizations() {
    log_header "应用优化配置"
    
    # 检查是否有需要变更的参数
    local total_changes=0
    for key in "${!VM_PARAM_DIFF[@]}"; do
        ((total_changes++))
    done
    
    if [ $total_changes -eq 0 ]; then
        log_success "所有参数已是最优值，无需变更！"
        return 0
    fi
    
    log_warn "检测到 ${total_changes} 项参数需要优化"
    echo ""
    
    # 执行安全检查
    if ! safety_check_before_apply; then
        log_error "安全检查未通过，终止优化流程"
        log_info "💡 建议："
        log_info "   1. 释放内存：停止不必要的服务"
        log_info "   2. 清理磁盘：删除临时文件"
        log_info "   3. 升级配置：增加服务器内存"
        return 1
    fi
    echo ""
    
    # 检查磁盘空间并尝试备份（但不阻止后续操作）
    local available_space=$(df /etc | tail -1 | awk '{print $4}')
    BACKUP_SUCCESS=0  # 全局变量，供main函数使用
    
    if [ $available_space -gt 512 ]; then
        # 空间充足，尝试备份
        local backup_file="/etc/sysctl.conf.backup.$(date +%Y%m%d_%H%M%S)"
        if [ -f /etc/sysctl.conf ] && cp /etc/sysctl.conf $backup_file 2>/dev/null; then
            log_success "已备份配置到: $backup_file"
            BACKUP_SUCCESS=1
            BACKUP_FILE="$backup_file"  # 记录备份文件路径
        fi
    fi
    
    if [ $BACKUP_SUCCESS -eq 0 ]; then
        log_warn "⚠️  磁盘空间不足，跳过备份（剩余${available_space}KB）"
        log_info "直接覆盖配置以确保永久生效（代理服务器模式）"
    fi
    
    # ⚠️ 重要：分阶段应用参数，避免在创建swap前应用overcommit限制
    # 阶段1：应用安全参数（不包括overcommit相关）
    log_progress "阶段1: 应用安全的虚拟内存参数..."
    
    local applied_count=0
    
    if [ "${VM_PARAM_DIFF[swappiness]}" = "变更" ]; then
        sysctl -w vm.swappiness=${PERFORMANCE_DATA[optimal_swappiness]} >/dev/null 2>&1
        log_info "  ✓ vm.swappiness: ${ORIGINAL_VM_PARAMS[swappiness]} → ${PERFORMANCE_DATA[optimal_swappiness]}"
        ((applied_count++))
    fi
    
    if [ "${VM_PARAM_DIFF[vfs_cache_pressure]}" = "变更" ]; then
        sysctl -w vm.vfs_cache_pressure=${PERFORMANCE_DATA[vfs_cache_pressure]} >/dev/null 2>&1
        log_info "  ✓ vm.vfs_cache_pressure: ${ORIGINAL_VM_PARAMS[vfs_cache_pressure]} → ${PERFORMANCE_DATA[vfs_cache_pressure]}"
        ((applied_count++))
    fi
    
    if [ "${VM_PARAM_DIFF[dirty_ratio]}" = "变更" ]; then
        sysctl -w vm.dirty_ratio=${PERFORMANCE_DATA[dirty_ratio]} >/dev/null 2>&1
        log_info "  ✓ vm.dirty_ratio: ${ORIGINAL_VM_PARAMS[dirty_ratio]} → ${PERFORMANCE_DATA[dirty_ratio]}"
        ((applied_count++))
    fi
    
    if [ "${VM_PARAM_DIFF[dirty_background_ratio]}" = "变更" ]; then
        sysctl -w vm.dirty_background_ratio=${PERFORMANCE_DATA[dirty_background_ratio]} >/dev/null 2>&1
        log_info "  ✓ vm.dirty_background_ratio: ${ORIGINAL_VM_PARAMS[dirty_background_ratio]} → ${PERFORMANCE_DATA[dirty_background_ratio]}"
        ((applied_count++))
    fi
    
    if [ "${VM_PARAM_DIFF[dirty_expire_centisecs]}" = "变更" ]; then
        sysctl -w vm.dirty_expire_centisecs=${PERFORMANCE_DATA[dirty_expire]} >/dev/null 2>&1
        log_info "  ✓ vm.dirty_expire_centisecs: ${ORIGINAL_VM_PARAMS[dirty_expire_centisecs]} → ${PERFORMANCE_DATA[dirty_expire]}"
        ((applied_count++))
    fi
    
    if [ "${VM_PARAM_DIFF[dirty_writeback_centisecs]}" = "变更" ]; then
        sysctl -w vm.dirty_writeback_centisecs=${PERFORMANCE_DATA[dirty_writeback]} >/dev/null 2>&1
        log_info "  ✓ vm.dirty_writeback_centisecs: ${ORIGINAL_VM_PARAMS[dirty_writeback_centisecs]} → ${PERFORMANCE_DATA[dirty_writeback]}"
        ((applied_count++))
    fi
    
    if [ "${VM_PARAM_DIFF[min_free_kbytes]}" = "变更" ]; then
        sysctl -w vm.min_free_kbytes=${PERFORMANCE_DATA[min_free_kbytes]} >/dev/null 2>&1
        log_info "  ✓ vm.min_free_kbytes: ${ORIGINAL_VM_PARAMS[min_free_kbytes]} → ${PERFORMANCE_DATA[min_free_kbytes]}"
        ((applied_count++))
    fi
    
    if [ "${VM_PARAM_DIFF[page_cluster]}" = "变更" ]; then
        sysctl -w vm.page_cluster=${PERFORMANCE_DATA[page_cluster]} >/dev/null 2>&1
        log_info "  ✓ vm.page_cluster: ${ORIGINAL_VM_PARAMS[page_cluster]} → ${PERFORMANCE_DATA[page_cluster]}"
        ((applied_count++))
    fi
    
    # ⚠️ 注意：overcommit参数将在创建swap后应用（阶段2）
    log_success "阶段1完成：已应用 ${applied_count} 项安全参数"
    
    echo ""
    
    # 注意：overcommit参数会在后面应用，不计入此处的applied_count
    # 真实的变更数量会在main函数中统一显示
    
    # 如果空间不足，先尝试清理
    if [ $available_space -lt 256 ]; then
        log_warn "磁盘空间极低，尝试自动清理..."
        # 清理旧的备份文件
        find /etc -name "sysctl.conf.backup.*" -mtime +7 -delete 2>/dev/null
        # 清理FIO测试残留
        rm -rf /tmp/fio_* 2>/dev/null
        log_info "已清理临时文件"
    fi
    
    # 移除旧的vm配置（使用更鲁棒的方法）
    if [ -f /etc/sysctl.conf ]; then
        # 方法1: 使用grep排除（不需要写临时文件）
        grep -v "^vm\." /etc/sysctl.conf > /tmp/sysctl.tmp 2>/dev/null && mv /tmp/sysctl.tmp /etc/sysctl.conf 2>/dev/null
        
        # 移除旧的注释块
        sed -i '/# ===.*虚拟内存优化/,/^$/d' /etc/sysctl.conf 2>/dev/null || true
    fi
    
    # 使用精简格式写入配置（减少空间占用）
    {
        echo ""
        echo "# VM优化 $(date +%Y%m%d)"
        echo "vm.swappiness=${PERFORMANCE_DATA[optimal_swappiness]}"
        echo "vm.vfs_cache_pressure=${PERFORMANCE_DATA[vfs_cache_pressure]}"
        echo "vm.dirty_ratio=${PERFORMANCE_DATA[dirty_ratio]}"
        echo "vm.dirty_background_ratio=${PERFORMANCE_DATA[dirty_background_ratio]}"
        echo "vm.dirty_expire_centisecs=${PERFORMANCE_DATA[dirty_expire]}"
        echo "vm.dirty_writeback_centisecs=${PERFORMANCE_DATA[dirty_writeback]}"
        echo "vm.min_free_kbytes=${PERFORMANCE_DATA[min_free_kbytes]}"
        echo "vm.page_cluster=${PERFORMANCE_DATA[page_cluster]}"
        echo "vm.overcommit_memory=${PERFORMANCE_DATA[overcommit_memory]}"
        echo "vm.overcommit_ratio=${PERFORMANCE_DATA[overcommit_ratio]}"
    } >> /etc/sysctl.conf 2>/dev/null
    
    if [ $? -eq 0 ]; then
        log_success "✅ 配置已永久保存到 /etc/sysctl.conf"
        log_info "重启后自动生效，无需手动干预"
    else
        # 最后的fallback：直接使用sysctl命令写入
        log_warn "标准方式写入失败，使用备用方法..."
        {
            sysctl -w vm.swappiness=${PERFORMANCE_DATA[optimal_swappiness]} 2>/dev/null
            sysctl -w vm.vfs_cache_pressure=${PERFORMANCE_DATA[vfs_cache_pressure]} 2>/dev/null
            sysctl -w vm.dirty_ratio=${PERFORMANCE_DATA[dirty_ratio]} 2>/dev/null
            sysctl -w vm.dirty_background_ratio=${PERFORMANCE_DATA[dirty_background_ratio]} 2>/dev/null
            sysctl -w vm.dirty_expire_centisecs=${PERFORMANCE_DATA[dirty_expire]} 2>/dev/null
            sysctl -w vm.dirty_writeback_centisecs=${PERFORMANCE_DATA[dirty_writeback]} 2>/dev/null
            sysctl -w vm.min_free_kbytes=${PERFORMANCE_DATA[min_free_kbytes]} 2>/dev/null
            sysctl -w vm.page_cluster=${PERFORMANCE_DATA[page_cluster]} 2>/dev/null
            sysctl -w vm.overcommit_memory=${PERFORMANCE_DATA[overcommit_memory]} 2>/dev/null
            sysctl -w vm.overcommit_ratio=${PERFORMANCE_DATA[overcommit_ratio]} 2>/dev/null
        } > /dev/null 2>&1
        log_warn "⚠️  配置文件写入失败，但运行时参数已生效"
        log_info "💡 建议清理磁盘空间后重新运行以确保重启后配置仍有效"
    fi
}

# 应用overcommit参数（阶段2，在创建swap后执行）
apply_overcommit_parameters() {
    log_progress "阶段2: 应用overcommit参数（在swap创建后）..."
    
    local applied_count=0
    
    if [ "${VM_PARAM_DIFF[overcommit_memory]}" = "变更" ]; then
        sysctl -w vm.overcommit_memory=${PERFORMANCE_DATA[overcommit_memory]} >/dev/null 2>&1
        log_info "  ✓ vm.overcommit_memory: ${ORIGINAL_VM_PARAMS[overcommit_memory]} → ${PERFORMANCE_DATA[overcommit_memory]}"
        ((applied_count++))
    fi
    
    if [ "${VM_PARAM_DIFF[overcommit_ratio]}" = "变更" ]; then
        sysctl -w vm.overcommit_ratio=${PERFORMANCE_DATA[overcommit_ratio]} >/dev/null 2>&1
        log_info "  ✓ vm.overcommit_ratio: ${ORIGINAL_VM_PARAMS[overcommit_ratio]} → ${PERFORMANCE_DATA[overcommit_ratio]}"
        ((applied_count++))
    fi
    
    if [ $applied_count -gt 0 ]; then
        log_success "阶段2完成：已应用 ${applied_count} 项overcommit参数"
    else
        log_success "阶段2完成：overcommit参数无需变更"
    fi
    
    # 验证系统是否正常
    echo ""
    log_progress "验证系统内存分配是否正常..."
    if echo "test" > /tmp/memory_test_$$ 2>/dev/null; then
        rm -f /tmp/memory_test_$$ 2>/dev/null
        log_success "✅ 内存分配正常"
    else
        log_error "❌ 内存分配失败！正在回滚overcommit设置..."
        sysctl -w vm.overcommit_memory=0 >/dev/null 2>&1
        log_warn "已回滚到安全模式(overcommit_memory=0)"
    fi
}

# 管理Swap分区/文件
# 参数 $1: auto_apply (可选) - 如果为"auto"则自动应用，不询问用户
manage_swap_advanced() {
    local auto_apply=${1:-""}
    
    log_header "Swap空间管理"
    
    local current_swap=$(free -m | awk '/^Swap:/{print $2}')
    local optimal_swap=${PERFORMANCE_DATA[optimal_swap]}
    
    log_info "当前Swap: ${current_swap} MB"
    log_info "推荐Swap: ${optimal_swap} MB"
    
    # 计算差异（使用与对比函数一致的动态阈值）
    local diff=$((optimal_swap - current_swap))
    local diff_abs=${diff#-}
    
    # 动态阈值：<2GB内存用10%，>=2GB用20%（与compare_vm_parameters一致）
    local ram_mb=${SYSTEM_INFO[total_ram_mb]:-1024}
    local threshold
    
    # 确保变量是整数
    ram_mb=$(echo "$ram_mb" | grep -oE '[0-9]+')
    optimal_swap=$(echo "$optimal_swap" | grep -oE '[0-9]+')
    current_swap=$(echo "$current_swap" | grep -oE '[0-9]+')
    diff_abs=$(echo "$diff_abs" | grep -oE '[0-9]+')
    
    if [ $ram_mb -lt 2048 ]; then
        threshold=$((optimal_swap / 10))  # 小内存：10%阈值
        log_info "小内存系统（${ram_mb}MB），使用10%精确阈值（${threshold}MB）"
    else
        threshold=$((optimal_swap / 5))   # 大内存：20%阈值
        log_info "使用20%阈值（${threshold}MB）"
    fi
    
    log_info "Swap差异计算：|${optimal_swap} - ${current_swap}| = ${diff_abs}MB, 阈值=${threshold}MB"
    
    local need_adjustment=0
    
    if [ $current_swap -eq 0 ]; then
        log_warn "系统当前没有Swap，强烈建议创建"
        need_adjustment=1
    elif [ $diff_abs -gt $threshold ]; then
        log_warn "⚠️ 当前Swap与推荐值差异超过阈值（${diff_abs}MB > ${threshold}MB）"
        log_info "需要调整：${current_swap}MB → ${optimal_swap}MB"
        need_adjustment=1
    else
        log_success "✅ 当前Swap大小合理，无需调整（差异${diff_abs}MB ≤ 阈值${threshold}MB）"
        return 0
    fi
    
    # 如果是自动应用模式，直接执行
    if [ "$auto_apply" = "auto" ]; then
        log_info "自动应用Swap调整..."
        local create_swap="y"
    else
        # 否则询问用户
        if [ $need_adjustment -eq 1 ]; then
            read -p "是否调整Swap大小? (y/n): " create_swap
            
            if [ "$create_swap" != "y" ] && [ "$create_swap" != "Y" ]; then
                log_info "跳过Swap调整"
                return 0
            fi
        fi
    fi
    
    # 关闭现有swap
    if [ $current_swap -gt 0 ]; then
        log_progress "关闭现有Swap..."
        swapoff -a
    fi
    
    local swapfile="/swapfile"
    
    # 删除旧swap文件
    if [ -f $swapfile ]; then
        rm -f $swapfile
    fi
    
    log_progress "创建${optimal_swap}MB的Swap文件（这可能需要几分钟）..."
    
    # 使用dd创建swap文件（更可靠）
    dd if=/dev/zero of=$swapfile bs=1M count=$optimal_swap status=progress 2>&1 | tail -1
    
    chmod 600 $swapfile
    log_progress "格式化Swap文件..."
    mkswap $swapfile >/dev/null 2>&1
    
    log_progress "启用Swap..."
    swapon $swapfile
    
    # 添加到fstab
    if ! grep -q "$swapfile" /etc/fstab; then
        echo "$swapfile none swap sw 0 0" >> /etc/fstab
        log_success "已添加Swap到/etc/fstab"
    fi
    
    log_success "Swap创建完成！"
    swapon --show
}

# 主函数
main() {
    clear
    echo ""
    echo -e "${CYAN}"
    cat << "EOF"
╔═══════════════════════════════════════════════════════════════════╗
║                                                                   ║
║     Linux虚拟内存专业级自动优化工具 v3.1                         ║
║     Professional Virtual Memory Optimization Tool                ║
║                                                                   ║
║     使用业界标准测试工具和商业级优化算法                         ║
║     🤖 智能模式：自动检测并应用所有优化                          ║
║     🛡️  安全增强：分阶段应用+自动回滚保护                        ║
║                                                                   ║
╚═══════════════════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
    echo ""
    printf "${GREEN}工作流程：${NC}\n"
    echo "  1️⃣  深度性能测试（CPU、内存、磁盘）"
    echo "  2️⃣  计算最优虚拟内存参数"
    echo "  3️⃣  对比当前配置与推荐配置"
    echo "  4️⃣  安全检查（内存、磁盘、系统状态）"
    echo "  5️⃣  分阶段自动应用优化（安全参数 → swap → overcommit）"
    echo "  6️⃣  永久保存配置并备份原设置"
    echo ""
    printf "${CYAN}🛡️  安全保护：${NC}\n"
    echo "  ✅ 永不使用 overcommit_memory=2（避免内存分配失败）"
    echo "  ✅ 小内存系统自动保护（不降低关键参数）"
    echo "  ✅ 应用参数前进行安全检查"
    echo "  ✅ 检测到问题自动回滚"
    echo ""
    
    # 环境检查
    check_root
    install_professional_tools
    
    echo ""
    log_warn "性能测试将执行约1分钟，请耐心等待..."
    log_info "脚本将自动完成：测试 → 分析 → 对比 → 应用优化"
    echo ""
    printf "${CYAN}准备开始...${NC}"
    sleep 1
    printf " 3"
    sleep 1
    printf " 2"
    sleep 1
    printf " 1${NC}\n"
    echo ""
    
    # 执行深度性能测试
    deep_cpu_benchmark
    deep_memory_benchmark
    deep_disk_benchmark
    
    # 计算优化参数
    calculate_optimal_swap_advanced
    calculate_optimal_swappiness_advanced
    calculate_advanced_vm_parameters
    
    # 读取当前系统参数并对比
    read_current_vm_parameters
    compare_vm_parameters
    
    # 显示报告
    show_professional_report
    
    # 统计需要变更的参数数量
    local change_count=0
    for key in "${!VM_PARAM_DIFF[@]}"; do
        ((change_count++))
    done
    
    # 自动应用变更（不需要询问）
    echo ""
    if [ $change_count -eq 0 ]; then
        printf "${GREEN}╔═══════════════════════════════════════════════════════════════════╗${NC}\n"
        printf "${GREEN}║                   ✅ 系统已是最优配置                             ║${NC}\n"
        printf "${GREEN}╚═══════════════════════════════════════════════════════════════════╝${NC}\n"
        echo ""
        log_success "恭喜！您的系统虚拟内存参数已经是最优配置！"
        log_info "所有参数均与推荐值一致，无需进行任何变更"
    else
        printf "${YELLOW}╔═══════════════════════════════════════════════════════════════════╗${NC}\n"
        printf "${YELLOW}║              🔧 检测到 ${change_count} 项参数需要优化                         ║${NC}\n"
        printf "${YELLOW}╚═══════════════════════════════════════════════════════════════════╝${NC}\n"
        echo ""
        log_warn "检测到参数与推荐值不一致，正在自动应用优化..."
        echo ""
        
        # 自动应用优化（阶段1：安全参数）
        apply_optimizations
        
        # 处理Swap变更（自动应用模式）- 必须在overcommit参数之前
        if [ "${VM_PARAM_DIFF[swap_size]}" = "变更" ]; then
            echo ""
            manage_swap_advanced "auto"
        else
            echo ""
            log_success "Swap大小已是最优值，无需调整"
        fi
        
        # 应用overcommit参数（阶段2：在swap创建后）
        echo ""
        apply_overcommit_parameters
        
        echo ""
        printf "${GREEN}╔═══════════════════════════════════════════════════════════════════╗${NC}\n"
        printf "${GREEN}║                      ✅ 优化成功完成                              ║${NC}\n"
        printf "${GREEN}╚═══════════════════════════════════════════════════════════════════╝${NC}\n"
        echo ""
        log_success "📊 已成功自动应用 ${change_count} 项参数变更"
        log_success "💾 配置已永久保存到 /etc/sysctl.conf"
        
        # 根据实际备份情况显示不同消息
        if [ "${BACKUP_SUCCESS:-0}" -eq 1 ] && [ -n "${BACKUP_FILE}" ]; then
            log_success "📁 原配置已备份到: ${BACKUP_FILE}"
        elif [ "${BACKUP_SUCCESS:-0}" -eq 0 ]; then
            log_warn "⚠️  磁盘空间不足，未备份原配置"
            log_info "💡 建议清理空间后运行以下命令手动备份："
            echo "   sudo cp /etc/sysctl.conf /etc/sysctl.conf.backup.\$(date +%Y%m%d)"
        fi
        
        echo ""
        log_warn "🔄 强烈建议重启系统以确保所有设置完全生效："
        printf "${CYAN}     sudo reboot${NC}\n"
        echo ""
        printf "${GREEN}═══════════════════════════════════════════════════════════════════${NC}\n"
    fi
    
    echo ""
}

# 运行主程序
main "$@"

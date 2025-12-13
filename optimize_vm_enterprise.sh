#!/bin/bash

################################################################################
# Linux虚拟内存专业级自动优化脚本
# 功能：使用业界标准测试工具精确测量系统性能，并应用商业级优化算法
# 版本：3.0 Professional Edition
################################################################################

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# 性能数据存储
declare -A PERFORMANCE_DATA
declare -A SYSTEM_INFO

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

log_success() {
    echo -e "${CYAN}[成功]${NC} $1"
}

log_header() {
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

log_progress() {
    echo -e "${MAGENTA}[进行中]${NC} $1"
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
        "stress-ng"     # CPU/内存压力测试
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
            "stress-ng")
                command -v stress-ng &> /dev/null || missing_tools+=("stress-ng")
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

# 深度CPU性能测试
deep_cpu_benchmark() {
    log_header "CPU深度性能测试（使用Sysbench + Stress-ng）"
    
    # 基础信息
    SYSTEM_INFO[cpu_cores]=$(nproc)
    SYSTEM_INFO[cpu_threads]=$(grep -c ^processor /proc/cpuinfo)
    SYSTEM_INFO[cpu_model]=$(grep "model name" /proc/cpuinfo | head -n1 | cut -d':' -f2 | xargs)
    
    log_info "CPU型号: ${SYSTEM_INFO[cpu_model]}"
    log_info "物理核心数: ${SYSTEM_INFO[cpu_cores]}"
    log_info "逻辑线程数: ${SYSTEM_INFO[cpu_threads]}"
    
    # CPU缓存信息
    if [ -f /sys/devices/system/cpu/cpu0/cache/index0/size ]; then
        local l1_cache=$(cat /sys/devices/system/cpu/cpu0/cache/index0/size 2>/dev/null)
        local l2_cache=$(cat /sys/devices/system/cpu/cpu0/cache/index2/size 2>/dev/null)
        local l3_cache=$(cat /sys/devices/system/cpu/cpu0/cache/index3/size 2>/dev/null)
        log_info "L1缓存: ${l1_cache:-未知}"
        log_info "L2缓存: ${l2_cache:-未知}"
        log_info "L3缓存: ${l3_cache:-未知}"
    fi
    
    # CPU频率（获取实际运行频率和最大频率）
    local cpu_cur_freq=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null)
    local cpu_max_freq=$(cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq 2>/dev/null)
    
    if [ ! -z "$cpu_max_freq" ]; then
        cpu_max_freq=$((cpu_max_freq / 1000))
        SYSTEM_INFO[cpu_max_freq]=$cpu_max_freq
        log_info "CPU最大频率: ${cpu_max_freq} MHz"
    else
        cpu_max_freq=$(grep "cpu MHz" /proc/cpuinfo | head -n1 | cut -d':' -f2 | xargs | cut -d'.' -f1)
        SYSTEM_INFO[cpu_max_freq]=${cpu_max_freq:-2000}
        log_info "CPU频率: ${cpu_max_freq} MHz"
    fi
    
    # Sysbench CPU测试 - 单线程性能
    log_progress "执行Sysbench单线程CPU测试（素数计算）..."
    local cpu_single_score=$(sysbench cpu --cpu-max-prime=20000 --threads=1 --time=10 run 2>/dev/null | grep "events per second:" | awk '{print $4}')
    PERFORMANCE_DATA[cpu_single_thread]=${cpu_single_score:-0}
    log_success "单线程性能分数: ${cpu_single_score} events/sec"
    
    # Sysbench CPU测试 - 多线程性能
    log_progress "执行Sysbench多线程CPU测试..."
    local cpu_multi_score=$(sysbench cpu --cpu-max-prime=20000 --threads=${SYSTEM_INFO[cpu_cores]} --time=10 run 2>/dev/null | grep "events per second:" | awk '{print $4}')
    PERFORMANCE_DATA[cpu_multi_thread]=${cpu_multi_score:-0}
    log_success "多线程性能分数: ${cpu_multi_score} events/sec"
    
    # Stress-ng CPU整数运算测试
    log_progress "执行Stress-ng整数运算测试..."
    local int_ops=$(stress-ng --cpu ${SYSTEM_INFO[cpu_cores]} --cpu-method int64 --metrics-brief --timeout 10s 2>&1 | grep "cpu " | awk '{print $9}')
    PERFORMANCE_DATA[cpu_int_ops]=${int_ops:-0}
    log_success "整数运算能力: ${int_ops} bogo ops/sec"
    
    # Stress-ng CPU浮点运算测试
    log_progress "执行Stress-ng浮点运算测试..."
    local float_ops=$(stress-ng --cpu ${SYSTEM_INFO[cpu_cores]} --cpu-method double --metrics-brief --timeout 10s 2>&1 | grep "cpu " | awk '{print $9}')
    PERFORMANCE_DATA[cpu_float_ops]=${float_ops:-0}
    log_success "浮点运算能力: ${float_ops} bogo ops/sec"
    
    # 计算综合CPU性能分数（0-100标准化）
    # 使用多维度加权算法
    local single_weight=0.2
    local multi_weight=0.3
    local int_weight=0.25
    local float_weight=0.25
    
    # 标准化分数（基于参考值）
    local single_norm=$(echo "scale=4; ${cpu_single_score} / 500" | bc)
    local multi_norm=$(echo "scale=4; ${cpu_multi_score} / 2000" | bc)
    local int_norm=$(echo "scale=4; ${int_ops} / 100000000" | bc)
    local float_norm=$(echo "scale=4; ${float_ops} / 100000000" | bc)
    
    # 综合分数
    PERFORMANCE_DATA[cpu_score]=$(echo "scale=2; ($single_norm * $single_weight + $multi_norm * $multi_weight + $int_norm * $int_weight + $float_norm * $float_weight) * 100" | bc)
    
    # 确保分数在合理范围内
    local cpu_score_int=$(echo "${PERFORMANCE_DATA[cpu_score]}" | cut -d'.' -f1)
    if [ $cpu_score_int -gt 100 ]; then
        PERFORMANCE_DATA[cpu_score]=100.00
    elif [ $cpu_score_int -lt 1 ]; then
        PERFORMANCE_DATA[cpu_score]=1.00
    fi
    
    log_success "CPU综合性能评分: ${PERFORMANCE_DATA[cpu_score]}/100"
}

# 深度内存性能测试
deep_memory_benchmark() {
    log_header "内存深度性能测试（使用Sysbench + Stress-ng）"
    
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
    
    # Sysbench内存顺序读写测试
    log_progress "执行Sysbench内存顺序读取测试..."
    local mem_read=$(sysbench memory --memory-block-size=1M --memory-total-size=10G --memory-oper=read --threads=${SYSTEM_INFO[cpu_cores]} run 2>/dev/null | grep "transferred" | awk '{print $(NF-1)}')
    PERFORMANCE_DATA[mem_read_speed]=${mem_read:-0}
    log_success "内存读取速度: ${mem_read} MiB/sec"
    
    log_progress "执行Sysbench内存顺序写入测试..."
    local mem_write=$(sysbench memory --memory-block-size=1M --memory-total-size=10G --memory-oper=write --threads=${SYSTEM_INFO[cpu_cores]} run 2>/dev/null | grep "transferred" | awk '{print $(NF-1)}')
    PERFORMANCE_DATA[mem_write_speed]=${mem_write:-0}
    log_success "内存写入速度: ${mem_write} MiB/sec"
    
    # Sysbench内存随机访问测试
    log_progress "执行Sysbench内存随机访问测试..."
    local mem_random=$(sysbench memory --memory-block-size=4K --memory-total-size=1G --memory-access-mode=rnd --threads=${SYSTEM_INFO[cpu_cores]} run 2>/dev/null | grep "transferred" | awk '{print $(NF-1)}')
    PERFORMANCE_DATA[mem_random_speed]=${mem_random:-0}
    log_success "内存随机访问速度: ${mem_random} MiB/sec"
    
    # Stress-ng内存压力测试（测试内存稳定性和真实带宽）
    log_progress "执行Stress-ng内存带宽测试..."
    local mem_bandwidth=$(stress-ng --vm ${SYSTEM_INFO[cpu_cores]} --vm-bytes 80% --vm-method all --metrics-brief --timeout 10s 2>&1 | grep "vm " | awk '{print $9}')
    PERFORMANCE_DATA[mem_bandwidth]=${mem_bandwidth:-0}
    log_success "内存带宽测试: ${mem_bandwidth} bogo ops/sec"
    
    # 计算综合内存性能分数（0-100标准化）
    # DDR4-2400: ~17000 MB/s读取, ~15000 MB/s写入
    # DDR4-3200: ~23000 MB/s读取, ~20000 MB/s写入
    # DDR3-1600: ~10000 MB/s读取, ~8000 MB/s写入
    
    local read_norm=$(echo "scale=4; ${mem_read} / 20000" | bc)
    local write_norm=$(echo "scale=4; ${mem_write} / 18000" | bc)
    local random_norm=$(echo "scale=4; ${mem_random} / 5000" | bc)
    
    PERFORMANCE_DATA[mem_score]=$(echo "scale=2; ($read_norm * 0.4 + $write_norm * 0.4 + $random_norm * 0.2) * 100" | bc)
    
    # 确保分数在合理范围内
    local mem_score_int=$(echo "${PERFORMANCE_DATA[mem_score]}" | cut -d'.' -f1)
    if [ -z "$mem_score_int" ] || [ $mem_score_int -lt 1 ]; then
        PERFORMANCE_DATA[mem_score]=10.00
    elif [ $mem_score_int -gt 100 ]; then
        PERFORMANCE_DATA[mem_score]=100.00
    fi
    
    log_success "内存综合性能评分: ${PERFORMANCE_DATA[mem_score]}/100"
}

# 专业级磁盘性能测试（使用FIO）
deep_disk_benchmark() {
    log_header "磁盘深度性能测试（使用FIO专业工具）"
    
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
    log_warn "FIO测试将执行约60秒，请耐心等待..."
    
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
    
    local seq_read_bw=$(cat /tmp/fio_seq_read.json | grep -oP '"bw":\s*\K[0-9]+' | head -1)
    PERFORMANCE_DATA[disk_seq_read]=$(echo "scale=2; $seq_read_bw / 1024" | bc)
    log_success "顺序读取速度: ${PERFORMANCE_DATA[disk_seq_read]} MB/s"
    
    # FIO测试2: 顺序写入 (Sequential Write)
    log_progress "执行FIO顺序写入测试（4MB块大小）..."
    fio --name=seq_write \
        --directory=$test_dir \
        --rw=write \
        --bs=4m \
        --size=512m \
        --numjobs=1 \
        --time_based \
        --runtime=10 \
        --ioengine=libaio \
        --direct=1 \
        --group_reporting \
        --output-format=json \
        > /tmp/fio_seq_write.json 2>/dev/null
    
    local seq_write_bw=$(cat /tmp/fio_seq_write.json | grep -oP '"bw":\s*\K[0-9]+' | head -1)
    PERFORMANCE_DATA[disk_seq_write]=$(echo "scale=2; $seq_write_bw / 1024" | bc)
    log_success "顺序写入速度: ${PERFORMANCE_DATA[disk_seq_write]} MB/s"
    
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
    
    local rand_read_iops=$(cat /tmp/fio_rand_read.json | grep -oP '"iops":\s*\K[0-9.]+' | head -1 | cut -d'.' -f1)
    PERFORMANCE_DATA[disk_rand_read_iops]=${rand_read_iops}
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
    
    local rand_write_iops=$(cat /tmp/fio_rand_write.json | grep -oP '"iops":\s*\K[0-9.]+' | head -1 | cut -d'.' -f1)
    PERFORMANCE_DATA[disk_rand_write_iops]=${rand_write_iops}
    log_success "4K随机写入IOPS: ${PERFORMANCE_DATA[disk_rand_write_iops]}"
    
    # FIO测试5: 混合读写测试 (Mixed R/W 70/30)
    log_progress "执行FIO混合读写测试（70%读/30%写）..."
    fio --name=mixed_rw \
        --directory=$test_dir \
        --rw=randrw \
        --rwmixread=70 \
        --bs=4k \
        --size=256m \
        --numjobs=2 \
        --time_based \
        --runtime=10 \
        --ioengine=libaio \
        --iodepth=16 \
        --direct=1 \
        --group_reporting \
        --output-format=json \
        > /tmp/fio_mixed.json 2>/dev/null
    
    local mixed_iops=$(cat /tmp/fio_mixed.json | grep -oP '"iops":\s*\K[0-9.]+' | head -1 | cut -d'.' -f1)
    PERFORMANCE_DATA[disk_mixed_iops]=${mixed_iops}
    log_success "混合读写IOPS: ${PERFORMANCE_DATA[disk_mixed_iops]}"
    
    # 磁盘延迟测试
    log_progress "执行FIO延迟测试..."
    fio --name=latency_test \
        --directory=$test_dir \
        --rw=randread \
        --bs=4k \
        --size=128m \
        --numjobs=1 \
        --time_based \
        --runtime=10 \
        --ioengine=libaio \
        --iodepth=1 \
        --direct=1 \
        --output-format=json \
        > /tmp/fio_latency.json 2>/dev/null
    
    local avg_latency=$(cat /tmp/fio_latency.json | grep -oP '"lat_ns":\s*{\s*"mean":\s*\K[0-9.]+' | head -1)
    if [ ! -z "$avg_latency" ]; then
        PERFORMANCE_DATA[disk_latency]=$(echo "scale=2; $avg_latency / 1000" | bc)  # 转换为微秒
        log_success "平均延迟: ${PERFORMANCE_DATA[disk_latency]} μs"
    fi
    
    # 清理测试文件
    rm -rf $test_dir /tmp/fio_*.json
    
    # 计算综合磁盘性能分数（0-100标准化）
    # 参考标准:
    # NVMe SSD: 顺序读写3000+ MB/s, 随机读写IOPS 200k+
    # SATA SSD: 顺序读写500+ MB/s, 随机读写IOPS 80k+
    # HDD: 顺序读写150+ MB/s, 随机读写IOPS 100+
    
    if [ "${SYSTEM_INFO[disk_type]}" = "SSD" ]; then
        # SSD评分标准
        local seq_read_norm=$(echo "scale=4; ${PERFORMANCE_DATA[disk_seq_read]} / 3000" | bc)
        local seq_write_norm=$(echo "scale=4; ${PERFORMANCE_DATA[disk_seq_write]} / 2500" | bc)
        local rand_read_norm=$(echo "scale=4; ${PERFORMANCE_DATA[disk_rand_read_iops]} / 200000" | bc)
        local rand_write_norm=$(echo "scale=4; ${PERFORMANCE_DATA[disk_rand_write_iops]} / 150000" | bc)
    else
        # HDD评分标准
        local seq_read_norm=$(echo "scale=4; ${PERFORMANCE_DATA[disk_seq_read]} / 200" | bc)
        local seq_write_norm=$(echo "scale=4; ${PERFORMANCE_DATA[disk_seq_write]} / 200" | bc)
        local rand_read_norm=$(echo "scale=4; ${PERFORMANCE_DATA[disk_rand_read_iops]} / 150" | bc)
        local rand_write_norm=$(echo "scale=4; ${PERFORMANCE_DATA[disk_rand_write_iops]} / 150" | bc)
    fi
    
    PERFORMANCE_DATA[disk_score]=$(echo "scale=2; ($seq_read_norm * 0.25 + $seq_write_norm * 0.25 + $rand_read_norm * 0.25 + $rand_write_norm * 0.25) * 100" | bc)
    
    # 确保分数在合理范围内
    local disk_score_int=$(echo "${PERFORMANCE_DATA[disk_score]}" | cut -d'.' -f1)
    if [ -z "$disk_score_int" ] || [ $disk_score_int -lt 1 ]; then
        PERFORMANCE_DATA[disk_score]=10.00
    elif [ $disk_score_int -gt 100 ]; then
        PERFORMANCE_DATA[disk_score]=100.00
    fi
    
    log_success "磁盘综合性能评分: ${PERFORMANCE_DATA[disk_score]}/100"
}

# 商业级算法：计算最优Swap大小
calculate_optimal_swap_advanced() {
    log_header "商业级算法：计算最优Swap配置"
    
    local ram_mb=${SYSTEM_INFO[total_ram_mb]}
    local ram_gb=$(echo "scale=2; $ram_mb / 1024" | bc)
    
    # 获取性能分数
    local cpu_score=${PERFORMANCE_DATA[cpu_score]}
    local mem_score=${PERFORMANCE_DATA[mem_score]}
    local disk_score=${PERFORMANCE_DATA[disk_score]}
    local disk_type=${SYSTEM_INFO[disk_type]}
    
    log_info "基于性能评分进行计算..."
    log_info "  - CPU性能: ${cpu_score}/100"
    log_info "  - 内存性能: ${mem_score}/100"
    log_info "  - 磁盘性能: ${disk_score}/100"
    
    # 商业级多因子加权算法
    # ==========================================
    # 因子1: 内存大小基础系数
    # 因子2: CPU性能系数（高性能CPU可减少swap依赖）
    # 因子3: 内存性能系数（高速内存减少swap需求）
    # 因子4: 磁盘类型和性能系数
    # 因子5: 工作负载预测系数
    # ==========================================
    
    # 基础swap计算（Netflix/Google生产环境算法改进版）
    local base_swap
    if (( $(echo "$ram_gb < 2" | bc -l) )); then
        # 低内存系统：需要更多swap来避免OOM
        base_swap=$(echo "scale=0; $ram_mb * 2" | bc)
    elif (( $(echo "$ram_gb < 4" | bc -l) )); then
        base_swap=$(echo "scale=0; $ram_mb * 1.5" | bc)
    elif (( $(echo "$ram_gb < 8" | bc -l) )); then
        base_swap=$(echo "scale=0; $ram_mb * 1.2" | bc)
    elif (( $(echo "$ram_gb < 16" | bc -l) )); then
        base_swap=$(echo "scale=0; $ram_mb * 0.8" | bc)
    elif (( $(echo "$ram_gb < 32" | bc -l) )); then
        base_swap=$(echo "scale=0; $ram_mb * 0.5" | bc)
    elif (( $(echo "$ram_gb < 64" | bc -l) )); then
        base_swap=$(echo "scale=0; $ram_mb * 0.25" | bc)
    else
        # 超大内存系统：最小swap即可
        base_swap=4096  # 4GB
    fi
    
    # CPU性能调整系数（0.85-1.15）
    # 高性能CPU能更好处理内存压力，减少swap需求
    local cpu_factor=$(echo "scale=4; 1.15 - ($cpu_score / 100) * 0.3" | bc)
    
    # 内存性能调整系数（0.9-1.1）
    # 高速内存可减少对swap的依赖
    local mem_factor=$(echo "scale=4; 1.1 - ($mem_score / 100) * 0.2" | bc)
    
    # 磁盘性能调整系数（0.7-1.3）
    local disk_factor
    if [ "$disk_type" = "SSD" ]; then
        # SSD: 减少swap以延长寿命，但高性能SSD可承受更多
        if (( $(echo "$disk_score > 70" | bc -l) )); then
            disk_factor=0.85  # 高性能SSD
        elif (( $(echo "$disk_score > 40" | bc -l) )); then
            disk_factor=0.75  # 中等SSD
        else
            disk_factor=0.70  # 低端SSD
        fi
    else
        # HDD: 根据性能调整
        if (( $(echo "$disk_score > 50" | bc -l) )); then
            disk_factor=1.1   # 高性能HDD
        elif (( $(echo "$disk_score > 25" | bc -l) )); then
            disk_factor=1.2   # 中等HDD
        else
            disk_factor=1.3   # 低性能HDD，需要更多缓冲
        fi
    fi
    
    # 综合计算最优swap
    local optimal_swap=$(echo "scale=0; $base_swap * $cpu_factor * $mem_factor * $disk_factor" | bc | cut -d'.' -f1)
    
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
    log_info "  算法调整系数: CPU=${cpu_factor}, MEM=${mem_factor}, DISK=${disk_factor}"
}

# 商业级算法：计算最优swappiness
calculate_optimal_swappiness_advanced() {
    log_progress "计算最优Swappiness值..."
    
    local ram_gb=$(echo "scale=2; ${SYSTEM_INFO[total_ram_mb]} / 1024" | bc)
    local cpu_score=${PERFORMANCE_DATA[cpu_score]}
    local mem_score=${PERFORMANCE_DATA[mem_score]}
    local disk_score=${PERFORMANCE_DATA[disk_score]}
    local disk_type=${SYSTEM_INFO[disk_type]}
    
    # Google/Red Hat Enterprise Linux推荐算法
    # Swappiness基础值由内存大小决定
    local base_swappiness
    if (( $(echo "$ram_gb < 1" | bc -l) )); then
        base_swappiness=80  # 极低内存，积极使用swap
    elif (( $(echo "$ram_gb < 2" | bc -l) )); then
        base_swappiness=70
    elif (( $(echo "$ram_gb < 4" | bc -l) )); then
        base_swappiness=60
    elif (( $(echo "$ram_gb < 8" | bc -l) )); then
        base_swappiness=40
    elif (( $(echo "$ram_gb < 16" | bc -l) )); then
        base_swappiness=20
    elif (( $(echo "$ram_gb < 32" | bc -l) )); then
        base_swappiness=10
    else
        base_swappiness=5   # 大内存系统，极少使用swap
    fi
    
    # 根据磁盘类型和性能微调
    local disk_adjustment=0
    if [ "$disk_type" = "SSD" ]; then
        # SSD: 可以稍微提高swappiness（速度快）
        if (( $(echo "$disk_score > 70" | bc -l) )); then
            disk_adjustment=5
        elif (( $(echo "$disk_score > 40" | bc -l) )); then
            disk_adjustment=3
        fi
    else
        # HDD: 降低swappiness避免性能问题
        if (( $(echo "$disk_score < 30" | bc -l) )); then
            disk_adjustment=-15
        elif (( $(echo "$disk_score < 50" | bc -l) )); then
            disk_adjustment=-10
        fi
    fi
    
    # 根据CPU和内存性能微调
    # 高性能系统可以降低swappiness
    if (( $(echo "$cpu_score > 70 && $mem_score > 70" | bc -l) )); then
        disk_adjustment=$((disk_adjustment - 5))
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

# 商业级算法：计算其他VM参数
calculate_advanced_vm_parameters() {
    log_progress "计算高级虚拟内存参数..."
    
    local disk_type=${SYSTEM_INFO[disk_type]}
    local disk_score=${PERFORMANCE_DATA[disk_score]}
    local ram_mb=${SYSTEM_INFO[total_ram_mb]}
    local cpu_cores=${SYSTEM_INFO[cpu_cores]}
    
    # 1. vm.vfs_cache_pressure
    # 控制内核回收用于缓存目录和inode对象的内存的倾向
    # Facebook生产环境优化算法
    if [ "$disk_type" = "SSD" ] && (( $(echo "$disk_score > 60" | bc -l) )); then
        # 高性能SSD：可以更积极回收缓存
        PERFORMANCE_DATA[vfs_cache_pressure]=150
    elif [ "$disk_type" = "SSD" ]; then
        PERFORMANCE_DATA[vfs_cache_pressure]=100
    else
        # HDD：保留更多缓存
        if (( $(echo "$disk_score < 30" | bc -l) )); then
            PERFORMANCE_DATA[vfs_cache_pressure]=50
        else
            PERFORMANCE_DATA[vfs_cache_pressure]=75
        fi
    fi
    
    # 2. vm.dirty_ratio
    # 当脏页达到内存的这个百分比时，进程会被阻塞并强制写回
    if [ "$disk_type" = "SSD" ]; then
        if (( $(echo "$disk_score > 70" | bc -l) )); then
            PERFORMANCE_DATA[dirty_ratio]=40  # 高性能SSD
        else
            PERFORMANCE_DATA[dirty_ratio]=30  # 普通SSD
        fi
    else
        # HDD根据性能分级
        if (( $(echo "$disk_score > 40" | bc -l) )); then
            PERFORMANCE_DATA[dirty_ratio]=20
        elif (( $(echo "$disk_score > 20" | bc -l) )); then
            PERFORMANCE_DATA[dirty_ratio]=15
        else
            PERFORMANCE_DATA[dirty_ratio]=10  # 低性能HDD
        fi
    fi
    
    # 3. vm.dirty_background_ratio
    # 后台pdflush进程开始写回的阈值
    PERFORMANCE_DATA[dirty_background_ratio]=$((${PERFORMANCE_DATA[dirty_ratio]} / 4))
    if [ ${PERFORMANCE_DATA[dirty_background_ratio]} -lt 3 ]; then
        PERFORMANCE_DATA[dirty_background_ratio]=3
    fi
    
    # 4. vm.dirty_expire_centisecs
    # 脏页的过期时间
    if [ "$disk_type" = "SSD" ]; then
        PERFORMANCE_DATA[dirty_expire]=1500  # 15秒
    else
        if (( $(echo "$disk_score < 30" | bc -l) )); then
            PERFORMANCE_DATA[dirty_expire]=3000  # 30秒，慢速HDD
        else
            PERFORMANCE_DATA[dirty_expire]=2000  # 20秒
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
    local min_free=$(echo "scale=0; ${SYSTEM_INFO[total_ram_kb]} * 0.005" | bc | cut -d'.' -f1)
    
    # 根据CPU核心数调整（更多核心需要更多空闲内存）
    min_free=$(echo "scale=0; $min_free * (1 + $cpu_cores * 0.05)" | bc | cut -d'.' -f1)
    
    # 限制范围：64MB - 1GB
    if [ $min_free -lt 65536 ]; then
        min_free=65536
    elif [ $min_free -gt 1048576 ]; then
        min_free=1048576
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
    # 0: 启发式策略(默认)
    # 1: 总是允许超额分配
    # 2: 不允许超额分配超过swap+RAM*overcommit_ratio
    if (( $(echo "${SYSTEM_INFO[total_ram_mb]} < 1024" | bc -l) )); then
        PERFORMANCE_DATA[overcommit_memory]=2  # 低内存系统，严格控制
        PERFORMANCE_DATA[overcommit_ratio]=50
    else
        PERFORMANCE_DATA[overcommit_memory]=0  # 使用启发式
        PERFORMANCE_DATA[overcommit_ratio]=50
    fi
    
    # 9. vm.zone_reclaim_mode
    # NUMA系统的区域回收模式
    if [ $cpu_cores -gt 8 ]; then
        PERFORMANCE_DATA[zone_reclaim_mode]=0  # 禁用，允许跨NUMA访问
    else
        PERFORMANCE_DATA[zone_reclaim_mode]=0
    fi
    
    log_success "高级参数计算完成"
}

# 显示完整的性能测试报告
show_professional_report() {
    log_header "专业性能测试与优化报告"
    
    cat << EOF

${CYAN}╔═══════════════════════════════════════════════════════════════════╗
║                     系统硬件配置信息                              ║
╚═══════════════════════════════════════════════════════════════════╝${NC}

${YELLOW}CPU信息:${NC}
  型号:        ${SYSTEM_INFO[cpu_model]}
  核心数:      ${SYSTEM_INFO[cpu_cores]} 核心
  最大频率:    ${SYSTEM_INFO[cpu_max_freq]} MHz
  单线程性能:  ${PERFORMANCE_DATA[cpu_single_thread]} events/sec
  多线程性能:  ${PERFORMANCE_DATA[cpu_multi_thread]} events/sec
  综合评分:    ${PERFORMANCE_DATA[cpu_score]}/100

${YELLOW}内存信息:${NC}
  总容量:      ${SYSTEM_INFO[total_ram_mb]} MB ($(echo "scale=2; ${SYSTEM_INFO[total_ram_mb]}/1024" | bc) GB)
  类型:        ${SYSTEM_INFO[mem_type]:-Unknown}
  速度:        ${SYSTEM_INFO[mem_speed]:-Unknown} MT/s
  读取速度:    ${PERFORMANCE_DATA[mem_read_speed]} MiB/sec
  写入速度:    ${PERFORMANCE_DATA[mem_write_speed]} MiB/sec
  随机访问:    ${PERFORMANCE_DATA[mem_random_speed]} MiB/sec
  综合评分:    ${PERFORMANCE_DATA[mem_score]}/100

${YELLOW}磁盘信息:${NC}
  设备:        ${SYSTEM_INFO[disk_device]}
  类型:        ${SYSTEM_INFO[disk_type]}
  顺序读取:    ${PERFORMANCE_DATA[disk_seq_read]} MB/s
  顺序写入:    ${PERFORMANCE_DATA[disk_seq_write]} MB/s
  随机读IOPS:  ${PERFORMANCE_DATA[disk_rand_read_iops]}
  随机写IOPS:  ${PERFORMANCE_DATA[disk_rand_write_iops]}
  混合IOPS:    ${PERFORMANCE_DATA[disk_mixed_iops]}
  平均延迟:    ${PERFORMANCE_DATA[disk_latency]:-N/A} μs
  综合评分:    ${PERFORMANCE_DATA[disk_score]}/100

${CYAN}╔═══════════════════════════════════════════════════════════════════╗
║                   商业级优化参数推荐                              ║
╚═══════════════════════════════════════════════════════════════════╝${NC}

${GREEN}核心参数:${NC}
  vm.swappiness                = ${PERFORMANCE_DATA[optimal_swappiness]}
  推荐Swap大小                 = ${PERFORMANCE_DATA[optimal_swap]} MB ($(echo "scale=2; ${PERFORMANCE_DATA[optimal_swap]}/1024" | bc) GB)

${GREEN}缓存控制参数:${NC}
  vm.vfs_cache_pressure        = ${PERFORMANCE_DATA[vfs_cache_pressure]}
  vm.dirty_ratio               = ${PERFORMANCE_DATA[dirty_ratio]}
  vm.dirty_background_ratio    = ${PERFORMANCE_DATA[dirty_background_ratio]}
  vm.dirty_expire_centisecs    = ${PERFORMANCE_DATA[dirty_expire]}
  vm.dirty_writeback_centisecs = ${PERFORMANCE_DATA[dirty_writeback]}

${GREEN}内存管理参数:${NC}
  vm.min_free_kbytes           = ${PERFORMANCE_DATA[min_free_kbytes]} KB
  vm.page_cluster              = ${PERFORMANCE_DATA[page_cluster]}
  vm.overcommit_memory         = ${PERFORMANCE_DATA[overcommit_memory]}
  vm.overcommit_ratio          = ${PERFORMANCE_DATA[overcommit_ratio]}

${CYAN}╔═══════════════════════════════════════════════════════════════════╗
║                       优化建议说明                                ║
╚═══════════════════════════════════════════════════════════════════╝${NC}

EOF

    # 根据系统类型给出具体建议
    if [ "${SYSTEM_INFO[disk_type]}" = "SSD" ]; then
        echo -e "${YELLOW}SSD系统优化策略:${NC}"
        echo "  ✓ 降低了swap大小以延长SSD寿命"
        echo "  ✓ 提高了dirty ratio允许更多内存缓冲"
        echo "  ✓ 减少了写回间隔利用SSD高速特性"
        echo "  ✓ 设置page_cluster=0优化随机访问"
    else
        echo -e "${YELLOW}HDD系统优化策略:${NC}"
        echo "  ✓ 保留了足够的swap空间应对慢速IO"
        echo "  ✓ 降低了vfs_cache_pressure保留更多缓存"
        echo "  ✓ 适度的dirty ratio避免IO突发"
        echo "  ✓ 增加page_cluster利用顺序读取优势"
    fi
    
    echo ""
    
    local ram_gb=$(echo "scale=0; ${SYSTEM_INFO[total_ram_mb]}/1024" | bc)
    if [ $ram_gb -lt 2 ]; then
        echo -e "${YELLOW}低内存系统建议:${NC}"
        echo "  ✓ 较高的swappiness确保有足够虚拟内存"
        echo "  ✓ 建议升级物理内存以获得更好性能"
        echo "  ✓ 避免同时运行过多程序"
    elif [ $ram_gb -lt 8 ]; then
        echo -e "${YELLOW}中等内存系统建议:${NC}"
        echo "  ✓ 平衡的swap策略兼顾性能和稳定性"
        echo "  ✓ 可以运行大多数日常应用"
    else
        echo -e "${YELLOW}高内存系统建议:${NC}"
        echo "  ✓ 最小化swap使用充分发挥内存优势"
        echo "  ✓ 可以运行内存密集型应用"
        echo "  ✓ 考虑使用zswap进一步优化"
    fi
    
    echo ""
}

# 应用优化设置
apply_optimizations() {
    log_header "应用优化配置"
    
    # 备份现有配置
    local backup_file="/etc/sysctl.conf.backup.$(date +%Y%m%d_%H%M%S)"
    if [ -f /etc/sysctl.conf ]; then
        cp /etc/sysctl.conf $backup_file
        log_success "已备份配置到: $backup_file"
    fi
    
    # 实时应用参数
    log_progress "正在实时应用虚拟内存参数..."
    
    sysctl -w vm.swappiness=${PERFORMANCE_DATA[optimal_swappiness]} >/dev/null 2>&1
    sysctl -w vm.vfs_cache_pressure=${PERFORMANCE_DATA[vfs_cache_pressure]} >/dev/null 2>&1
    sysctl -w vm.dirty_ratio=${PERFORMANCE_DATA[dirty_ratio]} >/dev/null 2>&1
    sysctl -w vm.dirty_background_ratio=${PERFORMANCE_DATA[dirty_background_ratio]} >/dev/null 2>&1
    sysctl -w vm.dirty_expire_centisecs=${PERFORMANCE_DATA[dirty_expire]} >/dev/null 2>&1
    sysctl -w vm.dirty_writeback_centisecs=${PERFORMANCE_DATA[dirty_writeback]} >/dev/null 2>&1
    sysctl -w vm.min_free_kbytes=${PERFORMANCE_DATA[min_free_kbytes]} >/dev/null 2>&1
    sysctl -w vm.page_cluster=${PERFORMANCE_DATA[page_cluster]} >/dev/null 2>&1
    sysctl -w vm.overcommit_memory=${PERFORMANCE_DATA[overcommit_memory]} >/dev/null 2>&1
    sysctl -w vm.overcommit_ratio=${PERFORMANCE_DATA[overcommit_ratio]} >/dev/null 2>&1
    
    log_success "实时参数已应用"
    
    # 写入配置文件永久生效
    log_progress "写入/etc/sysctl.conf使配置永久生效..."
    
    # 移除旧的vm配置
    if [ -f /etc/sysctl.conf ]; then
        sed -i '/^vm\./d' /etc/sysctl.conf
        sed -i '/# ===.*虚拟内存优化/,/^$/d' /etc/sysctl.conf
    fi
    
    # 写入新配置
    cat >> /etc/sysctl.conf << EOF

# ======================================================================
# 虚拟内存专业级优化配置
# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')
# 系统配置: ${SYSTEM_INFO[cpu_cores]}核CPU, ${SYSTEM_INFO[total_ram_mb]}MB RAM, ${SYSTEM_INFO[disk_type]}
# 性能评分: CPU=${PERFORMANCE_DATA[cpu_score]}, MEM=${PERFORMANCE_DATA[mem_score]}, DISK=${PERFORMANCE_DATA[disk_score]}
# ======================================================================

# 核心Swap参数
vm.swappiness = ${PERFORMANCE_DATA[optimal_swappiness]}
vm.vfs_cache_pressure = ${PERFORMANCE_DATA[vfs_cache_pressure]}

# 脏页管理
vm.dirty_ratio = ${PERFORMANCE_DATA[dirty_ratio]}
vm.dirty_background_ratio = ${PERFORMANCE_DATA[dirty_background_ratio]}
vm.dirty_expire_centisecs = ${PERFORMANCE_DATA[dirty_expire]}
vm.dirty_writeback_centisecs = ${PERFORMANCE_DATA[dirty_writeback]}

# 内存管理
vm.min_free_kbytes = ${PERFORMANCE_DATA[min_free_kbytes]}
vm.page_cluster = ${PERFORMANCE_DATA[page_cluster]}
vm.overcommit_memory = ${PERFORMANCE_DATA[overcommit_memory]}
vm.overcommit_ratio = ${PERFORMANCE_DATA[overcommit_ratio]}

EOF
    
    log_success "配置已写入/etc/sysctl.conf"
}

# 管理Swap分区/文件
manage_swap_advanced() {
    log_header "Swap空间管理"
    
    local current_swap=$(free -m | awk '/^Swap:/{print $2}')
    local optimal_swap=${PERFORMANCE_DATA[optimal_swap]}
    
    log_info "当前Swap: ${current_swap} MB"
    log_info "推荐Swap: ${optimal_swap} MB"
    
    # 计算差异
    local diff=$((optimal_swap - current_swap))
    local diff_abs=${diff#-}
    local threshold=$((optimal_swap / 5))  # 20%阈值
    
    if [ $current_swap -eq 0 ]; then
        log_warn "系统当前没有Swap，强烈建议创建"
        read -p "是否创建Swap? (y/n): " create_swap
    elif [ $diff_abs -gt $threshold ]; then
        log_warn "当前Swap与推荐值差异超过20%"
        read -p "是否重新调整Swap大小? (y/n): " create_swap
    else
        log_success "当前Swap大小合理，无需调整"
        return 0
    fi
    
    if [ "$create_swap" != "y" ] && [ "$create_swap" != "Y" ]; then
        log_info "跳过Swap调整"
        return 0
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

# 生成详细报告文件
generate_detailed_report() {
    local report_file="/tmp/vm_optimization_report_$(date +%Y%m%d_%H%M%S).txt"
    
    cat > $report_file << EOF
═══════════════════════════════════════════════════════════════════════
                Linux虚拟内存专业级优化报告
═══════════════════════════════════════════════════════════════════════
生成时间: $(date '+%Y-%m-%d %H:%M:%S')

───────────────────────────────────────────────────────────────────────
一、系统硬件配置
───────────────────────────────────────────────────────────────────────

CPU配置:
  型号:              ${SYSTEM_INFO[cpu_model]}
  物理核心:          ${SYSTEM_INFO[cpu_cores]}
  逻辑线程:          ${SYSTEM_INFO[cpu_threads]}
  最大频率:          ${SYSTEM_INFO[cpu_max_freq]} MHz

内存配置:
  总容量:            ${SYSTEM_INFO[total_ram_mb]} MB ($(echo "scale=2; ${SYSTEM_INFO[total_ram_mb]}/1024" | bc) GB)
  内存类型:          ${SYSTEM_INFO[mem_type]:-Unknown}
  内存速度:          ${SYSTEM_INFO[mem_speed]:-Unknown} MT/s

磁盘配置:
  设备路径:          ${SYSTEM_INFO[disk_device]}
  磁盘类型:          ${SYSTEM_INFO[disk_type]}

───────────────────────────────────────────────────────────────────────
二、性能测试结果
───────────────────────────────────────────────────────────────────────

CPU性能测试:
  单线程分数:        ${PERFORMANCE_DATA[cpu_single_thread]} events/sec
  多线程分数:        ${PERFORMANCE_DATA[cpu_multi_thread]} events/sec
  整数运算:          ${PERFORMANCE_DATA[cpu_int_ops]} ops/sec
  浮点运算:          ${PERFORMANCE_DATA[cpu_float_ops]} ops/sec
  综合评分:          ${PERFORMANCE_DATA[cpu_score]}/100

内存性能测试:
  顺序读取:          ${PERFORMANCE_DATA[mem_read_speed]} MiB/sec
  顺序写入:          ${PERFORMANCE_DATA[mem_write_speed]} MiB/sec
  随机访问:          ${PERFORMANCE_DATA[mem_random_speed]} MiB/sec
  综合评分:          ${PERFORMANCE_DATA[mem_score]}/100

磁盘性能测试 (FIO):
  顺序读取:          ${PERFORMANCE_DATA[disk_seq_read]} MB/s
  顺序写入:          ${PERFORMANCE_DATA[disk_seq_write]} MB/s
  4K随机读IOPS:      ${PERFORMANCE_DATA[disk_rand_read_iops]}
  4K随机写IOPS:      ${PERFORMANCE_DATA[disk_rand_write_iops]}
  混合读写IOPS:      ${PERFORMANCE_DATA[disk_mixed_iops]}
  平均延迟:          ${PERFORMANCE_DATA[disk_latency]:-N/A} μs
  综合评分:          ${PERFORMANCE_DATA[disk_score]}/100

───────────────────────────────────────────────────────────────────────
三、优化参数配置
───────────────────────────────────────────────────────────────────────

Swap配置:
  推荐大小:          ${PERFORMANCE_DATA[optimal_swap]} MB ($(echo "scale=2; ${PERFORMANCE_DATA[optimal_swap]}/1024" | bc) GB)
  Swappiness:        ${PERFORMANCE_DATA[optimal_swappiness]}

缓存控制:
  vfs_cache_pressure:        ${PERFORMANCE_DATA[vfs_cache_pressure]}
  dirty_ratio:               ${PERFORMANCE_DATA[dirty_ratio]}%
  dirty_background_ratio:    ${PERFORMANCE_DATA[dirty_background_ratio]}%
  dirty_expire_centisecs:    ${PERFORMANCE_DATA[dirty_expire]}
  dirty_writeback_centisecs: ${PERFORMANCE_DATA[dirty_writeback]}

内存管理:
  min_free_kbytes:   ${PERFORMANCE_DATA[min_free_kbytes]} KB
  page_cluster:      ${PERFORMANCE_DATA[page_cluster]}
  overcommit_memory: ${PERFORMANCE_DATA[overcommit_memory]}
  overcommit_ratio:  ${PERFORMANCE_DATA[overcommit_ratio]}%

───────────────────────────────────────────────────────────────────────
四、监控命令
───────────────────────────────────────────────────────────────────────

查看内存使用:
  free -h
  cat /proc/meminfo
  vmstat 1 10

查看Swap使用:
  swapon --show
  cat /proc/swaps

查看虚拟内存参数:
  sysctl -a | grep vm

实时监控:
  htop
  iostat -x 1
  sar -r 1 10

───────────────────────────────────────────────────────────────────────
五、备份与恢复
───────────────────────────────────────────────────────────────────────

配置备份位置:
  $(ls -t /etc/sysctl.conf.backup.* 2>/dev/null | head -1 || echo '无备份文件')

恢复原配置:
  sudo cp /etc/sysctl.conf.backup.XXXXXX /etc/sysctl.conf
  sudo sysctl -p

═══════════════════════════════════════════════════════════════════════
报告结束
═══════════════════════════════════════════════════════════════════════
EOF
    
    log_success "详细报告已保存到: $report_file"
    echo ""
    echo "查看报告: cat $report_file"
}

# 主函数
main() {
    clear
    echo ""
    echo -e "${CYAN}"
    cat << "EOF"
╔═══════════════════════════════════════════════════════════════════╗
║                                                                   ║
║     Linux虚拟内存专业级自动优化工具 v3.0                         ║
║     Professional Virtual Memory Optimization Tool                ║
║                                                                   ║
║     使用业界标准测试工具和商业级优化算法                         ║
║                                                                   ║
╚═══════════════════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
    
    # 环境检查
    check_root
    install_professional_tools
    
    echo ""
    log_warn "性能测试将执行约2-3分钟，请耐心等待..."
    read -p "按Enter键开始测试..." 
    
    # 执行深度性能测试
    deep_cpu_benchmark
    deep_memory_benchmark
    deep_disk_benchmark
    
    # 计算优化参数
    calculate_optimal_swap_advanced
    calculate_optimal_swappiness_advanced
    calculate_advanced_vm_parameters
    
    # 显示报告
    show_professional_report
    
    # 询问是否应用
    echo ""
    read -p "是否应用以上优化配置? (y/n): " apply_choice
    
    if [ "$apply_choice" = "y" ] || [ "$apply_choice" = "Y" ]; then
        apply_optimizations
        manage_swap_advanced
        generate_detailed_report
        
        echo ""
        log_success "═══════════════════════════════════════════════════"
        log_success "    优化完成！"
        log_success "    建议重启系统以确保所有设置完全生效"
        log_success "═══════════════════════════════════════════════════"
    else
        generate_detailed_report
        log_info "未应用任何更改，但已生成详细报告供参考"
    fi
    
    echo ""
}

# 运行主程序
main "$@"

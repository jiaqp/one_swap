#!/bin/bash

################################################################################
# Linux 虚拟内存智能优化脚本
# 功能：根据系统硬件自动优化swap和内存管理参数
# 作者：AI Assistant
# 版本：2.0
# 日期：2025-12-13
################################################################################

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # 无颜色

# 日志函数
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_step() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

# 检查root权限
check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "请使用root权限运行此脚本"
        exit 1
    fi
}

# 备份当前配置
backup_config() {
    local backup_dir="/root/vm_backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir"
    
    log_step "备份当前配置到: $backup_dir"
    
    # 备份sysctl配置
    cp /etc/sysctl.conf "$backup_dir/sysctl.conf.bak" 2>/dev/null
    sysctl -a > "$backup_dir/sysctl_current.txt" 2>/dev/null
    
    # 备份swap信息
    swapon --show > "$backup_dir/swap_current.txt" 2>/dev/null
    free -h > "$backup_dir/memory_current.txt"
    
    # 备份fstab
    cp /etc/fstab "$backup_dir/fstab.bak"
    
    echo "$backup_dir" > /tmp/vm_backup_path
    log_info "备份完成"
}

# 获取CPU核心数
get_cpu_cores() {
    local cores=$(nproc)
    echo "$cores"
}

# 获取CPU主频（MHz）
get_cpu_freq() {
    local freq=$(lscpu | grep "CPU MHz" | awk '{print $3}' | cut -d'.' -f1)
    if [ -z "$freq" ]; then
        freq=$(lscpu | grep "CPU max MHz" | awk '{print $4}' | cut -d'.' -f1)
    fi
    echo "${freq:-2000}"  # 默认2000MHz
}

# 获取总内存（MB）
get_total_memory() {
    local mem_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    local mem_mb=$((mem_kb / 1024))
    echo "$mem_mb"
}

# 检测硬盘类型（SSD或HDD）
detect_disk_type() {
    local root_device=$(df / | tail -1 | awk '{print $1}' | sed 's/[0-9]*$//' | sed 's/p$//')
    local device_name=$(basename "$root_device")
    
    # 去除分区号，获取设备名
    device_name=$(echo "$device_name" | sed 's/[0-9]*$//')
    
    # 检查是否为SSD
    local rotational=$(cat /sys/block/$device_name/queue/rotational 2>/dev/null)
    
    if [ "$rotational" = "0" ]; then
        echo "SSD"
    else
        echo "HDD"
    fi
}

# 检测硬盘读写速度（MB/s）
benchmark_disk() {
    log_step "正在测试硬盘性能（这可能需要10-20秒）..."
    
    local test_file="/tmp/disk_benchmark_test"
    
    # 写入测试
    local write_speed=$(dd if=/dev/zero of=$test_file bs=1M count=512 oflag=direct 2>&1 | \
        grep -oP '\d+\.?\d* MB/s' | grep -oP '\d+\.?\d*' | head -1)
    
    # 清除缓存
    sync
    echo 3 > /proc/sys/vm/drop_caches 2>/dev/null
    
    # 读取测试
    local read_speed=$(dd if=$test_file of=/dev/null bs=1M count=512 iflag=direct 2>&1 | \
        grep -oP '\d+\.?\d* MB/s' | grep -oP '\d+\.?\d*' | head -1)
    
    rm -f $test_file
    
    # 如果测试失败，根据硬盘类型设置默认值
    if [ -z "$write_speed" ] || [ -z "$read_speed" ]; then
        local disk_type=$(detect_disk_type)
        if [ "$disk_type" = "SSD" ]; then
            write_speed=300
            read_speed=400
        else
            write_speed=80
            read_speed=100
        fi
    fi
    
    echo "$write_speed $read_speed"
}

# 计算系统性能评分（0-100）
calculate_performance_score() {
    local cpu_cores=$1
    local cpu_freq=$2
    local memory_mb=$3
    local disk_type=$4
    local disk_write=$5
    local disk_read=$6
    
    # CPU评分（40分）
    local cpu_score=$((cpu_cores * 4))
    [ $cpu_score -gt 40 ] && cpu_score=40
    
    local freq_bonus=$((cpu_freq / 200))
    [ $freq_bonus -gt 10 ] && freq_bonus=10
    cpu_score=$((cpu_score + freq_bonus))
    
    # 内存评分（30分）
    local mem_score=$((memory_mb / 512))
    [ $mem_score -gt 30 ] && mem_score=30
    
    # 硬盘评分（30分）
    local disk_score=0
    if [ "$disk_type" = "SSD" ]; then
        disk_score=20
        local speed_bonus=$(echo "$disk_read / 100" | bc)
        [ $speed_bonus -gt 10 ] && speed_bonus=10
        disk_score=$((disk_score + speed_bonus))
    else
        disk_score=10
        local speed_bonus=$(echo "$disk_read / 50" | bc)
        [ $speed_bonus -gt 5 ] && speed_bonus=5
        disk_score=$((disk_score + speed_bonus))
    fi
    
    local total=$((cpu_score + mem_score + disk_score))
    echo "$total"
}

# 根据内存大小推荐swap大小
recommend_swap_size() {
    local memory_mb=$1
    local disk_type=$2
    local performance_score=$3
    
    local swap_mb=0
    
    # 基础规则
    if [ $memory_mb -le 2048 ]; then
        # 小于等于2GB内存，swap = 2倍内存
        swap_mb=$((memory_mb * 2))
    elif [ $memory_mb -le 8192 ]; then
        # 2GB-8GB内存，swap = 1倍内存
        swap_mb=$memory_mb
    elif [ $memory_mb -le 16384 ]; then
        # 8GB-16GB内存，swap = 0.5倍内存
        swap_mb=$((memory_mb / 2))
    else
        # 大于16GB内存，swap = 4GB到8GB
        swap_mb=4096
    fi
    
    # SSD优化：可以适当增加swap
    if [ "$disk_type" = "SSD" ] && [ $performance_score -gt 60 ]; then
        swap_mb=$((swap_mb * 120 / 100))  # 增加20%
    fi
    
    # HDD限制：避免过大swap导致性能问题
    if [ "$disk_type" = "HDD" ] && [ $swap_mb -gt 8192 ]; then
        swap_mb=8192
    fi
    
    echo "$swap_mb"
}

# 优化swappiness参数
optimize_swappiness() {
    local memory_mb=$1
    local disk_type=$2
    local performance_score=$3
    
    local swappiness=10
    
    if [ "$disk_type" = "SSD" ]; then
        # SSD场景
        if [ $memory_mb -le 2048 ]; then
            swappiness=60  # 低内存，多用swap
        elif [ $memory_mb -le 4096 ]; then
            swappiness=30
        elif [ $memory_mb -le 8192 ]; then
            swappiness=10
        else
            swappiness=5   # 大内存，少用swap
        fi
    else
        # HDD场景 - 更保守的策略
        if [ $memory_mb -le 2048 ]; then
            swappiness=40
        elif [ $memory_mb -le 4096 ]; then
            swappiness=20
        else
            swappiness=10
        fi
    fi
    
    echo "$swappiness"
}

# 优化vfs_cache_pressure参数
optimize_cache_pressure() {
    local memory_mb=$1
    local disk_type=$2
    
    local pressure=100
    
    if [ "$disk_type" = "SSD" ]; then
        if [ $memory_mb -ge 8192 ]; then
            pressure=50   # 大内存+SSD，保留更多缓存
        else
            pressure=80
        fi
    else
        if [ $memory_mb -ge 4096 ]; then
            pressure=100
        else
            pressure=150  # 小内存+HDD，更激进地回收缓存
        fi
    fi
    
    echo "$pressure"
}

# 优化dirty_ratio参数
optimize_dirty_ratio() {
    local disk_type=$1
    local disk_write=$2
    
    if [ "$disk_type" = "SSD" ]; then
        # SSD写入快，可以设置较小值，更频繁刷新
        echo "10 5"  # dirty_ratio dirty_background_ratio
    else
        # HDD写入慢，设置较大值，减少写入次数
        echo "20 10"
    fi
}

# 创建或调整swap文件
setup_swap() {
    local target_swap_mb=$1
    local swap_file="/swapfile"
    
    log_step "配置Swap文件..."
    
    # 检查现有swap
    local current_swap=$(swapon --show=NAME --noheadings | head -1)
    
    if [ -n "$current_swap" ]; then
        log_info "检测到现有swap: $current_swap"
        local current_size_kb=$(swapon --show=SIZE --noheadings --bytes | head -1)
        local current_size_mb=$((current_size_kb / 1024 / 1024))
        
        log_info "当前swap大小: ${current_size_mb}MB, 推荐大小: ${target_swap_mb}MB"
        
        # 如果差异超过20%，重新创建
        local diff=$((target_swap_mb - current_size_mb))
        local diff_abs=${diff#-}  # 绝对值
        local threshold=$((target_swap_mb * 20 / 100))
        
        if [ $diff_abs -gt $threshold ]; then
            log_warn "Swap大小差异较大，将重新创建"
            swapoff -a
            rm -f $current_swap
        else
            log_info "Swap大小合适，跳过创建"
            return 0
        fi
    fi
    
    # 创建新的swap文件
    log_step "创建${target_swap_mb}MB的swap文件..."
    
    # 使用fallocate快速创建（如果支持）
    if fallocate -l ${target_swap_mb}M $swap_file 2>/dev/null; then
        log_info "使用fallocate创建swap文件"
    else
        # 备用方案：使用dd
        log_info "使用dd创建swap文件（较慢）..."
        dd if=/dev/zero of=$swap_file bs=1M count=$target_swap_mb status=progress
    fi
    
    # 设置权限
    chmod 600 $swap_file
    
    # 格式化为swap
    mkswap $swap_file
    
    # 启用swap
    swapon $swap_file
    
    # 添加到fstab（如果不存在）
    if ! grep -q "$swap_file" /etc/fstab; then
        echo "$swap_file none swap sw 0 0" >> /etc/fstab
        log_info "已添加swap到/etc/fstab"
    fi
    
    log_info "Swap配置完成"
}

# 应用内核参数优化
apply_sysctl_optimizations() {
    local swappiness=$1
    local cache_pressure=$2
    local dirty_ratio=$3
    local dirty_bg_ratio=$4
    local disk_type=$5
    
    log_step "应用内核参数优化..."
    
    # 创建优化配置文件
    local config_file="/etc/sysctl.d/99-vm-optimized.conf"
    
    cat > $config_file << EOF
# ============================================
# 虚拟内存优化配置
# 由优化脚本自动生成
# 生成时间: $(date)
# ============================================

# Swap使用倾向（0-100，越小越少用swap）
vm.swappiness = $swappiness

# 缓存回收压力（默认100，越大越倾向回收缓存）
vm.vfs_cache_pressure = $cache_pressure

# 脏页比例（开始后台刷新）
vm.dirty_background_ratio = $dirty_bg_ratio

# 脏页比例（强制同步刷新）
vm.dirty_ratio = $dirty_ratio

# 脏页刷新间隔（厘秒）
vm.dirty_writeback_centisecs = 500

# 脏页过期时间（厘秒）
vm.dirty_expire_centisecs = 3000

# OOM killer倾向（0=尽量避免，1=允许杀进程）
vm.panic_on_oom = 0
vm.oom_kill_allocating_task = 0

# 内存过量分配策略（0=启发式，1=总是允许，2=不允许）
vm.overcommit_memory = 0
vm.overcommit_ratio = 50

# 最小保留内存（KB）
vm.min_free_kbytes = 65536

EOF

    # SSD特定优化
    if [ "$disk_type" = "SSD" ]; then
        cat >> $config_file << EOF

# ============================================
# SSD特定优化
# ============================================

# 大页内存策略（SSD随机读取快，按需分配）
kernel.mm.transparent_hugepage.enabled = madvise
kernel.mm.transparent_hugepage.defrag = defer

EOF
    else
        cat >> $config_file << EOF

# ============================================
# HDD特定优化
# ============================================

# 大页内存策略（减少HDD的随机访问）
kernel.mm.transparent_hugepage.enabled = always
kernel.mm.transparent_hugepage.defrag = defer+madvise

EOF
    fi
    
    # 应用配置
    sysctl -p $config_file
    
    log_info "内核参数已优化并持久化到: $config_file"
}

# 显示优化建议
show_recommendations() {
    local memory_mb=$1
    local disk_type=$2
    local performance_score=$3
    
    echo ""
    echo "========================================"
    echo "        额外优化建议"
    echo "========================================"
    
    if [ "$disk_type" = "SSD" ] && [ $performance_score -gt 60 ]; then
        echo "✓ 高性能系统，建议："
        echo "  - 考虑使用zram（压缩内存swap）"
        echo "  - 启用内核参数: vm.page-cluster = 0"
    fi
    
    if [ $memory_mb -le 1024 ]; then
        echo "✓ 低内存系统，建议："
        echo "  - 关闭不必要的服务"
        echo "  - 考虑使用轻量级应用"
        echo "  - 监控内存使用: free -h"
    fi
    
    if [ "$disk_type" = "HDD" ]; then
        echo "✓ HDD硬盘，建议："
        echo "  - 避免频繁大量写入"
        echo "  - 定期清理日志文件"
        echo "  - 考虑升级到SSD提升性能"
    fi
    
    echo ""
    echo "监控命令："
    echo "  - 查看内存: free -h"
    echo "  - 查看swap: swapon --show"
    echo "  - 查看vm参数: sysctl -a | grep vm"
    echo "  - 实时监控: vmstat 1"
    echo "========================================"
}

# 主函数
main() {
    echo ""
    echo "========================================"
    echo "   Linux 虚拟内存智能优化脚本 v2.0"
    echo "========================================"
    echo ""
    
    # 检查root权限
    check_root
    
    # 备份配置
    backup_config
    
    # 收集系统信息
    log_step "收集系统信息..."
    
    local cpu_cores=$(get_cpu_cores)
    local cpu_freq=$(get_cpu_freq)
    local memory_mb=$(get_total_memory)
    local disk_type=$(detect_disk_type)
    
    log_info "CPU核心数: $cpu_cores"
    log_info "CPU主频: ${cpu_freq}MHz"
    log_info "总内存: ${memory_mb}MB"
    log_info "硬盘类型: $disk_type"
    
    # 硬盘性能测试
    read disk_write disk_read <<< $(benchmark_disk)
    log_info "硬盘写入速度: ${disk_write}MB/s"
    log_info "硬盘读取速度: ${disk_read}MB/s"
    
    # 计算性能评分
    local performance_score=$(calculate_performance_score \
        $cpu_cores $cpu_freq $memory_mb "$disk_type" $disk_write $disk_read)
    log_info "系统性能评分: ${performance_score}/100"
    
    # 生成优化参数
    log_step "计算最优参数..."
    
    local swap_size=$(recommend_swap_size $memory_mb "$disk_type" $performance_score)
    local swappiness=$(optimize_swappiness $memory_mb "$disk_type" $performance_score)
    local cache_pressure=$(optimize_cache_pressure $memory_mb "$disk_type")
    read dirty_ratio dirty_bg_ratio <<< $(optimize_dirty_ratio "$disk_type" $disk_write)
    
    echo ""
    echo "========================================"
    echo "        优化方案"
    echo "========================================"
    echo "Swap大小: ${swap_size}MB"
    echo "vm.swappiness: $swappiness"
    echo "vm.vfs_cache_pressure: $cache_pressure"
    echo "vm.dirty_ratio: $dirty_ratio"
    echo "vm.dirty_background_ratio: $dirty_bg_ratio"
    echo "========================================"
    echo ""
    
    # 询问是否继续
    read -p "是否应用以上优化？(y/n): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_warn "用户取消操作"
        exit 0
    fi
    
    # 应用优化
    setup_swap $swap_size
    apply_sysctl_optimizations $swappiness $cache_pressure \
        $dirty_ratio $dirty_bg_ratio "$disk_type"
    
    # 显示当前状态
    echo ""
    log_step "优化完成！当前状态："
    echo ""
    echo "=== 内存状态 ==="
    free -h
    echo ""
    echo "=== Swap状态 ==="
    swapon --show
    echo ""
    echo "=== 关键VM参数 ==="
    sysctl vm.swappiness vm.vfs_cache_pressure vm.dirty_ratio vm.dirty_background_ratio
    echo ""
    
    # 显示额外建议
    show_recommendations $memory_mb "$disk_type" $performance_score
    
    # 显示回滚信息
    local backup_path=$(cat /tmp/vm_backup_path 2>/dev/null)
    if [ -n "$backup_path" ]; then
        echo ""
        log_info "配置备份位置: $backup_path"
        log_info "如需回滚，执行: cp $backup_path/sysctl.conf.bak /etc/sysctl.conf && sysctl -p"
    fi
    
    echo ""
    log_info "建议重启系统以确保所有优化生效"
    echo ""
}

# 执行主函数
main "$@"
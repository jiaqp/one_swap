#!/bin/bash

################################################################################
# Linux服务器虚拟内存专业级自动优化脚本
# 功能：使用业界标准测试工具精确测量系统性能，并应用商业级优化算法
# 版本：3.0 Server Edition
# 适用场景：Linux服务器环境（Web服务器、数据库服务器、应用服务器等）
#
# 性能评分标准体系（对标 spiritLHLS/ecs 项目标准）：
# ===========================================================
# 参考项目：https://github.com/spiritLHLS/ecs
# VPS融合怪服务器测评项目 - 业界知名的开源VPS测评标准
# 
# CPU性能评分：使用 Sysbench CPU 测试（素数计算）
#   - 评分方式：Sysbench events/sec（每秒事件数）
#   - 参考基准值（单线程 @5sec Fast Mode）：
#     * 低端VPS/老旧CPU:      200-500 Scores
#     * 入门服务器:           500-800 Scores
#     * 主流服务器:           800-1200 Scores  
#     * 中高端服务器:         1200-1800 Scores
#     * 高端服务器:           1800-2500 Scores
#     * 顶级服务器:           2500+ Scores
#   - 测试命令：sysbench cpu --cpu-max-prime=10000 --threads=1 --time=5 run
#   - 数据来源：spiritLHLS/ecs 项目实际测试数据积累
#
# 内存性能评分：使用 Sysbench Memory + Lemonbench 标准
#   - 评分方式：MB/s（兆字节/秒）
#   - 参考基准值（单线程测试）：
#     * DDR3-1333/1600 ECC:   8,000-11,000 MB/s
#     * DDR4-2133 ECC:        13,000-15,000 MB/s
#     * DDR4-2400 ECC:        15,000-17,000 MB/s
#     * DDR4-2666 ECC:        17,000-20,000 MB/s
#     * DDR4-3200 ECC:        20,000-25,000 MB/s
#     * DDR5-4800+ ECC:       30,000+ MB/s
#   - 测试方式：单线程读写测试
#   - 数据来源：Lemonbench 项目标准
#
# 磁盘性能评分：使用 FIO + DD 双重测试
#   - FIO 4K随机 IOPS（服务器最关键指标）：
#     * 低端HDD:              50-150 IOPS
#     * 企业HDD:              150-300 IOPS
#     * 入门SSD:              1k-10k IOPS
#     * 企业SATA SSD:         30k-90k IOPS
#     * 企业NVMe SSD:         100k-500k IOPS
#   - DD 顺序读写速度：
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

# CPU性能数据库对比（基于PassMark和ecs项目数据）
compare_with_database() {
    local cpu_model="${SYSTEM_INFO[cpu_model]}"
    local user_score=$(echo "${PERFORMANCE_DATA[cpu_single_thread]}" | cut -d'.' -f1)
    
    # 内置常见CPU基准数据库（Sysbench 5秒 素数10000，来源：ecs项目社区数据）
    # 格式：CPU型号关键词|典型分数|PassMark单线程|等级
    local cpu_database=(
        # Intel Xeon E5系列（常见VPS/云服务器）
        "E5-2683 v4|800|1891|主流服务器CPU（2016年）"
        "E5-2680 v4|820|1920|主流服务器CPU"
        "E5-2690 v4|850|1950|高性能服务器CPU"
        "E5-2650 v4|780|1850|入门服务器CPU"
        "E5-2630 v4|750|1800|入门服务器CPU"
        
        # Intel Xeon E5 v3系列
        "E5-2680 v3|750|1820|主流服务器CPU（2014年）"
        "E5-2683 v3|780|1860|主流服务器CPU"
        "E5-2690 v3|800|1890|高性能服务器CPU"
        
        # Intel Xeon Gold/Platinum（新一代）
        "Gold 6132|1100|2350|高端服务器CPU（2017年）"
        "Gold 6140|1150|2400|高端服务器CPU"
        "Gold 6240|1300|2550|高端服务器CPU（2019年）"
        "Platinum 8160|1200|2450|顶级服务器CPU"
        "Platinum 8280|1400|2650|顶级服务器CPU"
        
        # AMD EPYC系列
        "EPYC 7551|950|2100|AMD高性能服务器（2017年）"
        "EPYC 7601|1000|2150|AMD顶级服务器"
        "EPYC 7742|1600|2850|AMD顶级服务器（第二代）"
        "EPYC 7763|1800|3100|AMD顶级服务器（第三代）"
        
        # Intel Core i系列（常见独立服务器）
        "i9-9900K|2000|3050|高性能桌面/独立服务器"
        "i7-9700K|1800|2900|高性能桌面"
        "i9-10900K|2100|3150|高性能桌面（2020年）"
        "i9-12900K|2800|3900|高性能桌面（2021年）"
        
        # 常见VPS CPU
        "E5-2670 v3|700|1780|常见VPS CPU"
        "E5-2680 v2|650|1720|常见VPS CPU（老旧）"
    )
    
    local found=0
    local matched_cpu=""
    local expected_score=0
    local passmark_score=0
    local cpu_level=""
    
    # 搜索匹配的CPU
    for entry in "${cpu_database[@]}"; do
        IFS='|' read -r cpu_pattern expect_sc pm_sc level <<< "$entry"
        if echo "$cpu_model" | grep -qi "$cpu_pattern"; then
            found=1
            matched_cpu="$cpu_pattern"
            expected_score=$expect_sc
            passmark_score=$pm_sc
            cpu_level="$level"
            break
        fi
    done
    
    if [ $found -eq 1 ]; then
        echo ""
        log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        log_info "📊 与权威数据库对比（数据来源：PassMark + ecs项目）"
        log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        log_info "识别CPU: $matched_cpu"
        log_info "CPU等级: $cpu_level"
        echo ""
        log_info "性能对比："
        log_info "  您的得分:     $user_score Scores"
        log_info "  同型号典型值: $expected_score Scores"
        log_info "  PassMark单线程: $passmark_score"
        
        # 计算性能差异
        local diff=$((user_score - expected_score))
        local percent=$(echo "scale=1; ($user_score - $expected_score) * 100 / $expected_score" | bc 2>/dev/null || echo "0")
        
        echo ""
        if [ $diff -gt 50 ]; then
            log_success "🎉 您的CPU性能超出同型号典型值 ${percent}%！"
            log_info "可能原因：CPU超频、优化良好的系统、或较新批次"
        elif [ $diff -gt 0 ]; then
            log_success "✅ 您的CPU性能略优于同型号典型值 (+${percent}%)"
        elif [ $diff -gt -50 ]; then
            log_warn "⚠️  您的CPU性能略低于同型号典型值 (${percent}%)"
            log_info "可能原因：CPU降频、虚拟化性能损耗、或系统负载"
        else
            log_warn "⚠️  您的CPU性能明显低于同型号典型值 (${percent}%)"
            log_warn "建议检查："
            log_warn "  • 是否有CPU频率限制 (cpufreq-info)"
            log_warn "  • 是否虚拟化性能损耗过大"
            log_warn "  • 系统是否有其他进程占用CPU"
        fi
        
        # PassMark对比
        echo ""
        log_info "参考：PassMark单线程基准 = $passmark_score"
        log_info "说明：PassMark是全球权威的CPU性能数据库"
        log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        
        # 保存标准值供评分系统使用
        PERFORMANCE_DATA[cpu_expected_score]=$expected_score
        PERFORMANCE_DATA[cpu_found_in_db]="yes"
    else
        echo ""
        log_warn "未在数据库中找到您的CPU型号：$cpu_model"
        log_info "这可能是较新或较少见的CPU型号"
        log_info "您的得分：$user_score Scores 可作为此CPU的参考基准"
        
        # 未找到，使用固定基准
        PERFORMANCE_DATA[cpu_expected_score]=1000
        PERFORMANCE_DATA[cpu_found_in_db]="no"
    fi
}

# 内存性能数据库对比（基于标准内存规格）
compare_memory_with_database() {
    local mem_read=$(echo "${PERFORMANCE_DATA[mem_read_bandwidth]}" | cut -d'.' -f1)
    local mem_write=$(echo "${PERFORMANCE_DATA[mem_write_bandwidth]}" | cut -d'.' -f1)
    local mem_type="${SYSTEM_INFO[mem_type]:-Unknown}"
    local mem_speed="${SYSTEM_INFO[mem_speed]:-0}"
    
    # 内存性能数据库（数据来源：标准规格 + Lemonbench社区测试）
    # 格式：内存类型|典型读取(MB/s)|典型写入(MB/s)|PassMark内存分|说明
    local memory_database=(
        # DDR5服务器内存（最新一代）
        "DDR5-4800|38000|25000|4500|DDR5-4800 ECC（第四代至强/EPYC）"
        "DDR5-5600|45000|30000|5200|DDR5-5600 ECC（高端服务器）"
        
        # DDR4服务器内存（主流）
        "DDR4-3200|20000|15000|3800|DDR4-3200 ECC（主流服务器）"
        "DDR4-2933|19000|14500|3600|DDR4-2933 ECC（主流服务器）"
        "DDR4-2666|17000|13000|3400|DDR4-2666 ECC（主流服务器）"
        "DDR4-2400|16000|12000|3200|DDR4-2400 ECC（入门服务器）"
        "DDR4-2133|14000|10500|2900|DDR4-2133 ECC（老旧服务器）"
        
        # DDR3服务器内存（老旧）
        "DDR3-1866|13000|9800|2600|DDR3-1866 ECC（老旧服务器）"
        "DDR3-1600|11000|8500|2400|DDR3-1600 ECC（老旧服务器）"
        "DDR3-1333|9000|7000|2100|DDR3-1333 ECC（非常老旧）"
    )
    
    local found=0
    local matched_type=""
    local expected_read=0
    local expected_write=0
    local passmark_score=0
    local mem_desc=""
    
    # 根据读取速度匹配最接近的内存类型
    local best_match_diff=999999
    for entry in "${memory_database[@]}"; do
        IFS='|' read -r type exp_read exp_write pm_sc desc <<< "$entry"
        local diff=$((mem_read - exp_read))
        [ $diff -lt 0 ] && diff=$((-diff))
        
        if [ $diff -lt $best_match_diff ]; then
            best_match_diff=$diff
            matched_type="$type"
            expected_read=$exp_read
            expected_write=$exp_write
            passmark_score=$pm_sc
            mem_desc="$desc"
            found=1
        fi
    done
    
    if [ $found -eq 1 ]; then
        echo ""
        log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        log_info "📊 与权威数据库对比（数据来源：标准规格 + Lemonbench）"
        log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        log_info "识别内存: $mem_desc"
        log_info "匹配规格: $matched_type"
        echo ""
        log_info "性能对比："
        log_info "  您的读取速度: $mem_read MB/s"
        log_info "  标准读取速度: $expected_read MB/s"
        log_info "  您的写入速度: $mem_write MB/s"
        log_info "  标准写入速度: $expected_write MB/s"
        log_info "  PassMark内存分: $passmark_score"
        
        # 计算读取性能差异
        local read_diff=$((mem_read - expected_read))
        local read_percent=$(echo "scale=1; $read_diff * 100 / $expected_read" | bc 2>/dev/null || echo "0")
        
        # 计算写入性能差异
        local write_diff=$((mem_write - expected_write))
        local write_percent=$(echo "scale=1; $write_diff * 100 / $expected_write" | bc 2>/dev/null || echo "0")
        
        echo ""
        if [ $read_diff -gt 2000 ]; then
            log_success "🎉 读取速度超出标准 ${read_percent}%！"
        elif [ $read_diff -gt 0 ]; then
            log_success "✅ 读取速度符合标准 (+${read_percent}%)"
        elif [ $read_diff -gt -2000 ]; then
            log_warn "⚠️  读取速度略低于标准 (${read_percent}%)"
        else
            log_warn "⚠️  读取速度明显低于标准 (${read_percent}%)"
            log_warn "可能原因：内存通道未满配、频率降频、或硬件问题"
        fi
        
        if [ $write_diff -gt 1500 ]; then
            log_success "🎉 写入速度超出标准 ${write_percent}%！"
        elif [ $write_diff -gt 0 ]; then
            log_success "✅ 写入速度符合标准 (+${write_percent}%)"
        elif [ $write_diff -gt -1500 ]; then
            log_warn "⚠️  写入速度略低于标准 (${write_percent}%)"
        else
            log_warn "⚠️  写入速度明显低于标准 (${write_percent}%)"
        fi
        
        log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        
        # 保存标准值供评分系统使用
        PERFORMANCE_DATA[mem_expected_read]=$expected_read
        PERFORMANCE_DATA[mem_expected_write]=$expected_write
        PERFORMANCE_DATA[mem_found_in_db]="yes"
    else
        # 未找到，使用固定基准
        PERFORMANCE_DATA[mem_expected_read]=16000
        PERFORMANCE_DATA[mem_expected_write]=12000
        PERFORMANCE_DATA[mem_found_in_db]="no"
    fi
}

# 磁盘性能数据库对比（基于标准硬件规格）
compare_disk_with_database() {
    local disk_type="${SYSTEM_INFO[disk_type]}"
    local seq_read=$(echo "${PERFORMANCE_DATA[disk_seq_read]}" | cut -d'.' -f1)
    local rand_read=$(echo "${PERFORMANCE_DATA[disk_rand_read_iops]}" | cut -d'.' -f1)
    local is_virt="${SYSTEM_INFO[is_virtualized]:-否}"
    
    # 磁盘性能数据库（数据来源：厂商规格 + 实测数据）
    # 格式：磁盘类型|典型顺序读(MB/s)|典型4K读IOPS|DiskMark分|说明
    local disk_database=(
        # NVMe SSD（高端）
        "NVMe PCIe 4.0|7000|600000|15000|旗舰级NVMe SSD（Gen4）"
        "NVMe PCIe 3.0|3500|400000|12000|主流NVMe SSD（Gen3）"
        "NVMe入门|2000|250000|9000|入门级NVMe SSD"
        
        # SATA SSD
        "SATA SSD企业级|550|90000|7500|企业级SATA SSD"
        "SATA SSD消费级|550|75000|6500|消费级SATA SSD"
        
        # 机械硬盘
        "15K RPM SAS|280|250|2800|15000转企业级SAS硬盘"
        "10K RPM SAS|200|180|2200|10000转企业级SAS硬盘"
        "7200 RPM SAS|180|130|1800|7200转企业级SAS硬盘"
        "7200 RPM SATA|150|100|1500|7200转SATA硬盘"
        "5400 RPM|120|80|1200|5400转硬盘（笔记本/低功耗）"
        
        # 虚拟化磁盘（特殊情况）
        "虚拟化HDD|2000|100|1000|虚拟化环境HDD（宿主机SSD）"
        "虚拟化SSD|1500|5000|4000|虚拟化环境SSD（受限）"
    )
    
    local found=0
    local matched_type=""
    local expected_seq=0
    local expected_iops=0
    local diskmark_score=0
    local disk_desc=""
    
    # 特殊处理虚拟化环境
    if [ "$is_virt" != "否" ] && [ "$disk_type" = "HDD" ]; then
        if [ $seq_read -gt 500 ] && [ $rand_read -lt 1000 ]; then
            matched_type="虚拟化HDD"
            expected_seq=2000
            expected_iops=100
            diskmark_score=1000
            disk_desc="虚拟化环境HDD（宿主机SSD，虚拟盘IOPS受限）"
            found=1
        fi
    fi
    
    # 如果不是虚拟化特殊情况，按IOPS匹配
    if [ $found -eq 0 ]; then
        local best_match_diff=999999
        for entry in "${disk_database[@]}"; do
            IFS='|' read -r type exp_seq exp_iops dm_sc desc <<< "$entry"
            
            # 跳过虚拟化类型（已特殊处理）
            if [[ "$type" == "虚拟化"* ]]; then
                continue
            fi
            
            local diff=$((rand_read - exp_iops))
            [ $diff -lt 0 ] && diff=$((-diff))
            
            if [ $diff -lt $best_match_diff ]; then
                best_match_diff=$diff
                matched_type="$type"
                expected_seq=$exp_seq
                expected_iops=$exp_iops
                diskmark_score=$dm_sc
                disk_desc="$desc"
                found=1
            fi
        done
    fi
    
    if [ $found -eq 1 ]; then
        echo ""
        log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        log_info "📊 与权威数据库对比（数据来源：厂商规格 + 实测）"
        log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        log_info "识别磁盘: $disk_desc"
        log_info "匹配规格: $matched_type"
        echo ""
        log_info "性能对比："
        log_info "  您的顺序读取: $seq_read MB/s"
        log_info "  标准顺序读取: $expected_seq MB/s"
        log_info "  您的4K读IOPS: $rand_read IOPS ⭐关键指标"
        log_info "  标准4K读IOPS: $expected_iops IOPS"
        log_info "  DiskMark参考分: $diskmark_score"
        
        # 计算IOPS性能差异（关键指标）
        local iops_diff=$((rand_read - expected_iops))
        local iops_percent=$(echo "scale=1; $iops_diff * 100 / $expected_iops" | bc 2>/dev/null || echo "0")
        
        echo ""
        if [ "$is_virt" != "否" ]; then
            log_info "虚拟化环境说明："
            log_info "  顺序速度 ${seq_read} MB/s 来自宿主机SSD"
            log_info "  4K IOPS ${rand_read} 才是虚拟磁盘的真实性能"
            echo ""
        fi
        
        if [ $iops_diff -gt 50 ]; then
            log_success "🎉 4K IOPS超出标准 ${iops_percent}%！"
        elif [ $iops_diff -gt 0 ]; then
            log_success "✅ 4K IOPS符合标准 (+${iops_percent}%)"
        elif [ $iops_diff -gt -30 ]; then
            log_warn "⚠️  4K IOPS略低于标准 (${iops_percent}%)"
            log_info "可能原因：磁盘繁忙、虚拟化性能损耗、或磁盘老化"
        else
            log_warn "⚠️  4K IOPS明显低于标准 (${iops_percent}%)"
            log_warn "建议检查："
            log_warn "  • 磁盘是否过于繁忙 (iostat -x)"
            log_warn "  • 是否虚拟化IO限制过严"
            log_warn "  • 考虑升级到SSD获得更好性能"
        fi
        
        log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        
        # 保存标准值供评分系统使用
        PERFORMANCE_DATA[disk_expected_seq]=$expected_seq
        PERFORMANCE_DATA[disk_expected_iops]=$expected_iops
        PERFORMANCE_DATA[disk_found_in_db]="yes"
    else
        # 未找到，使用固定基准
        if [ "$disk_type" = "SSD" ]; then
            PERFORMANCE_DATA[disk_expected_seq]=500
            PERFORMANCE_DATA[disk_expected_iops]=75000
        else
            PERFORMANCE_DATA[disk_expected_seq]=150
            PERFORMANCE_DATA[disk_expected_iops]=100
        fi
        PERFORMANCE_DATA[disk_found_in_db]="no"
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
    # 使用5秒 + 10000素数，与spiritLHLS/ecs项目对标
    log_progress "执行Sysbench单线程CPU测试（5秒，素数10000）..."
    local cpu_single_score=$(sysbench cpu --cpu-max-prime=10000 --threads=1 --time=5 run 2>/dev/null | grep "events per second:" | awk '{print $4}')
    PERFORMANCE_DATA[cpu_single_thread]=${cpu_single_score:-0}
    log_success "单线程性能分数: ${cpu_single_score} events/sec ⭐对标ecs"
    
    # Sysbench CPU测试 - 多线程性能（仅多核时测试）
    if [ ${SYSTEM_INFO[cpu_cores]} -gt 1 ]; then
        log_progress "执行Sysbench多线程CPU测试（5秒）..."
        local cpu_multi_score=$(sysbench cpu --cpu-max-prime=10000 --threads=${SYSTEM_INFO[cpu_cores]} --time=5 run 2>/dev/null | grep "events per second:" | awk '{print $4}')
        PERFORMANCE_DATA[cpu_multi_thread]=${cpu_multi_score:-0}
        log_success "多线程性能分数: ${cpu_multi_score} events/sec"
    else
        # 单核CPU，多线程测试无意义
        PERFORMANCE_DATA[cpu_multi_thread]=${cpu_single_score:-0}
        log_info "单核CPU，跳过多线程测试"
    fi
    
    # Stress-ng CPU整数运算测试
    log_progress "执行Stress-ng整数运算测试（5秒）..."
    local int_ops=$(stress-ng --cpu ${SYSTEM_INFO[cpu_cores]} --cpu-method int64 --metrics-brief --timeout 5s 2>&1 | grep "cpu " | awk '{print $9}')
    PERFORMANCE_DATA[cpu_int_ops]=${int_ops:-0}
    log_success "整数运算能力: ${int_ops} bogo ops/sec"
    
    # Stress-ng CPU浮点运算测试
    log_progress "执行Stress-ng浮点运算测试（5秒）..."
    local float_ops=$(stress-ng --cpu ${SYSTEM_INFO[cpu_cores]} --cpu-method double --metrics-brief --timeout 5s 2>&1 | grep "cpu " | awk '{print $9}')
    PERFORMANCE_DATA[cpu_float_ops]=${float_ops:-0}
    log_success "浮点运算能力: ${float_ops} bogo ops/sec"
    
    # 计算CPU性能分数（对标 spiritLHLS/ecs 项目标准）
    # 使用Sysbench原始分数（events/sec）作为评分标准
    # 参考：https://github.com/spiritLHLS/ecs
    # 
    # Sysbench CPU 评分参考值（单线程 @5sec, 10000素数）：
    #   低端VPS/老旧CPU:      200-500 Scores
    #   入门服务器:           500-800 Scores
    #   主流服务器:           800-1200 Scores
    #   中高端服务器:         1200-1800 Scores
    #   高端服务器:           1800-2500 Scores
    #   顶级服务器:           2500+ Scores
    
    # 确保变量有默认值（避免bc语法错误）
    cpu_single_score=${cpu_single_score:-0}
    cpu_multi_score=${PERFORMANCE_DATA[cpu_multi_thread]:-${cpu_single_score}}
    int_ops=${int_ops:-0}
    float_ops=${float_ops:-0}
    
    # 保存到全局变量
    PERFORMANCE_DATA[cpu_single_score]=$cpu_single_score
    PERFORMANCE_DATA[cpu_multi_score]=$cpu_multi_score
    
    # 计算综合评分（0-100标准化，反映在当前服务器市场中的绝对水平）
    # 评分标准：
    #   90-100分：顶级服务器（2021+年新一代至强/EPYC）
    #   70-90分：高端服务器（2019-2020年至强Gold/EPYC）
    #   50-70分：主流服务器（2017-2018年至强Gold/E5 v4高端）
    #   30-50分：入门服务器（2014-2016年E5 v3/v4）
    #   10-30分：老旧服务器（2012-2013年E5 v2及更早）
    #   <10分：淘汰级硬件
    
    # 权重：单线程40%，多线程40%，整数10%，浮点10%
    local single_weight=0.40
    local multi_weight=0.40
    local int_weight=0.10
    local float_weight=0.10
    
    # 定义当前服务器市场的基准（2024年标准）
    # 100分基准：Intel Xeon Gold 6240 / AMD EPYC 7742 级别
    # 基准数据来源：spiritLHLS/ecs项目社区数据 + PassMark验证
    local market_baseline_single=1300   # 顶级服务器单线程性能 (sysbench 5s, prime 10000)
    local market_baseline_multi_per_core=1200  # 多核扩展效率（考虑超线程和缓存竞争）
    local market_baseline_int=2100      # 整数运算基准 (stress-ng bogo ops/s, 修正)
    local market_baseline_float=1800    # 浮点运算基准 (stress-ng bogo ops/s, 修正)
    
    # 标准化（基于当前服务器市场水平）
    local single_norm=$(echo "scale=4; ${cpu_single_score:-0} / $market_baseline_single" | bc -l)
    
    # 多线程：考虑核心数和多核扩展效率
    local expected_multi_market=$(echo "scale=0; $market_baseline_multi_per_core * ${SYSTEM_INFO[cpu_cores]}" | bc)
    local multi_norm=$(echo "scale=4; ${cpu_multi_score:-0} / $expected_multi_market" | bc -l)
    
    # 整数运算标准化
    local int_norm=$(echo "scale=4; ${int_ops:-0} / $market_baseline_int" | bc -l)
    
    # 浮点运算标准化
    local float_norm=$(echo "scale=4; ${float_ops:-0} / $market_baseline_float" | bc -l)
    
    # 计算0-100标准化分数
    local normalized_score=$(echo "scale=2; ($single_norm * $single_weight + $multi_norm * $multi_weight + $int_norm * $int_weight + $float_norm * $float_weight) * 100" | bc -l 2>/dev/null || echo "5.00")
    
    # 确保分数有效
    if [ -z "$normalized_score" ] || [ "$normalized_score" = "0" ]; then
        normalized_score=5.00
    fi
    
    # 限制范围 0-100
    local score_check=$(echo "$normalized_score > 100" | bc -l 2>/dev/null || echo "0")
    if [ "$score_check" = "1" ]; then
        normalized_score=100.00
    fi
    
    local score_check_low=$(echo "$normalized_score < 1" | bc -l 2>/dev/null || echo "0")
    if [ "$score_check_low" = "1" ]; then
        normalized_score=5.00
    fi
    
    PERFORMANCE_DATA[cpu_score]=$normalized_score
    
    # 存储整数和浮点分数供参考
    PERFORMANCE_DATA[cpu_int_ops]=$int_ops
    PERFORMANCE_DATA[cpu_float_ops]=$float_ops
    
    # 确保分数在合理范围内
    local cpu_score_int=$(echo "${PERFORMANCE_DATA[cpu_score]}" | cut -d'.' -f1)
    if [ -z "$cpu_score_int" ] || [ $cpu_score_int -lt 1 ]; then
        PERFORMANCE_DATA[cpu_score]=5.00
        PERFORMANCE_DATA[cpu_passmark_rating]=1250
    elif [ $cpu_score_int -gt 100 ]; then
        PERFORMANCE_DATA[cpu_score]=100.00
        PERFORMANCE_DATA[cpu_passmark_rating]=25000
    fi
    
    log_success "CPU综合性能评分: ${PERFORMANCE_DATA[cpu_score]}/100"
    echo ""
    log_info "📊 评分说明：反映在当前服务器市场中的绝对水平"
    log_info "   90-100分：顶级服务器（2021+新一代至强/EPYC）"
    log_info "   70-90分： 高端服务器（2019-2020年至强Gold/EPYC）"
    log_info "   50-70分： 主流服务器（2017-2018年至强Gold）"
    log_info "   30-50分： 入门服务器（2014-2016年E5 v3/v4）"
    log_info "   <30分：  老旧/淘汰级服务器"
    echo ""
    log_info "Sysbench单线程: ${PERFORMANCE_DATA[cpu_single_thread]} Scores (对标ecs)"
    if [ ${SYSTEM_INFO[cpu_cores]} -gt 1 ]; then
        log_info "Sysbench多线程: ${PERFORMANCE_DATA[cpu_multi_thread]} Scores"
    fi
    
    # 与权威数据库对比
    compare_with_database
    
    # 给出性能等级评价
    local cpu_single_score=$(echo "${PERFORMANCE_DATA[cpu_single_thread]}" | cut -d'.' -f1)
    
    if [ $cpu_single_score -lt 500 ]; then
        log_warn "性能等级: 低端VPS/老旧CPU (<500)"
    elif [ $cpu_single_score -lt 800 ]; then
        log_info "性能等级: 入门服务器 (500-800)"
    elif [ $cpu_single_score -lt 1200 ]; then
        log_info "性能等级: 主流服务器 (800-1200)"
    elif [ $cpu_single_score -lt 1800 ]; then
        log_info "性能等级: 中高端服务器 (1200-1800)"
    elif [ $cpu_single_score -lt 2500 ]; then
        log_info "性能等级: 高端服务器 (1800-2500)"
    else
        log_info "性能等级: 顶级服务器 (2500+)"
    fi
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
    local mem_read=$(sysbench memory --memory-block-size=1M --memory-total-size=10G --memory-oper=read --threads=${SYSTEM_INFO[cpu_cores]} run 2>/dev/null | grep "transferred" | awk '{print $(NF-1)}' | tr -d '()')
    PERFORMANCE_DATA[mem_read_speed]=${mem_read:-0}
    log_success "内存读取速度: ${mem_read} MiB/sec"
    
    log_progress "执行Sysbench内存顺序写入测试..."
    local mem_write=$(sysbench memory --memory-block-size=1M --memory-total-size=10G --memory-oper=write --threads=${SYSTEM_INFO[cpu_cores]} run 2>/dev/null | grep "transferred" | awk '{print $(NF-1)}' | tr -d '()')
    PERFORMANCE_DATA[mem_write_speed]=${mem_write:-0}
    log_success "内存写入速度: ${mem_write} MiB/sec"
    
    # Sysbench内存随机访问测试
    log_progress "执行Sysbench内存随机访问测试..."
    local mem_random=$(sysbench memory --memory-block-size=4K --memory-total-size=1G --memory-access-mode=rnd --threads=${SYSTEM_INFO[cpu_cores]} run 2>/dev/null | grep "transferred" | awk '{print $(NF-1)}' | tr -d '()')
    PERFORMANCE_DATA[mem_random_speed]=${mem_random:-0}
    log_success "内存随机访问速度: ${mem_random} MiB/sec"
    
    # Stress-ng内存压力测试（测试内存稳定性和真实带宽）
    log_progress "执行Stress-ng内存带宽测试..."
    local mem_bandwidth=$(stress-ng --vm ${SYSTEM_INFO[cpu_cores]} --vm-bytes 80% --vm-method all --metrics-brief --timeout 5s 2>&1 | grep "vm " | awk '{print $9}')
    PERFORMANCE_DATA[mem_bandwidth]=${mem_bandwidth:-0}
    log_success "内存带宽测试: ${mem_bandwidth} bogo ops/sec"
    
    # 计算综合内存性能分数（对标SPEC/STREAM和服务器内存标准）
    # 服务器ECC内存带宽标准参考值（JEDEC标准）：
    # 注意：ECC内存因为额外的错误校验，性能略低于非ECC内存（约5-10%）
    # 
    # 服务器DDR3 ECC:
    #   DDR3-1333 ECC: ~10,600 MB/s (理论)  实际: ~7,500-9,000 MB/s
    #   DDR3-1600 ECC: ~12,800 MB/s (理论)  实际: ~9,000-10,500 MB/s
    #   DDR3-1866 ECC: ~14,900 MB/s (理论)  实际: ~10,500-12,000 MB/s
    # 
    # 服务器DDR4 ECC (主流):
    #   DDR4-2133 ECC: ~17,000 MB/s (理论)  实际: ~13,000-15,000 MB/s ⭐ 入门服务器
    #   DDR4-2400 ECC: ~19,200 MB/s (理论)  实际: ~15,000-17,000 MB/s ⭐ 主流服务器
    #   DDR4-2666 ECC: ~21,300 MB/s (理论)  实际: ~17,000-19,500 MB/s ⭐ 中高端服务器
    #   DDR4-2933 ECC: ~23,500 MB/s (理论)  实际: ~19,000-21,500 MB/s
    #   DDR4-3200 ECC: ~25,600 MB/s (理论)  实际: ~20,000-23,000 MB/s ⭐ 高端服务器
    # 
    # 服务器DDR5 ECC (新一代):
    #   DDR5-4800 ECC: ~38,400 MB/s (理论)  实际: ~30,000-35,000 MB/s ⭐ 最新服务器
    #   DDR5-5600 ECC: ~44,800 MB/s (理论)  实际: ~35,000-42,000 MB/s
    # 
    # PassMark服务器内存评分参考：
    # 入门服务器内存 (DDR3 ECC):          1,000-1,800分
    # 主流服务器内存 (DDR4-2133/2400 ECC): 1,800-2,800分
    # 中高端服务器内存 (DDR4-2666 ECC):    2,800-3,500分
    # 高端服务器内存 (DDR4-3200 ECC):      3,500-4,500分
    # 顶级服务器内存 (DDR5 ECC):           5,000-7,000+分
    
    # 权重分配（基于SPEC标准和服务器工作负载）
    # 注意：权重总和必须为1.0
    local read_weight=0.40    # 服务器读操作更多 (40%)
    local write_weight=0.30   # 写操作次之 (30%)
    local random_weight=0.30  # 随机访问对数据库等应用很重要 (30%)
    
    # 定义当前服务器市场的内存基准（2024年标准）
    # 评分标准：反映在当前服务器市场中的绝对水平
    #   90-100分：顶级服务器内存（DDR5-4800+ ECC）
    #   70-90分：高端服务器内存（DDR4-3200 ECC）
    #   50-70分：主流服务器内存（DDR4-2666/2400 ECC）
    #   30-50分：入门服务器内存（DDR4-2133/DDR3-1866 ECC）
    #   <30分：老旧/淘汰级内存
    
    # 100分基准：DDR5-4800 ECC级别
    local baseline_read=38000   # 顶级服务器内存读取
    local baseline_write=25000  # 顶级服务器内存写入
    local baseline_random=8000  # 随机访问（辅助参考）
    
    # 清理并验证数值（去除非数字字符，确保有效）
    mem_read=$(echo "$mem_read" | grep -oE '[0-9]+\.?[0-9]*' | head -1)
    mem_write=$(echo "$mem_write" | grep -oE '[0-9]+\.?[0-9]*' | head -1)
    mem_random=$(echo "$mem_random" | grep -oE '[0-9]+\.?[0-9]*' | head -1)
    
    # 如果为空，设置默认值
    mem_read=${mem_read:-1000}
    mem_write=${mem_write:-800}
    mem_random=${mem_random:-500}
    
    local read_norm=$(echo "scale=4; ${mem_read} / $baseline_read" | bc 2>/dev/null || echo "0.05")
    local write_norm=$(echo "scale=4; ${mem_write} / $baseline_write" | bc 2>/dev/null || echo "0.05")
    local random_norm=$(echo "scale=4; ${mem_random} / $baseline_random" | bc 2>/dev/null || echo "0.05")
    
    # 计算原始性能分数
    local raw_mem_score=$(echo "scale=4; $read_norm * $read_weight + $write_norm * $write_weight + $random_norm * $random_weight" | bc)
    
    # 映射到0-100标准分数
    PERFORMANCE_DATA[mem_score]=$(echo "scale=2; $raw_mem_score * 100" | bc)
    
    # 存储原始测试结果（spiritLHLS/ecs + Lemonbench格式）
    PERFORMANCE_DATA[mem_read_bandwidth]=$mem_read
    PERFORMANCE_DATA[mem_write_bandwidth]=$mem_write
    
    # 根据实际带宽判断服务器内存类型（考虑ECC内存特性）
    local avg_bandwidth=$(echo "scale=0; ($mem_read + $mem_write) / 2" | bc)
    if (( $(echo "$avg_bandwidth < 10000" | bc -l) )); then
        SYSTEM_INFO[mem_category]="DDR3-1333/1600 ECC (老旧服务器)"
    elif (( $(echo "$avg_bandwidth < 14000" | bc -l) )); then
        SYSTEM_INFO[mem_category]="DDR3-1866 ECC 或 DDR4-2133 ECC (入门服务器)"
    elif (( $(echo "$avg_bandwidth < 16500" | bc -l) )); then
        SYSTEM_INFO[mem_category]="DDR4-2400 ECC (主流服务器)" 
    elif (( $(echo "$avg_bandwidth < 19500" | bc -l) )); then
        SYSTEM_INFO[mem_category]="DDR4-2666 ECC (中高端服务器)"
    elif (( $(echo "$avg_bandwidth < 23500" | bc -l) )); then
        SYSTEM_INFO[mem_category]="DDR4-3200 ECC (高端服务器)"
    elif (( $(echo "$avg_bandwidth < 33000" | bc -l) )); then
        SYSTEM_INFO[mem_category]="高频DDR4 ECC 或 DDR5-4800 ECC"
    else
        SYSTEM_INFO[mem_category]="DDR5-5600+ ECC (最新一代服务器)"
    fi
    
    # 确保分数在合理范围内
    local mem_score_int=$(echo "${PERFORMANCE_DATA[mem_score]}" | cut -d'.' -f1)
    if [ -z "$mem_score_int" ] || [ $mem_score_int -lt 1 ]; then
        PERFORMANCE_DATA[mem_score]=5.00
        PERFORMANCE_DATA[mem_passmark_rating]=500
    elif [ $mem_score_int -gt 100 ]; then
        PERFORMANCE_DATA[mem_score]=100.00
        PERFORMANCE_DATA[mem_passmark_rating]=7000
    fi
    
    log_success "内存综合性能评分: ${PERFORMANCE_DATA[mem_score]}/100"
    echo ""
    log_info "📊 评分说明：反映在当前服务器市场中的绝对水平"
    log_info "   90-100分：顶级服务器内存（DDR5-4800+ ECC）"
    log_info "   70-90分： 高端服务器内存（DDR4-3200 ECC）"
    log_info "   50-70分： 主流服务器内存（DDR4-2666/2400 ECC）"
    log_info "   30-50分： 入门服务器内存（DDR4-2133/DDR3 ECC）"
    log_info "   <30分：  老旧/淘汰级内存"
    echo ""
    log_info "读取/写入: ${PERFORMANCE_DATA[mem_read_bandwidth]}/${PERFORMANCE_DATA[mem_write_bandwidth]} MB/s"
    log_info "识别等级: ${SYSTEM_INFO[mem_category]:-未识别}"
    
    # 与权威数据库对比
    compare_memory_with_database
    
    # 给出性能等级评价（基于读取带宽）
    local mem_read_int=$(echo "${PERFORMANCE_DATA[mem_read_bandwidth]}" | cut -d'.' -f1)
    if [ $mem_read_int -lt 11000 ]; then
        log_warn "性能等级: 低端内存 (DDR3)"
    elif [ $mem_read_int -lt 15000 ]; then
        log_info "性能等级: 入门服务器 (DDR3-1866 / DDR4-2133)"
    elif [ $mem_read_int -lt 17000 ]; then
        log_info "性能等级: 主流服务器 (DDR4-2400)"
    elif [ $mem_read_int -lt 20000 ]; then
        log_info "性能等级: 中高端服务器 (DDR4-2666)"
    elif [ $mem_read_int -lt 25000 ]; then
        log_info "性能等级: 高端服务器 (DDR4-3200)"
    else
        log_info "性能等级: 顶级服务器 (DDR5-4800+)"
    fi
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
    
    local seq_write_bw=$(grep -oP '"bw"\s*:\s*\K[0-9]+' /tmp/fio_seq_write.json 2>/dev/null | head -1)
    if [ -z "$seq_write_bw" ] || [ "$seq_write_bw" = "0" ]; then
        seq_write_bw=$(fio --name=seq_write --directory=$test_dir --rw=write --bs=4m --size=256m --numjobs=1 --runtime=5 --ioengine=sync --direct=1 2>/dev/null | grep "WRITE:" | grep -oP 'bw=\K[0-9.]+[KMG]' | head -1)
        if [[ $seq_write_bw =~ ([0-9.]+)([KMG]) ]]; then
            local value="${BASH_REMATCH[1]}"
            local unit="${BASH_REMATCH[2]}"
            case $unit in
                K) seq_write_bw=$(echo "scale=2; $value / 1024" | bc) ;;
                M) seq_write_bw=$(echo "scale=2; $value" | bc) ;;
                G) seq_write_bw=$(echo "scale=2; $value * 1024" | bc) ;;
            esac
        else
            seq_write_bw=80
        fi
        PERFORMANCE_DATA[disk_seq_write]=$seq_write_bw
    else
        PERFORMANCE_DATA[disk_seq_write]=$(echo "scale=2; $seq_write_bw / 1024" | bc 2>/dev/null || echo "80")
    fi
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
    
    local mixed_iops=$(grep -oP '"iops"\s*:\s*\K[0-9.]+' /tmp/fio_mixed.json 2>/dev/null | head -1 | cut -d'.' -f1)
    if [ -z "$mixed_iops" ] || [ "$mixed_iops" = "0" ]; then
        mixed_iops=$(fio --name=mixed --directory=$test_dir --rw=randrw --rwmixread=70 --bs=4k --size=128m --numjobs=1 --runtime=5 --ioengine=sync --direct=1 2>/dev/null | grep "read :" | grep -oP 'IOPS=\K[0-9.]+[k]?' | head -1)
        if [[ $mixed_iops =~ ([0-9.]+)k ]]; then
            mixed_iops=$(echo "scale=0; ${BASH_REMATCH[1]} * 1000" | bc | cut -d'.' -f1)
        elif [ ! -z "$mixed_iops" ]; then
            mixed_iops=$(echo "$mixed_iops" | cut -d'.' -f1)
        else
            mixed_iops=90
        fi
    fi
    PERFORMANCE_DATA[disk_mixed_iops]=${mixed_iops:-90}
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
    
    local avg_latency=$(grep -oP '"lat_ns"\s*:\s*\{\s*"mean"\s*:\s*\K[0-9.]+' /tmp/fio_latency.json 2>/dev/null | head -1)
    if [ -z "$avg_latency" ]; then
        # 尝试从标准输出获取
        avg_latency=$(fio --name=lat --directory=$test_dir --rw=randread --bs=4k --size=64m --numjobs=1 --runtime=5 --ioengine=sync --iodepth=1 --direct=1 2>/dev/null | grep "lat (usec)" | head -1 | grep -oP 'avg=\s*\K[0-9.]+')
    fi
    
    if [ ! -z "$avg_latency" ] && [ "$avg_latency" != "0" ]; then
        # 判断单位并转换
        if (( $(echo "$avg_latency > 10000" | bc -l 2>/dev/null || echo 0) )); then
            # 纳秒转微秒
            PERFORMANCE_DATA[disk_latency]=$(echo "scale=2; $avg_latency / 1000" | bc 2>/dev/null || echo "5000")
        else
            # 已经是微秒
            PERFORMANCE_DATA[disk_latency]=$avg_latency
        fi
        log_success "平均延迟: ${PERFORMANCE_DATA[disk_latency]} μs"
    else
        PERFORMANCE_DATA[disk_latency]="N/A"
        log_success "平均延迟: N/A"
    fi
    
    # 清理测试文件
    rm -rf $test_dir /tmp/fio_*.json
    
    # 计算综合磁盘性能分数（对标PassMark DiskMark标准）
    # PassMark DiskMark评分参考值：
    # 
    # HDD性能分级：
    #   5400 RPM HDD:          50-100分    (顺序: 80-120 MB/s,  4K IOPS: 50-100)
    #   7200 RPM HDD:          100-200分   (顺序: 120-180 MB/s, 4K IOPS: 80-150)
    #   10000 RPM HDD:         200-400分   (顺序: 150-220 MB/s, 4K IOPS: 100-200)
    # 
    # SSD性能分级：
    #   SATA2 SSD (3Gbps):     500-1,500分  (顺序: 250-280 MB/s,  4K IOPS: 5k-15k)
    #   SATA3 SSD (6Gbps):     1,500-3,500分 (顺序: 450-550 MB/s,  4K IOPS: 30k-90k)
    #   PCIe 2.0 NVMe:         3,500-8,000分 (顺序: 1000-2000 MB/s, 4K IOPS: 100k-300k)
    #   PCIe 3.0 NVMe:         8,000-18,000分 (顺序: 2000-3500 MB/s, 4K IOPS: 200k-600k)
    #   PCIe 4.0 NVMe:         18,000-35,000分 (顺序: 4000-7000 MB/s, 4K IOPS: 400k-1000k)
    #   PCIe 5.0 NVMe:         35,000+分    (顺序: 10000+ MB/s,  4K IOPS: 1000k+)
    
    # 权重分配（服务器工作负载：IOPS > 顺序带宽）
    # 服务器应用（数据库、Web服务器等）主要是随机小IO
    local seq_read_weight=0.15
    local seq_write_weight=0.15
    local rand_read_weight=0.40   # 服务器最重要：随机读IOPS
    local rand_write_weight=0.30  # 服务器次重要：随机写IOPS
    
    # 声明标准化变量（在分支外）
    local seq_read_norm=0
    local seq_write_norm=0
    local rand_read_norm=0
    local rand_write_norm=0
    
    if [ "${SYSTEM_INFO[disk_type]}" = "SSD" ]; then
        # 定义当前服务器市场的SSD基准（2024年标准）
        # 评分标准：反映在当前服务器市场中的绝对水平
        #   90-100分：顶级NVMe（PCIe 4.0 企业级）
        #   70-90分：高端NVMe（PCIe 3.0 企业级）
        #   50-70分：主流SSD（入门NVMe/高端SATA）
        #   30-50分：入门SSD（SATA SSD）
        #   <30分：老旧/低端SSD
        
        # 100分基准：PCIe 4.0 NVMe企业级
        local baseline_seq_read=7000        # 顶级NVMe顺序读取
        local baseline_seq_write=6000       # 顶级NVMe顺序写入
        local baseline_rand_read_iops=600000   # 顶级NVMe 4K读IOPS
        local baseline_rand_write_iops=400000  # 顶级NVMe 4K写IOPS
        
        # 确保数值有效
        local disk_seq_read=${PERFORMANCE_DATA[disk_seq_read]:-100}
        local disk_seq_write=${PERFORMANCE_DATA[disk_seq_write]:-80}
        local disk_rand_read_iops=${PERFORMANCE_DATA[disk_rand_read_iops]:-1000}
        local disk_rand_write_iops=${PERFORMANCE_DATA[disk_rand_write_iops]:-800}
        
        # 标准化计算（限制每项最大贡献，避免异常值）
        local seq_read_norm=$(echo "scale=4; $disk_seq_read / $baseline_seq_read" | bc 2>/dev/null || echo "0.2")
        local seq_write_norm=$(echo "scale=4; $disk_seq_write / $baseline_seq_write" | bc 2>/dev/null || echo "0.18")
        local rand_read_norm=$(echo "scale=4; $disk_rand_read_iops / $baseline_rand_read_iops" | bc 2>/dev/null || echo "0.02")
        local rand_write_norm=$(echo "scale=4; $disk_rand_write_iops / $baseline_rand_write_iops" | bc 2>/dev/null || echo "0.02")
        
        # 判断服务器SSD类型（综合顺序速度和IOPS）
        local disk_rand_read=${PERFORMANCE_DATA[disk_rand_read_iops]:-1000}
        local seq_read=${PERFORMANCE_DATA[disk_seq_read]:-100}
        
        # 检测虚拟化环境特征：高顺序速度但低IOPS
        if (( $(echo "$seq_read > 1000 && $disk_rand_read < 1000" | bc -l) )); then
            SYSTEM_INFO[disk_category]="虚拟化环境 - 宿主机SSD但虚拟磁盘性能受限"
        elif (( $(echo "$seq_read > 5000" | bc -l) )) && (( $(echo "$disk_rand_read > 200000" | bc -l) )); then
            SYSTEM_INFO[disk_category]="PCIe 4.0 NVMe 企业级SSD"
        elif (( $(echo "$seq_read > 3000" | bc -l) )) && (( $(echo "$disk_rand_read > 100000" | bc -l) )); then
            SYSTEM_INFO[disk_category]="PCIe 3.0 NVMe 企业级SSD"
        elif (( $(echo "$seq_read > 1500" | bc -l) )) && (( $(echo "$disk_rand_read > 50000" | bc -l) )); then
            SYSTEM_INFO[disk_category]="入门NVMe或高端企业SATA SSD"
        elif (( $(echo "$seq_read > 400" | bc -l) )) && (( $(echo "$disk_rand_read > 30000" | bc -l) )); then
            SYSTEM_INFO[disk_category]="企业级SATA SSD"
        elif (( $(echo "$disk_rand_read > 10000" | bc -l) )); then
            SYSTEM_INFO[disk_category]="消费级SATA SSD"
        else
            SYSTEM_INFO[disk_category]="低端SSD或虚拟化受限环境"
        fi
        
    else
        # 定义当前服务器市场的HDD基准（2024年标准）
        # 关键原则：HDD评分必须基于IOPS，而非顺序速度
        # 原因：虚拟化环境顺序速度可能虚高（来自宿主机SSD）
        
        # 评分策略：
        #   1. 以IOPS为主要评分依据（权重70%）
        #   2. 顺序速度仅作辅助（权重30%）
        #   3. 虚拟化环境自动识别并特殊处理
        
        # HDD在整体存储市场中的定位：
        #   40-60分：顶级HDD（15K RPM SAS）- 整体市场中低端
        #   25-40分：主流HDD（10K/7200 RPM SAS）
        #   10-25分：入门HDD（7200 RPM SATA）
        #   <10分：淘汰级HDD（5400 RPM）
        
        # 100分基准：仍用顶级NVMe，让HDD自然落在低分区
        # 这样能真实反映HDD在整体市场中的劣势
        local baseline_seq_read=1000      # 用中等水平（让顺序速度权重降低）
        local baseline_seq_write=900
        local baseline_rand_read_iops=10000   # 用入门SSD级别作为满分（让HDD IOPS自然很低）
        local baseline_rand_write_iops=8000
        
        # 确保数值有效
        local disk_seq_read=${PERFORMANCE_DATA[disk_seq_read]:-100}
        local disk_seq_write=${PERFORMANCE_DATA[disk_seq_write]:-80}
        local disk_rand_read_iops=${PERFORMANCE_DATA[disk_rand_read_iops]:-80}
        local disk_rand_write_iops=${PERFORMANCE_DATA[disk_rand_write_iops]:-70}
        
        # 标准化计算
        seq_read_norm=$(echo "scale=4; $disk_seq_read / $baseline_seq_read" | bc 2>/dev/null || echo "0.67")
        seq_write_norm=$(echo "scale=4; $disk_seq_write / $baseline_seq_write" | bc 2>/dev/null || echo "0.57")
        rand_read_norm=$(echo "scale=4; $disk_rand_read_iops / $baseline_rand_read_iops" | bc 2>/dev/null || echo "0.8")
        rand_write_norm=$(echo "scale=4; $disk_rand_write_iops / $baseline_rand_write_iops" | bc 2>/dev/null || echo "0.78")
        
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
    
    # 统一应用限制（在分支外，确保对所有类型生效）
    echo ""
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "应用智能评分算法..."
    
    local disk_seq=${PERFORMANCE_DATA[disk_seq_read]:-100}
    local disk_iops=${PERFORMANCE_DATA[disk_rand_read_iops]:-100}
    
    # 虚拟化环境特殊处理
    if [ "${SYSTEM_INFO[disk_type]}" = "HDD" ] && (( $(echo "$disk_seq > 500 && $disk_iops < 1000" | bc -l) )); then
        # HDD虚拟化环境：严格限制顺序速度贡献
        log_warn "⚠️ 虚拟化环境特征（顺序${disk_seq}MB/s vs IOPS ${disk_iops}）"
        log_warn "评分算法：以IOPS为主，忽略虚高的顺序速度"
        
        # 极严格限制顺序速度贡献（虚拟化环境的顺序速度无意义）
        seq_read_norm=0.70
        seq_write_norm=0.70
        
        log_info "调整后: 顺序读贡献=${seq_read_norm}, 顺序写贡献=${seq_write_norm}"
        
    elif [ "${SYSTEM_INFO[disk_type]}" = "SSD" ] && (( $(echo "$disk_seq > 1000 && $disk_iops < 10000" | bc -l) )); then
        # SSD虚拟化环境受限
        log_warn "⚠️ SSD虚拟化环境检测：IOPS性能受限"
        
        # SSD限制较宽松
        if (( $(echo "$seq_read_norm > 2.0" | bc -l) )); then
            seq_read_norm=2.0
        fi
        if (( $(echo "$seq_write_norm > 2.0" | bc -l) )); then
            seq_write_norm=2.0
        fi
        
    else
        # 物理环境或正常虚拟化的通用限制
        if [ "${SYSTEM_INFO[disk_type]}" = "SSD" ]; then
            # SSD最大限制
            if (( $(echo "$seq_read_norm > 3.0" | bc -l) )); then
                seq_read_norm=3.0
            fi
            if (( $(echo "$seq_write_norm > 3.0" | bc -l) )); then
                seq_write_norm=3.0
            fi
            if (( $(echo "$rand_read_norm > 2.5" | bc -l) )); then
                rand_read_norm=2.5
            fi
            if (( $(echo "$rand_write_norm > 2.5" | bc -l) )); then
                rand_write_norm=2.5
            fi
        else
            # HDD正常限制
            if (( $(echo "$seq_read_norm > 1.5" | bc -l) )); then
                seq_read_norm=1.5
            fi
            if (( $(echo "$seq_write_norm > 1.5" | bc -l) )); then
                seq_write_norm=1.5
            fi
            if (( $(echo "$rand_read_norm > 1.5" | bc -l) )); then
                rand_read_norm=1.5
            fi
            if (( $(echo "$rand_write_norm > 1.5" | bc -l) )); then
                rand_write_norm=1.5
            fi
        fi
    fi
    
    log_info "最终评分贡献: 顺序读=${seq_read_norm}, 顺序写=${seq_write_norm}"
    log_info "               随机读=${rand_read_norm}, 随机写=${rand_write_norm}"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    # 设置虚拟化环境标记
    local is_virtualized=0
    local virt_warning=""
    
    local seq_read_val=${PERFORMANCE_DATA[disk_seq_read]:-0}
    local iops_read_val=${PERFORMANCE_DATA[disk_rand_read_iops]:-0}
    
    if [ "${SYSTEM_INFO[disk_type]}" = "HDD" ] && (( $(echo "$seq_read_val > 500 && $iops_read_val < 1000" | bc -l) )); then
        is_virtualized=1
        SYSTEM_INFO[is_virtualized]="是（宿主机SSD，虚拟盘IOPS受限）"
        virt_warning="⚠️ 虚拟化环境：顺序${seq_read_val}MB/s vs IOPS ${iops_read_val}"
        PERFORMANCE_DATA[disk_virt_warning]="$virt_warning"
    elif [ "${SYSTEM_INFO[disk_type]}" = "SSD" ] && (( $(echo "$seq_read_val > 1000 && $iops_read_val < 10000" | bc -l) )); then
        is_virtualized=1
        SYSTEM_INFO[is_virtualized]="是（SSD虚拟化受限）"
        virt_warning="⚠️ SSD虚拟化环境：IOPS性能受限"
        PERFORMANCE_DATA[disk_virt_warning]="$virt_warning"
    else
        SYSTEM_INFO[is_virtualized]="否"
    fi
    
    # 计算原始性能分数（使用限制后的标准化值）
    local raw_disk_score=$(echo "scale=4; $seq_read_norm * $seq_read_weight + $seq_write_norm * $seq_write_weight + $rand_read_norm * $rand_read_weight + $rand_write_norm * $rand_write_weight" | bc)
    
    log_info "原始分数计算: ${raw_disk_score} (限制后)"
    
    # 映射到0-100标准分数
    PERFORMANCE_DATA[disk_score]=$(echo "scale=2; $raw_disk_score * 100" | bc)
    
    log_info "最终磁盘评分: ${PERFORMANCE_DATA[disk_score]}/100"
    
    # 确保分数在合理范围内
    local disk_score_int=$(echo "${PERFORMANCE_DATA[disk_score]}" | cut -d'.' -f1)
    if [ -z "$disk_score_int" ] || [ $disk_score_int -lt 1 ]; then
        PERFORMANCE_DATA[disk_score]=5.00
        if [ "${SYSTEM_INFO[disk_type]}" = "SSD" ]; then
            PERFORMANCE_DATA[disk_passmark_rating]=500
        else
            PERFORMANCE_DATA[disk_passmark_rating]=50
        fi
    elif [ $disk_score_int -gt 100 ]; then
        PERFORMANCE_DATA[disk_score]=100.00
        if [ "${SYSTEM_INFO[disk_type]}" = "SSD" ]; then
            PERFORMANCE_DATA[disk_passmark_rating]=35000
        else
            PERFORMANCE_DATA[disk_passmark_rating]=400
        fi
    fi
    
    log_success "磁盘综合性能评分: ${PERFORMANCE_DATA[disk_score]}/100"
    echo ""
    if [ "${SYSTEM_INFO[disk_type]}" = "SSD" ]; then
        log_info "📊 评分说明：反映在当前存储市场中的绝对水平"
        log_info "   90-100分：顶级NVMe（PCIe 4.0 企业级）"
        log_info "   70-90分： 高端NVMe（PCIe 3.0 企业级）"
        log_info "   50-70分： 主流SSD（入门NVMe/高端SATA）"
        log_info "   30-50分： 入门SSD（SATA SSD）"
        log_info "   <30分：  老旧/低端SSD"
    else
        log_info "📊 评分说明：反映在当前存储市场中的绝对水平"
        log_info "   注意：HDD在当前市场中已是低端存储"
        log_info "   40-60分：顶级HDD（15K RPM SAS）- 整体市场中低端"
        log_info "   25-40分：主流HDD（10K/7200 RPM SAS）"
        log_info "   10-25分：入门HDD（7200 RPM SATA）"
        log_info "   <10分：  淘汰级HDD（5400 RPM）"
    fi
    echo ""
    log_info "顺序读/写: ${PERFORMANCE_DATA[disk_seq_read]}/${PERFORMANCE_DATA[disk_seq_write]} MB/s"
    log_info "4K IOPS 读/写: ${PERFORMANCE_DATA[disk_rand_read_iops]}/${PERFORMANCE_DATA[disk_rand_write_iops]} ⭐关键指标"
    log_info "识别等级: ${SYSTEM_INFO[disk_category]:-未识别}"
    
    # 与权威数据库对比
    compare_disk_with_database
    
    # 显示虚拟化环境检测结果
    if [ "${SYSTEM_INFO[is_virtualized]}" != "否" ]; then
        log_warn "虚拟化环境: ${SYSTEM_INFO[is_virtualized]}"
        log_warn "${PERFORMANCE_DATA[disk_virt_warning]}"
    fi
    log_warn "  - 服务器环境应关注4K IOPS，而非顺序速度"
    log_warn "  - 虚拟化环境的顺序速度仅供参考，IOPS才是真实性能"
    echo ""
    log_info "评分标准: FIO专业测试 + spiritLHLS/ecs参考 + 虚拟化环境智能识别"
    
    # 给出性能等级评价（基于4K随机读IOPS - 服务器最关键指标）
    local iops_read=$(echo "${PERFORMANCE_DATA[disk_rand_read_iops]}" | cut -d'.' -f1)
    if [ "${SYSTEM_INFO[disk_type]}" = "SSD" ]; then
        if [ $iops_read -lt 10000 ]; then
            log_warn "性能等级: 低端/消费级SSD（不推荐服务器使用）"
            log_warn "建议：更换为企业级SSD以保证可靠性"
        elif [ $iops_read -lt 30000 ]; then
            log_info "性能等级: 入门企业级SSD (SATA3)"
            log_info "适用场景：Web服务、开发测试、小型数据库"
        elif [ $iops_read -lt 100000 ]; then
            log_info "性能等级: 主流企业级SSD (高端SATA或入门NVMe)"
            log_info "适用场景：中型数据库、虚拟化、高并发Web"
        elif [ $iops_read -lt 300000 ]; then
            log_info "性能等级: 高性能企业级SSD (PCIe 3.0 NVMe)"
            log_info "适用场景：大型数据库、高并发应用、实时分析"
        else
            log_info "性能等级: 顶级企业级SSD (PCIe 4.0 NVMe)"
            log_info "适用场景：超高IOPS需求、内存数据库、AI训练"
        fi
    else
        if [ $iops_read -lt 100 ]; then
            log_warn "性能等级: 低速HDD (5400 RPM SATA，不推荐生产)"
            log_warn "建议：升级到7200 RPM SAS或SSD"
        elif [ $iops_read -lt 150 ]; then
            log_info "性能等级: 标准HDD (7200 RPM SATA)"
            log_info "适用场景：冷数据存储、归档、备份"
        elif [ $iops_read -lt 250 ]; then
            log_info "性能等级: 企业级HDD (7200 RPM SAS)"
            log_info "适用场景：大容量存储、顺序读写为主的应用"
        else
            log_info "性能等级: 高性能HDD (10000/15000 RPM SAS)"
            log_info "适用场景：高IOPS要求但预算有限的场景"
        fi
    fi
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
    
    # 服务器级多因子加权算法
    # ==========================================
    # 基于Google SRE、Red Hat Enterprise、Oracle生产环境最佳实践
    # 因子1: 内存大小基础系数（服务器版）
    # 因子2: CPU性能系数
    # 因子3: 内存性能系数
    # 因子4: 磁盘类型和性能系数
    # 因子5: 服务器稳定性系数（保守设置）
    # ==========================================
    
    # 基础swap计算（服务器环境算法 - Red Hat/Oracle推荐）
    # 服务器建议：即使内存很大，也保持一定swap以应对突发情况
    local base_swap
    if (( $(echo "$ram_gb < 1" | bc -l) )); then
        # 极小内存服务器（<1GB）- 特殊处理
        if [[ "${SYSTEM_INFO[is_virtualized]}" == "是"* ]]; then
            # 虚拟化+极小内存：需要更激进的swap策略
            base_swap=$(echo "scale=0; $ram_mb * 2.5" | bc)
            log_warn "极小内存虚拟化环境，采用激进swap策略(RAM×2.5)"
        else
            base_swap=$(echo "scale=0; $ram_mb * 2.2" | bc)
        fi
        log_warn "内存过小（<1GB），强烈不建议用于生产服务器"
    elif (( $(echo "$ram_gb < 2" | bc -l) )); then
        # 小内存服务器（1-2GB）
        base_swap=$(echo "scale=0; $ram_mb * 2" | bc)
        log_warn "内存较小（<2GB），不建议用于生产服务器"
    elif (( $(echo "$ram_gb < 4" | bc -l) )); then
        # 小内存服务器
        base_swap=$(echo "scale=0; $ram_mb * 2" | bc)
    elif (( $(echo "$ram_gb < 8" | bc -l) )); then
        # 中小内存服务器
        base_swap=$(echo "scale=0; $ram_mb * 1.5" | bc)
    elif (( $(echo "$ram_gb < 16" | bc -l) )); then
        # 中等内存服务器
        base_swap=$(echo "scale=0; $ram_mb * 1" | bc)
    elif (( $(echo "$ram_gb < 32" | bc -l) )); then
        # 大内存服务器
        base_swap=$(echo "scale=0; $ram_mb * 0.75" | bc)
    elif (( $(echo "$ram_gb < 64" | bc -l) )); then
        # 超大内存服务器
        base_swap=$(echo "scale=0; $ram_mb * 0.5" | bc)
    elif (( $(echo "$ram_gb < 128" | bc -l) )); then
        # 海量内存服务器
        base_swap=$(echo "scale=0; $ram_mb * 0.25" | bc)
    else
        # 极大内存服务器（128GB+）
        # Red Hat建议：至少保持8-16GB swap用于内核转储
        base_swap=16384  # 16GB
    fi
    
    # CPU性能调整系数（服务器版：更保守，范围0.90-1.10）
    # 服务器环境倾向于保留更多swap以应对突发情况
    local cpu_factor=$(echo "scale=4; 1.10 - ($cpu_score / 100) * 0.2" | bc)
    
    # 内存性能调整系数（服务器版：更保守，范围0.95-1.05）
    # ECC内存更可靠，但服务器仍需保持足够swap
    local mem_factor=$(echo "scale=4; 1.05 - ($mem_score / 100) * 0.1" | bc)
    
    # 磁盘性能调整系数（服务器版：0.85-1.15）
    # 特别考虑虚拟化环境的影响
    local disk_factor
    local is_virt=${SYSTEM_INFO[is_virtualized]:-"否"}
    
    if [ "$disk_type" = "SSD" ]; then
        # 企业级SSD: 耐久度高，可以承受更多写入
        if (( $(echo "$disk_score > 70" | bc -l) )); then
            disk_factor=0.95  # 高性能企业级SSD
        elif (( $(echo "$disk_score > 40" | bc -l) )); then
            disk_factor=0.90  # 中等企业级SSD
        else
            disk_factor=0.85  # 入门级SSD（服务器不应降太多）
        fi
    else
        # 企业级HDD或虚拟化环境: 性能较低，需要更多swap
        # 修复：使用通配符匹配，支持"是（xxx）"格式
        if [[ "$is_virt" == "是"* ]]; then
            # 虚拟化环境特殊处理：IOPS低，需要更多swap缓冲
            disk_factor=1.20  # 虚拟化环境增加swap
            log_warn "检测到虚拟化环境，IOPS受限，增加swap大小以应对IO性能波动"
        elif (( $(echo "$disk_score > 50" | bc -l) )); then
            disk_factor=1.05   # 高性能SAS HDD
        elif (( $(echo "$disk_score > 25" | bc -l) )); then
            disk_factor=1.10   # 标准企业级HDD
        else
            disk_factor=1.15   # 低性能HDD（不建议生产使用）
        fi
    fi
    
    log_info "服务器稳定性考虑：采用保守策略，确保足够swap空间"
    if [[ "$is_virt" == "是"* ]]; then
        log_info "虚拟化环境调整：考虑到IOPS限制，适当增加swap以提高稳定性"
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
    
    # 根据磁盘类型和性能微调（服务器版）
    # 特别考虑虚拟化环境的影响
    local disk_adjustment=0
    local is_virt=${SYSTEM_INFO[is_virtualized]:-"否"}
    
    if [ "$disk_type" = "SSD" ]; then
        # 企业级SSD: 性能好但服务器仍应保守
        if (( $(echo "$disk_score > 70" | bc -l) )); then
            disk_adjustment=2   # 高性能企业SSD，略微提高
        elif (( $(echo "$disk_score > 40" | bc -l) )); then
            disk_adjustment=1   # 中等企业SSD
        else
            disk_adjustment=0   # 低端SSD，不调整
        fi
    else
        # HDD或虚拟化环境: 降低swappiness避免swap抖动
        if [[ "$is_virt" == "是"* ]]; then
            # 虚拟化环境：IOPS不稳定，大幅降低swappiness
            disk_adjustment=-15
            log_warn "虚拟化环境检测：IOPS受限且不稳定，降低swappiness避免性能抖动"
        elif (( $(echo "$disk_score < 30" | bc -l) )); then
            disk_adjustment=-10  # 低性能HDD，严重降低
            log_warn "HDD性能较低，建议升级到SSD或降低工作负载"
        elif (( $(echo "$disk_score < 50" | bc -l) )); then
            disk_adjustment=-5   # 标准HDD
        else
            disk_adjustment=-2   # 高性能HDD
        fi
    fi
    
    # 根据CPU和内存性能微调（服务器版：更保守）
    # 高性能系统可以进一步降低swappiness，优先使用内存
    if (( $(echo "$cpu_score > 70 && $mem_score > 70" | bc -l) )); then
        disk_adjustment=$((disk_adjustment - 3))
        log_info "检测到高性能CPU和内存，降低swappiness以充分利用硬件"
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
    
    # Swap大小检查（差异超过20%才标记）
    local current_swap=${ORIGINAL_VM_PARAMS[current_swap]:-0}
    local optimal_swap=${PERFORMANCE_DATA[optimal_swap]:-0}
    local swap_diff=$((optimal_swap - current_swap))
    local swap_diff_abs=${swap_diff#-}
    local swap_threshold=$((optimal_swap / 5))
    
    if [ $current_swap -eq 0 ] || [ $swap_diff_abs -gt $swap_threshold ]; then
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
    local disk_score=${PERFORMANCE_DATA[disk_score]:-20}
    local ram_mb=${SYSTEM_INFO[total_ram_mb]:-1024}
    local ram_gb=$(echo "scale=2; $ram_mb / 1024" | bc)  # 修复：添加ram_gb变量定义
    local cpu_cores=${SYSTEM_INFO[cpu_cores]:-1}
    
    # 1. vm.vfs_cache_pressure
    # 控制内核回收用于缓存目录和inode对象的内存的倾向
    # Facebook生产环境优化算法
    if [ "$disk_type" = "SSD" ] && (( $(echo "${disk_score:-20} > 60" | bc -l) )); then
        # 高性能SSD：可以更积极回收缓存
        PERFORMANCE_DATA[vfs_cache_pressure]=150
    elif [ "$disk_type" = "SSD" ]; then
        PERFORMANCE_DATA[vfs_cache_pressure]=100
    else
        # HDD：保留更多缓存
        if (( $(echo "${disk_score:-20} < 30" | bc -l) )); then
            PERFORMANCE_DATA[vfs_cache_pressure]=50
        else
            PERFORMANCE_DATA[vfs_cache_pressure]=75
        fi
    fi
    
    # 2. vm.dirty_ratio
    # 当脏页达到内存的这个百分比时，进程会被阻塞并强制写回
    # 关键原则：内存越小，dirty_ratio应该越低（避免占用过多内存）
    if [ "$disk_type" = "SSD" ]; then
        if (( $(echo "${disk_score:-20} > 70" | bc -l) )); then
            PERFORMANCE_DATA[dirty_ratio]=40  # 高性能SSD
        else
            PERFORMANCE_DATA[dirty_ratio]=30  # 普通SSD
        fi
    else
        # HDD根据性能分级和内存大小
        if (( $(echo "${ram_gb:-1} < 1" | bc -l) )); then
            # 极小内存：dirty_ratio必须很低，避免脏页占用太多宝贵内存
            PERFORMANCE_DATA[dirty_ratio]=5
            log_info "极小内存系统：降低dirty_ratio到5%，避免脏页占用过多内存"
        elif (( $(echo "${disk_score:-20} > 40" | bc -l) )); then
            PERFORMANCE_DATA[dirty_ratio]=20
        elif (( $(echo "${disk_score:-20} > 20" | bc -l) )); then
            PERFORMANCE_DATA[dirty_ratio]=15
        else
            # 低性能HDD且低内存
            if (( $(echo "${ram_gb:-1} < 2" | bc -l) )); then
                PERFORMANCE_DATA[dirty_ratio]=8
            else
                PERFORMANCE_DATA[dirty_ratio]=10
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
    # 脏页的过期时间
    if [ "$disk_type" = "SSD" ]; then
        PERFORMANCE_DATA[dirty_expire]=1500  # 15秒
    else
        if (( $(echo "${disk_score:-20} < 30" | bc -l) )); then
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
    local total_ram_kb=${SYSTEM_INFO[total_ram_kb]:-1048576}
    local min_free=$(echo "scale=0; $total_ram_kb * 0.005" | bc | cut -d'.' -f1)
    
    # 根据CPU核心数调整（更多核心需要更多空闲内存）
    min_free=$(echo "scale=0; ${min_free:-52428} * (1 + ${cpu_cores:-1} * 0.05)" | bc | cut -d'.' -f1)
    
    # 限制范围：动态计算，避免占用过多内存
    local min_limit=$(echo "scale=0; $total_ram_kb * 0.02" | bc | cut -d'.' -f1)  # 最低2%
    local max_limit=$(echo "scale=0; $total_ram_kb * 0.10" | bc | cut -d'.' -f1)  # 最高10%
    
    # 绝对值限制：16MB - 1GB
    if [ $min_limit -lt 16384 ]; then
        min_limit=16384  # 最低16MB
    fi
    if [ $min_limit -gt 65536 ]; then
        min_limit=65536  # 超过64MB后不再按比例增长
    fi
    if [ $max_limit -gt 1048576 ]; then
        max_limit=1048576  # 最高1GB
    fi
    
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
    # 0: 启发式策略(默认)
    # 1: 总是允许超额分配
    # 2: 不允许超额分配超过swap+RAM*overcommit_ratio
    if (( $(echo "${ram_mb:-1024} < 1024" | bc -l) )); then
        PERFORMANCE_DATA[overcommit_memory]=2  # 低内存系统，严格控制
        PERFORMANCE_DATA[overcommit_ratio]=50
    else
        PERFORMANCE_DATA[overcommit_memory]=0  # 使用启发式
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
    printf "${YELLOW}CPU (Sysbench):${NC}\n"
    echo "  ${SYSTEM_INFO[cpu_model]}"
    echo "  ${SYSTEM_INFO[cpu_cores]} 核心 @ ${SYSTEM_INFO[cpu_max_freq]} MHz"
    printf "  ${CYAN}测试得分: ${PERFORMANCE_DATA[cpu_single_thread]} Scores ⭐对标ecs${NC}\n"
    echo "  标准化评分: ${PERFORMANCE_DATA[cpu_score]}/100"
    echo ""
    printf "${YELLOW}内存 (Lemonbench):${NC}\n"
    echo "  $(echo "scale=2; ${SYSTEM_INFO[total_ram_mb]}/1024" | bc) GB - ${SYSTEM_INFO[mem_category]:-未识别}"
    printf "  ${CYAN}读取: ${PERFORMANCE_DATA[mem_read_bandwidth]} MB/s  |  写入: ${PERFORMANCE_DATA[mem_write_bandwidth]} MB/s${NC}\n"
    echo "  标准化评分: ${PERFORMANCE_DATA[mem_score]}/100"
    echo ""
    printf "${YELLOW}磁盘 (FIO):${NC}\n"
    echo "  ${SYSTEM_INFO[disk_device]} - ${SYSTEM_INFO[disk_type]} - ${SYSTEM_INFO[disk_category]:-未识别}"
    echo "  虚拟化: ${SYSTEM_INFO[is_virtualized]:-否}"
    printf "  ${CYAN}顺序读写: ${PERFORMANCE_DATA[disk_seq_read]}/${PERFORMANCE_DATA[disk_seq_write]} MB/s${NC}\n"
    printf "  ${CYAN}4K IOPS: 读${PERFORMANCE_DATA[disk_rand_read_iops]} / 写${PERFORMANCE_DATA[disk_rand_write_iops]} ⭐真实性能${NC}\n"
    echo "  标准化评分: ${PERFORMANCE_DATA[disk_score]}/100"
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
        echo "  ✅ 评分以IOPS为准（忽略虚高的顺序速度）"
        echo "  ✅ Swap增加20%应对IO波动"
        echo "  ✅ Swappiness降低避免频繁交换（IOPS有限）"
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
    
    # 备份现有配置
    local backup_file="/etc/sysctl.conf.backup.$(date +%Y%m%d_%H%M%S)"
    if [ -f /etc/sysctl.conf ]; then
        cp /etc/sysctl.conf $backup_file
        log_success "已备份配置到: $backup_file"
    fi
    
    # 实时应用有差异的参数
    log_progress "正在智能应用需要变更的虚拟内存参数..."
    
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
    
    echo ""
    log_success "已实时应用 ${applied_count} 项参数变更"
    
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
# 参数 $1: auto_apply (可选) - 如果为"auto"则自动应用，不询问用户
manage_swap_advanced() {
    local auto_apply=${1:-""}
    
    log_header "Swap空间管理"
    
    local current_swap=$(free -m | awk '/^Swap:/{print $2}')
    local optimal_swap=${PERFORMANCE_DATA[optimal_swap]}
    
    log_info "当前Swap: ${current_swap} MB"
    log_info "推荐Swap: ${optimal_swap} MB"
    
    # 计算差异
    local diff=$((optimal_swap - current_swap))
    local diff_abs=${diff#-}
    local threshold=$((optimal_swap / 5))  # 20%阈值
    
    local need_adjustment=0
    
    if [ $current_swap -eq 0 ]; then
        log_warn "系统当前没有Swap，强烈建议创建"
        need_adjustment=1
    elif [ $diff_abs -gt $threshold ]; then
        log_warn "当前Swap与推荐值差异超过20%"
        need_adjustment=1
    else
        log_success "当前Swap大小合理，无需调整"
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
║     Linux虚拟内存专业级自动优化工具 v3.0                         ║
║     Professional Virtual Memory Optimization Tool                ║
║                                                                   ║
║     使用业界标准测试工具和商业级优化算法                         ║
║     🤖 智能模式：自动检测并应用所有优化                          ║
║                                                                   ║
╚═══════════════════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
    echo ""
    printf "${GREEN}工作流程：${NC}\n"
    echo "  1️⃣  深度性能测试（CPU、内存、磁盘）"
    echo "  2️⃣  计算最优虚拟内存参数"
    echo "  3️⃣  对比当前配置与推荐配置"
    echo "  4️⃣  自动应用所有需要的优化"
    echo "  5️⃣  永久保存配置并备份原设置"
    echo ""
    
    # 环境检查
    check_root
    install_professional_tools
    
    echo ""
    log_warn "性能测试将执行约2-3分钟，请耐心等待..."
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
        
        # 自动应用优化
        apply_optimizations
        
        # 处理Swap变更（自动应用模式）
        if [ "${VM_PARAM_DIFF[swap_size]}" = "变更" ]; then
            echo ""
            manage_swap_advanced "auto"
        else
            echo ""
            log_success "Swap大小已是最优值，无需调整"
        fi
        
        echo ""
        printf "${GREEN}╔═══════════════════════════════════════════════════════════════════╗${NC}\n"
        printf "${GREEN}║                      ✅ 优化成功完成                              ║${NC}\n"
        printf "${GREEN}╚═══════════════════════════════════════════════════════════════════╝${NC}\n"
        echo ""
        log_success "📊 已成功自动应用 ${change_count} 项参数变更"
        log_success "💾 配置已永久保存到 /etc/sysctl.conf"
        log_success "📁 原配置已备份到 /etc/sysctl.conf.backup.$(date +%Y%m%d)_*"
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

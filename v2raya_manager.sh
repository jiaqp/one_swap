#!/bin/bash

# v2rayA 管理脚本
# 适用于 Debian 系统

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # 无颜色

# 安装包下载地址
DOWNLOAD_URL="http://43.139.51.236:16666/installer_debian_x64_2.2.7.4.deb"
PACKAGE_NAME="installer_debian_x64_2.2.7.4.deb"

# 显示菜单
show_menu() {
    clear
    echo "======================================"
    echo "      v2rayA 管理脚本"
    echo "======================================"
    echo "0. 退出脚本"
    echo "1. 下载并安装 v2rayA"
    echo "2. 启动服务并显示管理端地址"
    echo "======================================"
    echo -n "请选择功能 [0-2]: "
}

# 功能1：下载并安装 v2rayA
install_v2raya() {
    echo -e "${YELLOW}开始下载 v2rayA 安装包...${NC}"
    
    # 下载安装包
    if wget -O "/tmp/${PACKAGE_NAME}" "${DOWNLOAD_URL}"; then
        echo -e "${GREEN}下载成功！${NC}"
    else
        echo -e "${RED}下载失败，请检查网络连接和下载地址${NC}"
        return 1
    fi
    
    echo -e "${YELLOW}开始安装 v2rayA...${NC}"
    
    # 安装 deb 包
    if sudo dpkg -i "/tmp/${PACKAGE_NAME}"; then
        echo -e "${GREEN}安装成功！${NC}"
    else
        echo -e "${YELLOW}尝试修复依赖问题...${NC}"
        sudo apt-get install -f -y
        echo -e "${GREEN}安装完成！${NC}"
    fi
    
    # 清理下载的安装包
    rm -f "/tmp/${PACKAGE_NAME}"
    
    # 检查并安装 v2ray-core
    echo -e "${YELLOW}检查 v2ray-core...${NC}"
    if ! command -v v2ray &> /dev/null; then
        echo -e "${YELLOW}v2ray-core 未安装，开始安装...${NC}"
        
        # 下载 v2ray-core（使用本地服务器）
        V2RAY_FILE="v2ray-linux-64.zip"
        V2RAY_URL="http://43.139.51.236:16666/${V2RAY_FILE}"
        
        echo -e "${YELLOW}从本地服务器下载 v2ray-core...${NC}"
        if wget -O "/tmp/${V2RAY_FILE}" "${V2RAY_URL}"; then
            echo -e "${GREEN}下载成功！${NC}"
        else
            echo -e "${RED}v2ray-core 下载失败，请检查服务器地址${NC}"
            return 1
        fi
        
        # 解压并安装
        echo -e "${YELLOW}解压并安装 v2ray-core...${NC}"
        sudo unzip -o "/tmp/${V2RAY_FILE}" -d /usr/local/bin/
        sudo chmod +x /usr/local/bin/v2ray
        
        # 清理下载文件
        rm -f "/tmp/${V2RAY_FILE}"
        
        # 验证安装
        if command -v v2ray &> /dev/null; then
            echo -e "${GREEN}v2ray-core 安装成功！版本：${NC}"
            v2ray version
        else
            echo -e "${RED}v2ray-core 安装失败${NC}"
            return 1
        fi
    else
        echo -e "${GREEN}v2ray-core 已安装${NC}"
        v2ray version
    fi
    
    # 下载必需的地理数据文件
    echo -e "${YELLOW}正在下载 v2ray-core 必需的地理数据文件...${NC}"
    
    # 创建 v2ray 数据目录
    sudo mkdir -p /usr/local/share/v2ray
    
    # 下载 geoip.dat（直接使用 CDN 加速地址）
    echo -e "${YELLOW}下载 geoip.dat...${NC}"
    if sudo wget -O /usr/local/share/v2ray/geoip.dat https://cdn.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/geoip.dat; then
        echo -e "${GREEN}geoip.dat 下载成功！${NC}"
    else
        echo -e "${RED}geoip.dat 下载失败${NC}"
    fi
    
    # 下载 geosite.dat（直接使用 CDN 加速地址）
    echo -e "${YELLOW}下载 geosite.dat...${NC}"
    if sudo wget -O /usr/local/share/v2ray/geosite.dat https://cdn.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/geosite.dat; then
        echo -e "${GREEN}geosite.dat 下载成功！${NC}"
    else
        echo -e "${RED}geosite.dat 下载失败${NC}"
    fi
    
    # 设置文件权限
    sudo chmod 644 /usr/local/share/v2ray/geo*.dat
    
    echo -e "${GREEN}v2rayA 安装完成！${NC}"
    echo -e "${YELLOW}提示：如果地理数据文件下载失败，服务可能无法正常启动${NC}"
}

# 功能2：启动服务并显示管理端地址
start_service() {
    echo -e "${YELLOW}正在启动 v2rayA 服务...${NC}"
    
    # 重启服务
    if sudo systemctl restart v2raya.service; then
        echo -e "${GREEN}服务启动成功！${NC}"
    else
        echo -e "${RED}服务启动失败，请检查服务状态${NC}"
        sudo systemctl status v2raya.service
        return 1
    fi
    
    # 等待服务完全启动
    sleep 2
    
    # 获取公网 IP
    echo -e "${YELLOW}正在获取服务器公网 IP...${NC}"
    PUBLIC_IP=$(curl -s --max-time 5 ifconfig.me)
    
    if [ -z "$PUBLIC_IP" ]; then
        # 如果第一个方法失败，尝试备用方法
        PUBLIC_IP=$(curl -s --max-time 5 ip.sb)
    fi
    
    if [ -z "$PUBLIC_IP" ]; then
        # 如果仍然失败，尝试第三个方法
        PUBLIC_IP=$(curl -s --max-time 5 icanhazip.com)
    fi
    
    if [ -z "$PUBLIC_IP" ]; then
        echo -e "${RED}无法获取公网 IP，但服务已启动${NC}"
        echo -e "${YELLOW}请手动访问: http://您的服务器IP:2017${NC}"
    else
        echo ""
        echo -e "${GREEN}======================================"
        echo -e "v2rayA Web 管理端地址："
        echo -e "http://${PUBLIC_IP}:2017"
        echo -e "======================================${NC}"
        echo ""
    fi
    
    # 显示服务状态
    echo -e "${YELLOW}服务状态：${NC}"
    sudo systemctl status v2raya.service --no-pager | head -n 10
}

# 主循环
while true; do
    show_menu
    read -r choice
    
    case $choice in
        0)
            echo -e "${GREEN}退出脚本，再见！${NC}"
            exit 0
            ;;
        1)
            install_v2raya
            echo ""
            read -p "按回车键继续..."
            ;;
        2)
            start_service
            echo ""
            read -p "按回车键继续..."
            ;;
        *)
            echo -e "${RED}无效选择，请输入 0-2${NC}"
            sleep 2
            ;;
    esac
done

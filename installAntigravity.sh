#!/bin/bash

# =================配置区域=================
# 以后只需修改这两个变量
version="1.12.4"
commitid="da3eb231fb10e6dc27750aa465b8582265c907d9"

# 定义安装路径和下载链接
TARGET_DIR="/root/.antigravity-server/bin/${commitid}"
DOWNLOAD_URL="https://edgedl.me.gvt1.com/edgedl/release2/j0qc3/antigravity/stable/${version}-${commitid}/linux-x64/Antigravity-reh.tar.gz"

# ==========================================

echo "开始安装 Antigravity Server 版本: ${version} (Commit: ${commitid:0:7})..."

# 1. 创建目标目录
if [ ! -d "$TARGET_DIR" ]; then
    echo "正在创建目录: $TARGET_DIR"
    mkdir -p "$TARGET_DIR"
fi

cd "$TARGET_DIR" || { echo "无法进入目录"; exit 1; }

# 2. 下载组件包
echo "正在从 Google 镜像源下载组件..."
wget -q --show-progress "$DOWNLOAD_URL" -O Antigravity-reh.tar.gz

# 检查下载是否成功
if [ $? -ne 0 ]; then
    echo "错误：下载失败！请检查 Clash 代理是否正常运行，或 Commit ID 是否正确。"
    exit 1
fi

# 3. 解压并清理
echo "正在解压组件..."
tar -xzf Antigravity-reh.tar.gz --strip-components=1

if [ $? -eq 0 ]; then
    touch 0  # 创建成功标记文件
    rm Antigravity-reh.tar.gz
    echo "------------------------------------------------"
    echo "恭喜！手动安装已完成。"
    echo "现在请在本地 Antigravity 客户端重新连接 SSH。"
    echo "------------------------------------------------"
else
    echo "错误：解压失败，文件可能已损坏。"
    exit 1
fi
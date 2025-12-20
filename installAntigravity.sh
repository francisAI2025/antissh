#!/bin/bash

# =================================================================================
# Antigravity Server 安装脚本 (交互式版本获取)
# 使用方法: 从 Antigravity 客户端的 "帮助 -> 关于" 复制版本信息并粘贴
# =================================================================================

echo "================================================"
echo "    Antigravity Server 安装脚本"
echo "================================================"
echo ""
echo "请从 Antigravity 客户端复制版本信息:"
echo "  1. 打开 Antigravity 客户端"
echo "  2. 点击 Help -> About"
echo "  3. 点击 'Copy' 按钮"
echo "  4. 在下方粘贴版本信息，然后连续按两次回车:"
echo "------------------------------------------------"

# 读取多行输入，遇到空行结束
version_info=""
while IFS= read -r line; do
    [ -z "$line" ] && break
    version_info+="$line"$'\n'
done

# 解析 Version 和 Commit
version=$(echo "$version_info" | grep -oP 'Antigravity Version:\s*\K[\d.]+' | head -1)
commitid=$(echo "$version_info" | grep -oP 'Commit:\s*\K[a-f0-9]+' | head -1)

# 验证解析结果
if [ -z "$version" ] || [ -z "$commitid" ]; then
    echo ""
    echo "[错误] 无法解析版本信息！"
    echo "请确保粘贴的内容包含 'Antigravity Version' 和 'Commit' 字段。"
    echo ""
    echo "示例格式:"
    echo "  Antigravity Version: 1.12.4"
    echo "  Commit: da3eb231fb10e6dc27750aa465b8582265c907d9"
    exit 1
fi

echo ""
echo "------------------------------------------------"
echo "[解析成功]"
echo "  版本号:   ${version}"
echo "  Commit:   ${commitid}"
echo "------------------------------------------------"

# 构建下载地址
TARGET_DIR="${HOME}/.antigravity-server/bin/${commitid}"
DOWNLOAD_URL="https://edgedl.me.gvt1.com/edgedl/release2/j0qc3/antigravity/stable/${version}-${commitid}/linux-x64/Antigravity-reh.tar.gz"

# 验证下载链接
echo ""
echo "正在验证下载链接..."
HTTP_CODE=$(curl -sI "$DOWNLOAD_URL" -o /dev/null -w "%{http_code}" --connect-timeout 10)

if [ "$HTTP_CODE" != "200" ]; then
    echo "[错误] 下载链接无效 (HTTP ${HTTP_CODE})"
    echo "可能原因: 版本号或 Commit ID 不正确"
    echo "下载链接: ${DOWNLOAD_URL}"
    exit 1
fi

echo "[✓] 下载链接验证通过"
echo "开始安装"


echo ""
echo "开始安装 Antigravity Server ..."

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
    echo "错误：下载失败！请检查网络连接。"
    exit 1
fi

# 3. 解压并清理
echo "正在解压组件..."
tar -xzf Antigravity-reh.tar.gz --strip-components=1

if [ $? -eq 0 ]; then
    touch 0  # 创建成功标记文件
    rm Antigravity-reh.tar.gz
    echo ""
    echo "================================================"
    echo "  恭喜！安装已完成。"
    echo "  版本: ${version}"
    echo "  Commit: ${commitid}"
    echo ""
    echo "  请在本地 Antigravity 客户端重新连接 SSH。"
    echo "================================================"
else
    echo "错误：解压失败，文件可能已损坏。"
    exit 1
fi

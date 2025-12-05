#!/usr/bin/env bash
#
# Antigravity Agent + graftcp 一键配置脚本
# 支持：Linux（macOS 需使用 Proxifier 等替代方案）
# 作用：
#   1. 询问是否需要代理，以及代理地址（格式：socks5://ip:port 或 http://ip:port）
#   2. 自动安装 / 编译 graftcp（Go 项目，使用 Go modules，要求 Go >= 1.13）
#   3. 自动查找 antigravity 的 language_server_* 可执行文件
#   4. 备份原二进制为 .bak，并写入 wrapper
#
# 安装位置：
#   graftcp 安装在：$HOME/.graftcp-antigravity/graftcp
#   安装日志：      $HOME/.graftcp-antigravity/install.log
#
# 再次执行脚本 = 修改代理 / 重新生成 wrapper（不会覆盖 .bak）

################################ 基本变量 ################################

INSTALL_ROOT="${HOME}/.graftcp-antigravity"
REPO_DIR="${INSTALL_ROOT}/graftcp"
INSTALL_LOG="${INSTALL_ROOT}/install.log"

mkdir -p "${INSTALL_ROOT}"
touch "${INSTALL_LOG}"

PLATFORM=""
PM=""          # 包管理器
SUDO=""        # sudo 命令
PROXY_URL=""   # 代理地址（不含协议前缀，如 127.0.0.1:10808）
PROXY_TYPE=""  # socks5 或 http
GRAFTCP_DIR="" # 最终的 graftcp 目录 = ${REPO_DIR}
TARGET_BIN=""  # language_server_* 路径
BACKUP_BIN=""  # 备份路径 = ${TARGET_BIN}.bak

################################ 日志输出 ################################

log() {
  echo "[INFO] $*" | tee -a "${INSTALL_LOG}"
}

warn() {
  echo "[WARN] $*" | tee -a "${INSTALL_LOG}" >&2
}

error() {
  echo "[ERROR] $*" | tee -a "${INSTALL_LOG}" >&2
  echo "安装失败，可查看日志：${INSTALL_LOG}"
  exit 1
}

################################ 系统检查 ################################

check_linux_version() {
  if [ ! -f /etc/os-release ]; then
    error "无法检测到 Linux 发行版（缺少 /etc/os-release），可能系统版本低，脚本暂不支持。"
  fi

  # shellcheck source=/dev/null
  . /etc/os-release

  case "${ID}" in
    ubuntu|debian)
      major="${VERSION_ID%%.*}"
      if [ "${major}" -lt 16 ]; then
        error "检测到 ${ID} ${VERSION_ID}，版本过低（<16），不在脚本支持范围。"
      fi
      ;;
    centos|rhel|rocky|almalinux)
      major="${VERSION_ID%%.*}"
      if [ "${major}" -lt 7 ]; then
        error "检测到 ${ID} ${VERSION_ID}，版本过低（<7），不在脚本支持范围。"
      fi
      ;;
    *)
      warn "检测到发行版 ${ID} ${VERSION_ID}，将尝试执行脚本（如失败请考虑手动配置）。"
      ;;
  esac
}

check_macos_version() {
  # graftcp 官方不支持 macOS，给出替代方案提示
  echo ""
  echo "============================================="
  echo " ⚠️  检测到 macOS 系统"
  echo "============================================="
  echo ""
  echo " graftcp 不支持 macOS，原因：macOS 的 ptrace(2) 功能受限"
  echo ""
  echo " 请使用以下替代方案："
  echo ""
  echo " 1. Proxifier（推荐）"
  echo "    - 官网: https://www.proxifier.com/"
  echo "    - 关于license key，请自行搜索，有特别版序列号，如有能力请支持正版"
  echo "    - 支持按应用配置代理规则"
  echo "    - 设置方法: Proxifier -> Profile -> Proxy Servers -> Add 添加代理服务器"
  echo "      然后在 Rules 中应用程序中添加 com.google.antigravity.helper; com.google.antigravity; Antigravity; language_server_macos_arm; language_server_macos_x64"
  echo ""
  echo " 2. Clash / Surge 等 TUN 模式"
  echo "    - 开启 TUN 模式后可全局透明代理"
  echo ""
  echo " 3. 环境变量，不推荐，Agent 服务无法走代理"
  echo "    export ALL_PROXY=socks5://127.0.0.1:10808"
  echo "    export HTTPS_PROXY=http://127.0.0.1:10809"
  echo ""
  echo "============================================="
  echo ""
  exit 0
}

check_system() {
  os="$(uname -s)"
  case "${os}" in
    Linux)
      PLATFORM="linux"
      check_linux_version
      ;;
    Darwin)
      PLATFORM="macos"
      check_macos_version
      ;;
    *)
      error "当前系统 ${os} 不在支持列表，仅支持 Linux。macOS/Windows 用户请使用 Proxifier 应用或 TUN 模式。"
      ;;
  esac
}

################################ 代理解析与校验（通用方法） ################################

# 校验 IP 地址格式（每段 0-255）
# 返回 0 表示有效，1 表示无效
validate_ip() {
  local ip="$1"
  local IFS='.'
  local -a octets
  read -ra octets <<< "${ip}"
  
  # 必须是 4 段
  if [ "${#octets[@]}" -ne 4 ]; then
    return 1
  fi
  
  for octet in "${octets[@]}"; do
    # 必须是纯数字
    if ! echo "${octet}" | grep -Eq '^[0-9]+$'; then
      return 1
    fi
    # 范围 0-255
    if [ "${octet}" -lt 0 ] || [ "${octet}" -gt 255 ]; then
      return 1
    fi
  done
  
  return 0
}

# 校验端口号（1-65535）
# 返回 0 表示有效，1 表示无效
validate_port() {
  local port="$1"
  
  # 必须是纯数字
  if ! echo "${port}" | grep -Eq '^[0-9]+$'; then
    return 1
  fi
  
  # 范围 1-65535
  if [ "${port}" -lt 1 ] || [ "${port}" -gt 65535 ]; then
    return 1
  fi
  
  return 0
}

# 解析代理 URL 并设置全局变量 PROXY_TYPE 和 PROXY_URL
# 输入格式：socks5://127.0.0.1:10808 或 http://127.0.0.1:10809
# 返回 0 表示解析成功，1 表示格式错误
# 错误信息存储在 PARSE_ERROR 变量中
PARSE_ERROR=""

parse_proxy_url() {
  local input="$1"
  local scheme host port host_port
  
  PARSE_ERROR=""
  
  # 检查是否包含协议前缀
  if ! echo "${input}" | grep -Eq '^(socks5|http)://'; then
    PARSE_ERROR="代理地址必须以 socks5:// 或 http:// 开头"
    return 1
  fi
  
  # 提取协议
  scheme="${input%%://*}"
  host_port="${input#*://}"
  
  # 校验协议类型
  case "${scheme}" in
    socks5)
      PROXY_TYPE="socks5"
      ;;
    http)
      PROXY_TYPE="http"
      ;;
    *)
      PARSE_ERROR="仅支持 socks5 或 http 协议，当前输入：${scheme}"
      return 1
      ;;
  esac
  
  # 检查是否包含端口
  if ! echo "${host_port}" | grep -q ':'; then
    PARSE_ERROR="代理地址缺少端口号，正确格式：${scheme}://IP:PORT"
    return 1
  fi
  
  # 提取 IP 和端口
  host="${host_port%%:*}"
  port="${host_port##*:}"
  
  # 移除端口后可能的路径（如 /）
  port="${port%%/*}"
  
  # 校验 IP 地址
  if ! validate_ip "${host}"; then
    # 也允许 localhost
    if [ "${host}" != "localhost" ]; then
      PARSE_ERROR="IP 地址格式无效：${host}（每段必须在 0-255 之间）"
      return 1
    fi
  fi
  
  # 校验端口
  if ! validate_port "${port}"; then
    PARSE_ERROR="端口号无效：${port}（必须在 1-65535 之间）"
    return 1
  fi
  
  # 设置代理地址（不含协议前缀）
  PROXY_URL="${host}:${port}"
  
  return 0
}

################################ 从环境变量中检测代理 ################################

ENV_PROXY_RAW=""
ENV_PROXY_SOURCE=""

detect_env_proxy() {
  local var val
  for var in ALL_PROXY all_proxy HTTPS_PROXY https_proxy HTTP_PROXY http_proxy; do
    val="${!var}"
    if [ -n "${val}" ]; then
      ENV_PROXY_RAW="${val}"
      ENV_PROXY_SOURCE="${var}"
      return 0
    fi
  done
  return 1
}

################################ 代理交互 ################################

ask_proxy() {
  echo "============================================="
  echo " 是否需要为 Antigravity Agent 配置代理？"
  echo "   - 输入 Y 或直接回车：配置代理（默认）"
  echo "   - 输入 N：不配置代理，退出脚本"
  echo "============================================="
  read -r -p "请选择 [Y/n] （默认 Y）: " yn

  yn="${yn:-Y}"
  case "${yn}" in
    [Nn]*)
      echo "恭喜，你目前的环境不需要代理，可以愉快的编码了 🎉"
      exit 0
      ;;
    *)
      ;;
  esac

  # 选择了"需要代理"，先检查环境变量里有没有
  if detect_env_proxy; then
    echo
    echo "检测到环境变量 ${ENV_PROXY_SOURCE} 中已配置代理：${ENV_PROXY_RAW}"
    
    # 尝试解析环境变量中的代理
    if parse_proxy_url "${ENV_PROXY_RAW}"; then
      echo "解析结果：类型=${PROXY_TYPE}，地址=${PROXY_URL}"
      read -r -p "是否直接使用该代理？ [Y/n] （默认 Y）: " use_env
      use_env="${use_env:-Y}"
      case "${use_env}" in
        [Nn]*)
          # 用户不需要使用环境变量里的代理，将进入自定义代理设置
          ;;
        *)
          log "将使用环境代理：${PROXY_TYPE}://${PROXY_URL}（来源：${ENV_PROXY_SOURCE}）"
          return
          ;;
      esac
    else
      warn "环境变量中的代理格式无效：${PARSE_ERROR}"
      echo "将进入手动输入..."
    fi
  fi

  # 没有检测到环境代理，或者用户拒绝使用环境代理 → 自定义输入
  echo
  echo "请输入代理地址，格式示例："
  echo "  SOCKS5: socks5://127.0.0.1:10808"
  echo "  HTTP:   http://127.0.0.1:10809"
  echo ""
  echo "直接回车 = 不设置代理，退出脚本"
  
  while true; do
    read -r -p "代理地址: " proxy_input

    if [ -z "${proxy_input}" ]; then
      echo "未设置代理，脚本退出"
      exit 0
    fi

    # 解析并校验代理地址
    if parse_proxy_url "${proxy_input}"; then
      log "代理设置成功：${PROXY_TYPE}://${PROXY_URL}"
      break
    else
      echo "❌ ${PARSE_ERROR}"
      echo "请重新输入正确格式的代理地址"
      echo ""
    fi
  done
}

################################ 依赖检查/安装 ################################

detect_pkg_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    PM="apt"
  elif command -v dnf >/dev/null 2>&1; then
    PM="dnf"
  elif command -v yum >/dev/null 2>&1; then
    PM="yum"
  elif command -v pacman >/dev/null 2>&1; then
    PM="pacman"
  elif command -v zypper >/dev/null 2>&1; then
    PM="zypper"
  else
    PM=""
  fi
}

check_go_version() {
  if ! command -v go >/dev/null 2>&1; then
    # 缺 go 的情况交给依赖安装逻辑
    return
  fi

  # go version 输出类似：go version go1.22.5 linux/amd64
  gv_raw="$(go version 2>/dev/null | awk '{print $3}')"
  gv="${gv_raw#go}"
  major="${gv%%.*}"
  rest="${gv#*.}"
  minor="${rest%%.*}"

  # graftcp 使用 Go Modules，要求 Go >= 1.13
  if [ "${major}" -lt 1 ] || { [ "${major}" -eq 1 ] && [ "${minor}" -lt 13 ]; }; then
    error "检测到 Go 版本 ${gv_raw}，过低（要求 >= 1.13），请先升级 Go 后重试。"
  fi
  
  log "Go 版本检查通过：${gv_raw}"
}

ensure_dependencies() {
  detect_pkg_manager

  missing=()
  for cmd in git make gcc go; do
    if ! command -v "${cmd}" >/dev/null 2>&1; then
      missing+=("${cmd}")
    fi
  done

  if [ "${#missing[@]}" -eq 0 ]; then
    log "依赖已满足：git / make / gcc / go"
    check_go_version
    return
  fi

  if [ -z "${PM}" ]; then
    error "缺少依赖 ${missing[*]}，且无法识别包管理器，请手动安装后重试。"
  fi

  if [ "$(id -u)" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1; then
      SUDO="sudo"
    else
      error "当前用户不是 root，且系统未安装 sudo，无法自动安装依赖：${missing[*]}，请手动安装后重试。"
    fi
  else
    SUDO=""
  fi

  log "缺少依赖：${missing[*]}，使用 ${PM} 自动安装..."

  case "${PM}" in
    apt)
      ${SUDO} apt-get update | tee -a "${INSTALL_LOG}"
      ${SUDO} apt-get install -y git make gcc golang-go | tee -a "${INSTALL_LOG}"
      ;;
    dnf)
      ${SUDO} dnf install -y git make gcc golang | tee -a "${INSTALL_LOG}"
      ;;
    yum)
      ${SUDO} yum install -y git make gcc golang | tee -a "${INSTALL_LOG}"
      ;;
    pacman)
      ${SUDO} pacman -Sy --noconfirm git base-devel go | tee -a "${INSTALL_LOG}"
      ;;
    zypper)
      ${SUDO} zypper refresh | tee -a "${INSTALL_LOG}"
      ${SUDO} zypper install -y git make gcc go | tee -a "${INSTALL_LOG}"
      ;;
    *)
      error "暂不支持使用 ${PM} 自动安装依赖，请手动安装：${missing[*]}"
      ;;
  esac

  check_go_version
  log "依赖安装完成。"
}

################################ 安装 / 编译 graftcp ################################

install_graftcp() {
  GRAFTCP_DIR="${REPO_DIR}"

  if [ -x "${GRAFTCP_DIR}/graftcp" ] && [ -x "${GRAFTCP_DIR}/local/graftcp-local" ]; then
    log "检测到已安装的 graftcp：${GRAFTCP_DIR}"
    return
  fi

  log "开始安装 graftcp 到：${GRAFTCP_DIR}"
  mkdir -p "${GRAFTCP_DIR}"

  if [ ! -d "${GRAFTCP_DIR}/.git" ]; then
    log "克隆 graftcp 仓库（官方 GitHub）..."
    git clone https://github.com/hmgle/graftcp.git "${GRAFTCP_DIR}" | tee -a "${INSTALL_LOG}"
  else
    log "检测到已有 graftcp 仓库，尝试更新..."
    (cd "${GRAFTCP_DIR}" && git pull --ff-only | tee -a "${INSTALL_LOG}") || warn "graftcp 仓库更新失败，继续使用当前版本。"
  fi

  cd "${GRAFTCP_DIR}" || error "无法进入目录：${GRAFTCP_DIR}"

  # 临时加速 Go 依赖（GOPROXY），仅针对本次 make 生效，不影响全局环境
  if [ -z "${GOPROXY:-}" ]; then
    log "为编译临时设置 GOPROXY=https://goproxy.cn,direct 加速 go 依赖下载（仅本次生效）。"
    GOPROXY_ENV="GOPROXY=https://goproxy.cn,direct"
  else
    GOPROXY_ENV=""
  fi

  # 兼容旧版本 Go：删除 go.mod 中的 toolchain 指令（Go 1.21+ 新增，旧版本无法识别）
  log "检查并移除 go.mod 中的 toolchain 指令（兼容 Go < 1.21）..."
  for gomod in go.mod local/go.mod; do
    if [ -f "${gomod}" ] && grep -q '^toolchain' "${gomod}"; then
      log "  移除 ${gomod} 中的 toolchain 行"
      sed -i '/^toolchain/d' "${gomod}"
    fi
  done

  log "开始编译 graftcp（日志写入：${INSTALL_LOG}）..."
  if ! env ${GOPROXY_ENV} make >> "${INSTALL_LOG}" 2>&1; then
    error "graftcp 编译失败，请检查 Go 环境或网络，详情见 ${INSTALL_LOG}。"
  fi

  if [ ! -x "${GRAFTCP_DIR}/graftcp" ] || [ ! -x "${GRAFTCP_DIR}/local/graftcp-local" ]; then
    error "编译完成但未找到 graftcp 或 graftcp-local，可执行文件缺失。"
  fi

  log "graftcp 安装/编译完成。"
}

################################ 查找 language_server_* ################################

find_language_server() {
  local pattern base current_user
  pattern="language_server_linux_"
  
  # 获取当前用户名
  current_user="$(whoami)"
  
  log "当前用户：${current_user}"
  log "用户目录：${HOME}"
  log "开始查找 *${pattern}* ..."

  candidates=()
  
  # 构建搜索路径列表（按优先级排序）
  local search_paths=()
  
  # 1. 当前用户的 .antigravity-server 目录（最常见）
  search_paths+=("${HOME}/.antigravity-server")
  
  # 2. 如果 HOME 不是 /root，也搜索 /root（可能以 sudo 运行）
  if [ "${HOME}" != "/root" ] && [ -d "/root/.antigravity-server" ]; then
    search_paths+=("/root/.antigravity-server")
  fi
  
  # 3. 扫描 /home 下的其他用户目录（WSL 或多用户环境）
  if [ -d "/home" ]; then
    for user_dir in /home/*; do
      if [ -d "${user_dir}/.antigravity-server" ]; then
        # 跳过已添加的路径
        if [ "${user_dir}" != "${HOME}" ]; then
          search_paths+=("${user_dir}/.antigravity-server")
        fi
      fi
    done
  fi
  
  # 4. 用户主目录的其他位置，兜底
  search_paths+=("${HOME}")
  
  # 遍历搜索路径
  for base in "${search_paths[@]}"; do
    if [ -d "${base}" ]; then
      log "搜索目录：${base}"
      while IFS= read -r path; do
        candidates+=("${path}")
        log "  找到：${path}"
      done < <(find "${base}" -maxdepth 10 -type f -path "*extensions/antigravity/bin/${pattern}*" 2>/dev/null)
    fi
  done

  if [ "${#candidates[@]}" -eq 0 ]; then
    echo ""
    echo "未在以下位置找到 language_server_* 文件："
    for base in "${search_paths[@]}"; do
      echo "  - ${base}"
    done
    echo ""
    echo "请手动输入 antigravity 安装目录"
    echo "（通常是 ~/.antigravity-server 或 /home/用户名/.antigravity-server）"
    read -r -p "目录路径，不输入直接回车则放弃: " base
    if [ -z "${base}" ] || [ ! -d "${base}" ]; then
      error "未找到 Agent 文件，请确认 antigravity 安装路径后重试。"
    fi

    log "搜索用户指定目录：${base}"
    while IFS= read -r path; do
      candidates+=("${path}")
    done < <(find "${base}" -maxdepth 10 -type f -path "*extensions/antigravity/bin/${pattern}*" 2>/dev/null)
  fi

  if [ "${#candidates[@]}" -eq 0 ]; then
    error "仍然没有找到 language_server_* 可执行文件，请检查 antigravity 安装。"
  fi

  if [ "${#candidates[@]}" -eq 1 ]; then
    TARGET_BIN="${candidates[0]}"
    log "找到 Agent 服务：${TARGET_BIN}"
  else
    echo "检测到多个 language_server 可执行文件，请选择要代理的一个："
    local i=1
    for p in "${candidates[@]}"; do
      echo "  [$i] ${p}"
      i=$((i+1))
    done
    read -r -p "请输入序号（默认 1）: " idx
    idx="${idx:-1}"
    if ! echo "${idx}" | grep -Eq '^[0-9]+$'; then
      error "输入无效：${idx}"
    fi
    if [ "${idx}" -lt 1 ] || [ "${idx}" -gt "${#candidates[@]}" ]; then
      error "输入序号超出范围。"
    fi
    TARGET_BIN="${candidates[$((idx-1))]}"
    log "已选择 Agent 服务：${TARGET_BIN}"
  fi
}

################################ 写入 wrapper ################################

setup_wrapper() {
  BACKUP_BIN="${TARGET_BIN}.bak"

  if [ -f "${BACKUP_BIN}" ]; then
    log "检测到已有备份文件：${BACKUP_BIN}，本地运行脚本将仅更新代理配置"
  else
    log "备份原始 Agent 服务到：${BACKUP_BIN}"
    mv "${TARGET_BIN}" "${BACKUP_BIN}" || error "备份失败：无法移动 ${TARGET_BIN} -> ${BACKUP_BIN}"
  fi

  cat > "${TARGET_BIN}" <<EOF
#!/usr/bin/env bash
# 该文件由 antigravity-set.sh 自动生成
# 用 graftcp 代理启动原始 Antigravity Agent

GRAFTCP_DIR="${GRAFTCP_DIR}"
PROXY_URL="${PROXY_URL}"
PROXY_TYPE="${PROXY_TYPE}"
LOG_FILE="\$HOME/.graftcp-antigravity/wrapper.log"

mkdir -p "\$(dirname "\$LOG_FILE")"
echo "[\$(date)] Starting wrapper: \$0 \$@" >> "\$LOG_FILE"

# 检查 graftcp-local 是否已在运行
if command -v pgrep >/dev/null 2>&1; then
  if ! pgrep -f "\$GRAFTCP_DIR/local/graftcp-local" >/dev/null 2>&1; then
    echo "[\$(date)] Starting graftcp-local with \$PROXY_TYPE proxy \$PROXY_URL" >> "\$LOG_FILE"
    if [ "\$PROXY_TYPE" = "http" ]; then
      nohup "\$GRAFTCP_DIR/local/graftcp-local" -http_proxy="\$PROXY_URL" -select_proxy_mode=only_http_proxy >/dev/null 2>&1 &
    else
      nohup "\$GRAFTCP_DIR/local/graftcp-local" -socks5="\$PROXY_URL" -select_proxy_mode=only_socks5 >/dev/null 2>&1 &
    fi
    sleep 0.5
  fi
else
  if ! ps aux | grep -v grep | grep -q "\$GRAFTCP_DIR/local/graftcp-local"; then
    echo "[\$(date)] Starting graftcp-local with \$PROXY_TYPE proxy \$PROXY_URL" >> "\$LOG_FILE"
    if [ "\$PROXY_TYPE" = "http" ]; then
      nohup "\$GRAFTCP_DIR/local/graftcp-local" -http_proxy="\$PROXY_URL" -select_proxy_mode=only_http_proxy >/dev/null 2>&1 &
    else
      nohup "\$GRAFTCP_DIR/local/graftcp-local" -socks5="\$PROXY_URL" -select_proxy_mode=only_socks5 >/dev/null 2>&1 &
    fi
    sleep 0.5
  fi
fi

# 1. 强制使用系统 DNS (解决解析问题)
export GODEBUG="netdns=cgo"
# 2. 关闭 HTTP/2 客户端 (解决 EOF 等问题)
export GODEBUG="\$GODEBUG,http2client=0"

# 使用 graftcp 启动备份的原始 Agent 服务
exec "\$GRAFTCP_DIR/graftcp" "\$0.bak" "\$@"
EOF

  chmod +x "${TARGET_BIN}" || error "无法为 ${TARGET_BIN} 添加执行权限"
  log "已生成代理 wrapper：${TARGET_BIN}"
}

################################ 主流程 ################################

main() {
  echo "==== Antigravity + graftcp 一键配置脚本 ===="
  echo "支持系统：Linux（macOS 请使用 Proxifier 等替代方案）"
  echo "安装日志：${INSTALL_LOG}"
  echo

  check_system
  ask_proxy
  ensure_dependencies
  install_graftcp
  find_language_server
  setup_wrapper

  echo
  echo "=================== 配置完成 🎉 ==================="
  echo "graftcp 安装目录： ${GRAFTCP_DIR}"
  echo "Agent 备份文件：   ${BACKUP_BIN}"
  echo "当前代理：         ${PROXY_TYPE}://${PROXY_URL}"
  echo
  echo "如需修改代理："
  echo "  1. 直接重新运行本脚本，按提示输入新的代理地址即可。"
  echo "  2. 或手动编辑 wrapper 文件："
  echo "       ${TARGET_BIN}"
  echo "     修改其中的 PROXY_URL 和 PROXY_TYPE 后重启 antigravity。"
  echo
  echo "如需完全恢复原始行为："
  echo "  mv \"${BACKUP_BIN}\" \"${TARGET_BIN}\""
  echo
  echo "安装/编译日志位于：${INSTALL_LOG}"
  echo "==================================================="
}

main
# 反重力代理配置工具

为 反重力 Agent 配置代理，解决网络连接问题。

## 系统支持

| 系统        | 支持情况      | 说明                           |
| ----------- | ------------- | ------------------------------ |
| **Linux**   | ✅ 完全支持   | 使用 graftcp 自动代理          |
| **macOS**   | ⚠️ 需替代方案 | 推荐使用 Proxifier 或 TUN 模式 |
| **Windows** | ⚠️ 需替代方案 | 推荐使用 Proxifier 或 TUN 模式 |

## Linux 使用方法

### 1. 下载脚本

```bash
curl -O https://raw.githubusercontent.com/ccpopy/antissh/main/antissh.sh
# 或者加速下载
# curl -O https://ghproxy.net/https://raw.githubusercontent.com/ccpopy/antissh/main/antissh.sh
chmod +x antissh.sh
```

### 2. 运行脚本

```bash
bash ./antissh.sh
```

### 3. 按提示操作

脚本会依次：

- 询问是否需要配置代理
- 输入代理地址，格式如下：
  - SOCKS5: `socks5://127.0.0.1:10808`
  - HTTP: `http://127.0.0.1:10809`
- 自动安装依赖和编译 graftcp
- 自动查找并配置 language_server

### 4. 修改代理

直接重新运行脚本即可更新代理设置。

### 5. 恢复原始状态

```bash
mv /path/to/language_server_xxx.bak /path/to/language_server_xxx
```

路径会在脚本执行完成后显示。

---

## macOS / Windows 替代方案

由于 graftcp 依赖 Linux 的 `ptrace` 系统调用，在 macOS/Windows 上无法使用。

### 推荐方案 1：Proxifier

1. 下载安装 [Proxifier](https://www.proxifier.com/)
2. 添加代理服务器：`Profile` → `Proxy Servers` → `Add`
3. 添加规则：`Profile` → `Proxification Rules` → `Add`
   - 应用程序选择 `language_server_*`
   - Action 选择刚添加的代理

### 推荐方案 2：TUN 模式

使用 Clash、Surge 等工具开启 TUN 模式，实现全局透明代理。

---

## 依赖要求

- **Go**: >= 1.13（脚本会自动安装）
- **Git, Make, GCC**（脚本会自动安装）

## 鸣谢

- [graftcp](https://github.com/hmgle/graftcp)
- [思路来源](https://www.v2ex.com/t/1174113)

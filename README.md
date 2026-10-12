# 求生之路2插件

本仓库作为 L4D2 SourceMod 插件的**统一开发工作区**，所有插件源码、第三方头文件、编译产物集中管理，统一通过 VSCode + SourcePawn Studio 编译。

---

## 📑 目录

- [快速开始](#快速开始)
- [环境要求](#环境要求)
- [目录结构](#目录结构)
- [VSCode 配置](#vscode-配置)
- [编写第一个插件](#编写第一个插件)
- [编译与上传](#编译与上传)
- [源码目录规范](#源码目录规范)
- [常见问题](#常见问题)
- [参考资料](#参考资料)

---

## 🚀 快速开始

只需 5 步即可开始开发：

```bash
# 1. 克隆仓库
git clone <仓库地址> l4d2-plugin
cd l4d2-plugin

# 2. 复制配置模板（实际配置被 .gitignore 排除，不会泄露凭据）
cp .vscode/settings.json.example .vscode/settings.json

# 3. 编辑 settings.json，填入你自己的：
#    - spcomp.exe 路径（默认就在工作区根目录）
#    - include 路径
#    - 服务器地址 / RCON 密码 / SFTP 凭据

# 4. 用 VSCode 打开工作区根目录
code .
# 然后安装推荐的两个扩展（首次打开会弹出提示）：
#   • SourcePawn Studio  （Sarrus1）
#   • All Autocomplete

# 5. 打开任意 .sp 文件，按 F7 编译
```

---

## 📋 环境要求

| 组件 | 版本 / 说明 | 是否必需 |
|---|---|---|
| **VSCode** | ≥ 1.85 | ✅ |
| **SourcePawn Studio** | Sarrus1 发布的扩展 | ✅ |
| **All Autocomplete** | 跨文件补全 | ✅ |
| **spcomp.exe** | SourcePawn 编译器（已包含在仓库根目录） | ✅ |
| **SourceMod** | ≥ 1.11（取决于服务器版本） | 服务器侧必需 |
| **L4D2 专用服务器** | 任意部署方式 | 仅在需要上传/调试时 |

> 💡 SourcePawn Studio 扩展同时承担**代码补全**、**编译**、**上传**三件事，是本工作区的核心扩展。

---

## 🗂 目录结构

```
l4d2-plugin/                ← 工作区根
│
├── spcomp.exe                      ← SourcePawn 编译器（所有插件共用）
├── compile.exe                     ← SourcePawn 的封装调用工具
│
├── include/                       ← 官方头文件层（公共基础库）
│   ├── sourcemod.inc
│   ├── core.inc
│   ├── clients.inc
│   ├── admin.inc
│   ├── menus.inc
│   ├── sdktools.inc
│   ├── sdktools_*.inc
│   ├── cstrike.inc
│   ├── tf2.inc
│   ├── halflife.inc
│   └── ...（其他 SourceMod 官方 .inc）
│
├── include-ext/                   ← 跨插件共享的第三方 include（多个插件共用的库放这里）
│   ├── README.md                  ←   本目录使用说明
│   ├── multicolors.inc
│   ├── left4dhooks_silver.inc
│   └── ...（按需添加）
│
├── plugins/                         ← 编译产物（与服务器 addons/sourcemod/plugins/ 同名）
│   ├── plugin_hello.smx
│   ├── plugin_l4d.smx
│   └── plugin_admin.smx
│
├── source/                         ← 插件源码根目录
│   │
│   ├── plugin_hello/               ← 插件 A：示例 / 学习插件
│   │   ├── hello.sp              ←   主源码文件
│   │   └── include/              ←   插件私有头文件（只属于这个插件）
│   │       ├── multicolors.inc
│   │       └── multicolors/      ←   兼容某些库用子目录组织 include 的情况
│   │           ├── morecolors.inc
│   │           └── colors.inc
│   │
│   ├── plugin_l4d/                 ← 插件 B：求生之路相关插件
│   │   ├── l4d_test.sp
│   │   └── include/
│   │       └── left4dhooks_silver.inc
│   │
│   └── plugin_admin/               ← 插件 C：管理 / 管理员相关插件
│       ├── admin.sp
│       └── include/
│           └── （按需添加）
```

### 📁 各个目录的角色

| 目录 | 角色 | 是否进 git |
|---|---|---|
| `include/` | 官方 SourceMod 头文件（所有插件共用） | ❌ 通常不进（太大且与平台绑定） |
| `include-ext/` | 跨插件共享的**第三方** include（多个插件都要用的库，如 `multicolors`） | ✅ |
| `source/<plugin>/` | 插件源码（每个子目录 = 一个独立插件） | ✅ |
| `source/<plugin>/include/` | 该插件**私有**的 include（只被这一个插件用到的库） | ✅ |
| `plugins/` | 编译产物 | ❌（见 `.gitignore`） |
| `.vscode/` | 编辑器配置（settings.json 已 gitignore） | ✅ 仅 example 文件 |

> 💡 简单记法：**只被一个插件用到 → 插件私有 `include/`；被多个插件用到 → 根目录 `include-ext/`；官方库 → 根目录 `include/`。**

---

## ⚙ VSCode 配置

工作区使用 `.vscode/settings.json` 统一管理所有编辑器相关配置。**真实配置（包含服务器地址、RCON 密码、SFTP 凭据）已被 `.gitignore` 排除**，请勿提交到仓库。

### 步骤 1：复制配置模板

```bash
cp .vscode/settings.json.example .vscode/settings.json
```

### 步骤 2：修改关键路径

打开 `.vscode/settings.json`，按你本机情况修改下列字段：

```jsonc
{
    // ① 编译器路径（默认指向工作区根目录下的 spcomp.exe）
    "sourcepawnLanguageServer.spcomp_path": "${workspaceFolder}/spcomp.exe",

    // ② 官方 include 根目录
    "sourcepawnLanguageServer.sourcemod_home": "${workspaceFolder}/include",

    // ③ 插件私有 include 路径（每个插件子目录都加一条）
    "sourcepawn.optionalIncludeDirsPaths": [
        "${workspaceFolder}/source/plugin_hello/include",
        "${workspaceFolder}/source/plugin_l4d/include"
        // 每加一个插件就追加一项
    ],

    // ④ 编译产物输出路径（必须以 / 结尾！）
    "sourcepawn.outputDirectoryPath": "C:/你的路径/l4d2-plugin/plugins/",
    //   ⚠️ 此字段不能用 ${workspaceFolder} 变量（SourcePawn Studio 已知 bug）
    //   ⚠️ 必须以 / 结尾，否则扩展把 .smx 文件名拼到路径后面会找不到目录

    // ⑤ 编译后自动上传到服务器（true / false）
    "sourcepawn.uploadToServerAfterCompile": true,

    // ⑥ SFTP/FTP 上传配置（编译产物从这里推到服务器）
    "sourcepawn.UploadOptions": {
        "host": "your-server.com",
        "port": 22,                       // SFTP=22，FTP=21
        "username": "your-ssh-user",
        "password": "your-ssh-password",  // 用 SSH 密钥则留空
        "sftp": true,                     // 推荐用 SFTP（Ubuntu 已自带 OpenSSH）
        "remoteRoot": "/your/l4d2/path/left4dead2/addons/sourcemod",
        "exclude": [
            "scripting/**/",
            ".vscode/**/",
            ".github/**/",
            ".git",
            ".gitignore",
            "*.md"
        ]
    },

    // ⑦ RCON 配置（编译后自动执行服务器命令，如 sm plugins refresh）
    "sourcepawn.SourceServerOptions": {
        "host": "your-server.com",
        "port": 27015,
        "encoding": "ascii",
        "timeout": 1000,
        "password": "your-rcon-password"
    }
}
```

### 步骤 3：重启 VSCode

修改完 `settings.json` 后**完全退出并重新打开 VSCode**（不是 Reload Window），SourcePawn Studio 才会重新加载配置。

---

## ✍ 编写第一个插件

以一个最小的「服务器欢迎消息」插件为例：

### 第 1 步：创建插件目录

```bash
mkdir source/hello_welcome
mkdir source/hello_welcome/include
```

### 第 2 步：写主源码 `source/hello_welcome/hello_welcome.sp`

```sourcepawn
#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>

public Plugin myinfo = {
    name        = "Hello Welcome",
    author      = "YourName",
    description = "玩家进服时发送欢迎消息",
    version     = "1.0.0",
    url         = ""
};

public void OnClientPutInServer(int client) {
    if (IsFakeClient(client)) return;
    PrintToChat(client, "欢迎来到服务器！");
}
```

### 第 3 步：（可选）下载第三方头文件

如果插件需要第三方库（例如 `multicolors`），按使用范围二选一：

- **只本插件用** → 放到 `source/hello_welcome/include/multicolors.inc`，并在 `settings.json` 的 `includeDirectories` 中加上 `source/hello_welcome/include`（`settings.json` / `settings.json.example` 默认未列出，需手动追加）
- **多个插件都要用** → 放到根目录 `include-ext/multicolors.inc`（已在 `settings.json` 的 `includeDirectories` 中默认包含，全工作区可见，无需额外配置）

> ⚠️ **重要**：所有第三方头文件必须使用 `.inc` 扩展名，不能用 `.sp`（spcomp 只识别 `.inc` 作为 include）。

### 第 4 步：编译

按 **`F7`**（SourcePawn Studio 默认编译快捷键）。预期：

- ✅ 编译产物出现在 `plugins/hello_welcome.smx`
- ✅ 如果 `uploadToServerAfterCompile: true`，自动上传到服务器
- ✅ 服务器自动 `sm plugins refresh`，新插件立即生效

---

## 🛠 编译与上传

### 编译流程图

```
┌──────────────────────────────────────────────────────────┐
│  按 F7（或保存文件触发）                                │
└──────────────────┬───────────────────────────────────────┘
                   ▼
┌──────────────────────────────────────────────────────────┐
│ ① spcomp 编译 .sp → .smx（本地生成）                   │
│    输出位置：plugins/<plugin_name>.smx                              │
└──────────────────┬───────────────────────────────────────┘
                   ▼
┌──────────────────────────────────────────────────────────┐
│ ② SFTP/FTP 上传 .smx 到服务器（如果开启）                             │
│    目标位置：<remoteRoot>/plugins/<plugin_name>.smx               │
│    ⚠️ 本地路径与 remoteRoot 必须满足镜像关系：                │
│      本地 source/... → 服务器 <remoteRoot>/source/...          │
│      本地 plugins/... → 服务器 <remoteRoot>/plugins/...     │
└──────────────────┬───────────────────────────────────────┘
                   ▼
┌──────────────────────────────────────────────────────────┐
│ ③ RCON 执行服务器命令（如果开启）                            │
│    默认命令：sm plugins refresh                                    │
│    作用：让 SourceMod 加载新上传的 .smx                       │
└──────────────────────────────────────────────────────────┘
```

### 手动触发上传（不必每次都重编译）：

1. 命令面板（`Ctrl+Shift+P`）
2. 输入 **`SM: Upload to Server`**
3. 回车

### 不上传到服务器也能开发

如果你只是想先在本地看 `.smx` 是否能成功生成，可以暂时关掉：

```json
"sourcepawn.uploadToServerAfterCompile": false
```

或干脆**注释掉**整个 `UploadOptions` 块。本地编译不受影响。

---

## 📐 源码目录规范

### 命名约定

| 类型 | 命名规则 | 示例 |
|---|---|---|
| 插件目录 | 小写 + 下划线 | `plugin_l4d`、`afk` |
| 主源码文件 | 与插件目录同名 | `plugin_l4d/plugin_l4d.sp` |
| 插件私有 include | `source/<plugin>/include/<库名>.inc` | `source/plugin_l4d/include/multicolors.inc` |
| 共享第三方 include | `include-ext/<库名>.inc` | `include-ext/multicolors.inc` |
| 第三方 include 子目录 | 与库的官方组织保持一致 | `include-ext/multicolors/{morecolors,colors}.inc` |

### 插件目录模板

```
source/<plugin_name>/
├── <plugin_name>.sp            ← 主源码（必需）
└── include/                     ← 插件私有头文件（按需）
    ├── lib1.inc
    ├── lib2.inc
    └── lib2_subdir/
            └── sub_module.inc
```

### 编码规范

每个 `.sp` 文件**强制**以这两行开头：

```sourcepawn
#pragma semicolon 1
#pragma newdecls required
```

- `semicolon 1`：强制每行语句以分号结束（避免老式 SourcePawn 代码的语法陷阱）
- `newdecls required`：使用新版声明语法，函数 tag 必须显式写出（`public`、`static` 等）

### myinfo 模板

```sourcepawn
public Plugin myinfo = {
    name        = "插件名",
    author      = "作者",
    description = "一句话说明功能",
    version     = "1.0.0",
    url         = ""
};
```

### 不要做的事

| ❌ 反面做法 | ✅ 正确做法 |
|---|---|
| 把多个插件源码混在一个目录 | 一个插件 = 一个子目录 |
| 跨插件共享 `.sp` 源文件 | 各自维护自己的副本（SourcePawn 不支持跨插件 include `.sp`） |
| 把 `.sp` 文件当 include 引用 | include 必须用 `.inc` 扩展名 |
| 把第三方 include 混进工作区根 `include/`（污染官方库） | 放 `include-ext/`（共享）或 `source/<plugin>/include/`（私有） |
| 把 `compiled/` 保留为输出目录 | 改名为 `plugins/`，与服务器同名目录一一对应 |

---

## ❓ 常见问题

### 编译时报 "cannot read from file: 'xxx'"

某个 include 找不到。检查：

1. 文件**扩展名是 `.inc`** 不是 `.sp`
2. 文件路径**确实存在于** `optionalIncludeDirsPaths` 列表中的某个目录
3. 文件名**拼写正确**（SourcePawn 大小写敏感）

### 编译时报 "output directory does not exist"

1. 检查 `sourcepawn.outputDirectoryPath` 是否**以 `/` 结尾**（最重要！）
2. 检查路径中的 `\` 是否写成了 `/`（SourcePawn Studio 在 Windows 上也要求用正斜杠）
3. 不要用 `${workspaceFolder}` 变量（已知 bug），用绝对路径

### 服务器连接 ECONNREFUSED

SourcePawn Studio 连服务器失败（TCP RCON）。常见原因：

1. **服务器绑定了 127.0.1.1** —— Linux 上 `srcds_run` 自动检测主机名解析时会撞上 Ubuntu 的 `/etc/hosts` 默认 `127.0.1.1 your-hostname`，根加 `-ip 0.0.0.0` 参数强制绑定全网卡
2. **TCP 27015 被防火墙/安全组挡了** —— 游戏客户端走 UDP 通，但 RCON 走 TCP 不通，需单独放行
3. **服务器防火墙未启用端口** —— Ubuntu 用 `sudo ufw allow 27015/tcp`，云厂商关前都需放

### 上传后服务器看不到插件

1. 检查 `remoteRoot` 是否指向服务器上 `addons/sourcemod` 目录
2. 检查本地输出目录名是否与 SourceMod 一致（即 `plugins/` 而不是 `compiled/`）
3. 上传是**镜像整个工作区树**到 `remoteRoot` 下，本地 `plugins/foo.smx` 镜像到 `<remoteRoot>/plugins/foo.smx`

### 服务器没自动重载插件

RCON 没成功执行。检查：

1. `sourcepawn.runServerCommandsAfterCompile` 是否为 `true`（默认）
2. 服务器 `cfg/server.cfg` 里有 `rcon_password "..."` 设置，且 `SourceServerOptions.password` 与之**完全一致**
3. 服务器进程确实在监听 TCP 27015（`ss -tlnp | grep 27015` 应有输出）

---

## 📚 参考资料

### 官方文档

- [SourcePawn Studio（VSCode 扩展）Wiki](https://github.com/Sarrus1/sourcepawn-studio/wiki/Settings)
- [SourceMod 官方文档](https://wiki.alliedmods.net/SourceMod_(zh_cn))
- [Left 4 DHooks Direct（Silvers）](https://github.com/Silvers-Careee/Left-4-Dead-Direct)
- [SourcePawn 语言参考](https://wiki.alliedmods.net/SourcePawn_(zh_cn))

### 推荐第三方库

- `multicolors` / `morecolors` —— 多线程安全的彩色聊天 API
- `left4dhooks` —— L4D2 专用 hooks 集合（支持 Silvers Direct 版本）
- `dhooks` —— 动态 hooks（SourceMod 内置）

### 常用服务器命令

```bash
# 重载所有插件
sm plugins refresh

# 重载指定插件
sm plugins reload <plugin_name>

# 查看所有插件加载状态
sm plugins list

# 启用/禁用插件
sm plugins load <plugin_name>
sm plugins unload <plugin_name>
```

---

## 📜 许可

本仓库源码遵循 GPL（继承自 SourceMod 生态）。具体许可见各 `.sp` 文件头注释。

---

## 🤝 维护说明

- 所有**敏感凭据**（RCON 密码、SSH 密码）必须放在 `.vscode/settings.json`，**绝不能提交**。`.gitignore` 已排除该文件。
- 新加第三方库时，**只被一个插件用到** → 放 `source/<plugin>/include/`；**被多个插件用到** → 放 `include-ext/`。**不要混进工作区根 `include/`**（那是给 SourceMod 官方头文件留的）。
- `include-ext/` 默认已经在 `settings.json` 的 `includeDirectories` 中包含；新增插件私有 include 时，记得在 `includeDirectories` 中**追加**对应的 `source/<plugin>/include/` 路径。
- 修改本工作区结构时，**同步更新本文档**，避免知识漂移。
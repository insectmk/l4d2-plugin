# include-ext/

本目录用于存放**跨插件共享的第三方 include 文件**（`.inc`）。

## 何时把 include 放到这里 vs 放到 `source/<plugin>/include/`

| 场景 | 放哪里 |
|---|---|
| 多个插件都用到的库（如 `multicolors`、`left4dhooks`） | ✅ 放本目录 `include-ext/` |
| 只被一个插件用到的库 | 放 `source/<plugin>/include/` |
| SourceMod 官方头文件（如 `sourcemod.inc`） | ❌ 不要放这里，放根目录的 `include/` |

## 怎么用

把 `.inc` 文件直接放进本目录即可。然后把本目录的绝对路径加到 `.vscode/settings.json` 的 `SourcePawnLanguageServer.includeDirectories` 数组中（`settings.json` 和 `settings.json.example` 里都已包含本目录路径，按需调整为你本机的 Windows 用户名即可）。

## 子目录约定

如果某个第三方库官方有自带的子目录组织方式（例如 `multicolors` 库下还分 `colors.inc` / `morecolors.inc`），保留它的子目录结构：

```
include-ext/
├── multicolors.inc
└── multicolors/
    ├── colors.inc
    └── morecolors.inc
```

这样 spcomp 在 `#include <multicolors/colors.inc>` 时能找到。

## 当前收录的组件

| 组件 | 维护者 | License | 说明 |
|---|---|---|---|
| `left4dhooks*.inc`（5 个） | Silvers | GPLv3+ | 来自 [Silvers-Careee/Left-4-Dead-Direct](https://github.com/Silvers-Careee/Left-4-Dead-Direct)，含历史作者 ProdigySim / Downtown1 / Visor / Attano / Accelerator74 / LuxLuma / Mr.Zero（详见各 .inc 文件头注释） |
| `multicolors.inc` + `multicolors/colors.inc` + `multicolors/morecolors.inc` | Popoklopsi / Powerlord / exvel / Dr. McKay | 待核实（迁移前未确认 license header） | 来自 Popoklopsi 的 multicolors 库 |

## 迁移记录

- **2026-10-12**：首次从 `source/afk/include/` 批量迁入上述 7 个文件 + 1 个子目录。迁移动机：与 README 命名约定对齐（多插件共享 → `include-ext/`），`afk` 不再独占这些库。

  ⚠️ 迁移过程中发现 `source/afk/include/left4dhooks.sp`（60346 字节）是一份**错放的旧副本**（与 `source/afk/left4dhooks.sp` 62644 字节内容不同），spcomp 不会以 `.sp` 当 include 用，所以未一并迁移。**待用户决定**：删除该错放副本，还是把它移动到正确位置（如 `source/afk/` 作为 left4dhooks 插件的源文件）。

## .gitignore 说明

本目录**整体**进 Git（第三方 include 是源码的一部分）。如果某个 .inc 文件体积特别大或与平台绑定，按需在该文件旁加 `*.inc` 级别的排除。

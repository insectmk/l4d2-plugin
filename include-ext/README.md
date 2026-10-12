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

## .gitignore 说明

本目录**整体**进 Git（第三方 include 是源码的一部分）。如果某个 .inc 文件体积特别大或与平台绑定，按需在该文件旁加 `*.inc` 级别的排除。

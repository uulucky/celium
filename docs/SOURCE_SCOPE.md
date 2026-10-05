# 源码公开范围

本仓库采用独立导出方式维护：只复制经过检查的客户端界面与平台封装文件，不同步内部产品仓库的 Git 历史。

## 已公开

| 文件 | 用途 |
| --- | --- |
| `client/windows/CeliumClient.ps1` | WinForms 界面、状态自动刷新、设备搜索与收藏、连接和诊断操作入口 |
| `client/windows/CeliumLauncher.ps1` | 界面脚本的启动与错误提示封装 |
| `client/windows/assets/` | 客户端显示使用的 Celium 图标资源 |
| `client/windows/store/activation.go` | 处理 Microsoft Store FullTrust 启动参数；不包含 broker 实现 |
| `client/windows/store/PluginHost.cpp` | Windows 原生应用激活后启动桌面界面的封装 |
| `client/windows/store/Host.cpp` | Windows 原生连接配置的创建、连接、断开与状态查询封装 |
| `packaging/msix/AppxManifest.example.xml` | 从清单生成逻辑导出的结构示例，包身份及发布者均为占位信息 |
| `docs/images/celium-desktop.png` | 用户指定的产品展示截图 |

前三个源码组件以及 Windows 封装来自当前客户端实现。清单示例不包含正式商店身份信息，也不是可提交的发行清单。

## 未公开

- 设备通信、加密协议与数据包转发核心。
- 本地网络引擎、后台 broker、状态与诊断命令的内部实现。
- Windows VPN 插件的数据通道实现与内部通信协议。
- 协调服务、中继服务、账号管理、计费和系统管理后台。
- 数据库、用户或设备运行数据、日志、备份及生产配置。
- SSH、支付、OSS、应用签名相关的凭据、私钥或证书。
- 内部部署脚本、构建产物、完整构建脚本与私有 Git 历史。

## 使用边界

这是一份部分客户端源码展示，而不是完整产品源码发行。界面依赖未公开的 `CeliumStore.exe`；仅有这些文件无法独立构建或运行完整客户端。

公开脚本保留官网安装版的共用界面分支，以便如实展示当前代码。官网版更新器和服务不在此导出范围内。不要将这些脚本覆盖到已安装的正式客户端中。

未来同步应继续使用文件白名单，检查新增内容后再提交；`.gitignore` 仅是辅助保护，不能代替内容审查。

# MSIX 清单示例

`AppxManifest.example.xml` 展示 Celium 商店版应用的结构，包括原生应用入口、后台 VPN 任务、桌面进程启动扩展、运行时依赖与平台能力声明。

示例中的包名、发布者和包族名称已替换为演示值。它不包含正式签名材料，不是可提交到 Microsoft Store 的发行清单。

清单所引用的 `CeliumStore.exe`、`CeliumVpnPlugin.dll`、正式图标尺寸资源与依赖包未随本仓库发布。完整打包工具链也未公开，不能仅凭该示例生成可用的客户端。

有关平台封装源码，见 `client/windows/store/`；公开边界见 `docs/SOURCE_SCOPE.md`。

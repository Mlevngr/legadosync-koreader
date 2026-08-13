# LegadoSync for KOReader v1.0.0

首个正式版本，用于在 Kindle 上通过 KOReader 同步 WebDAV 书库和阅读进度。

## 功能

- Kindle 本地书库与 WebDAV 双向同步。
- 按修改时间选择较新文件，不同步删除操作。
- 按书籍内容哈希匹配 KOReader 阅读位置。
- 支持自动和手动推送、拉取阅读进度。
- 离线自动同步静默跳过，避免频繁打扰。

## 安装

1. 下载 `legadosync-koreader-v1.0.0.zip` 和对应的 `.sha256` 文件。
2. 校验 ZIP 后解压。
3. 将 `legadosync.koplugin` 复制到 Kindle 的 `koreader/plugins/`。
4. 重启 KOReader，并在“WebDAV 同步 -> 连接设置”中完成配置。

## 注意

本插件同步的是 KOReader 阅读位置，不会读写 Kindle 原生阅读器或 Amazon 云端阅读进度。

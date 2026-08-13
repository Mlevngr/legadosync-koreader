# LegadoSync for KOReader v1.1.0

此版本增加 Legado（阅读）与 KOReader 的 EPUB 阅读进度双向互通。

## 功能

- Kindle 本地书库与 WebDAV 双向同步。
- 按修改时间选择较新文件，不同步删除操作。
- 按书名、作者和章节匹配 Legado `bookProgress` JSON。
- 将 Legado 的章节序号、章节标题和字符位置转换为 KOReader XPointer。
- 将 KOReader 位置反向写回同一个 Legado 进度文件。
- 保存 KOReader 精确 XPointer，同时兼容 Legado 原有字段。
- 离线自动同步静默跳过，避免频繁打扰。

## 安装

1. 下载 `legadosync-koreader-v1.1.0.zip` 和对应的 `.sha256` 文件。
2. 校验 ZIP 后解压。
3. 将 `legadosync.koplugin` 复制到 Kindle 的 `koreader/plugins/`。
4. 重启 KOReader，并在“WebDAV 同步 -> 连接设置”中完成配置。

## 注意

首次在两个阅读器之间转换时，因文本清洗差异可能有少量字符偏差。进度互通目前支持 EPUB 等流式文档，不支持 PDF，也不会读写 Kindle 原生阅读器或 Amazon 云端进度。

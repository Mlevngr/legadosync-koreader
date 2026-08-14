# LegadoSync for KOReader v1.1.2

此安全修复版本将书籍同步严格限制为 EPUB，避免误同步 Kindle 系统辅助文件。

## 功能

- Kindle 本地书库与 WebDAV 双向同步。
- 按修改时间选择较新文件，不同步删除操作。
- 按书名、作者和章节匹配 Legado `bookProgress` JSON。
- 将 Legado 的章节序号、章节标题和字符位置转换为 KOReader XPointer。
- 将 KOReader 位置反向写回同一个 Legado 进度文件。
- 保存 KOReader 精确 XPointer，同时兼容 Legado 原有字段。
- 离线自动同步静默跳过，避免频繁打扰。
- 已接受的手机进度会按时间戳记录，休眠唤醒后不会重复询问。

## 安装

1. 下载 `legadosync-koreader-v1.1.2.zip` 和对应的 `.sha256` 文件。
2. 校验 ZIP 后解压。
3. 将 `legadosync.koplugin` 复制到 Kindle 的 `koreader/plugins/`。
4. 重启 KOReader，并在“WebDAV 同步 -> 连接设置”中完成配置。

## 注意

“立即同步书籍”现在只扫描和传输 `.epub`；TXT、PDF、脚本、日志、字典及其他文件会被忽略。

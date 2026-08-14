# LegadoSync for KOReader v1.2.0

此版本重点改进同步方向、冲突防护、WebDAV 兼容性和可测试性。

## 功能

- 书籍同步支持仅下载、仅上传和双向模式，默认使用更安全的仅下载。
- 持久记录文件状态；两端都变化或无法可靠判断时报告冲突，不传播删除。
- 按书名、作者和章节匹配 Legado `bookProgress` JSON。
- 将 Legado 的章节序号、章节标题和字符位置转换为 KOReader XPointer。
- 将 KOReader 位置反向写回同一个 Legado 进度文件。
- 保存 KOReader 精确 XPointer，同时兼容 Legado 原有字段。
- 离线自动同步静默跳过，避免频繁打扰。
- 已接受的手机进度会按时间戳记录，休眠唤醒后不会重复询问。
- 缓存已匹配的进度文件，避免每次下载整个进度目录。
- 通过 ETag、上传前二次读取和上传后回读校验防止静默覆盖。
- 自动探测服务器是否真正支持 `If-Match`；不支持时停止自动上传，手动上传需确认。
- 提供 Kindle 目录选择器和 WebDAV 连接测试。

## 安装

1. 下载 `legadosync-koreader-v1.2.0.zip` 和对应的 `.sha256` 文件。
2. 校验 ZIP 后解压。
3. 将 `legadosync.koplugin` 复制到 Kindle 的 `koreader/plugins/`。
4. 重启 KOReader，并在“WebDAV 同步 -> 连接设置”中完成配置。

## 注意

“立即同步书籍”只扫描和传输 `.epub`；TXT、PDF、脚本、日志、字典及其他文件会被忽略。当前测试服务器会忽略 `If-Match`，因此插件会按设计停用自动进度上传；仍可在明确确认风险后手动上传。

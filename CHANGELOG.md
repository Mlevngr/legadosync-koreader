# Changelog

本项目遵循 [Semantic Versioning](https://semver.org/)；发布记录采用 [Keep a Changelog](https://keepachangelog.com/) 格式。

## [1.2.0] - 2026-08-15

### Added

- 新增仅下载、仅上传和双向三种书籍同步方向，新安装及旧版迁移默认使用更安全的仅下载模式。
- 新增 Kindle 本地目录选择器、WebDAV 连接测试、书籍同步状态基线和冲突计数。
- 新增进度文件名缓存、ETag 条件写入、服务器条件写入能力探测，以及上传前复核和上传后校验。
- 新增 Unicode、同名书匹配、同步决策和 WebDAV 响应解析的自动测试，并在分支、拉取请求和发布流程运行。

### Changed

- 进度匹配在书名相同但作者冲突时拒绝选择，KOReader XPointer 仅在同一 EPUB 指纹上复用。
- WebDAV `PROPFIND` 仅接受 `207`，不再依赖响应项顺序，并保留服务端返回的 ETag 原值。
- 双向书籍同步无法可靠判断新旧或检测到两端都变化时跳过冲突，不再把缺失时间视为旧文件。

### Fixed

- 本地 EPUB 替换先保留备份，避免重命名失败后丢失原文件。
- 检查进度 JSON 编码、写入和关闭错误，避免上传截断文件。
- 网络请求异常后恢复 KOReader socket 超时设置。

## [1.1.2] - 2026-08-14

### Fixed

- 书籍同步仅接受 EPUB，防止误选 `/mnt/us/documents` 时上传 Kindle 脚本、日志、字典和其他非书文件。
- 将已接受的 Legado 进度时间戳保存到书籍 `.sdr`，避免 Kindle 休眠唤醒后反复询问同一进度。

## [1.1.1] - 2026-08-14

### Fixed

- Legado 章节标题在替换 EPUB 后不存在时，回退到其零基章节索引，避免无法映射。
- 默认 Kindle 书籍同步目录改为 `/mnt/us/books`，并明确该设置不影响进度同步或 KOReader 文件浏览器目录。

## [1.1.0] - 2026-08-14

### Added

- 与 Legado `bookProgress` JSON 双向同步 EPUB 阅读进度。
- 通过书名、作者、章节标题和 UTF-16 字符位置映射 Legado 与 KOReader。
- 在 Legado JSON 中保存 KOReader XPointer，后续可精确恢复位置。

### Changed

- 新安装的默认远端目录改为 `legado/books` 和 `legado/bookProgress`。
- 自动上传仅在 Kindle 阅读位置实际发生变化后执行，避免覆盖未接受的手机进度。

## [1.0.0] - 2026-08-14

### Added

- Kindle 本地书库与 WebDAV 书库双向同步。
- 基于修改时间的冲突处理，以及不传播删除的安全策略。
- 基于书籍内容哈希的 KOReader 阅读位置同步。
- 打开书籍时拉取、关闭书籍或休眠时上传阅读进度。
- 手动同步菜单与 KOReader Dispatcher 动作。
- 可复现的 ZIP 发布包、SHA-256 校验文件和 GitHub Release 自动化。

[1.2.0]: https://github.com/Mlevngr/legadosync-koreader/releases/tag/v1.2.0
[1.1.2]: https://github.com/Mlevngr/legadosync-koreader/releases/tag/v1.1.2
[1.1.1]: https://github.com/Mlevngr/legadosync-koreader/releases/tag/v1.1.1
[1.1.0]: https://github.com/Mlevngr/legadosync-koreader/releases/tag/v1.1.0
[1.0.0]: https://github.com/Mlevngr/legadosync-koreader/releases/tag/v1.0.0

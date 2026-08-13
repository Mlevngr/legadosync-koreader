# LegadoSync for KOReader

一个运行在 Kindle/KOReader 上的 WebDAV 同步插件，用于：

- 在 Kindle 本地书库与 WebDAV 之间双向同步书籍。
- 按书籍内容哈希同步 KOReader 阅读位置。
- 打开书籍时检查远端进度，关闭书籍或休眠时上传进度。
- 从菜单或手势手动推送、拉取当前书籍进度。

## 安装

1. 从 [Releases](https://github.com/Mlevngr/legadosync-koreader/releases) 下载最新的 `legadosync-koreader-vX.Y.Z.zip`。
2. 对照同一 Release 中的 `.sha256` 文件检查下载完整性。
3. 解压 ZIP，将其中的 `legadosync.koplugin` 整个目录复制到 Kindle 的 `koreader/plugins/` 下。
4. 重启 KOReader，在“工具 -> 插件管理 -> 用户插件”中确认插件已启用。
5. 打开“WebDAV 同步 -> 连接设置”，填写 WebDAV 地址、账号、远端目录和 Kindle 本地书库目录。

Kindle 上常见的本地书库目录是 `/mnt/us/documents`。WebDAV 地址应指向一个已经存在且账号可写的根目录，例如：

```text
https://dav.example.com/remote.php/dav/files/alice/KOReader
```

插件会在该地址下自动创建配置的书籍目录和进度目录，默认分别为 `books` 和 `progress`。

## 同步规则

- 本地或远端单独存在的书籍会被复制到另一端。
- 两端都有同一路径的书籍时，修改时间较新的一端覆盖较旧的一端。
- 插件不会传播删除操作，防止错误配置或临时空目录导致书库被清空。
- 隐藏文件、`.sdr` 阅读元数据目录和 KOReader 不支持的文件不会作为书籍同步。
- 阅读进度以书籍内容哈希匹配，因此改名或移动书籍后仍可匹配；内容不同的版本视为不同书籍。
- 自动拉取发现不同进度时会询问是否跳转，手动拉取会直接应用。

## 限制

- 阅读进度只适用于 KOReader，不读写 Kindle 原生阅读器的数据库或 Amazon 云端进度。
- 当前同步阅读位置和百分比，不同步批注、书签、排版设置或统计数据。
- WebDAV 服务器需支持 `PROPFIND`、`GET`、`PUT` 和 `MKCOL`。
- 账号密码与 KOReader 内置 WebDAV 插件一样，以明文形式保存在 Kindle 的 KOReader 设置目录中；建议使用专用账号或应用密码。

## 开发与发布

运行 `./scripts/package.sh v1.0.0 dist` 可在 `dist/` 中生成与 GitHub Release 相同结构的 ZIP 和 SHA-256 校验文件。推送符合 `v*.*.*` 格式的标签后，GitHub Actions 会自动验证版本、构建资产并创建正式 Release。

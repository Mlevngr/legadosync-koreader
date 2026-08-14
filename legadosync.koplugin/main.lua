local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local Dispatcher = require("dispatcher")
local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local LuaSettings = require("luasettings")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local NetworkMgr = require("ui/network/manager")
local Notification = require("ui/widget/notification")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local SyncUtil = require("syncutil")
local ffiUtil = require("ffi/util")
local json = require("json")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")

local LegadoSync = WidgetContainer:extend{
    name = "legadosync",
    title = _("WebDAV 同步"),
    settings_file = DataStorage:getSettingsDir() .. "/legadosync.lua",
}

local defaults = {
    schema_version = 2,
    address = "https://",
    username = "",
    password = "",
    remote_books = "legado/books",
    remote_progress = "legado/bookProgress",
    local_books = "/mnt/us/books",
    book_sync_mode = "download",
    auto_progress = true,
}

local MAX_OFFSET_WALK = 50000
local APPLIED_TIMESTAMP_SETTING = "legadosync_applied_timestamp"
local PROGRESS_CACHE_SETTING = "legadosync_progress_cache"
local BOOK_STATE_SETTING = "legadosync_book_state"

local function joinPath(left, right)
    if left == "" then return right end
    if right == "" then return left end
    return left:gsub("/+$", "") .. "/" .. right:gsub("^/+", "")
end

local function isStrongETag(etag)
    return type(etag) == "string" and etag ~= "" and not etag:match("^[Ww]/")
end

local function copyDefaults(settings)
    local result = {}
    for key, value in pairs(defaults) do
        result[key] = settings[key] == nil and value or settings[key]
    end
    return result
end

function LegadoSync:init()
    self.settings = LuaSettings:open(self.settings_file)
    local stored = self.settings:readSetting("config", {})
    if (stored.schema_version or 0) < 2 then
        if stored.remote_books == "books" then stored.remote_books = "legado/books" end
        if stored.remote_progress == "progress" or stored.remote_progress == "legado/bookprogress" then
            stored.remote_progress = "legado/bookProgress"
        end
        if stored.local_books == "/mnt/us/documents" then stored.local_books = "/mnt/us/books" end
        stored.book_sync_mode = "download"
        stored.schema_version = 2
        self.settings:saveSetting("config", stored)
        self.settings:flush()
    end
    self.config = copyDefaults(stored)
    self.ui.menu:registerToMainMenu(self)
end

function LegadoSync:onFlushSettings()
    if self.updated then
        self.settings:saveSetting("config", self.config)
        self.settings:flush()
        self.updated = nil
    end
end

function LegadoSync:isConfigured()
    return self.config.address:match("^https?://[^/]+") ~= nil
        and self.config.local_books ~= ""
end

function LegadoSync:getClient()
    local WebDAV = require("webdav")
    return setmetatable({
        address = self.config.address:gsub("/+$", ""),
        username = self.config.username,
        password = self.config.password,
    }, { __index = WebDAV })
end

function LegadoSync:showMessage(text)
    UIManager:show(InfoMessage:new{ text = text, timeout = 4 })
end

function LegadoSync:runOnline(callback, silent, immediate)
    if not self:isConfigured() then
        self:showMessage(_("请先配置 WebDAV 同步。"))
        return
    end
    if silent and not NetworkMgr:isConnected() then
        return
    end
    if NetworkMgr:willRerunWhenConnected(function() self:runOnline(callback, silent, immediate) end) then
        return
    end
    local run = function()
        local ok, err = pcall(callback)
        if not ok then
            logger.err("LegadoSync:", err)
            self:showMessage(_("同步失败：") .. tostring(err))
        end
    end
    if immediate then
        run()
    else
        UIManager:nextTick(run)
    end
end

function LegadoSync:configure(menu)
    local dialog
    dialog = MultiInputDialog:new{
        title = _("WebDAV 同步设置"),
        fields = {
            { text = self.config.address, hint = _("WebDAV 地址，例如 https://example.com/dav/user") },
            { text = self.config.username, hint = _("用户名") },
            { text = self.config.password, hint = _("密码"), text_type = "password" },
            { text = self.config.remote_books, hint = _("远端书籍目录") },
            { text = self.config.remote_progress, hint = _("远端进度目录") },
            { text = self.config.local_books, hint = _("书籍文件同步目录，例如 /mnt/us/books") },
        },
        buttons = {{
            { text = _("取消"), id = "close", callback = function() UIManager:close(dialog) end },
            {
                text = _("保存"),
                callback = function()
                    local values = dialog:getFields()
                    self.config.address = util.trim(values[1]):gsub("/+$", "")
                    self.config.username = util.trim(values[2])
                    self.config.password = values[3]
                    self.config.remote_books = util.trim(values[4]):gsub("^/+", ""):gsub("/+$", "")
                    self.config.remote_progress = util.trim(values[5]):gsub("^/+", ""):gsub("/+$", "")
                    self.config.local_books = util.trim(values[6]):gsub("/+$", "")
                    self.updated = true
                    self:onFlushSettings()
                    UIManager:close(dialog)
                    Notification:notify(_("同步设置已保存。本地目录仅用于“立即同步书籍”。"))
                    if menu then menu:updateItems() end
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function LegadoSync:chooseLocalBooksDirectory(menu)
    local PathChooser = require("ui/widget/pathchooser")
    UIManager:show(PathChooser:new{
        title = _("选择 Kindle 书籍目录"),
        path = self.config.local_books,
        select_file = false,
        show_files = false,
        onConfirm = function(path)
            self.config.local_books = path:gsub("/+$", "")
            self.updated = true
            self:onFlushSettings()
            if menu then menu:updateItems() end
            Notification:notify(_("书籍同步目录已更新。"), Notification.SOURCE_ALWAYS_SHOW)
        end,
    })
end

function LegadoSync:testConnection()
    self:runOnline(function()
        local client = self:getClient()
        local books, books_err = client:list(self.config.remote_books)
        if not books then error(_("无法读取远端书籍目录：") .. tostring(books_err)) end
        local progress, progress_err = client:list(self.config.remote_progress)
        if not progress then error(_("无法读取远端进度目录：") .. tostring(progress_err)) end
        self:showMessage(string.format(_("连接成功。\n书籍目录：%d 项\n进度目录：%d 项"), #books, #progress))
    end)
end

function LegadoSync:setBookSyncMode(mode, menu)
    self.config.book_sync_mode = mode
    self.updated = true
    self:onFlushSettings()
    if menu then menu:updateItems() end
end

function LegadoSync:addToMainMenu(menu_items)
    menu_items.legadosync = {
        text = self.title,
        sub_item_table = {
            {
                text = _("书籍同步方向"),
                sub_item_table = {
                    {
                        text = _("仅从 WebDAV 下载（推荐）"),
                        radio = true,
                        checked_func = function() return self.config.book_sync_mode == "download" end,
                        callback = function(menu) self:setBookSyncMode("download", menu) end,
                    },
                    {
                        text = _("仅上传到 WebDAV"),
                        radio = true,
                        checked_func = function() return self.config.book_sync_mode == "upload" end,
                        callback = function(menu) self:setBookSyncMode("upload", menu) end,
                    },
                    {
                        text = _("双向同步（高级）"),
                        radio = true,
                        checked_func = function() return self.config.book_sync_mode == "bidirectional" end,
                        callback = function(menu) self:setBookSyncMode("bidirectional", menu) end,
                    },
                },
            },
            {
                text = _("立即同步书籍"),
                enabled_func = function() return self:isConfigured() end,
                callback = function() self:syncBooks() end,
            },
            {
                text = _("拉取当前书籍进度"),
                enabled_func = function() return self.ui.document ~= nil and self:isConfigured() end,
                callback = function() self:pullProgress(true) end,
            },
            {
                text = _("上传当前书籍进度"),
                enabled_func = function() return self.ui.document ~= nil and self:isConfigured() end,
                callback = function() self:pushProgress(true) end,
                separator = true,
            },
            {
                text = _("自动同步阅读进度"),
                checked_func = function() return self.config.auto_progress end,
                callback = function()
                    self.config.auto_progress = not self.config.auto_progress
                    self.updated = true
                end,
            },
            {
                text_func = function()
                    return _("Kindle 书籍目录：") .. self.config.local_books
                end,
                keep_menu_open = true,
                callback = function(menu) self:chooseLocalBooksDirectory(menu) end,
            },
            {
                text = _("测试连接"),
                keep_menu_open = true,
                callback = function() self:testConnection() end,
            },
            {
                text = _("连接设置"),
                keep_menu_open = true,
                callback = function(menu) self:configure(menu) end,
            },
        },
    }
end

function LegadoSync:replaceLocalFile(temp_path, local_path)
    if lfs.attributes(local_path, "mode") ~= "file" then
        return os.rename(temp_path, local_path)
    end
    local backup_path = local_path .. ".legadosync.old"
    os.remove(backup_path)
    local backed_up, backup_err = os.rename(local_path, backup_path)
    if not backed_up then return nil, backup_err end
    local replaced, replace_err = os.rename(temp_path, local_path)
    if not replaced then
        os.rename(backup_path, local_path)
        return nil, replace_err
    end
    os.remove(backup_path)
    return true
end

function LegadoSync:scanLocal(root, relative, result)
    local directory = joinPath(root, relative)
    local ok, iterator, dir_obj = pcall(lfs.dir, directory)
    if not ok then return nil, iterator end
    for name in iterator, dir_obj do
        if name ~= "." and name ~= ".." and name:sub(1, 1) ~= "." and not name:match("%.sdr$") then
            local rel_path = joinPath(relative, name)
            local full_path = joinPath(root, rel_path)
            local link_attr = lfs.symlinkattributes(full_path)
            local attr = link_attr and link_attr.mode ~= "link" and lfs.attributes(full_path)
            if attr and attr.mode == "directory" then
                local scanned, err = self:scanLocal(root, rel_path, result)
                if not scanned then return nil, err end
            elseif attr and attr.mode == "file" and SyncUtil.isBookFile(name) then
                result[rel_path] = { path = full_path, size = attr.size, modification = attr.modification }
            end
        end
    end
    return true
end

function LegadoSync:scanRemote(client, root, relative, result)
    local entries, err = client:list(joinPath(root, relative))
    if not entries then return nil, err end
    for _, entry in ipairs(entries) do
        if entry.name:sub(1, 1) ~= "." and not entry.name:match("%.sdr$") then
            local rel_path = joinPath(relative, entry.name)
            if entry.is_dir then
                local scanned, scan_err = self:scanRemote(client, root, rel_path, result)
                if not scanned then return nil, scan_err end
            elseif SyncUtil.isBookFile(entry.name) then
                result[rel_path] = entry
            end
        end
    end
    return true
end

function LegadoSync:syncBooks(unsafe_confirmed)
    self:runOnline(function()
        local client = self:getClient()
        util.makePath(self.config.local_books)
        local ok, err = client:ensureDirectory(self.config.remote_books)
        if not ok then error(_("无法创建远端书籍目录：") .. tostring(err)) end
        if self.config.book_sync_mode ~= "download" and not unsafe_confirmed then
            local conditional, conditional_err = self:serverSupportsConditionalWrites(
                client, self.config.remote_books)
            if conditional == nil then error(_("无法验证服务器写入安全性：") .. tostring(conditional_err)) end
            if not conditional then
                UIManager:show(ConfirmBox:new{
                    text = _("服务器不支持并发写入保护。上传书籍可能覆盖刚更新的远端文件，是否仅本次继续？"),
                    ok_callback = function() self:syncBooks(true) end,
                })
                return
            end
        end

        local local_files, remote_files = {}, {}
        ok, err = self:scanLocal(self.config.local_books, "", local_files)
        if not ok then error(_("无法读取本地书库：") .. tostring(err)) end
        ok, err = self:scanRemote(client, self.config.remote_books, "", remote_files)
        if not ok then error(_("无法读取远端书库：") .. tostring(err)) end
        if self.config.book_sync_mode ~= "download" and not unsafe_confirmed then
            for _, remote_item in pairs(remote_files) do
                if not isStrongETag(remote_item.etag) then
                    UIManager:show(ConfirmBox:new{
                        text = _("服务器未提供可用的强 ETag，无法安全覆盖远端书籍。是否仅本次继续？"),
                        ok_callback = function() self:syncBooks(true) end,
                    })
                    return
                end
            end
        end

        local uploaded, downloaded, skipped, conflicts = 0, 0, 0, 0
        local mode = self.config.book_sync_mode
        local state_scope = table.concat({
            self.config.address, self.config.username, self.config.remote_books, self.config.local_books,
        }, "|")
        local book_state = self.settings:readSetting(BOOK_STATE_SETTING, {})
        if book_state.scope ~= state_scope then book_state = { scope = state_scope, files = {} } end
        book_state.files = book_state.files or {}
        local all_paths = {}
        for path in pairs(local_files) do all_paths[path] = true end
        for path in pairs(remote_files) do all_paths[path] = true end

        for path in pairs(all_paths) do
            local local_item, remote_item = local_files[path], remote_files[path]
            local local_path = joinPath(self.config.local_books, path)
            local remote_path = joinPath(self.config.remote_books, path)
            local decision = SyncUtil.decideBookSync(mode, local_item, remote_item, book_state.files[path])
            if decision == "download" then
                util.makePath(local_path:match("^(.*)/[^/]+$") or self.config.local_books)
                local temp_path = local_path .. ".legadosync"
                local success, download_err = client:download(remote_path, temp_path)
                if not success then error(_("下载失败：") .. path .. ": " .. tostring(download_err)) end
                local renamed, rename_err = self:replaceLocalFile(temp_path, local_path)
                if not renamed then error(_("保存下载文件失败：") .. tostring(rename_err)) end
                if remote_item.modification then
                    lfs.touch(local_path, remote_item.modification, remote_item.modification)
                end
                downloaded = downloaded + 1
                local_item = lfs.attributes(local_path)
            elseif decision == "upload" then
                local remote_dir = remote_path:match("^(.*)/[^/]+$")
                ok, err = client:ensureDirectory(remote_dir)
                if not ok then error(_("无法创建远端目录：") .. tostring(err)) end
                local validator = remote_item and remote_item.etag
                if not isStrongETag(validator) then validator = nil end
                local success, upload_err, upload_code, upload_etag = client:upload(
                    remote_path, local_path, nil, validator, not remote_item)
                if upload_code == 412 then error(_("远端书籍已变化，已拒绝覆盖：") .. path) end
                if not success then error(_("上传失败：") .. path .. ": " .. tostring(upload_err)) end
                uploaded = uploaded + 1
                local refreshed, refresh_err = client:list(remote_dir)
                if not refreshed then error(_("上传后读取远端书籍失败：") .. tostring(refresh_err)) end
                remote_item = nil
                local remote_name = ffiUtil.basename(remote_path)
                for _, item in ipairs(refreshed) do
                    if item.name == remote_name then remote_item = item break end
                end
                if not remote_item then error(_("上传后未找到远端书籍：") .. path) end
                remote_item.etag = remote_item.etag or upload_etag
            elseif decision == "conflict" then
                conflicts = conflicts + 1
            else
                skipped = skipped + 1
            end
            if decision ~= "conflict" and local_item and remote_item then
                book_state.files[path] = {
                    local_item = { size = local_item.size, modification = local_item.modification },
                    remote_item = {
                        size = remote_item.size,
                        modification = remote_item.modification,
                        etag = remote_item.etag,
                    },
                }
            end
        end
        self.settings:saveSetting(BOOK_STATE_SETTING, book_state)
        self.settings:flush()
        self:showMessage(string.format(
            _("书籍同步完成：上传 %d，下载 %d，未变更 %d，冲突 %d。"),
            uploaded, downloaded, skipped, conflicts))
        if self.ui.file_chooser then self.ui.file_chooser:refreshPath() end
    end)
end

function LegadoSync:isLegadoProgressSupported()
    return self.ui.document and not self.ui.document.info.has_pages
        and self.ui.rolling and self.ui.toc
end

function LegadoSync:getBookIdentity()
    local props = self.ui.doc_props or self.ui.document:getProps() or {}
    local filename = ffiUtil.basename(self.ui.document.file):gsub("%.[^.]+$", "")
    local title = props.title
    if not title or title == "" then title = props.display_title end
    if not title or title == "" then title = filename end
    return {
        name = title,
        author = props.authors or "",
        filename = filename,
    }
end

function LegadoSync:loadToc()
    self.ui.toc:fillToc()
    return self.ui.toc.toc or {}
end

function LegadoSync:findTocIndex(progress, current_xp)
    local toc = self:loadToc()
    if current_xp then
        return self.ui.toc:getTocIndexByPage(current_xp), toc
    end
    local wanted_title = SyncUtil.normalizeText(progress.durChapterTitle)
    local wanted_index = tonumber(progress.durChapterIndex) and progress.durChapterIndex + 1
    local exact
    for index, item in ipairs(toc) do
        if wanted_title ~= "" and SyncUtil.normalizeText(item.title) == wanted_title then
            if exact then
                exact = nil
                break
            end
            exact = index
        end
    end
    if exact then return exact, toc end
    if wanted_index and toc[wanted_index] then
        return wanted_index, toc
    end
    return nil, toc
end

function LegadoSync:readJsonFile(path)
    local file = io.open(path, "rb")
    if not file then return end
    local content = file:read("*a")
    file:close()
    local ok, data = pcall(json.decode, content)
    return ok and data or nil
end

function LegadoSync:downloadProgressRecord(client, remote_name, sequence)
    local temp_path = DataStorage:getDataDir() .. "/legadosync-progress-" .. tostring(sequence or 0) .. ".json"
    local ok, err, code, etag = client:download(joinPath(self.config.remote_progress, remote_name), temp_path)
    if not ok then
        os.remove(temp_path)
        return nil, err, code
    end
    local data = self:readJsonFile(temp_path)
    os.remove(temp_path)
    if type(data) ~= "table" or not data.name then
        return nil, _("远端进度 JSON 无效。")
    end
    return { name = remote_name, data = data, etag = etag }
end

function LegadoSync:downloadProgressRecords(client)
    local entries, err = client:list(self.config.remote_progress)
    if not entries then
        return nil, err
    end
    local records = {}
    for _, entry in ipairs(entries) do
        if not entry.is_dir and entry.name:sub(1, 1) ~= "." and entry.name:lower():match("%.json$") then
            local record, download_err = self:downloadProgressRecord(client, entry.name, #records + 1)
            if not record then return nil, download_err end
            record.etag = record.etag or entry.etag
            records[#records + 1] = record
        end
    end
    return records
end

function LegadoSync:findProgressRecord(records)
    return SyncUtil.findProgressRecord(records, self:getBookIdentity())
end

function LegadoSync:getProgressCacheScope()
    return table.concat({ self.config.address, self.config.username, self.config.remote_progress }, "|")
end

function LegadoSync:getMatchedProgressRecord(client)
    local cache = self.ui.doc_settings:readSetting(PROGRESS_CACHE_SETTING)
    if cache and cache.scope == self:getProgressCacheScope() and cache.name then
        local record, err, code = self:downloadProgressRecord(client, cache.name, "cached")
        if record then
            local matched = SyncUtil.findProgressRecord({ record }, self:getBookIdentity())
            if matched then return matched end
        elseif code ~= 404 then
            return nil, err
        end
    end

    local records, err = self:downloadProgressRecords(client)
    if not records then return nil, err end
    local record, reason = self:findProgressRecord(records)
    if not record then return nil, reason end
    self.ui.doc_settings:saveSetting(PROGRESS_CACHE_SETTING, {
        scope = self:getProgressCacheScope(),
        name = record.name,
    })
    return record
end

function LegadoSync:getCurrentLegadoProgress(previous)
    local xp = self.ui.rolling:getLastProgress()
    local toc_index, toc = self:findTocIndex(nil, xp)
    local chapter = toc_index and toc[toc_index]
    if not chapter or not chapter.xpointer then return end
    local text = self.ui.document:getTextFromXPointers(chapter.xpointer, xp) or ""
    local identity = self:getBookIdentity()
    local progress = previous or {}
    progress.name = previous and previous.name or identity.name
    progress.author = previous and previous.author or identity.author
    progress.durChapterIndex = toc_index - 1
    progress.durChapterPos = SyncUtil.utf16Length(text)
    progress.durChapterTime = os.time() * 1000
    progress.durChapterTitle = chapter.title
    progress.koreaderXPointer = xp
    progress.koreaderPercentage = self.ui.rolling:getLastPercent()
    progress.koreaderMappingVersion = 1
    progress.koreaderDocument = self.ui.doc_settings:readSetting("partial_md5_checksum")
    return progress
end

function LegadoSync:writeProgress(client, record, progress)
    local temp_path = DataStorage:getDataDir() .. "/legadosync-progress.json"
    local encoded_ok, encoded = pcall(json.encode, progress)
    if not encoded_ok then return nil, encoded end
    local file, err = io.open(temp_path, "wb")
    if not file then return nil, err end
    local wrote, write_err = file:write(encoded)
    local closed, close_err = file:close()
    if not wrote or not closed then
        os.remove(temp_path)
        return nil, write_err or close_err
    end
    local ok, upload_err, upload_code = client:upload(
        joinPath(self.config.remote_progress, record.name), temp_path, "application/json", record.etag)
    os.remove(temp_path)
    return ok, upload_err, upload_code
end

function LegadoSync:progressRecordChanged(previous, current)
    if previous.etag and current.etag and previous.etag ~= current.etag then return true end
    return previous.data.durChapterTime ~= current.data.durChapterTime
        or previous.data.durChapterIndex ~= current.data.durChapterIndex
        or previous.data.durChapterPos ~= current.data.durChapterPos
end

function LegadoSync:serverSupportsConditionalWrites(client, remote_directory)
    local scope = table.concat({ self.config.address, self.config.username, remote_directory }, "|")
    self.conditional_write_support = self.conditional_write_support or {}
    if self.conditional_write_support[scope] ~= nil then
        return self.conditional_write_support[scope]
    end

    local local_path = DataStorage:getDataDir() .. "/legadosync-precondition-test.json"
    local file, err = io.open(local_path, "wb")
    if not file then return nil, err end
    local wrote, write_err = file:write('{"probe":"initial"}')
    local closed, close_err = file:close()
    if not wrote or not closed then
        os.remove(local_path)
        return nil, write_err or close_err
    end
    local remote_path = joinPath(remote_directory,
        ".legadosync-precondition-" .. tostring(os.time()) .. "-" .. tostring(math.random(1000000)) .. ".json")
    local created, create_err = client:upload(remote_path, local_path, "application/json", nil, true)
    if not created then
        os.remove(local_path)
        return nil, create_err
    end
    file, err = io.open(local_path, "wb")
    if not file then
        client:delete(remote_path)
        return nil, err
    end
    wrote, write_err = file:write('{"probe":"stale"}')
    local closed, close_err = file:close()
    if not wrote or not closed then
        os.remove(local_path)
        client:delete(remote_path)
        return nil, write_err or close_err
    end
    local updated, update_err, update_code = client:upload(
        remote_path, local_path, "application/json", '"legadosync-invalid-etag"')
    os.remove(local_path)
    local deleted, delete_err = client:delete(remote_path)
    if not deleted then return nil, delete_err end
    if not updated and update_code ~= 412 then return nil, update_err or update_code end
    self.conditional_write_support[scope] = not updated and update_code == 412
    return self.conditional_write_support[scope]
end

function LegadoSync:pushProgress(interactive, immediate, unsafe_confirmed)
    if not self.config.auto_progress and not interactive then return end
    if not self:isLegadoProgressSupported() then
        if interactive then self:showMessage(_("Legado 进度互通目前仅支持 EPUB 等流式文档。")) end
        return
    end
    local current_xp = self.ui.rolling:getLastProgress()
    if not interactive and self.last_synced_xp == current_xp then return end
    if not interactive and self.opened_xp == current_xp then return end
    if not interactive and not self.progress_reconciled then
        logger.warn("LegadoSync: skipping automatic push before progress reconciliation")
        return
    end
    local snapshot = self:getCurrentLegadoProgress()
    if not snapshot then
        if interactive then self:showMessage(_("无法确定当前章节。")) end
        return
    end
    self:runOnline(function()
        local client = self:getClient()
        local ok, err = client:ensureDirectory(self.config.remote_progress)
        if not ok then error(_("无法创建远端进度目录：") .. tostring(err)) end
        local conditional, conditional_err = self:serverSupportsConditionalWrites(
            client, self.config.remote_progress)
        if conditional == nil then error(_("无法验证服务器写入安全性：") .. tostring(conditional_err)) end
        if not conditional and not unsafe_confirmed then
            if not interactive then
                if not self.conditional_warning_shown then
                    Notification:notify(_("服务器不支持并发写入保护，已取消自动上传进度。"), Notification.SOURCE_ALWAYS_SHOW)
                    self.conditional_warning_shown = true
                end
                return
            end
            UIManager:show(ConfirmBox:new{
                text = _("服务器不支持并发写入保护。继续可能覆盖手机端刚更新的进度，是否仅本次继续？"),
                ok_callback = function() self:pushProgress(true, false, true) end,
            })
            return
        end
        local record, match_err = self:getMatchedProgressRecord(client)
        if not record then
            error(_("未找到唯一匹配的 Legado 进度：") .. tostring(match_err))
        end
        if not isStrongETag(record.etag) and not unsafe_confirmed then
            if not interactive then
                if not self.conditional_warning_shown then
                    Notification:notify(_("服务器未提供进度版本标识，已取消自动上传进度。"), Notification.SOURCE_ALWAYS_SHOW)
                    self.conditional_warning_shown = true
                end
                return
            end
            UIManager:show(ConfirmBox:new{
                text = _("服务器未提供进度版本标识。继续可能覆盖手机端刚更新的进度，是否仅本次继续？"),
                ok_callback = function() self:pushProgress(true, false, true) end,
            })
            return
        end
        if not interactive and self.observed_remote_timestamp ~= record.data.durChapterTime then
            Notification:notify(_("手机端进度已变化，Kindle 自动上传已取消。"), Notification.SOURCE_ALWAYS_SHOW)
            return
        end
        local latest, latest_err = self:downloadProgressRecord(client, record.name, "preflight")
        if not latest then error(_("上传前复核远端进度失败：") .. tostring(latest_err)) end
        if self:progressRecordChanged(record, latest) then
            error(_("手机端进度在上传期间发生变化，已取消覆盖。请重新拉取。"))
        end
        if not isStrongETag(latest.etag) then latest.etag = record.etag end
        if not isStrongETag(latest.etag) and not unsafe_confirmed then
            error(_("上传前无法取得远端进度版本标识，已取消覆盖。"))
        end
        if not isStrongETag(latest.etag) then latest.etag = nil end
        record = latest
        local progress = record.data
        for key, value in pairs(snapshot) do progress[key] = value end
        local success, upload_err, upload_code = self:writeProgress(client, record, progress)
        if upload_code == 412 then
            error(_("手机端刚刚更新了进度，已拒绝覆盖。请重新拉取。"))
        end
        if not success then error(_("上传进度失败：") .. tostring(upload_err)) end
        local verified, verify_err = self:downloadProgressRecord(client, record.name, "verify")
        if not verified then error(_("上传后校验进度失败：") .. tostring(verify_err)) end
        if verified.data.durChapterTime ~= progress.durChapterTime
                or verified.data.durChapterIndex ~= progress.durChapterIndex
                or verified.data.durChapterPos ~= progress.durChapterPos then
            error(_("上传后发现远端进度已被并发修改，请重新拉取。"))
        end
        self.last_synced_xp = current_xp
        self.observed_remote_timestamp = progress.durChapterTime
        self.progress_reconciled = true
        self.ui.doc_settings:saveSetting(APPLIED_TIMESTAMP_SETTING, progress.durChapterTime)
        self.ui.doc_settings:flush()
        if interactive then Notification:notify(_("阅读进度已同步到 Legado。")) end
    end, not interactive, immediate)
end

function LegadoSync:resolveProgressXPointer(remote)
    local document_fingerprint = self.ui.doc_settings:readSetting("partial_md5_checksum")
    if document_fingerprint and document_fingerprint ~= ""
            and remote.koreaderMappingVersion == 1
            and remote.koreaderDocument == document_fingerprint
            and remote.koreaderXPointer
            and self.ui.document:isXPointerInDocument(remote.koreaderXPointer) then
        return remote.koreaderXPointer, true
    end
    local toc_index, toc = self:findTocIndex(remote)
    local chapter = toc_index and toc[toc_index]
    if not chapter or not chapter.xpointer then return end
    local target = tonumber(remote.durChapterPos) or 0
    if target <= 0 then return chapter.xpointer, false end
    if target > MAX_OFFSET_WALK then
        return chapter.xpointer, false
    end
    local xp, consumed = chapter.xpointer, 0
    local next_boundary = toc[toc_index + 1] and toc[toc_index + 1].xpointer
    while consumed < target do
        local next_xp = self.ui.document:getNextVisibleChar(xp)
        if not next_xp then break end
        if next_boundary and self.ui.document:compareXPointers(next_xp, next_boundary) ~= 1 then break end
        local character = self.ui.document:getTextFromXPointers(xp, next_xp) or ""
        consumed = consumed + math.max(1, SyncUtil.utf16Length(character))
        xp = next_xp
    end
    return xp, false
end

function LegadoSync:pullProgress(interactive)
    if not self.config.auto_progress and not interactive then return end
    if not self:isLegadoProgressSupported() then
        if interactive then self:showMessage(_("Legado 进度互通目前仅支持 EPUB 等流式文档。")) end
        return
    end
    self:runOnline(function()
        local client = self:getClient()
        local record, match_err = self:getMatchedProgressRecord(client)
        if not record then
            if interactive then self:showMessage(_("没有找到唯一匹配的 Legado 阅读进度：") .. tostring(match_err)) end
            return
        end
        local remote = record.data
        self.observed_remote_timestamp = remote.durChapterTime
        local applied_timestamp = self.ui.doc_settings:readSetting(APPLIED_TIMESTAMP_SETTING)
        if applied_timestamp == remote.durChapterTime then
            self.last_synced_xp = self.ui.rolling:getLastProgress()
            self.progress_reconciled = true
            if interactive then Notification:notify(_("该 Legado 进度已处理。")) end
            return
        end
        local xp, exact = self:resolveProgressXPointer(remote)
        if not xp then error(_("无法将 Legado 章节映射到当前 EPUB。")) end
        local current_xp = self.ui.rolling:getLastProgress()
        if xp == current_xp then
            self.ui.doc_settings:saveSetting(APPLIED_TIMESTAMP_SETTING, remote.durChapterTime)
            self.progress_reconciled = true
            if interactive then Notification:notify(_("阅读进度已经是最新的。")) end
            return
        end
        local apply = function()
            self.ui:handleEvent(Event:new("GotoXPointer", xp))
            self.last_synced_xp = xp
            self.opened_xp = xp
            self.progress_reconciled = true
            self.ui.doc_settings:saveSetting(APPLIED_TIMESTAMP_SETTING, remote.durChapterTime)
            self.ui.doc_settings:flush()
            Notification:notify(exact and _("已精确应用 Legado 阅读进度。") or _("已按章节位置应用 Legado 阅读进度。"))
        end
        if interactive then
            apply()
        else
            UIManager:show(ConfirmBox:new{
                text = string.format(_("发现 Legado 进度：%s，是否跳转？"), remote.durChapterTitle or _("未知章节")),
                ok_callback = apply,
            })
        end
    end, not interactive)
end

function LegadoSync:onReaderReady()
    Dispatcher:registerAction("legadosync_pull_progress", {
        category = "none", event = "LegadoSyncPullProgress", title = _("拉取 WebDAV 阅读进度"), reader = true,
    })
    Dispatcher:registerAction("legadosync_push_progress", {
        category = "none", event = "LegadoSyncPushProgress", title = _("上传 WebDAV 阅读进度"), reader = true,
    })
    if self:isLegadoProgressSupported() then
        self.opened_xp = self.ui.rolling:getLastProgress()
    end
    if self.config.auto_progress then
        UIManager:scheduleIn(1, function() self:pullProgress(false) end)
    end
end

function LegadoSync:onLegadoSyncPullProgress() self:pullProgress(true) end
function LegadoSync:onLegadoSyncPushProgress() self:pushProgress(true) end

function LegadoSync:onCloseDocument()
    self:pushProgress(false)
end

function LegadoSync:onSuspend()
    self:pushProgress(false, true)
end

return LegadoSync

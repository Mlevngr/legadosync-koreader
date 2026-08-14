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
    address = "https://",
    username = "",
    password = "",
    remote_books = "legado/books",
    remote_progress = "legado/bookProgress",
    local_books = "/mnt/us/books",
    auto_progress = true,
}

local MAX_OFFSET_WALK = 50000
local APPLIED_TIMESTAMP_SETTING = "legadosync_applied_timestamp"

local function joinPath(left, right)
    if left == "" then return right end
    if right == "" then return left end
    return left:gsub("/+$", "") .. "/" .. right:gsub("^/+", "")
end

local function isBookFile(filename)
    return filename:lower():match("%.epub$") ~= nil
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
    self.config = copyDefaults(self.settings:readSetting("config", {}))
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

function LegadoSync:addToMainMenu(menu_items)
    menu_items.legadosync = {
        text = self.title,
        sub_item_table = {
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
                text = _("连接设置"),
                keep_menu_open = true,
                callback = function(menu) self:configure(menu) end,
            },
        },
    }
end

function LegadoSync:scanLocal(root, relative, result)
    local directory = joinPath(root, relative)
    local ok, iterator, dir_obj = pcall(lfs.dir, directory)
    if not ok then return nil, iterator end
    for name in iterator, dir_obj do
        if name ~= "." and name ~= ".." and name:sub(1, 1) ~= "." and not name:match("%.sdr$") then
            local rel_path = joinPath(relative, name)
            local full_path = joinPath(root, rel_path)
            local attr = lfs.attributes(full_path)
            if attr and attr.mode == "directory" then
                local scanned, err = self:scanLocal(root, rel_path, result)
                if not scanned then return nil, err end
            elseif attr and attr.mode == "file" and isBookFile(name) then
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
            elseif isBookFile(entry.name) then
                result[rel_path] = entry
            end
        end
    end
    return true
end

function LegadoSync:syncBooks()
    self:runOnline(function()
        local client = self:getClient()
        util.makePath(self.config.local_books)
        local ok, err = client:ensureDirectory(self.config.remote_books)
        if not ok then error(_("无法创建远端书籍目录：") .. tostring(err)) end

        local local_files, remote_files = {}, {}
        ok, err = self:scanLocal(self.config.local_books, "", local_files)
        if not ok then error(_("无法读取本地书库：") .. tostring(err)) end
        ok, err = self:scanRemote(client, self.config.remote_books, "", remote_files)
        if not ok then error(_("无法读取远端书库：") .. tostring(err)) end

        local uploaded, downloaded, skipped = 0, 0, 0
        local all_paths = {}
        for path in pairs(local_files) do all_paths[path] = true end
        for path in pairs(remote_files) do all_paths[path] = true end

        for path in pairs(all_paths) do
            local local_item, remote_item = local_files[path], remote_files[path]
            local local_path = joinPath(self.config.local_books, path)
            local remote_path = joinPath(self.config.remote_books, path)
            if not local_item or (remote_item and remote_item.modification
                    and remote_item.modification > local_item.modification + 2) then
                util.makePath(local_path:match("^(.*)/[^/]+$") or self.config.local_books)
                local temp_path = local_path .. ".legadosync"
                local success, download_err = client:download(remote_path, temp_path)
                if not success then error(_("下载失败：") .. path .. ": " .. tostring(download_err)) end
                os.remove(local_path)
                local renamed, rename_err = os.rename(temp_path, local_path)
                if not renamed then error(_("保存下载文件失败：") .. tostring(rename_err)) end
                if remote_item.modification then
                    lfs.touch(local_path, remote_item.modification, remote_item.modification)
                end
                downloaded = downloaded + 1
            elseif not remote_item or local_item.modification > (remote_item.modification or 0) + 2
                    or (local_item.size ~= remote_item.size
                        and math.abs(local_item.modification - (remote_item.modification or 0)) <= 2) then
                local remote_dir = remote_path:match("^(.*)/[^/]+$")
                ok, err = client:ensureDirectory(remote_dir)
                if not ok then error(_("无法创建远端目录：") .. tostring(err)) end
                local success, upload_err = client:upload(remote_path, local_path)
                if not success then error(_("上传失败：") .. path .. ": " .. tostring(upload_err)) end
                local now = os.time()
                lfs.touch(local_path, now, now)
                uploaded = uploaded + 1
            else
                skipped = skipped + 1
            end
        end
        self:showMessage(string.format(_("书籍同步完成：上传 %d，下载 %d，未变更 %d。"), uploaded, downloaded, skipped))
        if self.ui.file_chooser then self.ui.file_chooser:refreshPath() end
    end)
end

local function normalizeText(value)
    return (value or ""):lower():gsub("%s+", ""):gsub("[%p%c]", "")
end

local function utf16Length(value)
    local length, index, bytes = 0, 1, #value
    while index <= bytes do
        local byte = value:byte(index)
        if byte < 0x80 then
            index = index + 1
            length = length + 1
        elseif byte < 0xE0 then
            index = index + 2
            length = length + 1
        elseif byte < 0xF0 then
            index = index + 3
            length = length + 1
        else
            index = index + 4
            length = length + 2
        end
    end
    return length
end

function LegadoSync:isLegadoProgressSupported()
    return self.ui.document and not self.ui.document.info.has_pages
        and self.ui.rolling and self.ui.toc
end

function LegadoSync:getBookIdentity()
    local props = self.ui.doc_props or self.ui.document:getProps() or {}
    local filename = ffiUtil.basename(self.ui.document.file):gsub("%.[^.]+$", "")
    return {
        name = props.title or props.display_title or filename,
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
    local wanted_title = normalizeText(progress.durChapterTitle)
    local wanted_index = tonumber(progress.durChapterIndex) and progress.durChapterIndex + 1
    local exact
    for index, item in ipairs(toc) do
        if wanted_title ~= "" and normalizeText(item.title) == wanted_title then
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

function LegadoSync:downloadProgressRecords(client)
    local entries, err = client:list(self.config.remote_progress)
    if not entries then
        return nil, err
    end
    local records = {}
    for _, entry in ipairs(entries) do
        if not entry.is_dir and entry.name:lower():match("%.json$") then
            local temp_path = DataStorage:getDataDir() .. "/legadosync-progress-" .. tostring(#records + 1) .. ".json"
            local ok = client:download(joinPath(self.config.remote_progress, entry.name), temp_path)
            if ok then
                local record = self:readJsonFile(temp_path)
                if type(record) == "table" and record.name then
                    records[#records + 1] = { name = entry.name, data = record }
                end
            end
            os.remove(temp_path)
        end
    end
    return records
end

function LegadoSync:findProgressRecord(records)
    local identity = self:getBookIdentity()
    local title = normalizeText(identity.name)
    local filename = normalizeText(identity.filename)
    local author = normalizeText(identity.author)
    local title_match
    for _, record in ipairs(records) do
        local remote_title = normalizeText(record.data.name)
        if remote_title == title or remote_title ~= "" and filename:find(remote_title, 1, true) then
            if author == "" or normalizeText(record.data.author) == author
                    or filename:find(normalizeText(record.data.author), 1, true) then
                return record
            end
            title_match = title_match or record
        end
    end
    return title_match
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
    progress.durChapterPos = utf16Length(text)
    progress.durChapterTime = os.time() * 1000
    progress.durChapterTitle = chapter.title
    progress.koreaderXPointer = xp
    progress.koreaderPercentage = self.ui.rolling:getLastPercent()
    progress.koreaderMappingVersion = 1
    return progress
end

function LegadoSync:writeProgress(client, remote_name, progress)
    local temp_path = DataStorage:getDataDir() .. "/legadosync-progress.json"
    local file, err = io.open(temp_path, "wb")
    if not file then return nil, err end
    file:write(json.encode(progress))
    file:close()
    local ok, upload_err = client:upload(joinPath(self.config.remote_progress, remote_name), temp_path, "application/json")
    os.remove(temp_path)
    return ok, upload_err
end

function LegadoSync:pushProgress(interactive, immediate)
    if not self.config.auto_progress and not interactive then return end
    if not self:isLegadoProgressSupported() then
        if interactive then self:showMessage(_("Legado 进度互通目前仅支持 EPUB 等流式文档。")) end
        return
    end
    local current_xp = self.ui.rolling:getLastProgress()
    if not interactive and self.last_synced_xp == current_xp then return end
    if not interactive and self.opened_xp == current_xp then return end
    local snapshot = self:getCurrentLegadoProgress()
    if not snapshot then
        if interactive then self:showMessage(_("无法确定当前章节。")) end
        return
    end
    self:runOnline(function()
        local client = self:getClient()
        local ok, err = client:ensureDirectory(self.config.remote_progress)
        if not ok then error(_("无法创建远端进度目录：") .. tostring(err)) end
        local records, list_err = self:downloadProgressRecords(client)
        if not records then error(_("无法读取 Legado 进度：") .. tostring(list_err)) end
        local record = self:findProgressRecord(records)
        if not record then
            error(_("未找到匹配的 Legado 进度。请先在手机上打开一次这本书。"))
        end
        local progress = record.data
        for key, value in pairs(snapshot) do progress[key] = value end
        progress.name = record.data.name
        progress.author = record.data.author
        local success, upload_err = self:writeProgress(client, record.name, progress)
        if not success then error(_("上传进度失败：") .. tostring(upload_err)) end
        self.last_synced_xp = current_xp
        self.ui.doc_settings:saveSetting(APPLIED_TIMESTAMP_SETTING, progress.durChapterTime)
        self.ui.doc_settings:flush()
        if interactive then Notification:notify(_("阅读进度已同步到 Legado。")) end
    end, not interactive, immediate)
end

function LegadoSync:resolveProgressXPointer(remote)
    if remote.koreaderXPointer and self.ui.document:isXPointerInDocument(remote.koreaderXPointer) then
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
        consumed = consumed + math.max(1, utf16Length(character))
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
        local directory_ok, directory_err = client:ensureDirectory(self.config.remote_progress)
        if not directory_ok then error(_("无法创建远端进度目录：") .. tostring(directory_err)) end
        local records, err = self:downloadProgressRecords(client)
        if not records then error(_("无法读取 Legado 进度：") .. tostring(err)) end
        local record = self:findProgressRecord(records)
        if not record then
            if interactive then self:showMessage(_("没有找到匹配的 Legado 阅读进度。")) end
            return
        end
        local remote = record.data
        local applied_timestamp = self.ui.doc_settings:readSetting(APPLIED_TIMESTAMP_SETTING)
        if applied_timestamp == remote.durChapterTime then
            self.last_synced_xp = self.ui.rolling:getLastProgress()
            if interactive then Notification:notify(_("该 Legado 进度已处理。")) end
            return
        end
        local xp, exact = self:resolveProgressXPointer(remote)
        if not xp then error(_("无法将 Legado 章节映射到当前 EPUB。")) end
        local current_xp = self.ui.rolling:getLastProgress()
        if xp == current_xp then
            if interactive then Notification:notify(_("阅读进度已经是最新的。")) end
            return
        end
        local apply = function()
            self.ui:handleEvent(Event:new("GotoXPointer", xp))
            self.last_synced_xp = xp
            self.opened_xp = xp
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

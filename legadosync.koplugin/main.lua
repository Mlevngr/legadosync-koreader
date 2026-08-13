local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local Dispatcher = require("dispatcher")
local DocumentRegistry = require("document/documentregistry")
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
    remote_books = "books",
    remote_progress = "progress",
    local_books = "/mnt/us/documents",
    auto_progress = true,
}

local function joinPath(left, right)
    if left == "" then return right end
    if right == "" then return left end
    return left:gsub("/+$", "") .. "/" .. right:gsub("^/+", "")
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
            { text = self.config.local_books, hint = _("Kindle 本地书籍目录") },
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
            elseif attr and attr.mode == "file" and DocumentRegistry:hasProvider(full_path) then
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
            elseif DocumentRegistry:hasProvider(entry.name) then
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

function LegadoSync:getProgressKey()
    if not self.ui.document or not self.ui.doc_settings then return end
    local digest = self.ui.doc_settings:readSetting("partial_md5_checksum")
    if not digest and self.ui.document.file then
        digest = util.partialMD5(self.ui.document.file)
    end
    return digest
end

function LegadoSync:getCurrentProgress()
    local progress, percentage
    if self.ui.document.info.has_pages then
        progress = self.ui.paging:getLastProgress()
        percentage = self.ui.paging:getLastPercent()
    else
        progress = self.ui.rolling:getLastProgress()
        percentage = self.ui.rolling:getLastPercent()
    end
    return {
        version = 1,
        document = self:getProgressKey(),
        filename = ffiUtil.basename(self.ui.document.file),
        progress = progress,
        percentage = percentage,
        timestamp = os.time(),
    }
end

function LegadoSync:pushProgress(interactive, immediate)
    if not self.config.auto_progress and not interactive then return end
    local key = self:getProgressKey()
    if not key then return end
    local progress = self:getCurrentProgress()
    self:runOnline(function()
        local client = self:getClient()
        local ok, err = client:ensureDirectory(self.config.remote_progress)
        if not ok then error(_("无法创建远端进度目录：") .. tostring(err)) end
        local temp_path = DataStorage:getDataDir() .. "/legadosync-progress.json"
        local file, file_err = io.open(temp_path, "wb")
        if not file then error(file_err) end
        file:write(json.encode(progress))
        file:close()
        local success, upload_err = client:upload(joinPath(self.config.remote_progress, key .. ".json"), temp_path, "application/json")
        os.remove(temp_path)
        if not success then error(_("上传进度失败：") .. tostring(upload_err)) end
        if interactive then Notification:notify(_("阅读进度已上传。")) end
    end, not interactive, immediate)
end

function LegadoSync:applyProgress(remote)
    if self.ui.document.info.has_pages then
        self.ui:handleEvent(Event:new("GotoPage", tonumber(remote.progress)))
    else
        self.ui:handleEvent(Event:new("GotoXPointer", remote.progress))
    end
end

function LegadoSync:pullProgress(interactive)
    if not self.config.auto_progress and not interactive then return end
    local key = self:getProgressKey()
    if not key then return end
    self:runOnline(function()
        local client = self:getClient()
        local temp_path = DataStorage:getDataDir() .. "/legadosync-progress.json"
        local success, err, code = client:download(joinPath(self.config.remote_progress, key .. ".json"), temp_path)
        if not success then
            if code == 404 then
                if interactive then self:showMessage(_("远端没有这本书的阅读进度。")) end
                return
            end
            error(_("下载进度失败：") .. tostring(err))
        end
        local file = io.open(temp_path, "rb")
        local content = file and file:read("*a")
        if file then file:close() end
        os.remove(temp_path)
        local ok, remote = pcall(json.decode, content or "")
        if not ok or type(remote) ~= "table" or remote.document ~= key or remote.progress == nil then
            error(_("远端进度文件无效。"))
        end
        local current = self:getCurrentProgress()
        if remote.progress == current.progress then
            if interactive then Notification:notify(_("阅读进度已经是最新的。")) end
            return
        end
        local apply = function()
            self:applyProgress(remote)
            Notification:notify(_("已应用远端阅读进度。"))
        end
        if interactive then
            apply()
        else
            UIManager:show(ConfirmBox:new{
                text = string.format(_("发现远端阅读进度 %.1f%%，是否跳转？"), (remote.percentage or 0) * 100),
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

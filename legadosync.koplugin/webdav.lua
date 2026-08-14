local datetime = require("datetime")
local ffiUtil = require("ffi/util")
local http = require("socket.http")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local ltn12 = require("ltn12")
local socket = require("socket")
local socket_url = require("socket.url")
local socketutil = require("socketutil")
local util = require("util")

local WebDAV = {}

local function trimSlashes(value)
    return (value or ""):gsub("^/+", ""):gsub("/+$", "")
end

function WebDAV.join(address, path)
    address = (address or ""):gsub("/+$", "")
    path = trimSlashes(path)
    if path == "" then
        return address .. "/"
    end
    return address .. "/" .. util.urlEncode(path, "/")
end

local function request(options)
    local response = {}
    options.sink = options.sink or ltn12.sink.table(response)
    socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
    local ok, _, code, headers, status = pcall(http.request, options)
    socketutil:reset_timeout()
    if not ok then error(_) end
    return tonumber(code), headers, status, table.concat(response)
end

local function normalizeHref(href)
    href = util.htmlEntitiesToUtf8(util.urlDecode(href) or href)
    if href:match("^https?://") then
        href = socket_url.parse(href).path or href
    end
    href = href:gsub("/+$", "")
    return href == "" and "/" or href
end

function WebDAV:list(path)
    local body = [[<?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/><d:getcontentlength/><d:getlastmodified/><d:getetag/></d:prop></d:propfind>]]
    local url = WebDAV.join(self.address, path)
    if url:sub(-1) ~= "/" then
        url = url .. "/"
    end
    local code, headers, status, response = request({
        url = url,
        method = "PROPFIND",
        user = self.username,
        password = self.password,
        source = ltn12.source.string(body),
        headers = {
            ["Content-Type"] = "application/xml",
            ["Content-Length"] = #body,
            ["Depth"] = "1",
        },
    })
    if code ~= 207 then
        return nil, status or code, code
    end

    local entries = {}
    local requested_href = normalizeHref(socket_url.parse(url).path or "/")
    local found_collection = false
    for item in response:gmatch("<[^:]*:response[^>]*>(.-)</[^:]*:response>") do
        local raw_href = item:match("<[^:]*:href[^>]*>(.-)</[^:]*:href>")
        if raw_href then
            local href = normalizeHref(raw_href)
            if href == requested_href then
                found_collection = true
            else
            local name = href and ffiUtil.basename(href:gsub("/+$", ""))
            if name and name ~= "" and name ~= "." and name ~= ".." and not name:find("/", 1, true) then
                local is_dir = item:find("<[^:]*:collection[^<]*/>") ~= nil
                    or item:find("<[^:]*:collection>%s*</[^:]*:collection>") ~= nil
                local modified = item:match("<[^:]*:getlastmodified[^>]*>(.-)</[^:]*:getlastmodified>")
                entries[#entries + 1] = {
                    name = name,
                    is_dir = is_dir,
                    size = tonumber(item:match("<[^:]*:getcontentlength[^>]*>(%d+)</[^:]*:getcontentlength>")),
                    modification = modified and datetime.stringRFC1123ToSeconds(modified),
                    etag = item:match("<[^:]*:getetag[^>]*>(.-)</[^:]*:getetag>"),
                }
            end
            end
        end
    end
    if not found_collection then
        return nil, "Invalid WebDAV multistatus response", code
    end
    return entries, nil, code, headers
end

function WebDAV:makeDirectory(path)
    local code, _, status = request({
        url = WebDAV.join(self.address, path),
        method = "MKCOL",
        user = self.username,
        password = self.password,
    })
    if code and code >= 200 and code < 300 then
        return true
    end
    if code == 405 and self:list(path) then return true end
    return nil, status or code
end

function WebDAV:ensureDirectory(path)
    local current = ""
    for part in trimSlashes(path):gmatch("[^/]+") do
        current = current == "" and part or current .. "/" .. part
        local entries, _, code = self:list(current)
        if not entries then
            if code ~= 404 and code ~= 405 then
                return nil, code
            end
            local ok, err = self:makeDirectory(current)
            if not ok then
                return nil, err
            end
        end
    end
    return true
end

function WebDAV:download(path, local_path)
    local file, err = io.open(local_path, "wb")
    if not file then
        return nil, err
    end
    socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
    local ok, _, code, headers, status = pcall(http.request, {
        url = WebDAV.join(self.address, path),
        method = "GET",
        user = self.username,
        password = self.password,
        sink = ltn12.sink.file(file),
    })
    socketutil:reset_timeout()
    if not ok then
        pcall(file.close, file)
        os.remove(local_path)
        return nil, _, nil
    end
    code = tonumber(code)
    if code ~= 200 then
        os.remove(local_path)
        logger.warn("LegadoSync: WebDAV download failed:", status or code)
        return nil, status or code, code
    end
    return true, nil, code, headers and headers.etag
end

function WebDAV:upload(path, local_path, content_type, etag, create_only)
    local file, err = io.open(local_path, "rb")
    if not file then
        return nil, err
    end
    local headers = {
        ["Content-Length"] = lfs.attributes(local_path, "size"),
        ["Content-Type"] = content_type or "application/octet-stream",
    }
    if etag then
        headers["If-Match"] = etag
    elseif create_only then
        headers["If-None-Match"] = "*"
    end
    local code, response_headers, status = request({
        url = WebDAV.join(self.address, path),
        method = "PUT",
        user = self.username,
        password = self.password,
        source = ltn12.source.file(file),
        sink = ltn12.sink.null(),
        headers = headers,
    })
    if code and code >= 200 and code < 300 then
        return true, nil, code, response_headers and response_headers.etag
    end
    return nil, status or code, code
end

function WebDAV:delete(path)
    local code, _, status = request({
        url = WebDAV.join(self.address, path),
        method = "DELETE",
        user = self.username,
        password = self.password,
        sink = ltn12.sink.null(),
    })
    if code and code >= 200 and code < 300 or code == 404 then return true end
    return nil, status or code, code
end

return WebDAV

package.path = "legadosync.koplugin/?.lua;" .. package.path

local response_body, response_code, last_request

package.preload["datetime"] = function()
    return { stringRFC1123ToSeconds = function() return 123 end }
end
package.preload["ffi/util"] = function()
    return { basename = function(path) return path:match("([^/]+)$") end }
end
package.preload["libs/libkoreader-lfs"] = function()
    return { attributes = function() return 1 end }
end
package.preload["logger"] = function()
    return { warn = function() end }
end
package.preload["ltn12"] = function()
    return {
        sink = {
            table = function(target)
                return function(chunk)
                    if chunk then target[#target + 1] = chunk end
                    return 1
                end
            end,
            null = function() return function() return 1 end end,
            file = function() return function() return 1 end end,
        },
        source = { string = function() return function() end end, file = function() return function() end end },
    }
end
package.preload["socket"] = function()
    return { skip = function(_, ...) return ... end }
end
package.preload["socket.url"] = function()
    return {
        parse = function(url)
            return { path = url:match("^https?://[^/]+(.*)$") or url }
        end,
    }
end
package.preload["socketutil"] = function()
    return {
        FILE_BLOCK_TIMEOUT = 1,
        FILE_TOTAL_TIMEOUT = 1,
        set_timeout = function() end,
        reset_timeout = function() end,
    }
end
package.preload["util"] = function()
    return {
        urlEncode = function(value) return value end,
        urlDecode = function(value) return value end,
        htmlEntitiesToUtf8 = function(value) return value end,
    }
end
package.preload["socket.http"] = function()
    return {
        request = function(options)
            last_request = options
            options.sink(response_body)
            options.sink(nil)
            return 1, response_code, {}, "status"
        end,
    }
end

local WebDAV = require("webdav")
local client = setmetatable({ address = "http://example/base" }, { __index = WebDAV })

response_code = 207
response_body = [[<?xml version="1.0"?><D:multistatus xmlns:D="DAV:">
<D:response><D:href>/base/books/book.epub</D:href><D:propstat><D:prop>
<D:resourcetype/><D:getcontentlength>42</D:getcontentlength><D:getetag>"abc"</D:getetag>
</D:prop></D:propstat></D:response>
<D:response><D:href>/base/books/</D:href><D:propstat><D:prop>
<D:resourcetype><D:collection/></D:resourcetype>
</D:prop></D:propstat></D:response></D:multistatus>]]

local entries = assert(client:list("books"))
assert(#entries == 1, "reordered multistatus must keep the child")
assert(entries[1].name == "book.epub", "filename parsing")
assert(entries[1].size == 42, "size parsing")
assert(entries[1].etag == '"abc"', "ETag parsing")

response_code = 200
response_body = "<html>login</html>"
assert(client:list("books") == nil, "HTTP 200 is not a valid PROPFIND response")

response_code = 207
response_body = [[<D:multistatus xmlns:D="DAV:"><D:response><D:href>/wrong/</D:href></D:response></D:multistatus>]]
assert(client:list("books") == nil, "missing collection response must fail")

response_code = 201
response_body = ""
local upload_path = "/tmp/legadosync-webdav-test"
local upload_file = assert(io.open(upload_path, "wb"))
assert(upload_file:write("test"))
assert(upload_file:close())
assert(client:upload("books/test.epub", upload_path, nil, 'W/"weak"'))
os.remove(upload_path)
assert(last_request.headers["If-Match"] == 'W/"weak"', "weak ETag must be preserved exactly")

response_code = 204
assert(client:delete("books/test.epub"))
assert(last_request.method == "DELETE", "DELETE method")

print("webdav tests passed")

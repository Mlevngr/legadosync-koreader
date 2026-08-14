package.path = "legadosync.koplugin/?.lua;" .. package.path

local SyncUtil = require("syncutil")

local function equal(actual, expected, message)
    if actual ~= expected then
        error(string.format("%s: expected %s, got %s", message, tostring(expected), tostring(actual)))
    end
end

equal(SyncUtil.isBookFile("book.EPUB"), true, "EPUB suffix")
equal(SyncUtil.isBookFile("book.txt"), false, "non-EPUB suffix")
equal(SyncUtil.utf16Length("佛本是道"), 4, "BMP UTF-16 length")
equal(SyncUtil.utf16Length("A😀B"), 4, "surrogate pair UTF-16 length")
equal(SyncUtil.normalizeAuthor(" 作者：[日]东野圭吾 "), "日东野圭吾", "author normalization")

local records = {
    { name = "a.json", data = { name = "同名书", author = "甲" } },
    { name = "b.json", data = { name = "同名书", author = "乙" } },
}
local record, reason = SyncUtil.findProgressRecord(records, {
    name = "同名书", author = "乙", filename = "同名书 作者：乙",
})
equal(record.name, "b.json", "author disambiguation")
equal(reason, nil, "successful match reason")

record, reason = SyncUtil.findProgressRecord(records, {
    name = "同名书", author = "", filename = "同名书",
})
equal(record, nil, "ambiguous title")
equal(reason, "ambiguous", "ambiguous reason")

record, reason = SyncUtil.findProgressRecord(records, {
    name = "不存在", author = "", filename = "不存在",
})
equal(record, nil, "missing title")
equal(reason, "not_found", "missing reason")

record, reason = SyncUtil.findProgressRecord({ records[1] }, {
    name = "同名书", author = "乙", filename = "同名书",
})
equal(record, nil, "sole title with wrong author")
equal(reason, "author_mismatch", "author mismatch reason")

equal(SyncUtil.decideBookSync("bidirectional",
    { size = 10 }, { size = 20 }, nil), "conflict", "missing timestamps")
equal(SyncUtil.decideBookSync("bidirectional",
    { size = 10, modification = 100 }, { size = 20, modification = 100 }, nil),
    "conflict", "equal timestamps with different content")
equal(SyncUtil.decideBookSync("download",
    { size = 10, modification = 1 }, { size = 10, modification = 1 }, nil),
    "download", "first authoritative sync")
local baseline = {
    local_item = { size = 10, modification = 100 },
    remote_item = { size = 10, modification = 100, etag = '"a"' },
}
equal(SyncUtil.decideBookSync("bidirectional",
    { size = 11, modification = 110 }, { size = 12, modification = 110, etag = '"b"' }, baseline),
    "conflict", "both sides changed")
equal(SyncUtil.decideBookSync("bidirectional",
    { size = 10, modification = 100 }, { size = 12, modification = 110, etag = '"b"' }, baseline),
    "download", "remote side changed")

print("syncutil tests passed")

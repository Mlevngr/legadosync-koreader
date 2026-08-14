local SyncUtil = {}

local punctuation = {
    "，", "。", "！", "？", "：", "；", "（", "）", "【", "】",
    "《", "》", "“", "”", "‘", "’", "·", "•",
}

function SyncUtil.normalizeText(value)
    value = (value or ""):lower():gsub("[%s%p%c]", "")
    for _, character in ipairs(punctuation) do
        value = value:gsub(character, "")
    end
    return value
end

function SyncUtil.normalizeAuthor(value)
    value = (value or ""):gsub("^%s*作者%s*：%s*", "")
    value = value:gsub("^%s*作者%s*:%s*", "")
    return SyncUtil.normalizeText(value)
end

function SyncUtil.utf16Length(value)
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

function SyncUtil.isBookFile(filename)
    return type(filename) == "string" and filename:lower():match("%.epub$") ~= nil
end

function SyncUtil.findProgressRecord(records, identity)
    local title = SyncUtil.normalizeText(identity.name)
    local filename = SyncUtil.normalizeText(identity.filename)
    local author = SyncUtil.normalizeAuthor(identity.author)
    local title_matches = {}
    for _, record in ipairs(records) do
        local data = record.data or {}
        local remote_title = SyncUtil.normalizeText(data.name)
        if remote_title ~= "" and (remote_title == title
                or filename:find(remote_title, 1, true)
                or remote_title:find(title, 1, true)) then
            title_matches[#title_matches + 1] = record
        end
    end
    if #title_matches == 0 then return nil, "not_found" end

    local author_matches = {}
    for _, record in ipairs(title_matches) do
        local remote_author = SyncUtil.normalizeAuthor(record.data.author)
        if author ~= "" and remote_author ~= "" and (remote_author == author
                or remote_author:find(author, 1, true)
                or author:find(remote_author, 1, true)) then
            author_matches[#author_matches + 1] = record
        end
    end
    if #author_matches == 1 then return author_matches[1] end
    if #title_matches == 1 then
        local remote_author = SyncUtil.normalizeAuthor(title_matches[1].data.author)
        if author == "" or remote_author == "" then return title_matches[1] end
        return nil, "author_mismatch"
    end
    return nil, "ambiguous"
end

local function changed(item, state, remote)
    if not state then return true end
    if item.size ~= state.size then return true end
    if remote and item.etag and state.etag then return item.etag ~= state.etag end
    if item.modification and state.modification then
        return math.abs(item.modification - state.modification) > 2
    end
    return false
end

function SyncUtil.decideBookSync(mode, local_item, remote_item, state)
    if not local_item then return remote_item and mode ~= "upload" and "download" or "skip" end
    if not remote_item then return mode ~= "download" and "upload" or "skip" end

    if mode == "download" then
        return state and not changed(remote_item, state.remote_item, true) and not changed(local_item, state.local_item)
            and "skip" or "download"
    end
    if mode == "upload" then
        return state and not changed(remote_item, state.remote_item, true) and not changed(local_item, state.local_item)
            and "skip" or "upload"
    end

    if state then
        local local_changed = changed(local_item, state.local_item)
        local remote_changed = changed(remote_item, state.remote_item, true)
        if local_changed and remote_changed then return "conflict" end
        if local_changed then return "upload" end
        if remote_changed then return "download" end
        return "skip"
    end
    if not local_item.modification or not remote_item.modification then return "conflict" end
    if math.abs(local_item.modification - remote_item.modification) <= 2 then
        return local_item.size == remote_item.size and "skip" or "conflict"
    end
    return local_item.modification > remote_item.modification and "upload" or "download"
end

return SyncUtil

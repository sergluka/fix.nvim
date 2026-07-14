local Cache = require("fix.cache")
local Dictionary = require("fix.dictionary")
local Log = require("fix.log")

local M = {}

local FORMAT_VERSION = 2

-- Set on the first filesystem failure; persistence stays off for the session.
M._disabled = false

local function opts()
    return require("fix").opts
end

local function cache_dir()
    return opts().cache.persist.dir or (vim.fn.stdpath("cache") .. "/fix.nvim")
end

local function enabled()
    return opts().cache.persist.enabled and not M._disabled
end

--- Cache file path for a buffer; nil for unnamed buffers.
---@param buf number
---@return string|nil
function M.path_for(buf)
    local name = vim.api.nvim_buf_get_name(buf)
    if name == "" then
        return nil
    end
    return cache_dir() .. "/" .. vim.fn.sha256(name):sub(1, 32) .. ".mpack"
end

function M.fingerprint()
    local fingerprint = Dictionary.fingerprint()
    if not fingerprint or fingerprint == "" then
        Log.warn("no dictionaries found for fingerprint")
    end
    return fingerprint
end

---@param buf number
function M.load_into_cache(buf)
    if not enabled() then
        return
    end
    local path = M.path_for(buf)
    if not path then
        return
    end
    local f = io.open(path, "rb")
    if not f then
        return
    end
    local blob = f:read("*a")
    f:close()

    local ok, data = pcall(vim.mpack.decode, blob)
    if
        not ok
        or type(data) ~= "table"
        or data.format_version ~= FORMAT_VERSION
        or data.dict_fingerprint ~= M.fingerprint()
        or data.fallback_version ~= opts().fallback_version
        or type(data.entries) ~= "table"
    then
        vim.print("discarding stale or corrupt cache file: " .. path)
        return
    end
    Cache.merge(data.entries)
end

local function disable(msg)
    M._disabled = true
    local full = msg .. " — persistence disabled for this session"
    Log.warn(full)
    vim.notify_once("fix.nvim: cache persistence disabled: " .. msg, vim.log.levels.WARN)
end

--- Delete oldest files until enabled count and byte limits are satisfied.
--- Main loop only.
function M.rotate()
    local dir = cache_dir()
    local persist = opts().cache.persist
    local max_files = persist.max_files
    local max_bytes = persist.max_bytes
    local scanner = vim.uv.fs_scandir(dir)
    if not scanner then
        return
    end
    local files = {}
    local total_bytes = 0
    while true do
        local name, kind = vim.uv.fs_scandir_next(scanner)
        if not name then
            break
        end
        if kind == "file" and name:match("%.mpack$") then
            local path = dir .. "/" .. name
            local stat = vim.uv.fs_stat(path)
            if stat then
                local size = stat.size or 0
                files[#files + 1] = { path = path, mtime = stat.mtime.sec, size = size }
                total_bytes = total_bytes + size
            end
        end
    end

    local count_limit_enabled = max_files ~= false
    local byte_limit_enabled = max_bytes ~= false
    if (not count_limit_enabled or #files <= max_files) and (not byte_limit_enabled or total_bytes <= max_bytes) then
        return
    end

    table.sort(files, function(a, b)
        return a.mtime < b.mtime
    end)
    local removed = 0
    for _, file in ipairs(files) do
        local count_over = count_limit_enabled and (#files - removed > max_files)
        local bytes_over = byte_limit_enabled and (total_bytes > max_bytes)
        if not count_over and not bytes_over then
            break
        end
        removed = removed + 1
        total_bytes = total_bytes - file.size
        vim.uv.fs_unlink(file.path, function() end)
    end
end

---@param buf number
---@param keys table<string, boolean>
---@param sync boolean|nil  -- sync write for VimLeavePre (async would be lost)
function M.save(buf, keys, sync)
    if not enabled() then
        return
    end
    local path = M.path_for(buf)
    if not path then
        return
    end
    local entries = Cache.collect(keys)
    if vim.tbl_isempty(entries) then
        return
    end
    local ok_enc, blob = pcall(vim.mpack.encode, {
        format_version = FORMAT_VERSION,
        dict_fingerprint = M.fingerprint(),
        fallback_version = opts().fallback_version,
        entries = entries,
    })
    if not ok_enc then
        Log.warn("failed to encode cache: " .. tostring(blob))
        return
    end

    local ok_mkdir = pcall(vim.fn.mkdir, cache_dir(), "p")
    if not ok_mkdir then
        disable("cannot create cache dir " .. cache_dir())
        return
    end

    local tmp = path .. ".tmp." .. vim.uv.os_getpid()

    if sync then
        local f = io.open(tmp, "wb")
        if not f then
            disable("cannot write " .. tmp)
            return
        end
        f:write(blob)
        f:close()
        local ok_mv, err_mv = os.rename(tmp, path)
        if not ok_mv then
            os.remove(tmp)
            disable("cannot rename cache file: " .. tostring(err_mv))
            return
        end
        M.rotate()
        return
    end

    -- tmp name ends in ".tmp.<pid>", not ".mpack", so rotate()'s "%.mpack$"
    -- filter never touches it mid-rename.
    vim.uv.fs_open(tmp, "w", 438, function(err, fd)
        if err or not fd then
            vim.schedule(function()
                disable("cannot write " .. tmp .. ": " .. tostring(err))
            end)
            return
        end
        vim.uv.fs_write(fd, blob, -1, function(werr)
            vim.uv.fs_close(fd, function()
                if werr then
                    vim.uv.fs_unlink(tmp, function() end)
                    vim.schedule(function()
                        disable("cache write failed: " .. tostring(werr))
                    end)
                    return
                end
                vim.uv.fs_rename(tmp, path, function(rerr)
                    if rerr then
                        vim.uv.fs_unlink(tmp, function() end)
                        vim.schedule(function()
                            disable("cannot rename cache file: " .. tostring(rerr))
                        end)
                        return
                    end
                    vim.schedule(M.rotate)
                end)
            end)
        end)
    end)
end

--- Remove the persisted cache for a buffer (used by :FIX cache clear).
---@param buf number
function M.delete(buf)
    local path = M.path_for(buf)
    if path then
        os.remove(path)
    end
end

return M

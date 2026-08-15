--- The plugin's validation exposed as a language server running inside Neovim.
---
--- The engine owns every bit of state; this module answers
--- `textDocument/codeAction` and `textDocument/hover` from it and owns the
--- client the diagnostics are published under. Edits are always applied by
--- Neovim's LSP client as a workspace edit, so undo, `gra` and any
--- code-action UI behave as usual.

local Overrides = require("fix.overrides")

local M = {}

local CLIENT_NAME = "fix-validate"

local FIX_ALL_TITLE = "Fix all FIX messages"
local KIND_QUICKFIX = "quickfix"
local KIND_FIX_ALL = "source.fixAll"

local client_id = nil ---@type number|nil
local dispatchers = nil ---@type vim.lsp.rpc.Dispatchers|nil

local function engine()
    return require("fix.validate")
end

--- LSP `only` filters by kind prefix; no filter means everything.
---@param only string[]|nil
---@param kind string
---@return boolean
local function wants(only, kind)
    if type(only) ~= "table" or #only == 0 then
        return true
    end
    for _, want in ipairs(only) do
        if kind == want or vim.startswith(kind, want .. ".") then
            return true
        end
    end
    return false
end

--- Byte columns pass straight through as characters: the server declares utf-8.
---@param lnum number 0-based
---@param diagnostic FixDiagnostic
---@return lsp.Diagnostic
function M.to_lsp_diagnostic(lnum, diagnostic)
    return {
        range = {
            start = { line = lnum, character = diagnostic.col },
            ["end"] = { line = diagnostic.end_lnum or lnum, character = diagnostic.end_col },
        },
        severity = diagnostic.severity,
        code = diagnostic.code,
        source = diagnostic.source,
        message = diagnostic.message,
    }
end

---@param lnum number 0-based
---@param edits FixEdit[]
---@return lsp.TextEdit[]
local function to_text_edits(lnum, edits)
    local out = {}
    for _, edit in ipairs(edits) do
        local row = edit.lnum or lnum
        out[#out + 1] = {
            range = {
                start = { line = row, character = edit.col },
                ["end"] = { line = row, character = edit.end_col },
            },
            newText = edit.new_text,
        }
    end
    return out
end

---@param uri string
---@param edits lsp.TextEdit[]
---@return lsp.WorkspaceEdit
local function workspace_edit(uri, edits)
    return { changes = { [uri] = edits } }
end

---@param buf number
---@param first number 0-based inclusive
---@param last number 0-based inclusive
---@return number[]
local function lines_to_visit(buf, first, last)
    if first == last then
        -- A cursor invocation must see edits made since the last walk, even on
        -- a line that had nothing wrong with it before.
        return { first }
    end
    return engine().lines_with_diagnostics(buf, first, last)
end

--- Revalidate a line and pair every diagnostic with the fixes that repair it.
--- Two rules can hand out the same fix table (BodyLength and CheckSum share
--- one repair); the first diagnostic to claim it keeps it.
---@param buf number
---@param lnum number 0-based
---@return { diagnostic: FixDiagnostic, fix: FixFix, edits: FixEdit[] }[]
local function fixes_on_line(buf, lnum)
    local diagnostics, ctx = engine().refresh_line(buf, lnum)
    local items, seen = {}, {}
    for _, diagnostic in ipairs(diagnostics or {}) do
        for _, fix in ipairs(diagnostic.fixes or {}) do
            if not seen[fix] then
                seen[fix] = true
                local edits = engine().fix_edits(fix, ctx)
                if edits then
                    items[#items + 1] = { diagnostic = diagnostic, fix = fix, edits = edits }
                end
            end
        end
    end
    return items
end

---@param params lsp.CodeActionParams
---@return lsp.CodeAction[]
local function code_actions(params)
    local uri = params.textDocument and params.textDocument.uri
    local buf = engine().buf_from_uri(uri)
    if not buf then
        return {}
    end

    -- lsp.enabled=false leaves the in-process client attached, so this must
    -- gate itself rather than rely on being detached.
    if not Overrides.effective(buf).lsp.enabled then
        return {}
    end

    local range = params.range
    local only = params.context and params.context.only
    local actions = {}

    if wants(only, KIND_QUICKFIX) then
        for _, lnum in ipairs(lines_to_visit(buf, range.start.line, range["end"].line)) do
            for _, item in ipairs(fixes_on_line(buf, lnum)) do
                actions[#actions + 1] = {
                    title = item.fix.title,
                    kind = KIND_QUICKFIX,
                    diagnostics = { M.to_lsp_diagnostic(lnum, item.diagnostic) },
                    edit = workspace_edit(uri, to_text_edits(lnum, item.edits)),
                }
            end
        end
    end

    if wants(only, KIND_FIX_ALL) then
        local edits = {}
        for _, lnum in ipairs(engine().lines_with_diagnostics(buf)) do
            for _, item in ipairs(fixes_on_line(buf, lnum)) do
                vim.list_extend(edits, to_text_edits(lnum, item.edits))
            end
        end
        if #edits > 0 then
            actions[#actions + 1] = {
                title = FIX_ALL_TITLE,
                kind = KIND_FIX_ALL,
                edit = workspace_edit(uri, edits),
            }
        end
    end

    return actions
end

--- Dictionary hover for the field at the request position, or nil.
---@param params lsp.HoverParams
---@return lsp.Hover|nil
local function hover(params)
    local buf = engine().buf_from_uri(params.textDocument and params.textDocument.uri)
    if not buf then
        return nil -- subsystem detached, e.g. `:FIX lsp toggle` off
    end
    -- Same gate as code_actions: lsp.enabled leaves the client attached, so
    -- hover must check both flags itself rather than rely on detachment.
    local lsp = Overrides.effective(buf).lsp
    if not lsp.enabled or not lsp.hover.enabled then
        return nil
    end

    -- utf-8 position encoding: `character` is a byte column.
    local pos = params.position
    local message, field = require("fix.document").get_field_at(buf, pos.line, pos.character)
    if not message or not field then
        return nil
    end

    local value = require("fix.validate.hover").markdown(buf, message, field)
    if not value then
        return nil
    end
    return {
        contents = { kind = "markdown", value = value },
        range = {
            start = { line = pos.line, character = field.tag_start },
            ["end"] = { line = pos.line, character = field.value_end },
        },
    }
end

---@param server_dispatchers vim.lsp.rpc.Dispatchers
---@return vim.lsp.rpc.PublicClient
local function server(server_dispatchers)
    dispatchers = server_dispatchers
    local closing = false
    local message_id = 0

    return {
        request = function(method, params, callback)
            message_id = message_id + 1
            if method == "initialize" then
                callback(nil, {
                    -- Byte columns are what the rules produce; declaring utf-8
                    -- keeps them meaningful all the way through the client.
                    capabilities = {
                        positionEncoding = "utf-8",
                        textDocumentSync = {
                            openClose = false,
                            change = vim.lsp.protocol.TextDocumentSyncKind.None,
                        },
                        codeActionProvider = { codeActionKinds = { KIND_QUICKFIX, KIND_FIX_ALL } },
                        -- Always advertised: initialize runs once per client, so a
                        -- config-driven flag here would freeze the setting until
                        -- restart. The handler checks the option per request.
                        hoverProvider = true,
                    },
                    serverInfo = { name = CLIENT_NAME },
                })
            elseif method == "textDocument/codeAction" then
                local ok, result = pcall(code_actions, params)
                if ok then
                    callback(nil, result)
                else
                    vim.notify_once("fix.nvim: code action failed: " .. tostring(result), vim.log.levels.ERROR)
                    callback(nil, {})
                end
            elseif method == "textDocument/hover" then
                local ok, result = pcall(hover, params)
                if ok then
                    callback(nil, result)
                else
                    vim.notify_once("fix.nvim: hover failed: " .. tostring(result), vim.log.levels.ERROR)
                    callback(nil, nil)
                end
            elseif method == "shutdown" then
                callback(nil, nil)
            else
                callback(vim.lsp.rpc.rpc_response_error(vim.lsp.protocol.ErrorCodes.MethodNotFound, method), nil)
            end
            return true, message_id
        end,
        notify = function(method)
            if method == "exit" then
                closing = true
            end
            return true
        end,
        is_closing = function()
            return closing
        end,
        terminate = function()
            closing = true
        end,
    }
end

--- Start (or reuse) the client and attach `buf` to it.
---@param buf number
---@return number|nil client_id
function M.ensure_client(buf)
    local ok, id = pcall(vim.lsp.start, { name = CLIENT_NAME, cmd = server }, {
        bufnr = buf,
        reuse_client = function(client)
            return client.name == CLIENT_NAME
        end,
        silent = true,
    })
    if not ok or not id then
        vim.notify_once("fix.nvim: could not start the validation server; diagnostics are off", vim.log.levels.WARN)
        return nil
    end
    client_id = id
    return id
end

--- The namespace our diagnostics land in, once the client is running.
---@return number|nil
function M.namespace()
    if not client_id or not vim.lsp.get_client_by_id(client_id) then
        return nil
    end
    return vim.lsp.diagnostic.get_namespace(client_id, false)
end

--- Replace this buffer's diagnostics, the way any language server does. Going
--- through the client rather than `vim.diagnostic.set` is what fills in the
--- bookkeeping the rest of `vim.lsp` reads back, `user_data.lsp` above all.
---
--- Buffers with no name are skipped: their URI is `file://`, which
--- `vim.uri_to_bufnr` turns into a brand new buffer on every call.
---@param buf number
---@param diagnostics lsp.Diagnostic[]
function M.publish(buf, diagnostics)
    if not dispatchers or not client_id or not vim.lsp.get_client_by_id(client_id) then
        return
    end
    if not vim.api.nvim_buf_is_valid(buf) or vim.api.nvim_buf_get_name(buf) == "" then
        return
    end
    dispatchers.notification("textDocument/publishDiagnostics", {
        uri = vim.uri_from_bufnr(buf),
        diagnostics = diagnostics,
    })
end

---@param buf number
function M.clear(buf)
    M.publish(buf, {})
end

return M

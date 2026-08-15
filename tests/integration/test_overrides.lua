local H = require("tests.integration.helpers")
local MiniTest = require("mini.test")

local T = H.new_test_set()
local nvim = H.nvim

local BINANCE_OE = "xml/custom/binance/spot-fix-oe.xml"
local BINANCE_MD = "xml/custom/binance/spot-fix-md.xml"

--- New buffer, given lines, `fix.overrides` attached — but no `filetype=fix`
--- and no wait: the module doesn't need a parser and nothing else consumes
--- it yet, so tests talk to its API directly.
local function set_lines_and_attach(lines)
    nvim().cmd("enew")
    nvim().lua("vim.api.nvim_buf_set_lines(0, 0, -1, false, " .. vim.inspect(lines) .. ")")
    nvim().lua([[require("fix.overrides").attach(vim.api.nvim_get_current_buf())]])
    return nvim().lua_get("vim.api.nvim_get_current_buf()")
end

local function effective_position(buf)
    return nvim().lua_get(("require('fix.overrides').effective(%d).annotate.title.position"):format(buf))
end

local function effective_tag_enabled(buf)
    return nvim().lua_get(("require('fix.overrides').effective(%d).annotate.tag.enabled"):format(buf))
end

-- Modeline parsing -----------------------------------------------------

T["modeline: valid pairs are applied"] = function()
    local buf = set_lines_and_attach({
        "# fix: annotate.tag.enabled=true, annotate.title.position=below",
        "8=FIX.4.4|9=0|35=0|34=1|49=A|56=B|52=20260101-00:00:00.000|10=000|",
    })
    local result = nvim().lua_get(
        (
            "(function() local o = require('fix.overrides').effective(%d) "
            .. "return { tag = o.annotate.tag.enabled, position = o.annotate.title.position } end)()"
        ):format(buf)
    )
    MiniTest.expect.equality(result, { tag = true, position = "below" })
end

T["modeline: a payload without '=' is an ordinary comment"] = function()
    local buf = set_lines_and_attach({ "# fix: TODO check this later" })
    local same = nvim().lua_get(("require('fix.overrides').effective(%d) == require('fix').opts"):format(buf))
    MiniTest.expect.equality(same, true)
    H.expect_no_error_notifications(nvim())
    local warning_count = nvim().lua_get(("#require('fix.overrides').describe(%d).warnings"):format(buf))
    MiniTest.expect.equality(warning_count, 0)
end

T["modeline: unknown key warns and is skipped"] = function()
    local buf = set_lines_and_attach({ "# fix: not.a.real.key=true" })
    H.expect_notified(nvim(), "unknown key")
    local warning_count = nvim().lua_get(("#require('fix.overrides').describe(%d).warnings"):format(buf))
    MiniTest.expect.equality(warning_count, 1)
end

T["modeline: invalid enum value warns"] = function()
    local buf = set_lines_and_attach({ "# fix: annotate.title.position=diagonal" })
    H.expect_notified(nvim(), "must be one of")
    MiniTest.expect.equality(effective_position(buf), "above") -- global default, override dropped
end

T["modeline: a modeline past the first 5 lines is ignored"] = function()
    local buf = set_lines_and_attach({
        "1",
        "2",
        "3",
        "4",
        "5",
        "# fix: annotate.tag.enabled=true",
    })
    MiniTest.expect.equality(effective_tag_enabled(buf), false) -- global default
end

T["modeline: the first matching line wins"] = function()
    local buf = set_lines_and_attach({
        "# fix: annotate.tag.enabled=true",
        "# fix: annotate.tag.enabled=false",
    })
    MiniTest.expect.equality(effective_tag_enabled(buf), true)
end

T["modeline: an invalid value falls through to the next weaker layer"] = function()
    nvim().lua([[vim.g.fix_annotate_title_position = "below"]])
    local buf = set_lines_and_attach({ "# fix: annotate.title.position=bogus" })
    MiniTest.expect.equality(effective_position(buf), "below")
    H.expect_notified(nvim(), "must be one of")
end

-- Layer precedence -----------------------------------------------------

T["layer precedence: modeline > vim.b > editorconfig > vim.g > setup"] = function()
    nvim().cmd("enew")
    nvim().lua([[vim.api.nvim_buf_set_lines(0, 0, -1, false, { "" })]])
    local buf = nvim().lua_get("vim.api.nvim_get_current_buf()")

    nvim().lua([[
        local buf = vim.api.nvim_get_current_buf()
        vim.g.fix_annotate_title_position = "below"
        require("fix.overrides").attach(buf)
    ]])
    MiniTest.expect.equality(effective_position(buf), "below")

    nvim().lua([[
        local buf = vim.api.nvim_get_current_buf()
        vim.b[buf].editorconfig = { fix_annotate_title_position = "front" }
        require("fix.overrides").refresh(buf)
    ]])
    MiniTest.expect.equality(effective_position(buf), "front")

    nvim().lua([[
        local buf = vim.api.nvim_get_current_buf()
        vim.b[buf].fix_annotate_title_position = "replace"
        require("fix.overrides").refresh(buf)
    ]])
    MiniTest.expect.equality(effective_position(buf), "replace")

    nvim().lua([[
        local buf = vim.api.nvim_get_current_buf()
        vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "# fix: annotate.title.position=replace_front" })
        require("fix.overrides").refresh(buf)
    ]])
    MiniTest.expect.equality(effective_position(buf), "replace_front")
end

T["layer precedence: flat vim.b beats nested vim.b.fix"] = function()
    nvim().cmd("enew")
    nvim().lua([[
        local buf = vim.api.nvim_get_current_buf()
        vim.b[buf].fix = { annotate = { title = { position = "below" } } }
        vim.b[buf].fix_annotate_title_position = "front"
        require("fix.overrides").attach(buf)
    ]])
    local buf = nvim().lua_get("vim.api.nvim_get_current_buf()")
    MiniTest.expect.equality(effective_position(buf), "front")
end

T["layer precedence: flat vim.g beats nested vim.g.fix"] = function()
    nvim().lua([[
        vim.g.fix = { annotate = { title = { position = "below" } } }
        vim.g.fix_annotate_title_position = "front"
    ]])
    nvim().cmd("enew")
    nvim().lua([[require("fix.overrides").attach(vim.api.nvim_get_current_buf())]])
    local buf = nvim().lua_get("vim.api.nvim_get_current_buf()")
    MiniTest.expect.equality(effective_position(buf), "front")
end

-- effective() identity --------------------------------------------------

T["effective(): a buffer with no overrides returns the global opts table itself"] = function()
    local buf = set_lines_and_attach({ "" })
    local same = nvim().lua_get(("require('fix.overrides').effective(%d) == require('fix').opts"):format(buf))
    MiniTest.expect.equality(same, true)
end

T["effective(): an overridden buffer's overlay does not mutate the global table"] = function()
    nvim().cmd("enew")
    nvim().lua([[
        local buf = vim.api.nvim_get_current_buf()
        vim.b[buf].fix_annotate_tag_enabled = true
        require("fix.overrides").attach(buf)
    ]])
    local result = nvim().lua_get([[(function()
        local buf = vim.api.nvim_get_current_buf()
        local overlay = require("fix.overrides").effective(buf)
        local global_opts = require("fix").opts
        return {
            overlay_tag = overlay.annotate.tag.enabled,
            global_tag = global_opts.annotate.tag.enabled,
            different_identity = overlay ~= global_opts,
            shared_subtable = overlay.render == global_opts.render,
        }
    end)()]])
    MiniTest.expect.equality(
        result,
        { overlay_tag = true, global_tag = false, different_identity = true, shared_subtable = true }
    )
end

T["effective(): a dictionary-only override does not build an overlay"] = function()
    nvim().lua(([[
        require("fix").setup({
            dictionaries = { { path = %q, mode = "quickfix", name = "binance-oe" } },
        })
    ]]):format(BINANCE_OE))
    nvim().cmd("enew")
    nvim().lua([[
        local buf = vim.api.nvim_get_current_buf()
        vim.b[buf].fix_dictionary = "binance-oe"
        require("fix.overrides").attach(buf)
    ]])
    local same =
        nvim().lua_get([[require("fix.overrides").effective(vim.api.nvim_get_current_buf()) == require("fix").opts]])
    MiniTest.expect.equality(same, true)
end

-- Formatter target mapping ----------------------------------------------

T["formatter override lands the resolved function at annotate.tag.formatter"] = function()
    nvim().lua([[
        require("fix").setup({
            formatters = {
                tag = {
                    loud = function(_) return { text = "LOUD", highlight = "Comment" } end,
                },
            },
        })
    ]])
    nvim().cmd("enew")
    nvim().lua([[
        local buf = vim.api.nvim_get_current_buf()
        vim.b[buf].fix_formatter_tag = "loud"
        require("fix.overrides").attach(buf)
    ]])
    local matches = nvim().lua_get([[(function()
        local buf = vim.api.nvim_get_current_buf()
        local overlay = require("fix.overrides").effective(buf)
        return overlay.annotate.tag.formatter == require("fix").opts.formatters.tag.loud
    end)()]])
    MiniTest.expect.equality(matches, true)
end

T["formatter: an unknown formatter name warns"] = function()
    set_lines_and_attach({ "# fix: formatter.tag=nonexistent" })
    H.expect_notified(nvim(), "unknown formatter")
end

-- allow_paths -------------------------------------------------------------

T["allow_paths: a modeline dictionary path is refused by default"] = function()
    local buf = set_lines_and_attach({ ("# fix: dictionary=%s"):format(BINANCE_OE) })
    H.expect_notified(nvim(), "overrides.modeline.allow_paths")
    local source = nvim().lua_get(("require('fix.overrides').dictionary_source(%d)"):format(buf))
    MiniTest.expect.equality(source, vim.NIL)
end

T["allow_paths: enabling it accepts a modeline dictionary path"] = function()
    nvim().lua([[require("fix").setup({ overrides = { modeline = { allow_paths = true } } })]])
    local buf = set_lines_and_attach({ ("# fix: dictionary=%s"):format(BINANCE_OE) })
    local version = nvim().lua_get(("require('fix.overrides').dictionary_source(%d).version"):format(buf))
    MiniTest.expect.equality(type(version), "string")
end

T["allow_paths: a registered dictionary name works regardless"] = function()
    nvim().lua(([[
        require("fix").setup({
            dictionaries = { { path = %q, mode = "quickfix", name = "binance-oe" } },
        })
    ]]):format(BINANCE_OE))
    local buf = set_lines_and_attach({ "# fix: dictionary=binance-oe" })
    local name = nvim().lua_get(("require('fix.overrides').describe(%d).overrides.dictionary.value.name"):format(buf))
    MiniTest.expect.equality(name, "binance-oe")
end

T["dictionary: an unresolvable path warns even when paths are allowed"] = function()
    nvim().lua([[require("fix").setup({ overrides = { modeline = { allow_paths = true } } })]])
    local buf = set_lines_and_attach({ "# fix: dictionary=xml/custom/does-not-exist.xml" })
    H.expect_notified(nvim(), "could not load")
    local source = nvim().lua_get(("require('fix.overrides').dictionary_source(%d)"):format(buf))
    MiniTest.expect.equality(source, vim.NIL)
end

-- cache_suffix ------------------------------------------------------------

T["cache_suffix: nil without a content override"] = function()
    nvim().cmd("enew")
    nvim().lua([[
        local buf = vim.api.nvim_get_current_buf()
        vim.b[buf].fix_annotate_tag_enabled = true -- not a content key
        require("fix.overrides").attach(buf)
    ]])
    local suffix = nvim().lua_get([[require("fix.overrides").cache_suffix(vim.api.nvim_get_current_buf())]])
    MiniTest.expect.equality(suffix, vim.NIL)
end

T["cache_suffix: stable across calls, 32 hex chars"] = function()
    nvim().cmd("enew")
    nvim().lua([[
        local buf = vim.api.nvim_get_current_buf()
        vim.b[buf].fix_annotate_group_path_enabled = false
        require("fix.overrides").attach(buf)
    ]])
    local a = nvim().lua_get([[require("fix.overrides").cache_suffix(vim.api.nvim_get_current_buf())]])
    local b = nvim().lua_get([[require("fix.overrides").cache_suffix(vim.api.nvim_get_current_buf())]])
    MiniTest.expect.equality(a, b)
    MiniTest.expect.equality(#a, 33)
    MiniTest.expect.equality(a:sub(1, 1), ":")
    MiniTest.expect.equality(a:sub(2):match("^%x+$") ~= nil, true)
end

T["cache_suffix: differs for two different dictionaries"] = function()
    nvim().lua(([[
        require("fix").setup({
            dictionaries = {
                { path = %q, mode = "quickfix", name = "binance-oe" },
                { path = %q, mode = "quickfix", name = "binance-md" },
            },
        })
    ]]):format(BINANCE_OE, BINANCE_MD))
    nvim().cmd("enew")
    nvim().lua([[
        local buf = vim.api.nvim_get_current_buf()
        vim.b[buf].fix_dictionary = "binance-oe"
        require("fix.overrides").attach(buf)
    ]])
    local buf = nvim().lua_get("vim.api.nvim_get_current_buf()")
    local suffix_a = nvim().lua_get([[require("fix.overrides").cache_suffix(vim.api.nvim_get_current_buf())]])

    nvim().lua([[
        local buf = vim.api.nvim_get_current_buf()
        vim.b[buf].fix_dictionary = "binance-md"
        require("fix.overrides").refresh(buf)
    ]])
    local suffix_b = nvim().lua_get([[require("fix.overrides").cache_suffix(vim.api.nvim_get_current_buf())]])

    MiniTest.expect.equality(suffix_a ~= suffix_b, true)
    MiniTest.expect.equality(buf ~= nil, true)
end

-- Live rescan -------------------------------------------------------------

T["live rescan: editing the modeline updates the resolved map"] = function()
    local buf = set_lines_and_attach({ "# fix: annotate.tag.enabled=false" })
    MiniTest.expect.equality(effective_tag_enabled(buf), false)

    nvim().lua([[vim.api.nvim_buf_set_lines(0, 0, 1, false, { "# fix: annotate.tag.enabled=true" })]])
    local ok =
        H.wait_for(nvim(), ("require('fix.overrides').effective(%d).annotate.tag.enabled == true"):format(buf), 2000)
    MiniTest.expect.equality(ok, true)
end

-- Lifecycle -----------------------------------------------------------

T["detach keeps the resolved state; a later attach re-scans without resetting it"] = function()
    local buf = set_lines_and_attach({ "# fix: annotate.tag.enabled=true" })
    MiniTest.expect.equality(effective_tag_enabled(buf), true)

    nvim().lua(("require('fix.overrides').detach(%d)"):format(buf))
    local still_resolved =
        nvim().lua_get(("require('fix.overrides').describe(%d).overrides['annotate.tag.enabled'].value"):format(buf))
    MiniTest.expect.equality(still_resolved, true)

    nvim().lua(("require('fix.overrides').attach(%d)"):format(buf))
    MiniTest.expect.equality(effective_tag_enabled(buf), true)
end

T["a detach/attach cycle without an edit does not leak a second listener"] = function()
    nvim().cmd("enew")
    nvim().lua([[
        local buf = vim.api.nvim_get_current_buf()
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "# fix: annotate.tag.enabled=false" })

        -- Wrap nvim_buf_attach so every listener reports its own on_lines
        -- firings: a deduplicated set fires once per edit no matter how many
        -- attach/detach cycles preceded it.
        _G._fix_test_on_lines_calls = 0
        local orig_attach = vim.api.nvim_buf_attach
        vim.api.nvim_buf_attach = function(b, send_buffer, callbacks)
            local orig_on_lines = callbacks.on_lines
            callbacks.on_lines = function(...)
                if b == buf then
                    _G._fix_test_on_lines_calls = _G._fix_test_on_lines_calls + 1
                end
                return orig_on_lines(...)
            end
            return orig_attach(b, send_buffer, callbacks)
        end

        local O = require("fix.overrides")
        O.attach(buf)
        O.detach(buf)
        O.attach(buf)
        O.detach(buf)
        O.attach(buf)

        vim.api.nvim_buf_attach = orig_attach
    ]])

    nvim().lua([[vim.api.nvim_buf_set_lines(0, 0, 1, false, { "# fix: annotate.tag.enabled=true" })]])

    local calls = nvim().lua_get("_G._fix_test_on_lines_calls")
    MiniTest.expect.equality(calls, 1)
end

-- Cache namespacing (rendered output) --------------------------------------
--
-- Both cache layers used to be keyed by content hash alone, shared across
-- buffers. Two buffers holding the byte-identical line below, overriding to
-- different dictionaries for the same FIX version, must not leak decodes
-- into each other.

local SAME_VERSION_DICTS = [[
    require("fix").setup({
        dictionaries = {
            {
                version = "FIX.4.4",
                name = "dict-a",
                tags = { [100] = function() return { tag_text = "LabelA" } end },
            },
            {
                version = "FIX.4.4",
                name = "dict-b",
                tags = { [100] = function() return { tag_text = "LabelB" } end },
            },
        },
    })
]]

local SHARED_MESSAGE_LINE = "8=FIX.4.4|9=5|35=D|100=X|10=000|"

--- New buffer with a `# fix: dictionary=<name>` modeline above the shared
--- message line, overrides attached and rendered. Returns its bufnr.
local function open_dict_buffer(name)
    nvim().cmd("enew")
    nvim().lua(([[
        vim.api.nvim_buf_set_lines(0, 0, -1, false, { "# fix: dictionary=%s", %q })
        local buf = vim.api.nvim_get_current_buf()
        require("fix.overrides").attach(buf)
        vim.bo.filetype = "fix"
    ]]):format(name, SHARED_MESSAGE_LINE))
    H.wait_annotated(nvim())
    return nvim().lua_get("vim.api.nvim_get_current_buf()")
end

local function assert_buffer_shows(buf, label, not_label)
    nvim().cmd("buffer " .. buf)
    H.expect_inline_label(nvim(), label)
    H.expect_no_inline_label(nvim(), not_label)
end

T["cache namespacing: two buffers, same line, different dictionaries (a opened first)"] = function()
    H.enable_inline_annotations(nvim())
    nvim().lua(SAME_VERSION_DICTS)

    local buf_a = open_dict_buffer("dict-a")
    local buf_b = open_dict_buffer("dict-b")

    assert_buffer_shows(buf_a, "LabelA", "LabelB")
    assert_buffer_shows(buf_b, "LabelB", "LabelA")

    -- Force a re-render of both from scratch; neither must have poisoned the
    -- other's cache entry.
    nvim().lua(("require('fix.render').rerender(%d)"):format(buf_a))
    nvim().lua(("require('fix.render').rerender(%d)"):format(buf_b))
    nvim().cmd("buffer " .. buf_a)
    H.wait_annotated(nvim())
    nvim().cmd("buffer " .. buf_b)
    H.wait_annotated(nvim())

    assert_buffer_shows(buf_a, "LabelA", "LabelB")
    assert_buffer_shows(buf_b, "LabelB", "LabelA")
end

T["cache namespacing: two buffers, same line, different dictionaries (b opened first)"] = function()
    H.enable_inline_annotations(nvim())
    nvim().lua(SAME_VERSION_DICTS)

    local buf_b = open_dict_buffer("dict-b")
    local buf_a = open_dict_buffer("dict-a")

    assert_buffer_shows(buf_b, "LabelB", "LabelA")
    assert_buffer_shows(buf_a, "LabelA", "LabelB")
end

-- Document.key_for ----------------------------------------------------------

T["Document.key_for: an unattached buffer's key equals the bare Cache.key"] = function()
    local equal = nvim().lua_get([[(function()
        local Document = require("fix.document")
        local Cache = require("fix.cache")
        vim.cmd("enew")
        local buf = vim.api.nvim_get_current_buf()
        local line = "8=FIX.4.4|9=5|35=D|10=000|"
        return Document.key_for(buf, line) == Cache.key(line)
    end)()]])
    MiniTest.expect.equality(equal, true)
end

T["Document.key_for: an attached buffer without a content override still shares the bare key"] = function()
    local equal = nvim().lua_get([[(function()
        local Document = require("fix.document")
        local Cache = require("fix.cache")
        vim.cmd("enew")
        local buf = vim.api.nvim_get_current_buf()
        vim.b[buf].fix_annotate_tag_enabled = true -- not a content-affecting key
        require("fix.overrides").attach(buf)
        local line = "8=FIX.4.4|9=5|35=D|10=000|"
        return Document.key_for(buf, line) == Cache.key(line)
    end)()]])
    MiniTest.expect.equality(equal, true)
end

-- Alias-aware version matching -----------------------------------------

T["alias: a FIXT.1.1 message decodes through an override registered under FIX.5.0SP2"] = function()
    H.enable_inline_annotations(nvim())
    nvim().lua([[
        require("fix").setup({
            dictionaries = {
                {
                    version = "FIX.5.0SP2",
                    name = "fixt-override",
                    tags = { [100] = function() return { tag_text = "FixtLabel" } end },
                },
            },
        })
        vim.cmd("enew")
        local buf = vim.api.nvim_get_current_buf()
        vim.b[buf].fix_dictionary = "fixt-override"
        require("fix.overrides").attach(buf)
        vim.api.nvim_buf_set_lines(0, 0, -1, false, { "8=FIXT.1.1|9=5|35=D|100=X|10=000|" })
        vim.bo.filetype = "fix"
    ]])
    H.wait_annotated(nvim())
    H.expect_inline_label(nvim(), "FixtLabel")
end

-- Persist gate ---------------------------------------------------------

local LUA_TAG_DECODER_SETUP = [[
    _G._persist_dir = vim.fn.tempname()
    require("fix").setup({
        cache = { persist = { dir = _G._persist_dir } },
        dictionaries = {
            {
                version = "FIX.4.4",
                name = "lua-tags",
                tags = { [100] = function() return { tag_text = "Decoded" } end },
            },
        },
    })
]]

T["persist gate: a buffer with Lua tag decoders writes no persist file"] = function()
    nvim().lua(LUA_TAG_DECODER_SETUP)
    nvim().lua([[
        vim.cmd("enew")
        local buf = vim.api.nvim_get_current_buf()
        vim.api.nvim_buf_set_name(buf, vim.fn.tempname() .. ".fix")
        vim.b[buf].fix_dictionary = "lua-tags"
        require("fix.overrides").attach(buf)
        _G._excluded = require("fix.overrides").persist_excluded(buf)
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "8=FIX.4.4|9=5|35=D|100=X|10=000|" })
        vim.bo.filetype = "fix"
    ]])
    MiniTest.expect.equality(nvim().lua_get("_G._excluded"), true)
    H.wait_annotated(nvim())
    H.sleep(nvim(), 300) -- give any async save a chance it should never take
    MiniTest.expect.equality(nvim().lua_get([[#vim.fn.globpath(_G._persist_dir, "*.mpack", false, true)]]), 0)
end

T["persist gate: a buffer with Lua tag decoders does not load a stale persist file"] = function()
    nvim().lua(LUA_TAG_DECODER_SETUP)
    local path = nvim().lua_get([[vim.fn.tempname() .. ".fix"]])
    -- Pre-seed a file that a load would happily accept (correct format/dict
    -- fingerprint/fallback version) if the gate were missing.
    nvim().lua(string.format(
        [[
        vim.fn.mkdir(_G._persist_dir, "p")
        local name = vim.fn.sha256(vim.fn.fnamemodify(%q, ":p")):sub(1, 32)
        local blob = vim.mpack.encode({
            format_version = 3,
            dict_fingerprint = require("fix.persist").fingerprint(),
            fallback_version = require("fix").opts.fallback_version,
            entries = { seed = { version = "FIX.4.4", fields = {} } },
        })
        local f = io.open(_G._persist_dir .. "/" .. name .. ".mpack", "wb")
        f:write(blob)
        f:close()

        vim.cmd("enew")
        local buf = vim.api.nvim_get_current_buf()
        vim.api.nvim_buf_set_name(buf, %q)
        vim.b[buf].fix_dictionary = "lua-tags"
        require("fix.overrides").attach(buf)
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "8=FIX.4.4|9=5|35=D|100=X|10=000|" })
        vim.bo.filetype = "fix"
    ]],
        path,
        path
    ))
    H.wait_annotated(nvim())
    local seeded_loaded = nvim().lua_get([[require("fix.cache").get_semantic("seed") ~= nil]])
    MiniTest.expect.equality(seeded_loaded, false)
end

-- Render.reset_keys -----------------------------------------------------

T["Render.reset_keys: a no-op on an unattached buffer"] = function()
    local ok = nvim().lua_get([[(function()
        local ok = pcall(require("fix.render").reset_keys, 999999)
        return ok
    end)()]])
    MiniTest.expect.equality(ok, true)
end

T["Render.reset_keys: an attached buffer stops persisting its old keys until it re-warms"] = function()
    nvim().lua([[
        _G._persist_dir = vim.fn.tempname()
        require("fix").setup({ cache = { persist = { dir = _G._persist_dir } } })
    ]])
    H.load_fixture(nvim(), "4.4.fix")
    local path = nvim().lua_get([[require("fix.persist").path_for(vim.api.nvim_get_current_buf())]])
    local had_file = H.wait_for(nvim(), ([[vim.uv.fs_stat(%q) ~= nil]]):format(path), 5000)
    MiniTest.expect.equality(had_file, true)

    -- Drop the file and the buffer's tracked keys, then flush again: with no
    -- keys left to collect, the save is a no-op and the file must stay gone.
    nvim().lua(([[
        os.remove(%q)
        local buf = vim.api.nvim_get_current_buf()
        require("fix.render").reset_keys(buf)
        require("fix.render").flush(buf, true)
    ]]):format(path))
    local recreated = nvim().lua_get(([[vim.uv.fs_stat(%q) ~= nil]]):format(path))
    MiniTest.expect.equality(recreated, false)
end

-- Buffer-aware settings reads --------------------------------------------
--
-- Render, validate, hover, code actions, and yank all read a buffer's own
-- `Overrides.effective(buf)` instead of the global `fix.opts`.

local HEARTBEAT = "8=FIX.4.4|9=57|35=0|34=1|49=CLIENT1|56=BROKER1|52=20251026-09:02:00.000|10=171|"
local BAD_CHECKSUM = "8=FIX.4.4|9=57|35=0|34=1|49=CLIENT1|56=BROKER1|52=20251026-09:02:00.000|10=001|"
local MSGTYPE_COL = assert(BAD_CHECKSUM:find("35=")) - 1

--- New buffer with `lines` and `filetype=fix`, so the real FileType autocmd
--- drives Render/Validate as in production. Named, not a bare `enew`:
--- `Lsp.publish` skips unnamed buffers, which would silently starve every
--- diagnostics assertion below.
local function open_buffer(lines)
    nvim().cmd("enew")
    nvim().lua([[vim.api.nvim_buf_set_name(0, vim.fn.tempname() .. ".fix")]])
    nvim().lua(("vim.api.nvim_buf_set_lines(0, 0, -1, false, %s)"):format(vim.inspect(lines)))
    local buf = nvim().lua_get("vim.api.nvim_get_current_buf()")
    nvim().lua(("require('fix.overrides').attach(%d)"):format(buf))
    nvim().lua([[vim.bo.filetype = "fix"]])
    H.wait_annotated(nvim())
    return buf
end

-- Annotation flags -------------------------------------------------------

T["per-buffer: annotate.title.enabled=false hides titles while a sibling buffer keeps them"] = function()
    local buf_off = open_buffer({ "# fix: annotate.title.enabled=false", HEARTBEAT })
    H.expect_virt_lines_count(nvim(), 0)

    open_buffer({ HEARTBEAT })
    H.expect_virt_lines_count(nvim(), 1)

    nvim().cmd("buffer " .. buf_off)
    H.wait_annotated(nvim())
    H.expect_virt_lines_count(nvim(), 0)
end

-- The headline guarantee (README + vimdoc): a buffer override always wins
-- over the runtime :FIX annotations toggle, which mutates the *global*
-- M.opts in place. This is why Overrides.effective() never caches the merged
-- view — a cached copy would go stale here.
T["overrides: a buffer's annotate.title.enabled override beats :FIX annotations title toggle"] = function()
    open_buffer({ "# fix: annotate.title.enabled=false", HEARTBEAT })
    H.expect_virt_lines_count(nvim(), 0)

    -- Toggled while THIS buffer is current: :FIX annotations title flips the
    -- global flag and immediately calls Render.rerender(buf) on this very
    -- buffer, forcing effective() to be re-evaluated against the new global.
    nvim().cmd("FIX annotations title") -- global: true -> false
    H.wait_annotated(nvim())
    H.expect_virt_lines_count(nvim(), 0)

    nvim().cmd("FIX annotations title") -- global: false -> true
    H.wait_annotated(nvim())
    H.expect_virt_lines_count(nvim(), 0) -- the override still wins over the now-true global

    -- A sibling with no override does track the (now restored) global.
    open_buffer({ HEARTBEAT })
    H.expect_virt_lines_count(nvim(), 1)
end

-- title.position and the diagnostic virtual_text resolver ----------------
--
-- One client, one namespace, shared across buffers — and the namespace's
-- `virtual_text` option is global by construction.

T["per-buffer: the diagnostic virtual_text resolver honours each buffer's own title.position"] = function()
    nvim().lua([[vim.diagnostic.config({ virtual_text = { prefix = "@" } })]])

    local buf_above = open_buffer({ BAD_CHECKSUM })
    H.wait_validated(nvim())
    local buf_replace = open_buffer({ "# fix: annotate.title.position=replace", BAD_CHECKSUM })
    H.wait_validated(nvim())
    local buf_front = open_buffer({ "# fix: annotate.title.position=replace_front", BAD_CHECKSUM })
    H.wait_validated(nvim())

    -- "above" (default): stock virtual text renders normally, unnarrowed.
    local above_marks = H.stock_virt_text(nvim(), buf_above)
    MiniTest.expect.equality(#above_marks, 1)
    MiniTest.expect.equality(above_marks[1].text:find("@", 1, true) ~= nil, true)

    -- "replace": the title carries the diagnostics; stock virtual text is off.
    MiniTest.expect.equality(#H.stock_virt_text(nvim(), buf_replace), 0)

    -- "replace_front": narrowed to the one revealed (cursor) line, the
    -- configured prefix preserved rather than replaced.
    nvim().cmd("buffer " .. buf_front)
    nvim().lua([[vim.api.nvim_win_set_cursor(0, { 2, 0 })]]) -- reveal the message line (row 2 of 2)
    H.wait_validated(nvim())
    local front_marks = H.stock_virt_text(nvim(), buf_front)
    MiniTest.expect.equality(#front_marks, 1)
    MiniTest.expect.equality(front_marks[1].text:find("@", 1, true) ~= nil, true)

    -- Re-check "above" last: the resolver decides fresh per call, not frozen
    -- by whichever buffer last configured the (buffer-independent) namespace.
    MiniTest.expect.equality(#H.stock_virt_text(nvim(), buf_above), 1)
end

-- A presentation-only override (annotate.title.position) changes what the
-- resolver decides without touching a buffer line, and the resolver is only
-- consulted again on the next publish — so nothing re-renders on its own.

-- vim.b throughout, not the modeline: modeline outranks vim.b and would keep
-- winning over the live edit below, masking the transition under test.

T["per-buffer: switching title.position away from replace re-renders the stock diagnostic"] = function()
    nvim().lua([[vim.diagnostic.config({ virtual_text = { prefix = "@" } })]])
    local buf = open_buffer({ BAD_CHECKSUM })
    nvim().lua(("vim.b[%d].fix_annotate_title_position = 'replace'"):format(buf))
    nvim().cmd("FIX overrides refresh")
    H.wait_validated(nvim())
    H.wait_annotated(nvim())
    MiniTest.expect.equality(#H.stock_virt_text(nvim(), buf), 0) -- title carries it

    nvim().lua(("vim.b[%d].fix_annotate_title_position = 'below'"):format(buf))
    nvim().cmd("FIX overrides refresh")
    H.wait_validated(nvim())
    H.wait_annotated(nvim())
    MiniTest.expect.equality(#H.stock_virt_text(nvim(), buf), 1) -- must now render inline
end

T["per-buffer: switching title.position to replace stops the doubled diagnostic"] = function()
    nvim().lua([[vim.diagnostic.config({ virtual_text = { prefix = "@" } })]])
    local buf = open_buffer({ BAD_CHECKSUM })
    nvim().lua(("vim.b[%d].fix_annotate_title_position = 'below'"):format(buf))
    nvim().cmd("FIX overrides refresh")
    H.wait_validated(nvim())
    H.wait_annotated(nvim())
    MiniTest.expect.equality(#H.stock_virt_text(nvim(), buf), 1)

    nvim().lua(("vim.b[%d].fix_annotate_title_position = 'replace'"):format(buf))
    nvim().cmd("FIX overrides refresh")
    H.wait_validated(nvim())
    H.wait_annotated(nvim())
    MiniTest.expect.equality(#H.stock_virt_text(nvim(), buf), 0) -- must not double up with the title
end

-- LSP gating ---------------------------------------------------------------

--- Quickfix-only action count. When no client is attached at all,
--- H.code_actions returns bare `nil` from the remote call, which crosses the
--- RPC boundary as `vim.NIL` (truthy, `#`-unsafe) rather than real Lua nil.
local function quickfix_count(nvim_, first, last)
    local actions = H.code_actions(nvim_, first, last, { "quickfix" })
    if actions == vim.NIL then
        return 0
    end
    return #actions
end

T["per-buffer: lsp.enabled=false blocks diagnostics, hover, and code actions while a sibling validates"] = function()
    open_buffer({ "# fix: lsp.enabled=false", BAD_CHECKSUM })
    H.wait_validated(nvim())
    MiniTest.expect.equality(#H.get_diagnostics(nvim()), 0)
    MiniTest.expect.equality(H.hover(nvim(), 1, MSGTYPE_COL), nil)
    MiniTest.expect.equality(quickfix_count(nvim(), 0), 0)

    open_buffer({ BAD_CHECKSUM })
    H.wait_validated(nvim())
    MiniTest.expect.equality(#H.get_diagnostics(nvim()), 1)
    MiniTest.expect.no_equality(H.hover(nvim(), 0, MSGTYPE_COL), nil)
    MiniTest.expect.equality(quickfix_count(nvim(), 0), 1)
end

T["per-buffer: lsp.validate.enabled=false stops diagnostics but hover still answers"] = function()
    open_buffer({ "# fix: lsp.validate.enabled=false", BAD_CHECKSUM })
    H.wait_validated(nvim())
    MiniTest.expect.equality(#H.get_diagnostics(nvim()), 0)
    MiniTest.expect.no_equality(H.hover(nvim(), 1, MSGTYPE_COL), nil)
end

-- A mid-session lsp.validate.enabled flip does not go through attach/detach
-- (lsp.enabled itself stays true), so it needs its own reconciliation path in
-- Validate.sync — separate from the lsp.enabled cases above.

T["per-buffer: lsp.validate.enabled=false clears existing diagnostics via :FIX overrides refresh"] = function()
    local buf = open_buffer({ BAD_CHECKSUM })
    H.wait_validated(nvim())
    MiniTest.expect.equality(#H.get_diagnostics(nvim()), 1)

    nvim().lua(("vim.b[%d].fix_lsp_validate_enabled = false"):format(buf))
    nvim().cmd("FIX overrides refresh")
    H.wait_validated(nvim())
    MiniTest.expect.equality(#H.get_diagnostics(nvim()), 0)
end

T["per-buffer: lsp.validate.enabled=true after starting false resumes diagnostics"] = function()
    -- vim.b throughout, not the modeline: modeline outranks vim.b, so a
    -- modeline-set false would keep winning over the live vim.b flip below.
    local buf = open_buffer({ BAD_CHECKSUM })
    nvim().lua(("vim.b[%d].fix_lsp_validate_enabled = false"):format(buf))
    nvim().cmd("FIX overrides refresh")
    H.wait_validated(nvim())
    MiniTest.expect.equality(#H.get_diagnostics(nvim()), 0)

    nvim().lua(("vim.b[%d].fix_lsp_validate_enabled = true"):format(buf))
    nvim().cmd("FIX overrides refresh")
    H.wait_validated(nvim())
    MiniTest.expect.equality(#H.get_diagnostics(nvim()), 1)
end

-- An override refresh drives Validate.sync(buf), so the engine detaches too
-- and hover/quickfix degrade to "no client". Its own case because it
-- isolates the handlers' gate in lsp.lua, not just the engine's attach state.
T["per-buffer: lsp.enabled=false mutes hover/code actions while the engine stays attached"] = function()
    local buf = open_buffer({ BAD_CHECKSUM })
    H.wait_validated(nvim())
    MiniTest.expect.equality(#H.get_diagnostics(nvim()), 1)
    MiniTest.expect.no_equality(H.hover(nvim(), 0, MSGTYPE_COL), nil)
    MiniTest.expect.equality(quickfix_count(nvim(), 0), 1)

    nvim().lua(("vim.b[%d].fix_lsp_enabled = false; require('fix.overrides').refresh(%d)"):format(buf, buf))

    MiniTest.expect.equality(H.hover(nvim(), 0, MSGTYPE_COL), nil)
    MiniTest.expect.equality(quickfix_count(nvim(), 0), 0)
end

-- Global toggle interaction -------------------------------------------------

T["global toggle: a buffer with an explicit override keeps its own state through :FIX lsp toggle"] = function()
    local buf_override_off = open_buffer({ "# fix: lsp.enabled=false", BAD_CHECKSUM })
    H.wait_validated(nvim())
    local buf_default = open_buffer({ BAD_CHECKSUM })
    H.wait_validated(nvim())
    MiniTest.expect.equality(#H.get_diagnostics(nvim()), 1)

    nvim().cmd("FIX lsp toggle") -- global off
    H.wait_validated(nvim())
    nvim().cmd("buffer " .. buf_default)
    H.wait_validated(nvim())
    MiniTest.expect.equality(#H.get_diagnostics(nvim()), 0)
    nvim().cmd("buffer " .. buf_override_off)
    H.wait_validated(nvim())
    MiniTest.expect.equality(#H.get_diagnostics(nvim()), 0)

    nvim().cmd("FIX lsp toggle") -- global on
    H.wait_validated(nvim())
    nvim().cmd("buffer " .. buf_default)
    H.wait_validated(nvim())
    MiniTest.expect.equality(#H.get_diagnostics(nvim()), 1)
    nvim().cmd("buffer " .. buf_override_off)
    H.wait_validated(nvim())
    MiniTest.expect.equality(#H.get_diagnostics(nvim()), 0) -- override always wins
end

T["reattach_all: a modeline lsp.enabled=true override survives re-setup() with the global flag false"] = function()
    nvim().lua([[require("fix").setup({ lsp = { enabled = false } })]])
    open_buffer({ "# fix: lsp.enabled=true", BAD_CHECKSUM })
    H.wait_validated(nvim())
    MiniTest.expect.equality(#H.get_diagnostics(nvim()), 1)

    -- A re-setup() with the same (still-false) global flag drives
    -- Validate.reattach_all(); the buffer's own override must survive it.
    nvim().lua([[require("fix").setup({ lsp = { enabled = false } })]])
    H.wait_validated(nvim())
    MiniTest.expect.equality(#H.get_diagnostics(nvim()), 1)
end

-- Yank -----------------------------------------------------------------

T["yank: a buffer's formatter.tag override is used by :FIX yank while a sibling keeps the default"] = function()
    nvim().lua([[
        require("fix").setup({
            formatters = { tag = { loud = function(_) return { "LOUD", "Comment" } end } },
        })
    ]])

    open_buffer({ "# fix: formatter.tag=loud", HEARTBEAT })
    nvim().cmd("normal! 2G0")
    nvim().fn.setreg("", "")
    nvim().cmd("FIX yank")
    local reg_loud = nvim().fn.getreg("")
    MiniTest.expect.equality(reg_loud:find("LOUD", 1, true) ~= nil, true)
    MiniTest.expect.equality(reg_loud:find("BeginString", 1, true), nil)

    open_buffer({ HEARTBEAT })
    nvim().cmd("normal! 1G0")
    nvim().fn.setreg("", "")
    nvim().cmd("FIX yank")
    local reg_default = nvim().fn.getreg("")
    MiniTest.expect.equality(reg_default:find("BeginString", 1, true) ~= nil, true)
    MiniTest.expect.equality(reg_default:find("LOUD", 1, true), nil)
end

-- Production wiring ------------------------------------------------------
--
-- Unlike every test above, these open buffers the way a real user would:
-- the FileType/BufWinEnter autocmds drive attach, no manual
-- `require("fix.overrides").attach(buf)` anywhere below.

T["end-to-end: a modeline in a freshly opened file hides titles with no manual attach"] = function()
    local path = nvim().lua_get([[vim.fn.tempname() .. ".fix"]])
    nvim().lua(([[
        vim.fn.writefile({ "# fix: annotate.title.enabled=false", %q }, %q)
        vim.cmd("edit " .. %q)
    ]]):format(HEARTBEAT, path, path))
    H.wait_annotated(nvim(), 5000)
    H.expect_virt_lines_count(nvim(), 0)
end

T["attach order: Overrides.attach runs before Render.attach, so the persist gate is reachable"] = function()
    nvim().lua(LUA_TAG_DECODER_SETUP)
    local path = nvim().lua_get([[vim.fn.tempname() .. ".fix"]])
    -- Pre-seed a file a load would happily accept if the gate were
    -- unreachable, i.e. if Render.attach ran before Overrides' state exists.
    nvim().lua(string.format(
        [[
        vim.fn.mkdir(_G._persist_dir, "p")
        local name = vim.fn.sha256(vim.fn.fnamemodify(%q, ":p")):sub(1, 32)
        local blob = vim.mpack.encode({
            format_version = 3,
            dict_fingerprint = require("fix.persist").fingerprint(),
            fallback_version = require("fix").opts.fallback_version,
            entries = { seed = { version = "FIX.4.4", fields = {} } },
        })
        local f = io.open(_G._persist_dir .. "/" .. name .. ".mpack", "wb")
        f:write(blob)
        f:close()

        vim.fn.writefile({ "# fix: dictionary=lua-tags", %q }, %q)
        vim.cmd("edit " .. %q)
    ]],
        path,
        "8=FIX.4.4|9=5|35=D|100=X|10=000|",
        path,
        path
    ))
    H.wait_annotated(nvim(), 5000)
    local seeded_loaded = nvim().lua_get([[require("fix.cache").get_semantic("seed") ~= nil]])
    MiniTest.expect.equality(seeded_loaded, false)
end

T["live edit: editing the modeline flips titles on and off"] = function()
    local buf = open_buffer({ HEARTBEAT })
    H.expect_virt_lines_count(nvim(), 1)

    nvim().lua(("vim.api.nvim_buf_set_lines(%d, 0, 0, false, { '# fix: annotate.title.enabled=false' })"):format(buf))
    H.sleep(nvim(), 300) -- exceeds the modeline rescan debounce
    H.wait_annotated(nvim())
    H.expect_virt_lines_count(nvim(), 0)

    nvim().lua(("vim.api.nvim_buf_set_lines(%d, 0, 1, false, { '# fix: annotate.title.enabled=true' })"):format(buf))
    H.sleep(nvim(), 300)
    H.wait_annotated(nvim())
    H.expect_virt_lines_count(nvim(), 1)
end

T["live edit: editing the modeline starts and stops diagnostics"] = function()
    local buf = open_buffer({ BAD_CHECKSUM })
    H.wait_validated(nvim())
    MiniTest.expect.equality(#H.get_diagnostics(nvim()), 1)

    nvim().lua(("vim.api.nvim_buf_set_lines(%d, 0, 0, false, { '# fix: lsp.enabled=false' })"):format(buf))
    H.sleep(nvim(), 300)
    H.wait_validated(nvim())
    MiniTest.expect.equality(#H.get_diagnostics(nvim()), 0)

    nvim().lua(("vim.api.nvim_buf_set_lines(%d, 0, 1, false, { '# fix: lsp.enabled=true' })"):format(buf))
    H.sleep(nvim(), 300)
    H.wait_validated(nvim())
    MiniTest.expect.equality(#H.get_diagnostics(nvim()), 1)
end

T["live edit: editing the dictionary in the modeline re-renders and refreshes the tree"] = function()
    H.enable_inline_annotations(nvim())
    nvim().lua(SAME_VERSION_DICTS)

    nvim().cmd("enew")
    nvim().lua(([[
        vim.api.nvim_buf_set_lines(0, 0, -1, false, { "# fix: dictionary=dict-a", %q })
        vim.bo.filetype = "fix"
    ]]):format(SHARED_MESSAGE_LINE))
    H.wait_annotated(nvim())
    H.expect_inline_label(nvim(), "LabelA")
    H.expect_no_inline_label(nvim(), "LabelB")
    local buf = nvim().lua_get("vim.api.nvim_get_current_buf()")

    local refreshes_before = H.get_tree_refreshes(nvim())
    nvim().lua(("vim.api.nvim_buf_set_lines(%d, 0, 1, false, { '# fix: dictionary=dict-b' })"):format(buf))
    H.sleep(nvim(), 300)
    H.wait_annotated(nvim())
    H.expect_inline_label(nvim(), "LabelB")
    H.expect_no_inline_label(nvim(), "LabelA")
    MiniTest.expect.equality(H.get_tree_refreshes(nvim()) > refreshes_before, true)
end

T["re-setup: a formatter rebound under the same name renders with the new function"] = function()
    H.enable_inline_annotations(nvim())
    nvim().lua([[
        require("fix").setup({
            formatters = { tag = { loud = function(_) return { "VerA", "Comment" } end } },
        })
    ]])
    open_buffer({ "# fix: formatter.tag=loud", HEARTBEAT })
    H.expect_inline_label(nvim(), "VerA")

    nvim().lua([[
        require("fix").setup({
            formatters = { tag = { loud = function(_) return { "VerB", "Comment" } end } },
        })
    ]])
    H.wait_annotated(nvim())
    H.expect_inline_label(nvim(), "VerB")
    H.expect_no_inline_label(nvim(), "VerA")
end

-- editorconfig -------------------------------------------------------------
--
-- Unlike the layer tests above, every fixture here is real: a temp directory
-- with an actual `.editorconfig` on disk and a real `:edit`, no hand-set
-- vim.b.editorconfig and no manual attach. "root = true" keeps each fixture
-- self-contained no matter what sits above the temp dir.

--- Writes a rooted `[*.fix]`-scoped `.editorconfig` and a `msg.fix` beside
--- it, edits the latter, and returns the buffer plus both paths for tests
--- that rewrite the `.editorconfig` and reopen.
local function open_with_editorconfig(ec_body, fix_lines)
    local dir = nvim().lua_get([[vim.fn.tempname()]])
    local path = dir .. "/msg.fix"
    local ec_lines = { "root = true", "[*.fix]" }
    for _, l in ipairs(ec_body) do
        ec_lines[#ec_lines + 1] = l
    end
    nvim().lua(([[
        vim.fn.mkdir(%q, "p")
        vim.fn.writefile(%s, %q .. "/.editorconfig")
        vim.fn.writefile(%s, %q)
        vim.cmd("edit " .. %q)
    ]]):format(dir, vim.inspect(ec_lines), dir, vim.inspect(fix_lines), path, path))
    H.wait_annotated(nvim(), 5000)
    local buf = nvim().lua_get("vim.api.nvim_get_current_buf()")
    return buf, dir, path
end

local function rewrite_editorconfig(dir, ec_body)
    local ec_lines = { "root = true", "[*.fix]" }
    for _, l in ipairs(ec_body) do
        ec_lines[#ec_lines + 1] = l
    end
    nvim().lua(("vim.fn.writefile(%s, %q .. '/.editorconfig')"):format(vim.inspect(ec_lines), dir))
end

--- Wipes the current buffer and re-edits `path`, forcing a fresh FileType +
--- editorconfig application: the case a callback-driven layer would get
--- wrong (no callback fires for a removed/`unset` property).
local function reopen(path)
    nvim().cmd("bwipeout!")
    nvim().cmd("edit " .. path)
    H.wait_annotated(nvim(), 5000)
end

T["editorconfig: a real .editorconfig file hides titles with no manual wiring"] = function()
    open_with_editorconfig({ "fix_annotate_title_enabled = false" }, { HEARTBEAT })
    H.expect_virt_lines_count(nvim(), 0)
end

T["editorconfig: a real b:fix_* set from a FileType autocmd wins over a real .editorconfig"] = function()
    nvim().lua([[
        vim.api.nvim_create_autocmd("FileType", {
            pattern = "fix",
            callback = function(args)
                vim.b[args.buf].fix_annotate_title_enabled = true
            end,
        })
    ]])
    open_with_editorconfig({ "fix_annotate_title_enabled = false" }, { HEARTBEAT })
    H.expect_virt_lines_count(nvim(), 1)
end

T["editorconfig: removing the last fix_* property + reopen reverts to global"] = function()
    local _, dir, path = open_with_editorconfig({ "fix_annotate_title_enabled = false" }, { HEARTBEAT })
    H.expect_virt_lines_count(nvim(), 0)

    rewrite_editorconfig(dir, {})
    reopen(path)
    H.expect_virt_lines_count(nvim(), 1)
end

T["editorconfig: setting fix_* to unset + reopen reverts to global"] = function()
    local _, dir, path = open_with_editorconfig({ "fix_annotate_title_enabled = false" }, { HEARTBEAT })
    H.expect_virt_lines_count(nvim(), 0)

    rewrite_editorconfig(dir, { "fix_annotate_title_enabled = unset" })
    reopen(path)
    H.expect_virt_lines_count(nvim(), 1)
end

T["editorconfig: vim.g.editorconfig = false + reopen reverts to global"] = function()
    local _, _, path = open_with_editorconfig({ "fix_annotate_title_enabled = false" }, { HEARTBEAT })
    H.expect_virt_lines_count(nvim(), 0)

    nvim().lua([[vim.g.editorconfig = false]])
    reopen(path)
    H.expect_virt_lines_count(nvim(), 1)
end

T["editorconfig: fix_dictionary=<path> is refused by default"] = function()
    local buf = open_with_editorconfig({ ("fix_dictionary = %s"):format(BINANCE_OE) }, { "8=FIX.4.4|9=5|35=0|10=000|" })
    H.expect_notified(nvim(), "allow_paths")
    local source = nvim().lua_get(("require('fix.overrides').dictionary_source(%d)"):format(buf))
    MiniTest.expect.equality(source, vim.NIL)
end

T["editorconfig: fix_dictionary=<path> is accepted when allow_paths is enabled"] = function()
    nvim().lua([[require("fix").setup({ overrides = { modeline = { allow_paths = true } } })]])
    local buf = open_with_editorconfig({ ("fix_dictionary = %s"):format(BINANCE_OE) }, { "8=FIX.4.4|9=5|35=0|10=000|" })
    local version = nvim().lua_get(("require('fix.overrides').dictionary_source(%d).version"):format(buf))
    MiniTest.expect.equality(type(version), "string")
end

T["editorconfig: fix_dictionary=<name> resolves regardless of allow_paths"] = function()
    nvim().lua(([[
        require("fix").setup({
            dictionaries = { { path = %q, mode = "quickfix", name = "binance-oe" } },
        })
    ]]):format(BINANCE_OE))
    local buf = open_with_editorconfig({ "fix_dictionary = binance-oe" }, { "8=FIX.4.4|9=5|35=0|10=000|" })
    local name = nvim().lua_get(("require('fix.overrides').describe(%d).overrides.dictionary.value.name"):format(buf))
    MiniTest.expect.equality(name, "binance-oe")
end

T["editorconfig: a mixed-case value does not resolve; the lowercased value does"] = function()
    H.enable_inline_annotations(nvim())
    -- Nvim lowercases the property value before this module sees it, so a
    -- mixed-case formatter name is unreachable via editorconfig. Two
    -- unrelated names, not case variants, so a lowercased lookup can't
    -- accidentally land on the right one.
    nvim().lua([[
        require("fix").setup({
            formatters = {
                tag = {
                    MixedName = function(_) return { "MIXED", "Comment" } end,
                    plainname = function(_) return { "LOWER", "Comment" } end,
                },
            },
        })
    ]])

    open_with_editorconfig({ "fix_formatter_tag = MixedName" }, { HEARTBEAT })
    H.expect_no_inline_label(nvim(), "MIXED")
    H.expect_no_inline_label(nvim(), "LOWER")
    H.expect_notified(nvim(), "unknown formatter")

    open_with_editorconfig({ "fix_formatter_tag = plainname" }, { HEARTBEAT })
    H.expect_inline_label(nvim(), "LOWER")
end

T["editorconfig: an invalid value surfaces an error without breaking the rest of the buffer's setup"] = function()
    open_with_editorconfig({ "fix_annotate_title_enabled = maybe" }, { HEARTBEAT })
    H.expect_notified(nvim(), "invalid value for option fix_annotate_title_enabled")
    H.expect_virt_lines_count(nvim(), 1) -- default stays on: the rest of setup was unaffected
end

-- :FIX overrides ----------------------------------------------------------

T[":FIX overrides show: reports the winning layer per key and lists warnings"] = function()
    nvim().lua([[vim.g.fix_annotate_title_position = "below"]])
    open_buffer({ "# fix: annotate.tag.enabled=true, not.a.real.key=1", HEARTBEAT })

    nvim().cmd("FIX overrides show")
    H.expect_notified(nvim(), "annotate.tag.enabled = true")
    H.expect_notified(nvim(), "modeline")
    H.expect_notified(nvim(), "annotate.title.position = below")
    H.expect_notified(nvim(), "vim.g")
    H.expect_notified(nvim(), "warning")
    H.expect_notified(nvim(), "unknown key")
end

T[":FIX overrides (bare) behaves like show"] = function()
    open_buffer({ "# fix: annotate.tag.enabled=true", HEARTBEAT })
    nvim().cmd("FIX overrides")
    H.expect_notified(nvim(), "annotate.tag.enabled = true")
end

T[":FIX overrides show: a fix buffer with no overrides reports a friendly message"] = function()
    open_buffer({ HEARTBEAT })
    nvim().cmd("FIX overrides show")
    H.expect_notified(nvim(), "no overrides in effect")
    H.expect_no_error_notifications(nvim())
end

T[":FIX overrides show: a non-fix buffer gets a friendly message, not an error"] = function()
    nvim().cmd("enew")
    nvim().cmd("FIX overrides show")
    H.expect_notified(nvim(), "not a FIX buffer")
    H.expect_no_error_notifications(nvim())
end

T[":FIX overrides refresh: a non-fix buffer gets a friendly message, not an error"] = function()
    nvim().cmd("enew")
    nvim().cmd("FIX overrides refresh")
    H.expect_notified(nvim(), "not a FIX buffer")
    H.expect_no_error_notifications(nvim())
end

T[":FIX overrides refresh: applies a vim.b change made mid-session"] = function()
    local buf = open_buffer({ HEARTBEAT })
    H.expect_virt_lines_count(nvim(), 1)

    nvim().lua(("vim.b[%d].fix_annotate_title_enabled = false"):format(buf))
    nvim().cmd("FIX overrides refresh")
    H.wait_annotated(nvim())
    H.expect_virt_lines_count(nvim(), 0)
end

local DISK_DICT_XML = [[
<fix major='4' type='FIX' servicepack='0' minor='4'>
 <header>
  <field name='BeginString' required='Y'/>
  <field name='BodyLength' required='Y'/>
  <field name='MsgType' required='Y'/>
 </header>
 <trailer>
  <field name='CheckSum' required='Y'/>
 </trailer>
 <messages>
  <message name='Heartbeat' msgcat='admin' msgtype='0'>
   <field name='ExtraTag' required='N'/>
  </message>
 </messages>
 <fields>
  <field number='8' name='BeginString' type='STRING'/>
  <field number='9' name='BodyLength' type='LENGTH'/>
  <field number='10' name='CheckSum' type='STRING'/>
  <field number='35' name='MsgType' type='STRING'/>
  <field number='100' name='%s' type='STRING'/>
 </fields>
</fix>
]]

T[":FIX overrides refresh: a dictionary XML edited on disk is picked up"] = function()
    H.enable_inline_annotations(nvim())
    local xml_path = nvim().lua_get([[vim.fn.tempname() .. ".xml"]])
    nvim().lua(
        string.format(
            [[vim.fn.writefile(vim.split(%q, "\n", { plain = true }), %q)]],
            DISK_DICT_XML:format("DiskV1"),
            xml_path
        )
    )
    nvim().lua(([[
        require("fix").setup({
            dictionaries = { { path = %q, mode = "quickfix", name = "disk-dict" } },
        })
    ]]):format(xml_path))

    open_buffer({ "# fix: dictionary=disk-dict", "8=FIX.4.4|9=5|35=0|100=X|10=000|" })
    H.expect_inline_label(nvim(), "DiskV1")

    -- A longer name changes the file's size, so eviction can't depend on
    -- coarse filesystem mtime resolution to notice the edit.
    nvim().lua(
        string.format(
            [[vim.fn.writefile(vim.split(%q, "\n", { plain = true }), %q)]],
            DISK_DICT_XML:format("DiskVersionTwo"),
            xml_path
        )
    )
    H.expect_inline_label(nvim(), "DiskV1") -- unrefreshed: still the cached instance

    nvim().cmd("FIX overrides refresh")
    H.wait_annotated(nvim())
    H.expect_inline_label(nvim(), "DiskVersionTwo")
    H.expect_no_inline_label(nvim(), "DiskV1")
end

-- The eviction check above changes the file's size, which any fingerprint
-- would catch. This one holds size and the whole second fixed and varies
-- only the sub-second part: a sec-only fingerprint would see the two writes
-- as identical and never evict.
T[":FIX overrides refresh: a same-second, same-size dictionary edit is picked up"] = function()
    H.enable_inline_annotations(nvim())
    local xml_path = nvim().lua_get([[vim.fn.tempname() .. ".xml"]])

    local function write_and_stamp(name, mtime_offset)
        nvim().lua(string.format(
            [[
            vim.fn.writefile(vim.split(%q, "\n", { plain = true }), %q)
            local base_sec = 1700000000
            local ok, err = vim.uv.fs_utime(%q, base_sec + %f, base_sec + %f)
            assert(ok, err)
            ]],
            DISK_DICT_XML:format(name),
            xml_path,
            xml_path,
            mtime_offset,
            mtime_offset
        ))
    end

    -- Same integer second (base_sec + 0), sub-second parts 0.1s apart —
    -- comfortably above any filesystem's mtime resolution in this harness,
    -- while both offsets still round down to the same whole second.
    write_and_stamp("TagNameA", 0.1)
    local before = nvim().lua_get(([[(function()
        local stat = vim.uv.fs_stat(%q)
        return { size = stat.size, sec = stat.mtime.sec }
    end)()]]):format(xml_path))

    nvim().lua(([[
        require("fix").setup({
            dictionaries = { { path = %q, mode = "quickfix", name = "fp-dict" } },
        })
    ]]):format(xml_path))
    open_buffer({ "# fix: dictionary=fp-dict", "8=FIX.4.4|9=5|35=0|100=X|10=000|" })
    H.expect_inline_label(nvim(), "TagNameA")

    write_and_stamp("TagNameB", 0.2)
    local after = nvim().lua_get(([[(function()
        local stat = vim.uv.fs_stat(%q)
        return { size = stat.size, sec = stat.mtime.sec }
    end)()]]):format(xml_path))
    MiniTest.expect.equality(before.size, after.size)
    MiniTest.expect.equality(before.sec, after.sec)

    H.expect_inline_label(nvim(), "TagNameA") -- unrefreshed: still the cached instance

    nvim().cmd("FIX overrides refresh")
    H.wait_annotated(nvim())
    H.expect_inline_label(nvim(), "TagNameB")
    H.expect_no_inline_label(nvim(), "TagNameA")
end

return T

-- Enhancing mpv with features that I want
--  > show filename and playlist position
--  > show playlist
--  > shuffle playlist
--

local settings = {
    filename_replace_list = {},
    filename_replace = [[
        [
          {
            "ext": { "mp4": true, "mkv": true, "webm": true },
            "rules": [
              { "^(.+)%..+$": "%1" },
              { "(%w)%.(%w)": "%1 %2" }
            ]
          }
        ]
    ]],

    sync_cursor_on_load = true,
    --font size scales by window, if false requires larger font and padding sizes
    scale_playlist_by_window = true,
    --playlist ass style overrides inside curly brackets, \keyvalue is one field, extra \ for escape in lua
    --example {\\fnUbuntu\\fs10\\b0\\bord1} equals: font=Ubuntu, size=10, bold=no, border=1
    --read http://docs.aegisub.org/3.2/ASS_Tags/ for reference of tags
    --undeclared tags will use default osd settings
    --these styles will be used for the whole playlist
    style_ass_tags = "{}",
    --paddings from top left corner
    text_padding_x = 10,
    text_padding_y = 30,

    --screen dim when menu is open 0.0 - 1.0 (0 is no dim, 1 is black)
    curtain_opacity = 0,

    -- the maximum amount of lines playlist will render. Optimal value depends on font/video size etc.
    show_amount = 9,

    --slice long filenames, and how many chars to show
    slice_longfilenames = false,
    slice_longfilenames_amount = 70,

    --Playlist header template
    --%mediatitle or %filename = title or name of playing file
    --%pos = position of playing file
    --%cursor = position of navigation
    --%plen = playlist length
    --%N = newline
    playlist_header = "[%pos/%plen]",
    normal_file = "○ %name",
    playing_file = "▷ %name",

    -- what to show when playlist is truncated
    playlist_sliced_prefix = "...",
    playlist_sliced_suffix = "...",

    --output visual feedback to OSD for tasks
    display_osd_feedback = true,
    display_filename_on_start = true,
}

local mp = require("mp")
local utils = require("mp.utils")
local msg = require("mp.msg")
local assdraw = require("mp.assdraw")

--check os
if settings.system == "auto" then
    local o = {}
    if mp.get_property_native('options/vo-mmcss-profile', o) ~= o then
        settings.system = "windows"
    else
        settings.system = "linux"
    end
end

--global variables
local C = {}
local playlist_visible = false
local stripped_name = nil
local path = nil
local pos = 0
local plen = 0
local cursor = 0
--table for saved media titles for later if we prefer them
local title_table = {}
local filetype_lookup = {}

function C.update_opts(changelog)
    msg.verbose('updating options')

    --parse filename json
    if changelog.filename_replace then
        if (settings.filename_replace ~= "") then
            settings.filename_replace_list = utils.parse_json(settings.filename_replace)
        else
            settings.filename_replace = false
        end
    end

    if playlist_visible then
        C.show_playlist();
    end
end

C.update_opts({ filename_replace = true })


local function is_protocol(path)
    return type(path) == 'string' and path:match('^%a[%a%d-_]+://') ~= nil
end

local function on_file_loaded()
    C.refresh_globals()

    path = mp.get_property('path')
    local media_title = mp.get_property("media-title")

    if is_protocol(path) and not title_table[path] and path ~= media_title then
        title_table[path] = media_title
    end

    if settings.sync_cursor_on_load then
        cursor = pos
        --refresh playlist if cursor moved
        if playlist_visible then
            C.draw_playlist();
        end
    end

    if settings.show_filename_on_file_load then
        stripped_name = C.strip_filename(mp.get_property('media-title'))
        mp.commandv('show-text', stripped_name)
    end
end

local function on_start_file()
    C.refresh_globals()

    if settings.display_filename_on_start then
        local index = pos;
        local stripped_name = C.parse_filename("[%pos/%plen] %name", C.get_name_from_index(index), index)

        if stripped_name then
            mp.commandv('show-text', stripped_name); return
        end
    end
end

function C.refresh_globals()
    pos = mp.get_property_number('playlist-pos', 0)
    plen = mp.get_property_number('playlist-count', 0)
end

--#region Filename Utils
local function replace_table_has_value(value, valid_values)
    if value == nil or valid_values == nil then
        return false
    end

    return valid_values['all'] or valid_values[value]
end

local filename_replace_functions = {
    --decode special characters in url
    hex_to_char = function(x) return string.char(tonumber(x, 16)) end
}
--#endregion Filename Utils

--#region Filename and String creations
local function strip_filename(path_file, media_title)
    if path_file == nil then
        return ''
    end

    local ext = path_file:match("%.([^%.]+)$")
    local protocol = path_file:match("^(%a%a+)://")

    if not ext then ext = "" end

    local tmp = path_file
    if settings.filename_replace and not media_title then
        for k, v in ipairs(settings.filename_replace_list) do
            if replace_table_has_value(ext, v['ext']) or replace_table_has_value(protocol, v['protocol']) then
                for ruleindex, indexrules in ipairs(v['rules']) do
                    for rule, override in pairs(indexrules) do
                        override = filename_replace_functions[override] or override
                        tmp = tmp:gsub(rule, override)
                    end
                end
            end
        end
    end

    if settings.slice_longfilenames and tmp:len() > settings.slice_longfilenames_amount + 5 then
        tmp = tmp:sub(1, settings.slice_longfilenames_amount) .. " ..."
    end

    return tmp
end

local function parse_header(string)
    local esc_title = strip_filename(mp.get_property("media-title"), true):gsub("%%", "%%%%")
    local esc_file = strip_filename(mp.get_property("filename")):gsub("%%", "%%%%")
    return string:gsub("%%N", "\\N")
        :gsub("%%pos", mp.get_property_number("playlist-pos", 0) + 1)
        :gsub("%%plen", mp.get_property("playlist-count"))
        :gsub("%%cursor", cursor + 1)
        :gsub("%%mediatitle", esc_title)
        :gsub("%%filename", esc_file)
        -- undo name escape
        :gsub("%%%%", "%%")
end

function C.parse_filename(string, name, index)
    local base = tostring(plen):len()
    local esc_name = strip_filename(name):gsub("%%", "%%%%")
    return string:gsub("%%N", "\\N")
        :gsub("%%pos", string.format("%0" .. base .. "d", index + 1))
        :gsub("%%plen", mp.get_property("playlist-count"))
        :gsub("%%name", esc_name)
        -- undo name escape
        :gsub("%%%%", "%%")
end

--gets a nicename of playlist entry at 0-based position i
function C.get_name_from_index(i, notitle)
    C.refresh_globals()

    if plen <= i then
        msg.error("no index in playlist", i, "length", plen); return nil
    end

    local title = mp.get_property('playlist/' .. i .. '/title')
    local name = mp.get_property('playlist/' .. i .. '/filename')

    local should_use_title = settings.prefer_titles == 'all' or is_protocol(name) and settings.prefer_titles == 'url'
    --check if file has a media title stored or as property
    if not title and should_use_title then
        local mtitle = mp.get_property('media-title')
        if i == pos and mp.get_property('filename') ~= mtitle then
            if not title_table[name] then
                title_table[name] = mtitle
            end
            title = mtitle
        elseif title_table[name] then
            title = title_table[name]
        end
    end

    --if we have media title use a more conservative strip
    if title and not notitle and should_use_title then
        -- Escape a string for verbatim display on the OSD
        -- Ref: https://github.com/mpv-player/mpv/blob/94677723624fb84756e65c8f1377956667244bc9/player/lua/stats.lua#L145
        return strip_filename(title, true):gsub("\\", '\\\239\187\191'):gsub("{", "\\{"):gsub("^ ", "\\h")
    end

    --remove paths if they exist, keeping protocols for stripping
    if string.sub(name, 1, 1) == '/' or name:match("^%a:[/\\]") then
        _, name = utils.split_path(name)
    end

    return strip_filename(name):gsub("\\", '\\\239\187\191'):gsub("{", "\\{"):gsub("^ ", "\\h")
end

local function parse_filename_by_index(index)
    local template = settings.normal_file

    local is_idle = mp.get_property_native('idle-active')
    local position = is_idle and -1 or pos

    if index == position then
        template = settings.playing_file
    end

    return C.parse_filename(template, C.get_name_from_index(index), index)
end
--#endregion Filename and String creations

--#region Playlist functions
local function shuffle_playlist()
    C.refresh_globals()

    if plen < 2 then
        return
    end

    mp.command("playlist-shuffle")
    math.randomseed(os.time())
    mp.commandv("playlist-move", pos, math.random(0, plen - 1))

    local playlist = mp.get_property_native('playlist')
    for i = 1, #playlist do
        local filename = mp.get_property('playlist/' .. i - 1 .. '/filename')
        local ext = filename:match("%.([^%.]+)$")
        if not ext or not filetype_lookup[ext:lower()] then
            --move the directory to the end of the playlist
            mp.commandv('playlist-move', i - 1, #playlist)
        end
    end

    mp.set_property('playlist-pos', 0)
    C.refresh_globals()

    if playlist_visible then
        C.show_playlist()
    elseif settings.display_osd_feedback then
        mp.osd_message("Playlist shuffled")
    end
end

local function remove_playlist()
    mp.set_osd_ass(0, 0, "")
    playlist_visible = false
end

function C.draw_playlist()
    C.refresh_globals()

    local ass = assdraw.ass_new()
    local _, _, a = mp.get_osd_size()
    local h = 360
    local w = h * a

    if settings.curtain_opacity ~= nil and settings.curtain_opacity ~= 0 and settings.curtain_opacity < 1.0 then
        -- curtain dim from https://github.com/christoph-heinrich/mpv-quality-menu/blob/501794bfbef468ee6a61e54fc8821fe5cd72c4ed/quality-menu.lua#L699-L707
        local alpha = 255 - math.ceil(255 * settings.curtain_opacity)
        ass.text = string.format('{\\pos(0,0)\\rDefault\\an7\\1c&H000000&\\alpha&H%X&}', alpha)
        ass:draw_start()
        ass:rect_cw(0, 0, w, h)
        ass:draw_stop()
        ass:new_event()
    end

    ass:append(settings.style_ass_tags)

    -- TODO: padding should work even on different osd alignments
    if mp.get_property("osd-align-x") == "left" and mp.get_property("osd-align-y") == "top" then
        ass:pos(settings.text_padding_x, settings.text_padding_y)
    end

    if settings.playlist_header ~= "" then
        ass:append(parse_header(settings.playlist_header) .. "\\N")
    end

    -- (visible index, playlist index) pairs of playlist entries that should be rendered
    local visible_indices = {}

    local one_based_cursor = cursor + 1
    table.insert(visible_indices, one_based_cursor)

    local offset = 1;
    local visible_indices_length = 1;
    while visible_indices_length < settings.show_amount and visible_indices_length < plen do
        -- add entry for offset steps below the cursor
        local below = one_based_cursor + offset
        if below <= plen then
            table.insert(visible_indices, below)
            visible_indices_length = visible_indices_length + 1;
        end

        -- add entry for offset steps above the cursor
        -- also need to double check that there is still space, this happens if we have even numbered limit
        local above = one_based_cursor - offset
        if above >= 1 and visible_indices_length < settings.show_amount and visible_indices_length < plen then
            table.insert(visible_indices, 1, above)
            visible_indices_length = visible_indices_length + 1;
        end

        offset = offset + 1
    end

    -- both indices are 1 based
    for display_index, playlist_index in pairs(visible_indices) do
        if display_index == 1 and playlist_index ~= 1 then
            ass:append(settings.playlist_sliced_prefix .. "\\N")
        elseif display_index == settings.show_amount and playlist_index ~= plen then
            ass:append(settings.playlist_sliced_suffix)
        else
            -- parse_filename_by_index expects 0 based index
            ass:append(parse_filename_by_index(playlist_index - 1) .. "\\N")
        end
    end

    if settings.scale_playlist_by_window then
        w, h = 0, 0
    end

    mp.set_osd_ass(w, h, ass.text)
end

function C.show_playlist()
    C.refresh_globals()

    if plen == 0 then
        return
    end

    playlist_visible = true
    C.draw_playlist()
end

local function toggle_playlist()
    if playlist_visible then
        remove_playlist()
    else
        C.show_playlist()
    end
end
--#endregion Playlist functions

-- Core handler that will handle incoming messages
-- and lay them off to the correct functions
local function handle_messages(msg, value, value2)
    if msg == "show" and value == "playlist" then
        toggle_playlist(); return
    end

    if msg == "show" and value == "filename" then
        C.refresh_globals();
        local index = pos;
        local stripped_name = C.parse_filename("[%pos/%plen] %name", C.get_name_from_index(index), index)

        if stripped_name and value2 then
            mp.commandv('show-text', stripped_name, tonumber(value2) * 1000); return
        end
        if msg == "show" and value == "filename" and stripped_name then
            mp.commandv('show-text', stripped_name); return
        end
    end

    if msg == "shuffle" then
        shuffle_playlist(); return
    end
end

-- Setup the script for listening to outside inputs
mp.register_script_message("bkz-mpvenhancer", handle_messages)
mp.register_event("start-file", on_start_file)
mp.register_event("file-loaded", on_file_loaded)

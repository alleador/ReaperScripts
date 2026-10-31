--[[
-- @description alleadorPlaybackControl
-- @author alleador
-- @version 1.0
-- @about
-- This script does awesome things in REAPER.
]]--

local SCALE = tonumber(reaper.GetExtState("LiveControl", "scale")) or 1.0
SCALE = math.max(0.5, math.min(3.0, SCALE))
local function S(v) return math.floor(v * SCALE) end

gfx.init("alleadorPlaybackControl", S(900), S(1200), 0, 100, 100)

gfx.setfont(1, "Arial", S(40), 1)
gfx.setfont(2, "Arial", S(22), 1)
gfx.setfont(3, "Arial", S(18), 1)
gfx.setfont(4, "Arial", S(30), 1)
gfx.setfont(5, "Arial", S(44), 1)
gfx.setfont(6, "Arial", S(22), 1)
gfx.setfont(7, "Arial", S(28), 1)
gfx.setfont(8, "Arial", S(16), 1)
gfx.setfont(9, "Arial", S(20), 1)
gfx.setfont(10, "Arial", S(26), 1)
gfx.setfont(11, "Arial", S(20), 1)
gfx.setfont(12, "Arial", S(36), 1)
gfx.setfont(13, "Arial", S(30), 1)
gfx.setfont(14, "Arial", S(24), 1)
gfx.setfont(15, "Arial", S(20), 1)

local IS_WINDOWS = package.config:sub(1,1) == '\\'
local PATH_SEP = IS_WINDOWS and "\\" or "/"

local pending = {}
local was_down = false
local was_right_down = false
local scroll_pos = 1
local selected_idx = 0
local songs = {}
local songs_version = -1
local drag_idx = nil
local space_was_pressed = false
local last_transition_idx = 0
local last_current_idx = 0
local locked = false
local current_setlist_name = nil
local search_text = ""
local search_enabled = false

-- WEB SERVER STATE
local WEB_PORTS = {8080, 6060, 7070, 9090}
local current_web_port_idx = 1

local web_enabled = false
local web_pid = nil
local web_last_update = 0
local web_ip = "127.0.0.1"
local web_error = nil

local last_played_idx = 0

local files_cache = nil
local files_cache_time = 0
local FILES_CACHE_TTL = 2.0

local last_update_songs_time = 0
local UPDATE_SONGS_INTERVAL = 0.5

local last_check_auto_time = 0
local CHECK_AUTO_INTERVAL = 0.1

local reorganize_list

local function find_next_used_song(from_idx)
    for i = from_idx + 1, #songs do
        if songs[i].use then return i end
    end
    return nil
end

local function enforce_lock_protection()
    if not locked then return end
    if reaper.JS_Window_Find and reaper.JS_Window_SetFocus then
        local hwnd = reaper.JS_Window_Find("alleadorPlaybackControl with Search", true)
        if hwnd then reaper.JS_Window_SetFocus(hwnd) end
    end
    local playing = (reaper.GetPlayState() & 1) ~= 0
    if not playing and selected_idx >= 1 and songs[selected_idx] then
        local safe_pos = songs[selected_idx].start
        local current_pos = reaper.GetCursorPosition()
        if math.abs(current_pos - safe_pos) > 0.05 then
            reaper.SetEditCurPos(safe_pos, false, false) 
        end
    end
end

-- UTF-8 утилиты
local function utf8_chars_with_offsets(s)
    local result = {}
    local i = 1
    local n = #s
    while i <= n do
        local b = s:byte(i)
        if not b then break end
        local len
        if b < 128 then len = 1
        elseif b < 224 then len = 2
        elseif b < 240 then len = 3
        else len = 4 end
        if i + len - 1 > n then break end
        result[#result + 1] = { char = s:sub(i, i + len - 1), offset = i, len = len }
        i = i + len
    end
    return result
end

local RU_TO_EN = {
    ['а']='f', ['б']=',', ['в']='d', ['г']='u', ['д']='l', ['е']='t', ['ё']='t',
    ['ж']=';', ['з']='p', ['и']='b', ['й']='q', ['к']='r', ['л']='k', ['м']='v',
    ['н']='y', ['о']='j', ['п']='g', ['р']='h', ['с']='c', ['т']='n', ['у']='e',
    ['ф']='a', ['х']='[', ['ц']='w', ['ч']='x', ['ш']='i', ['щ']='o', ['ъ']=']',
    ['ы']='s', ['ь']='m', ['э']="'", ['ю']='.', ['я']='z',
    ['А']='F', ['Б']=',', ['В']='D', ['Г']='U', ['Д']='L', ['Е']='T', ['Ё']='T',
    ['Ж']=';', ['З']='P', ['И']='B', ['Й']='Q', ['К']='R', ['Л']='K', ['М']='V',
    ['Н']='Y', ['О']='J', ['П']='G', ['Р']='H', ['С']='C', ['Т']='N', ['У']='E',
    ['Ф']='A', ['Х']='[', ['Ц']='W', ['Ч']='X', ['Ш']='I', ['Щ']='O', ['Ъ']=']',
    ['Ы']='S', ['Ь']='M', ['Э']="'", ['Ю']='.', ['Я']='Z',
}

local function find_match(name, query)
    if query == "" then return nil, nil end
    local lower_query = query:lower()
    local query_len = #lower_query
    local chars = utf8_chars_with_offsets(name)
    if #chars == 0 then return nil, nil end
    local en_chars = {}
    for _, info in ipairs(chars) do
        local mapped = RU_TO_EN[info.char]
        if mapped then en_chars[#en_chars + 1] = mapped:lower()
        else en_chars[#en_chars + 1] = info.char:lower() end
    end
    local lower_name_chars = {}
    for _, info in ipairs(chars) do lower_name_chars[#lower_name_chars + 1] = info.char:lower() end
    local lower_name = table.concat(lower_name_chars)
    local start_idx = lower_name:find(lower_query, 1, true)
    if start_idx then
        return chars[start_idx].offset, chars[start_idx + query_len - 1].offset + chars[start_idx + query_len - 1].len - 1
    end
    local en_name = table.concat(en_chars)
    start_idx = en_name:find(lower_query, 1, true)
    if start_idx then
        return chars[start_idx].offset, chars[start_idx + query_len - 1].offset + chars[start_idx + query_len - 1].len - 1
    end
    return nil, nil
end

local function fmt(sec)
    if sec < 0 then sec = 0 end
    return string.format("%d:%02d", math.floor(sec / 60), math.floor(sec % 60))
end

local function in_box(px, py, x, y, w, h)
    return px >= x and px <= x + w and py >= y and py <= y + h
end

local function script_dir()
    local f = select(2, reaper.get_action_context())
    return (f:match("^(.*)[\\/]")) or reaper.GetResourcePath()
end

local DIR = script_dir()
local SET_DIR = DIR .. PATH_SEP .. "SetLists"
if IS_WINDOWS then os.execute('if not exist "' .. SET_DIR .. '" mkdir "' .. SET_DIR .. '"')
else os.execute('mkdir -p "' .. SET_DIR .. '" 2>/dev/null') end

local function execute_pending()
    if #pending == 0 then return end
    local batch, idx = pending, selected_idx
    pending = {}
    for _, cmd in ipairs(batch) do
        if cmd == "stop" then reaper.Main_OnCommand(1016, 0)
        elseif cmd == "play" then reaper.Main_OnCommand(1007, 0)
        elseif type(cmd) == "table" then
            if cmd[1] == "goto" then reaper.SetEditCurPos(cmd[2], true, false)
            elseif cmd[1] == "goto_play" then
                reaper.SetEditCurPos(cmd[2], true, false)
                reaper.Main_OnCommand(1007, 0)
            elseif cmd[1] == "select" then idx = cmd[2] end
        end
    end
    selected_idx = idx
end

local function schedule(cmd)
    pending[#pending + 1] = cmd
    reaper.defer(execute_pending)
end

-- SETLIST FILES
local function enumerate_dir_fast(path)
    local out = {}
    if reaper.EnumerateFiles then
        local idx = 0
        while true do
            local name = reaper.EnumerateFiles(path, idx)
            if not name or name == "" then break end
            out[#out + 1] = name
            idx = idx + 1
        end
        return out
    end
    return nil
end

local function list_files(force_refresh)
    local now = reaper.time_precise()
    if not force_refresh and files_cache and (now - files_cache_time) < FILES_CACHE_TTL then return files_cache end
    local out = {}
    local fast_list = enumerate_dir_fast(SET_DIR)
    if fast_list then
        for _, name in ipairs(fast_list) do
            local n = name:match("^(.+)%.setlist$")
            if n then out[#out + 1] = n end
        end
    else
        local cmd = IS_WINDOWS and ('dir /b "' .. SET_DIR .. '" 2>nul') or ('ls -1 "' .. SET_DIR .. '" 2>/dev/null')
        local h = io.popen(cmd)
        if h then
            for l in h:lines() do
                local n = l:match("^(.+)%.setlist$")
                if n then out[#out + 1] = n end
            end
            h:close()
        end
    end
    table.sort(out)
    files_cache = out
    files_cache_time = now
    return out
end

local function invalidate_files_cache() files_cache = nil; files_cache_time = 0 end

-- ============================================================
-- ИСПРАВЛЕНО: save_list теперь сохраняет порядок выделенных
-- ============================================================
local function save_list(name)
    local f = io.open(SET_DIR .. PATH_SEP .. name .. ".setlist", "w")
    if not f then return end
    
    -- НОВОЕ: записываем порядок выделенных регионов в заголовок
    local order = {}
    for _, s in ipairs(songs) do
        if s.use then order[#order + 1] = s.name end
    end
    if #order > 0 then
        -- Используем табуляцию как разделитель (имена песен не содержат табуляцию)
        f:write("#ORDER:" .. table.concat(order, "\t") .. "\n")
    end
    
    -- Записываем данные о каждой песне
    for _, s in ipairs(songs) do
        f:write(string.format("%s|%d|%d\n", s.name, s.use and 1 or 0, s.combine and 1 or 0))
    end
    f:close()
    invalidate_files_cache()
end

-- ============================================================
-- ИСПРАВЛЕНО: load_list теперь восстанавливает порядок
-- ============================================================
local function load_list(name)
    local f = io.open(SET_DIR .. PATH_SEP .. name .. ".setlist", "r")
    if not f then return end
    
    local order = nil
    local data = {}
    local data_lines = {}
    
    -- Читаем файл построчно
    for line in f:lines() do
        if line:sub(1, 7) == "#ORDER:" then
            -- НОВОЕ: читаем порядок выделенных регионов
            order = {}
            local rest = line:sub(8)
            for n in rest:gmatch("[^\t]+") do
                order[#order + 1] = n
            end
        else
            data_lines[#data_lines + 1] = line
        end
    end
    f:close()
    
    -- Парсим данные
    for _, line in ipairs(data_lines) do
        local n, u, c = line:match("^(.+)|(%d)|(%d)$")
        if n then data[n] = {use = (u == "1"), combine = (c == "1")} end
    end
    
    -- Применяем use/combine ко всем песням
    for _, s in ipairs(songs) do
        if data[s.name] then
            s.use, s.combine = data[s.name].use, data[s.name].combine
        else
            -- Песни, которых нет в файле, считаем невыделенными
            s.use, s.combine = false, false
        end
    end
    
    -- НОВОЕ: восстанавливаем порядок выделенных регионов
    if order and #order > 0 then
        -- Собираем выделенные песни в порядке из файла
        local ordered_used = {}
        local name_to_song = {}
        for _, s in ipairs(songs) do
            name_to_song[s.name] = s
        end
        for _, n in ipairs(order) do
            if name_to_song[n] and name_to_song[n].use then
                ordered_used[#ordered_used + 1] = name_to_song[n]
            end
        end
        
        -- Собираем невыделенные песни
        local unused = {}
        for _, s in ipairs(songs) do
            if not s.use then unused[#unused + 1] = s end
        end
        
        -- Сортируем невыделенные по алфавиту
        table.sort(unused, function(a, b) return a.name:lower() < b.name:lower() end)
        
        -- Собираем новый массив: сначала выделенные в сохранённом порядке, потом невыделенные
        songs = {}
        for _, s in ipairs(ordered_used) do songs[#songs + 1] = s end
        for _, s in ipairs(unused) do songs[#songs + 1] = s end
        for i, s in ipairs(songs) do s.num = i end
    else
        -- Старый формат файла (без #ORDER:) — используем стандартную сортировку
        reorganize_list()
    end
    
    if selected_idx > #songs then selected_idx = #songs end
    if selected_idx < 0 then selected_idx = 0 end
end

local function delete_list(name)
    os.remove(SET_DIR .. PATH_SEP .. name .. ".setlist")
    invalidate_files_cache()
end

local function clear_all()
    for _, s in ipairs(songs) do s.use = false; s.combine = false end
    reorganize_list()
end

-- WEB SERVER
local WEB_DIR = DIR .. PATH_SEP .. "webset"

local function web_write_file(name, content)
    local f = io.open(WEB_DIR .. PATH_SEP .. name, "w")
    if f then f:write(content); f:close() end
end

local function get_current_web_port() return WEB_PORTS[current_web_port_idx] end

local function web_json_state()
    local playing = (reaper.GetPlayState() & 1) ~= 0
    local display_selected = 0
    if selected_idx >= 1 and selected_idx <= #songs and songs[selected_idx].use then
        display_selected = selected_idx
    end
    local arr = {}
    local n = 0
    for i, s in ipairs(songs) do
        if s.use then
            n = n + 1
            local nm = s.name:gsub('\\', '\\\\'):gsub('"', '\\"')
            local is_selected = (i == display_selected) and "true" or "false"
            local has_combine = s.combine and "true" or "false"
            arr[#arr + 1] = string.format('{"num":%d,"name":"%s","is_selected":%s,"combine":%s}', 
                n, nm, is_selected, has_combine)
        end
    end
    local setlist = (current_setlist_name or "SET LIST"):gsub('\\', '\\\\'):gsub('"', '\\"')
    local playing_str = playing and "true" or "false"
    return string.format('{"setlist":"%s","playing":%s,"songs":[%s]}', 
        setlist, playing_str, table.concat(arr, ","))
end

local WEB_HTML = [[<!DOCTYPE html>
<html lang="ru"><head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Set List</title>
<style>
*{margin:0;padding:0;box-sizing:border-box}
body{background:#0a0a12;color:#fff;font-family:-apple-system,Arial,sans-serif;padding:20px;min-height:100vh}
h1{color:#f0d050;font-size:28px;text-align:center;margin-bottom:10px;padding-bottom:15px;border-bottom:1px solid #333}
.status{text-align:center;font-size:14px;color:#888;margin-bottom:30px;letter-spacing:2px}
.status b{color:#5fff8f}
.status b.off{color:#888}
.song{display:flex;align-items:center;padding:16px 20px;margin-bottom:8px;background:#15151e;border-radius:10px;font-size:20px;transition:all .3s}
.song.selected{background:#1a3520;border:2px solid #4fff7f;box-shadow:0 0 15px rgba(79,255,127,.2)}
.song .n{color:#666;font-weight:bold;min-width:40px;font-size:18px}
.song.selected .n{color:#4fff7f}
.song .t{flex:1;margin-left:15px;color:#eee}
.song.selected .t{color:#fff;font-weight:600}
.combine{margin-left:10px;font-size:24px;color:#666}
.combine.on{color:#ffa040}
.empty{text-align:center;color:#555;padding:60px 20px;font-size:18px}
.foot{text-align:center;color:#333;font-size:11px;margin-top:40px}
#dot{position:fixed;top:12px;right:12px;width:10px;height:10px;border-radius:50%;background:#222;transition:background .3s}
#dot.ok{background:#4fff7f}
#dot.err{background:#ff4040}
</style></head><body>
<div id="dot"></div>
<h1 id="title">—</h1>
<div class="status" id="status">STOPPED</div>
<div id="list"></div>
<div class="foot">alleadorPlaybackControl • auto-refresh</div>
<script>
function esc(s){return String(s).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]))}
async function load(){
 const d=document.getElementById('dot');
 try{
  const r=await fetch('setlist.json?t='+Date.now());
  const s=await r.json();
  document.getElementById('title').textContent=s.setlist;
  const st=document.getElementById('status');
  if(s.playing){st.innerHTML='STATUS: <b>PLAYING</b>'}
  else{st.innerHTML='STATUS: <b class="off">STOPPED</b>'}
  let h='';
  if(!s.songs.length){h='<div class="empty">No songs in set</div>'}
  else{s.songs.forEach(v=>{
   let cls = v.is_selected ? 'song selected' : 'song';
   const combineIcon=v.combine?'<span class="combine on">↓</span>':'<span class="combine">•</span>';
   h+='<div class="'+cls+'"><div class="n">'+String(v.num).padStart(2,'0')+'</div><div class="t">'+esc(v.name)+'</div>'+combineIcon+'</div>';
  })}
  document.getElementById('list').innerHTML=h;
  d.className='ok';setTimeout(()=>d.className='',300);
 }catch(e){d.className='err'}
}
load();setInterval(load,1500);
document.addEventListener('visibilitychange',()=>{if(!document.hidden)load()});
</script></body></html>]]

local function get_local_ip()
    local ip = "127.0.0.1"
    if IS_WINDOWS then
        local h = io.popen("ipconfig | findstr IPv4")
        if h then
            local line = h:read("*l")
            if line then ip = line:match("IPv4.-: [%s]*(%d+%.%d+%.%d+%.%d+)") or ip end
            h:close()
        end
    else
        local h = io.popen("ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}'")
        if h then
            local res = h:read("*l")
            if res and #res > 7 then ip = res end
            h:close()
        end
    end
    return ip
end

local function start_web_server()
    local py_cmd = IS_WINDOWS and "python" or "python3"
    local current_port = get_current_web_port()
    local h = io.popen(py_cmd .. " --version 2>&1")
    if not h then web_error = py_cmd .. " not found"; return false end
    local ver = h:read("*l") or ""
    h:close()
    if not ver:lower():find("python") then web_error = py_cmd .. " not found"; return false end
    os.execute(IS_WINDOWS and ('mkdir "' .. WEB_DIR .. '" 2>nul') or ('mkdir -p "' .. WEB_DIR .. '"'))
    web_write_file("index.html", WEB_HTML)
    web_write_file("setlist.json", web_json_state())
    web_ip = get_local_ip()
    local cmd
    if IS_WINDOWS then
        cmd = string.format('start /B %s -m http.server %d --bind 0.0.0.0 --directory "%s" >nul 2>&1', py_cmd, current_port, WEB_DIR)
    else
        cmd = string.format('nohup %s -m http.server %d --bind 0.0.0.0 --directory "%s" >/dev/null 2>&1 & echo $!', py_cmd, current_port, WEB_DIR)
    end
    local p = io.popen(cmd)
    if p then
        if not IS_WINDOWS then web_pid = tonumber(p:read("*l") or "0") end
        p:close()
    end
    if not IS_WINDOWS and (not web_pid or web_pid == 0) then
        web_error = "Failed to start (port " .. current_port .. " busy?)"; return false
    end
    os.execute(IS_WINDOWS and "timeout /t 1 /nobreak >nul" or "sleep 0.3")
    web_error = nil
    return true
end

local function stop_web_server()
    if IS_WINDOWS then
        os.execute('taskkill /F /FI "WINDOWTITLE eq *http.server*" >nul 2>&1')
    else
        if web_pid and web_pid > 0 then os.execute("kill " .. web_pid .. " 2>/dev/null"); web_pid = nil end
    end
end

local function web_server_tick()
    if not web_enabled then return end
    local now = reaper.time_precise()
    if now - web_last_update < 0.3 then return end
    web_last_update = now
    web_write_file("setlist.json", web_json_state())
end

reorganize_list = function()
    local on, off = {}, {}
    for _, s in ipairs(songs) do if s.use then on[#on + 1] = s else off[#off + 1] = s end end
    table.sort(off, function(a, b) return a.name:lower() < b.name:lower() end)
    songs = {}
    for _, s in ipairs(on) do songs[#songs + 1] = s end
    for _, s in ipairs(off) do songs[#songs + 1] = s end
    for i, s in ipairs(songs) do s.num = i end
    if selected_idx > #songs then selected_idx = #songs end
    if selected_idx < 0 then selected_idx = 0 end
end

local function update_songs()
    local ok, total = pcall(reaper.CountProjectMarkers, 0)
    if not ok or not total then return end
    local rc = ({reaper.CountProjectMarkers(0)})[3]
    if rc == songs_version and rc > 0 then
        for i = 0, total - 1 do
            local rv, isr, st, en, nm = reaper.EnumProjectMarkers(i)
            if rv and isr and nm and nm ~= "" then
                for _, s in ipairs(songs) do
                    if s.name == nm and math.abs(s.start - st) < 0.5 and math.abs(s.finish - en) > 0.01 then
                        s.finish, s.duration = en, en - st
                    end
                end
            end
        end
        return
    end
    local use_order, use_order_idx = {}, 0
    for _, s in ipairs(songs) do if s.use then use_order_idx = use_order_idx + 1; use_order[s.name] = use_order_idx end end
    local old = {}
    for _, s in ipairs(songs) do old[s.name] = { use = s.use, combine = s.combine, tempo = s.tempo } end
    local new = {}
    for i = 0, total - 1 do
        local rv, isr, st, en, nm = reaper.EnumProjectMarkers(i)
        if rv and isr and nm and nm ~= "" then
            local o = old[nm]
            new[#new + 1] = {
                name = nm, start = st, finish = en, duration = en - st,
                tempo = (o and o.tempo) or reaper.TimeMap2_GetDividedBpmAtTime(0, st),
                use = o and o.use or false, combine = o and o.combine or false
            }
        end
    end
    table.sort(new, function(a, b)
        local oa, ob = use_order[a.name], use_order[b.name]
        if oa and ob then return oa < ob end
        if oa and not ob then return true end
        if not oa and ob then return false end
        return a.start < b.start
    end)
    songs = new
    reorganize_list()
    songs_version = rc
end

local function update_songs_throttled()
    local now = reaper.time_precise()
    if now - last_update_songs_time < UPDATE_SONGS_INTERVAL then return end
    last_update_songs_time = now
    update_songs()
end

local function move_song(from, to)
    if from < 1 or from > #songs or to < 1 or to > #songs + 1 or from == to then return end
    pending = {}
    local item = table.remove(songs, from)
    local insert_at = (from < to) and (to - 1) or to
    if insert_at > #songs + 1 then insert_at = #songs + 1 end
    if insert_at < 1 then insert_at = 1 end
    table.insert(songs, insert_at, item)
    for i, s in ipairs(songs) do s.num = i end
    if selected_idx == from then selected_idx = insert_at
    elseif from < selected_idx and insert_at >= selected_idx then selected_idx = selected_idx - 1
    elseif from > selected_idx and insert_at <= selected_idx then selected_idx = selected_idx + 1 end
    current_setlist_name = nil
end

local function start_drag(i, y) drag_idx = i end
local function end_drag(target)
    if drag_idx and target and target ~= drag_idx then move_song(drag_idx, target) end
    drag_idx = nil
end

local function get_use_bounds()
    local first_use, last_use = nil, nil
    for i = 1, #songs do
        if songs[i].use then
            if not first_use then first_use = i end
            last_use = i
        end
    end
    return first_use, last_use
end

local function goto_selected()
    if selected_idx >= 1 and songs[selected_idx] then schedule({"goto", songs[selected_idx].start}) end
end

local function keep_visible(LIST_H, ROW_H)
    local vis = math.floor(LIST_H / ROW_H)
    if selected_idx < scroll_pos then scroll_pos = selected_idx end
    if selected_idx > scroll_pos + vis - 1 then scroll_pos = selected_idx - vis + 1 end
    if scroll_pos < 1 then scroll_pos = 1 end
end

local function select_prev(LIST_H, ROW_H)
    if #songs == 0 then return end
    local first_use, last_use = get_use_bounds()
    if locked then
        if not first_use then return end
        if selected_idx < first_use or selected_idx > last_use or not songs[selected_idx].use then selected_idx = last_use
        else
            local new_idx = selected_idx - 1
            while new_idx >= first_use and not songs[new_idx].use do new_idx = new_idx - 1 end
            if new_idx >= first_use and songs[new_idx].use then selected_idx = new_idx end
        end
    else
        if selected_idx <= 1 then selected_idx = #songs else selected_idx = selected_idx - 1 end
    end
    goto_selected(); keep_visible(LIST_H, ROW_H)
end

local function select_next(LIST_H, ROW_H)
    if #songs == 0 then return end
    local first_use, last_use = get_use_bounds()
    if locked then
        if not first_use then return end
        if selected_idx < first_use or selected_idx > last_use or not songs[selected_idx].use then selected_idx = first_use
        else
            local new_idx = selected_idx + 1
            while new_idx <= last_use and not songs[new_idx].use do new_idx = new_idx + 1 end
            if new_idx <= last_use and songs[new_idx].use then selected_idx = new_idx end
        end
    else
        if selected_idx <= 0 or selected_idx >= #songs then selected_idx = 1 else selected_idx = selected_idx + 1 end
    end
    goto_selected(); keep_visible(LIST_H, ROW_H)
end

local function toggle_play()
    local playing = (reaper.GetPlayState() & 1) ~= 0
    if playing then schedule("stop")
    else
        drag_idx = nil
        if locked then
            if selected_idx >= 1 and songs[selected_idx] and songs[selected_idx].use then schedule({"goto_play", songs[selected_idx].start}) end
        else
            if selected_idx >= 1 and songs[selected_idx] then schedule({"goto_play", songs[selected_idx].start}) end
        end
    end
end

local function check_auto(cur)
    local playing = (reaper.GetPlayState() & 1) ~= 0
    if not playing then
        if last_played_idx > 0 and last_played_idx <= #songs and songs[last_played_idx] then
            local s = songs[last_played_idx]
            local p = reaper.GetCursorPosition()
            local ni = find_next_used_song(last_played_idx)
            if ni and songs[ni] then
                local next_s = songs[ni]
                if p >= s.finish - 0.08 and p < next_s.start - 0.01 then
                    schedule({"select", ni})
                    schedule({"goto", songs[ni].start})
                end
            end
        end
        last_played_idx = 0
        last_transition_idx = 0
        last_current_idx = 0
        return
    end
    if last_current_idx > 0 and cur > 0 and cur ~= last_current_idx then
        if last_transition_idx ~= last_current_idx then
            local ni = find_next_used_song(last_current_idx)
            schedule("stop")
            if ni and songs[ni] then
                schedule({"select", ni})
                schedule({"goto", songs[ni].start})
            end
            last_played_idx = last_current_idx
            last_transition_idx = 0
            last_current_idx = cur
            return
        end
    end
    if cur == 0 then return end
    if cur ~= last_current_idx then
        last_transition_idx = 0
        last_current_idx = cur
        last_played_idx = cur
    end
    if cur < 1 or cur > #songs then return end
    local s = songs[cur]
    local p = reaper.GetPlayPosition()
    if p < s.start or p > s.finish then last_transition_idx = 0; return end
    if p >= s.finish - 0.08 and p <= s.finish + 0.2 and last_transition_idx ~= cur then
        local ni = find_next_used_song(cur)
        if not s.use then
            if not locked then
                schedule("stop")
                if ni then
                    schedule({"select", ni})
                    schedule({"goto", songs[ni].start})
                end
            end
            last_transition_idx = cur
            return
        end
        if s.combine and ni then
            schedule({"select", ni})
            schedule({"goto_play", songs[ni].start})
            last_transition_idx = cur
        else
            schedule("stop")
            if ni then
                schedule({"select", ni})
                schedule({"goto", songs[ni].start})
            end
            last_transition_idx = cur
        end
    end
end

local function check_auto_throttled(cur)
    local now = reaper.time_precise()
    if now - last_check_auto_time < CHECK_AUTO_INTERVAL then return end
    last_check_auto_time = now
    check_auto(cur)
end

local function total_time()
    local t = 0
    for _, s in ipairs(songs) do if s.use then t = t + s.duration end end
    return t
end

local function time_to_end(cur, pos)
    if cur < 1 or cur > #songs then return total_time() end
    local t = 0
    if songs[cur].use then t = t + math.max(0, songs[cur].finish - pos) end
    for i = cur + 1, #songs do if songs[i].use then t = t + songs[i].duration end end
    return t
end

local function draw_arrow_down(cx, cy, sz)
    local stem_w = math.max(S(3), sz * 0.35)
    local stem_h = sz * 1.2
    gfx.rect(cx - stem_w / 2, cy - stem_h, stem_w, stem_h, 1)
    local tri_sz = sz * 1.1
    gfx.triangle(cx, cy + tri_sz * 0.6, cx - tri_sz, cy - tri_sz * 0.3, cx + tri_sz, cy - tri_sz * 0.3)
end

local function draw_centered_fit_text(text, cx, y, max_w, font_ids, color)
    for _, fid in ipairs(font_ids) do
        gfx.setfont(fid)
        local w = gfx.measurestr(text)
        if w <= max_w then
            gfx.set(color[1], color[2], color[3])
            gfx.x, gfx.y = cx - w / 2, y
            gfx.drawstr(text)
            return
        end
    end
    gfx.setfont(font_ids[#font_ids])
    local display, ellipsis, ell_w = text, "...", gfx.measurestr("...")
    while #display > 0 do
        if gfx.measurestr(display) + ell_w <= max_w then break end
        display = display:sub(1, -2)
    end
    display = display .. ellipsis
    local w = gfx.measurestr(display)
    gfx.set(color[1], color[2], color[3])
    gfx.x, gfx.y = cx - w / 2, y
    gfx.drawstr(display)
end

-- ============================================================
-- DRAW
-- ============================================================
local function draw()
    local char = gfx.getchar()
    if char < 0 then stop_web_server(); return end

    update_songs_throttled()
    enforce_lock_protection()
    if web_enabled then web_server_tick() end

    local ROW_H, TRANS_Y, TRANS_H = S(44), S(130), S(90)
    local TOOL_Y, TOOL_H = S(245), S(45)
    local STATS_Y, STATS_H = S(325), S(100)
    local LIST_Y, PROG_H = S(480), S(90)
    local PROG_Y = gfx.h - PROG_H - S(10)
    local LIST_TOP, LIST_H = LIST_Y, math.max(S(200), PROG_Y - LIST_Y - S(20))

    local mx, my = gfx.mouse_x, gfx.mouse_y
    local down = (gfx.mouse_cap & 1) ~= 0
    local right_down = (gfx.mouse_cap & 2) ~= 0
    local pressed = down and not was_down
    local right_pressed = right_down and not was_right_down
    local released = (not down) and was_down
    was_down = down
    was_right_down = right_down
    local playing = (reaper.GetPlayState() & 1) ~= 0

    if search_enabled and not locked then
        if char == 8 and #search_text > 0 then search_text = search_text:sub(1, -2); scroll_pos = 1 end
        if char == 27 then search_text = ""; scroll_pos = 1 end
        if char >= 32 and char <= 126 and char ~= 13 and char ~= 27 and char ~= 8 then
            local c = string.char(char)
            if c:match('[A-Za-z0-9]') then search_text = search_text .. c; scroll_pos = 1 end
        end
    end

    if char == 32 then if not space_was_pressed then space_was_pressed = true; toggle_play() end
    else space_was_pressed = false end
    if char == 13 then toggle_play() end
    if not playing then
        if char == 30064 or char == 65362 then select_prev(LIST_H, ROW_H) end
        if char == 65364 or char == 1685026670 then select_next(LIST_H, ROW_H) end
    end

    if gfx.mouse_wheel ~= 0 and #songs > 0 then
        local d = gfx.mouse_wheel
        if math.abs(d) < 120 then d = (d > 0) and 120 or -120 end
        local delta = -math.floor(d / 120)
        if locked then
            local first_use, last_use = get_use_bounds()
            if first_use and last_use then
                local vis = math.floor(LIST_H / ROW_H)
                local new_scroll = math.max(first_use, math.min(last_use - vis + 1, scroll_pos + delta))
                scroll_pos = math.max(1, new_scroll)
            else scroll_pos = scroll_pos + delta end
        else scroll_pos = scroll_pos + delta end
        gfx.mouse_wheel = 0
    end

    gfx.set(0.07, 0.07, 0.09); gfx.rect(0, 0, gfx.w, gfx.h, 1)

    local pos = playing and reaper.GetPlayPosition() or reaper.GetCursorPosition()
    local cur = 0
    for i = 1, #songs do if pos >= songs[i].start - 0.01 and pos <= songs[i].finish + 0.01 then cur = i; break end end
    if cur == 0 then for i = 1, #songs do if pos >= songs[i].start - 0.01 then cur = i end end end
    check_auto_throttled(cur)

    local title = "NO SONG SELECTED"
    if selected_idx >= 1 and songs[selected_idx] then title = string.format("%02d  %s", selected_idx, songs[selected_idx].name) end
    gfx.setfont(1); gfx.set(0.25, 0.95, 0.45)
    local tw = gfx.measurestr(title)
    gfx.x, gfx.y = (gfx.w - tw) / 2, S(35); gfx.drawstr(title)

    gfx.setfont(2); gfx.set(0.75, 0.75, 0.75)
    local st = playing and "PLAYING" or "STOPPED"
    local sw = gfx.measurestr(st)
    gfx.x, gfx.y = (gfx.w - sw) / 2, S(95); gfx.drawstr(st)

    local function btn(x, y, w, h, label, r, g, b, font_id)
        font_id = font_id or 2
        local hover = in_box(mx, my, x, y, w, h)
        local rr, gg, bb = r, g, b
        if hover then rr, gg, bb = r + 0.12, g + 0.12, b + 0.12 end
        if hover and pressed then rr, gg, bb = r * 0.7, g * 0.7, b * 0.7 end
        gfx.set(rr, gg, bb); gfx.rect(x, y, w, h, 1)
        gfx.set(0.55, 0.55, 0.6); gfx.rect(x, y, w, h, 0)
        gfx.setfont(font_id); gfx.set(1, 1, 1)
        local a, b2 = gfx.measurestr(label)
        gfx.x, gfx.y = x + (w - a) / 2, y + (h - b2) / 2; gfx.drawstr(label)
        return hover and pressed
    end

    local bx, by, bw, bh = S(40), TRANS_Y, gfx.w - S(80), TRANS_H
    local hover = in_box(mx, my, bx, by, bw, bh)
    local play_blocked = (locked and not playing and (selected_idx < 1 or not songs[selected_idx] or not songs[selected_idx].use))
    local pr, pg, pb
    if play_blocked then pr, pg, pb = 0.25, 0.25, 0.28
    elseif playing then pr, pg, pb = 0.45, 0.12, 0.12
    else pr, pg, pb = 0.10, 0.45, 0.15 end
    if hover and not play_blocked then pr, pg, pb = pr + 0.12, pg + 0.12, pb + 0.12 end
    if hover and pressed and not play_blocked then pr, pg, pb = pr * 0.7, pg * 0.7, pb * 0.7 end
    gfx.set(pr, pg, pb); gfx.rect(bx, by, bw, bh, 1)
    gfx.set(0.55, 0.55, 0.6); gfx.rect(bx, by, bw, bh, 0)
    local icon_size, icon_gap = S(50), S(20)
    local label = playing and "STOP" or "PLAY"
    gfx.setfont(1); local label_w = gfx.measurestr(label)
    local total_w = icon_size + icon_gap + label_w
    local start_x, center_y = bx + (bw - total_w) / 2, by + bh / 2
    local icon_x, icon_y = start_x, center_y - icon_size / 2
    if play_blocked then gfx.set(0.5, 0.5, 0.55); gfx.rect(icon_x, icon_y, icon_size, icon_size, 1)
    elseif playing then gfx.set(1, 1, 1); gfx.rect(icon_x, icon_y, icon_size, icon_size, 1)
    else gfx.set(0.2, 0.9, 0.3); gfx.triangle(icon_x, icon_y, icon_x, icon_y + icon_size, icon_x + icon_size, icon_y + icon_size / 2) end
    gfx.setfont(1)
    gfx.set(play_blocked and 0.5 or 1, play_blocked and 0.5 or 1, play_blocked and 0.55 or 1)
    local _, lh = gfx.measurestr(label)
    gfx.x, gfx.y = icon_x + icon_size + icon_gap, center_y - lh / 2; gfx.drawstr(label)
    if hover and pressed and not play_blocked then toggle_play() end

    local tool_gap, tool_pad, tool_count = S(10), S(20), 8
    local tool_total_gap = tool_gap * (tool_count - 1)
    local tool_avail_w = gfx.w - tool_pad * 2 - tool_total_gap
    local tool_btn_w = tool_avail_w / tool_count
    local tool_x = tool_pad

    local save_clicked = btn(tool_x, TOOL_Y, tool_btn_w, TOOL_H, "SAVE", locked and 0.12 or 0.2, locked and 0.15 or 0.3, locked and 0.18 or 0.4, 8)
    if not locked and save_clicked then
        local fs = list_files(true)
        if #fs == 0 then
            local ok, nm = reaper.GetUserInputs("Save SetList", 1, "Name:", ""); gfx.update()
            if ok and nm ~= "" then save_list(nm); current_setlist_name = nm end
        else
            local menu = "Create New|"
            for _, f in ipairs(fs) do menu = menu .. f .. "|" end
            local i = gfx.showmenu(menu); gfx.update()
            if i == 1 then
                local ok, nm = reaper.GetUserInputs("Save SetList", 1, "Name:", ""); gfx.update()
                if ok and nm ~= "" then save_list(nm); current_setlist_name = nm end
            elseif i > 1 then
                local name = fs[i - 1]
                local result = reaper.ShowMessageBox("Overwrite setlist \"" .. name .. "\"?", "Confirm Overwrite", 4); gfx.update()
                if result == 6 then save_list(name); current_setlist_name = name end
            end
        end
    end
    tool_x = tool_x + tool_btn_w + tool_gap

    local load_clicked = btn(tool_x, TOOL_Y, tool_btn_w, TOOL_H, "LOAD", locked and 0.15 or 0.2, locked and 0.15 or 0.3, locked and 0.18 or 0.4, 8)
    if not locked and load_clicked then
        local fs = list_files(true)
        if #fs > 0 then
            local menu = ""
            for _, f in ipairs(fs) do menu = menu .. f .. "|" end
            local i = gfx.showmenu(menu); gfx.update()
            if i > 0 then load_list(fs[i]); current_setlist_name = fs[i] end
        end
    end
    tool_x = tool_x + tool_btn_w + tool_gap

    local delete_clicked = btn(tool_x, TOOL_Y, tool_btn_w, TOOL_H, "DELETE", locked and 0.15 or 0.4, locked and 0.15 or 0.2, locked and 0.18 or 0.2, 8)
    if not locked and delete_clicked then
        local fs = list_files(true)
        if #fs > 0 then
            local menu = ""
            for _, f in ipairs(fs) do menu = menu .. f .. "|" end
            local i = gfx.showmenu(menu); gfx.update()
            if i > 0 then
                local name = fs[i]
                local result = reaper.ShowMessageBox("Delete setlist \"" .. name .. "\"?", "Confirm Delete", 4); gfx.update()
                if result == 6 then delete_list(name); if current_setlist_name == name then current_setlist_name = nil end end
            end
        end
    end
    tool_x = tool_x + tool_btn_w + tool_gap

    local clear_clicked = btn(tool_x, TOOL_Y, tool_btn_w, TOOL_H, "CLEAR", locked and 0.15 or 0.35, locked and 0.15 or 0.25, locked and 0.18 or 0.15, 8)
    if not locked and clear_clicked then clear_all(); current_setlist_name = nil end
    tool_x = tool_x + tool_btn_w + tool_gap

    local web_is_locked = locked
    local web_r, web_g, web_b
    if web_is_locked then web_r, web_g, web_b = 0.15, 0.15, 0.15
    elseif web_enabled then web_r, web_g, web_b = 0.15, 0.45, 0.35
    else web_r, web_g, web_b = 0.25, 0.25, 0.3 end
    local web_x = tool_x
    local web_y = TOOL_Y
    local web_w = tool_btn_w
    local web_h = TOOL_H
    local web_hover = in_box(mx, my, web_x, web_y, web_w, web_h)
    local web_rr, web_gg, web_bb = web_r, web_g, web_b
    if web_hover then web_rr, web_gg, web_bb = web_r + 0.12, web_g + 0.12, web_b + 0.12 end
    if web_hover and (down or right_down) then web_rr, web_gg, web_bb = web_r * 0.7, web_g * 0.7, web_b * 0.7 end
    gfx.set(web_rr, web_gg, web_bb); gfx.rect(web_x, web_y, web_w, web_h, 1)
    gfx.set(0.55, 0.55, 0.6); gfx.rect(web_x, web_y, web_w, web_h, 0)
    gfx.setfont(8); gfx.set(1, 1, 1)
    local web_label = web_enabled and "WEB ON" or "WEB"
    local a, b2 = gfx.measurestr(web_label)
    gfx.x, gfx.y = web_x + (web_w - a) / 2, web_y + (web_h - b2) / 2
    gfx.drawstr(web_label)
    if web_hover and not web_is_locked then
        if right_pressed then
            local menu = ""
            local port_order = {6060, 7070, 8080, 9090}
            for i, p in ipairs(port_order) do
                local is_current = (get_current_web_port() == p)
                local prefix = is_current and "✓ Port " .. p .. "|" or "  Port " .. p .. "|"
                menu = menu .. prefix
            end
            local choice = gfx.showmenu(menu)
            if choice > 0 then
                local selected_port = port_order[choice]
                for i, p in ipairs(WEB_PORTS) do
                    if p == selected_port then current_web_port_idx = i; break end
                end
                local was_running = web_enabled
                if was_running then stop_web_server() end
                if was_running then start_web_server() end
            end
        elseif pressed then
            if web_enabled then
                stop_web_server()
                web_enabled = false
            else
                if start_web_server() then
                    web_enabled = true
                else
                    reaper.ShowMessageBox(
                        "Failed to start web server on port " .. get_current_web_port() .. "\n\n" .. 
                        (web_error or "Unknown error") .. 
                        "\n\nMake sure Python 3 is installed:\n" ..
                        "• macOS: xcode-select --install\n" ..
                        "• Windows: install Python from python.org",
                        "Web Server Error", 0)
                end
            end
        end
    end
    tool_x = tool_x + tool_btn_w + tool_gap

    btn(tool_x, TOOL_Y, tool_btn_w, TOOL_H, string.format("A:%.2f", SCALE), 0.25, 0.25, 0.3, 8)
    tool_x = tool_x + tool_btn_w + tool_gap
    if btn(tool_x, TOOL_Y, tool_btn_w, TOOL_H, "A+", 0.3, 0.3, 0.2, 8) then SCALE = math.min(3, SCALE + 0.25); reaper.SetExtState("LiveControl", "scale", tostring(SCALE), true) end
    tool_x = tool_x + tool_btn_w + tool_gap
    if btn(tool_x, TOOL_Y, tool_btn_w, TOOL_H, "A-", 0.3, 0.3, 0.2, 8) then SCALE = math.max(0.5, SCALE - 0.25); reaper.SetExtState("LiveControl", "scale", tostring(SCALE), true) end

    if web_enabled and web_ip ~= "127.0.0.1" then
        gfx.setfont(10); gfx.set(0.5, 0.85, 0.6)
        local current_port = get_current_web_port()
        local url_text = "http://" .. web_ip .. ":" .. current_port .. " (Right-click WEB to change)"
        local uw = gfx.measurestr(url_text)
        gfx.x, gfx.y = gfx.w - uw - S(30), TOOL_Y + TOOL_H + S(5)
        gfx.drawstr(url_text)
    elseif web_enabled and web_error then
        gfx.setfont(8); gfx.set(0.9, 0.4, 0.4)
        local err_text = "Error: " .. web_error
        gfx.x, gfx.y = gfx.w - gfx.measurestr(err_text) - S(30), TOOL_Y + TOOL_H + S(5)
        gfx.drawstr(err_text)
    end

    local gap = S(15)
    local total_w = gfx.w - S(60) - gap * 2
    local bwid_small, bwid_large = total_w * 0.25, total_w * 0.50
    local x1, x2, x3 = S(30), S(30) + bwid_small + gap, S(30) + bwid_small + gap + bwid_large + gap
    local cnt = 0
    for _, s in ipairs(songs) do if s.use then cnt = cnt + 1 end end

    local function stat_block(x, w, label, value, color)
        gfx.set(0.12, 0.12, 0.15); gfx.rect(x, STATS_Y, w, STATS_H, 1)
        gfx.set(0.4, 0.4, 0.45); gfx.rect(x, STATS_Y, w, STATS_H, 0)
        gfx.setfont(3); gfx.set(0.7, 0.7, 0.7)
        local lbl_w = gfx.measurestr(label)
        gfx.x, gfx.y = x + (w - lbl_w) / 2, STATS_Y + S(10); gfx.drawstr(label)
        gfx.setfont(5); gfx.set(color[1], color[2], color[3])
        local vw = gfx.measurestr(value)
        gfx.x, gfx.y = x + (w - vw) / 2, STATS_Y + S(40); gfx.drawstr(value)
    end
    local function stat_block_setlist(x, w, label, value, color)
        gfx.set(0.12, 0.12, 0.15); gfx.rect(x, STATS_Y, w, STATS_H, 1)
        gfx.set(0.4, 0.4, 0.45); gfx.rect(x, STATS_Y, w, STATS_H, 0)
        gfx.setfont(3); gfx.set(0.7, 0.7, 0.7)
        local lbl_w = gfx.measurestr(label)
        gfx.x, gfx.y = x + (w - lbl_w) / 2, STATS_Y + S(10); gfx.drawstr(label)
        draw_centered_fit_text(value, x + w / 2, STATS_Y + S(40), w - S(20), {5, 12, 13, 14, 15}, color)
    end
    stat_block(x1, bwid_small, "TOTAL TIME", fmt(total_time()), {0.25, 0.95, 0.45})
    stat_block_setlist(x2, bwid_large, "SET LIST", current_setlist_name or "SET LIST", {0.95, 0.85, 0.3})
    stat_block(x3, bwid_small, "END", fmt(time_to_end(cur, pos)), {0.95, 0.6, 0.25})

    local header_h = S(40)
    local header_y = (STATS_Y + STATS_H + LIST_Y) / 2 - header_h / 2
    local search_btn_w, search_btn_h = S(130), header_h
    local search_btn_x, search_btn_y = S(40), header_y
    local search_locked = locked
    local search_r, search_g, search_b
    if search_locked then search_r, search_g, search_b = 0.18, 0.18, 0.22
    elseif search_enabled then search_r, search_g, search_b = 0.2, 0.45, 0.7
    else search_r, search_g, search_b = 0.3, 0.3, 0.35 end
    local search_btn_hover = in_box(mx, my, search_btn_x, search_btn_y, search_btn_w, search_btn_h)
    if search_btn_hover and not search_locked then search_r, search_g, search_b = search_r + 0.12, search_g + 0.12, search_b + 0.12 end
    if search_btn_hover and pressed and not search_locked then search_r, search_g, search_b = search_r * 0.7, search_g * 0.7, search_b * 0.7 end
    gfx.set(search_r, search_g, search_b); gfx.rect(search_btn_x, search_btn_y, search_btn_w, search_btn_h, 1)
    gfx.set(0.55, 0.55, 0.6); gfx.rect(search_btn_x, search_btn_y, search_btn_w, search_btn_h, 0)
    gfx.setfont(9); gfx.set(search_locked and 0.4 or 1, search_locked and 0.4 or 1, search_locked and 0.45 or 1)
    local icon_r = S(7); local icon_cx, icon_cy = search_btn_x + S(20), search_btn_y + search_btn_h / 2
    gfx.circle(icon_cx, icon_cy, icon_r, 0, false)
    gfx.line(icon_cx + icon_r * 0.7, icon_cy + icon_r * 0.7, icon_cx + icon_r * 1.4, icon_cy + icon_r * 1.4)
    local search_text_w, search_text_h = gfx.measurestr("SEARCH")
    gfx.x, gfx.y = search_btn_x + S(38), search_btn_y + (search_btn_h - search_text_h) / 2; gfx.drawstr("SEARCH")
    if search_btn_hover and pressed and not search_locked then
        search_enabled = not search_enabled
        if not search_enabled then search_text = "" end
        scroll_pos = 1
    end

    local lock_w, lock_h = S(130), header_h
    local lock_x, lock_y = gfx.w - S(40) - lock_w, header_y
    local lock_hover = in_box(mx, my, lock_x, lock_y, lock_w, lock_h)
    local lock_r, lock_g, lock_b, lock_label
    if locked then lock_r, lock_g, lock_b, lock_label = 0.7, 0.15, 0.15, "LOCKED"
    else lock_r, lock_g, lock_b, lock_label = 0.3, 0.3, 0.35, "LOCK" end
    if lock_hover then lock_r, lock_g, lock_b = lock_r + 0.12, lock_g + 0.12, lock_b + 0.12 end
    if lock_hover and pressed then lock_r, lock_g, lock_b = lock_r * 0.7, lock_g * 0.7, lock_b * 0.7 end
    gfx.set(lock_r, lock_g, lock_b); gfx.rect(lock_x, lock_y, lock_w, lock_h, 1)
    gfx.set(0.55, 0.55, 0.6); gfx.rect(lock_x, lock_y, lock_w, lock_h, 0)
    gfx.setfont(9); gfx.set(1, 1, 1)
    local lw, lhh = gfx.measurestr(lock_label)
    gfx.x, gfx.y = lock_x + (lock_w - lw) / 2, lock_y + (lock_h - lhh) / 2; gfx.drawstr(lock_label)
    if lock_hover and pressed then
        locked = not locked
        if locked then
            drag_idx = nil; search_enabled = false; search_text = ""
            local first_use, last_use = get_use_bounds()
            if first_use and last_use then
                if selected_idx < first_use or selected_idx > last_use or not songs[selected_idx].use then selected_idx = first_use end
                local vis = math.floor(LIST_H / ROW_H)
                if scroll_pos < first_use then scroll_pos = first_use end
                if scroll_pos > math.max(1, last_use - vis + 1) then scroll_pos = math.max(1, last_use - vis + 1) end
            end
        end
        scroll_pos = 1
    end

    if search_enabled and not locked then
        local field_x = search_btn_x + search_btn_w + S(15)
        local field_w = lock_x - field_x - S(15)
        local field_y, field_h = header_y, header_h
        gfx.set(search_text ~= "" and 0.15 or 0.10, search_text ~= "" and 0.18 or 0.12, search_text ~= "" and 0.22 or 0.15)
        gfx.rect(field_x, field_y, field_w, field_h, 1)
        gfx.set(search_text ~= "" and 0.4 or 0.35, search_text ~= "" and 0.6 or 0.35, search_text ~= "" and 0.8 or 0.4)
        gfx.rect(field_x, field_y, field_w, field_h, 0)
        gfx.setfont(11); local text_x = field_x + S(12)
        if search_text == "" then 
            gfx.set(0.4, 0.4, 0.45); gfx.x, gfx.y = text_x, field_y + (field_h - S(20)) / 2; gfx.drawstr("Type to search (EN layout)...")
        else 
            gfx.set(0.95, 0.95, 0.95); gfx.x, gfx.y = text_x, field_y + (field_h - S(20)) / 2; gfx.drawstr(search_text) 
        end
        local filtered_count_tmp = 0
        for i = 1, #songs do if find_match(songs[i].name, search_text) then filtered_count_tmp = filtered_count_tmp + 1 end end
        gfx.setfont(11)
        if search_text ~= "" then
            gfx.set(0.6, 0.8, 1.0)
            local counter = string.format("Found: %d / %d", filtered_count_tmp, #songs)
            local cw = gfx.measurestr(counter)
            gfx.x, gfx.y = field_x + field_w - cw - S(12), field_y + (field_h - S(20)) / 2; gfx.drawstr(counter)
        else
            gfx.set(0.5, 0.5, 0.55)
            local counter = string.format("Total: %d", #songs)
            local cw = gfx.measurestr(counter)
            gfx.x, gfx.y = field_x + field_w - cw - S(12), field_y + (field_h - S(20)) / 2; gfx.drawstr(counter)
        end
        if search_text ~= "" then
            local clear_x = field_x + field_w - S(30); local clear_y = field_y + (field_h - S(20)) / 2
            local clear_hover = in_box(mx, my, clear_x - S(5), field_y, S(25), field_h)
            gfx.set(clear_hover and 1 or 0.6, clear_hover and 0.5 or 0.6, clear_hover and 0.5 or 0.65)
            gfx.line(clear_x, clear_y, clear_x + S(12), clear_y + S(12))
            gfx.line(clear_x + S(12), clear_y, clear_x, clear_y + S(12))
            if clear_hover and pressed then search_text = ""; scroll_pos = 1 end
        end
    end

    gfx.set(0.3, 0.3, 0.35); gfx.rect(S(30), LIST_TOP - S(5), gfx.w - S(60), LIST_H, 0)

    local filtered_count, filtered_indices = 0, {}
    if search_enabled and search_text ~= "" and not locked then
        for i = 1, #songs do
            if find_match(songs[i].name, search_text) then filtered_count = filtered_count + 1; filtered_indices[filtered_count] = i end
        end
    else
        for i = 1, #songs do filtered_count = filtered_count + 1; filtered_indices[filtered_count] = i end
    end

    local vis = math.floor(LIST_H / ROW_H)
    local maxscroll = math.max(1, filtered_count - vis + 1)
    scroll_pos = math.max(1, math.min(scroll_pos, maxscroll))
    local first_use, last_use = get_use_bounds()
    if locked and first_use and last_use then
        if scroll_pos < first_use then scroll_pos = first_use end
        local lock_max_scroll = math.max(1, last_use - vis + 1)
        if scroll_pos > lock_max_scroll then scroll_pos = lock_max_scroll end
    end
    local last_vis = math.min(scroll_pos + vis - 1, filtered_count)

    local drop = nil
    if drag_idx and not locked and not playing then
        for vis_i = scroll_pos, last_vis do
            local real_i = filtered_indices[vis_i]
            local ry = LIST_TOP + (vis_i - scroll_pos) * ROW_H
            if in_box(mx, my, S(35), ry, gfx.w - S(70), ROW_H) then
                local center_y = ry + ROW_H / 2
                if my < center_y then drop = real_i else drop = real_i + 1 end
                break
            end
        end
        if drop == nil and filtered_count > 0 then
            local last_ry = LIST_TOP + (last_vis - scroll_pos) * ROW_H
            if my > last_ry + ROW_H then drop = filtered_indices[last_vis] + 1 end
        end
    end

    local first_selected, last_selected = nil, nil
    if locked then
        for vis_i = scroll_pos, last_vis do
            local real_i = filtered_indices[vis_i]
            if songs[real_i].use then
                if not first_selected then first_selected = vis_i end
                last_selected = vis_i
            end
        end
    end
    local last_use_idx = last_use

    for vis_i = scroll_pos, last_vis do
        local i = filtered_indices[vis_i]
        local s = songs[i]
        local ry = LIST_TOP + (vis_i - scroll_pos) * ROW_H
        local dy = ry
        gfx.set(i == cur and 0.15 or (not s.use and 0.10 or 0.16), i == cur and 0.35 or (not s.use and 0.10 or 0.16), i == cur and 0.15 or (not s.use and 0.12 or 0.20))
        gfx.rect(S(35), dy, gfx.w - S(70), ROW_H - 2, 1)

        if drag_idx and not locked and not playing and drag_idx ~= i then
            if drop == i then
                gfx.set(1, 0.8, 0.2, 0.9)
                gfx.rect(S(35), dy - 2, gfx.w - S(70), 4, 1)
            elseif drop == i + 1 then
                gfx.set(1, 0.8, 0.2, 0.9)
                gfx.rect(S(35), dy + ROW_H - 2, gfx.w - S(70), 4, 1)
            end
        end

        gfx.setfont(6); gfx.set(s.use and 1 or 0.4, s.use and 0.9 or 0.4, s.use and 0.3 or 0.4)
        gfx.x, gfx.y = S(42), dy + S(10); gfx.drawstr(string.format("%02d", i))

        local ux, uw, uh, uy = S(82), S(40), ROW_H - S(6), dy + S(3)
        local symbol = s.use and "-" or "+"
        local bg_r, bg_g, bg_b, sym_r, sym_g, sym_b
        if locked then bg_r, bg_g, bg_b, sym_r, sym_g, sym_b = 0.22, 0.22, 0.28, 0.45, 0.45, 0.5
        elseif s.use then bg_r, bg_g, bg_b, sym_r, sym_g, sym_b = 0.45, 0.28, 0.12, 0.9, 0.55, 0.2
        else bg_r, bg_g, bg_b, sym_r, sym_g, sym_b = 0.12, 0.25, 0.15, 0.35, 0.85, 0.45 end
        gfx.set(bg_r, bg_g, bg_b); gfx.rect(ux, uy, uw, uh, 1)
        gfx.setfont(7); gfx.set(sym_r, sym_g, sym_b)
        local pw, ph = gfx.measurestr(symbol)
        gfx.x, gfx.y = ux + (uw - pw) / 2, uy + (uh - ph) / 2; gfx.drawstr(symbol)

        if pressed and in_box(mx, my, ux, uy, uw, uh) and not drag_idx and not locked and not playing then
            s.use = not s.use; if not s.use then s.combine = false end
            reorganize_list(); current_setlist_name = nil
            last_use_idx = nil; for k = #songs, 1, -1 do if songs[k].use then last_use_idx = k; break end end
        end

        local nx, nw = ux + uw + S(15), gfx.w - S(310)
        gfx.setfont(4)
        local match_start, match_end = find_match(s.name, search_text)
        if search_enabled and not locked and match_start and match_end and match_start >= 1 then
            local before = s.name:sub(1, match_start - 1)
            local match = s.name:sub(match_start, match_end)
            local after = s.name:sub(match_end + 1)
            gfx.set(s.use and 0.95 or 0.45, s.use and 0.95 or 0.45, s.use and 0.95 or 0.45)
            gfx.x, gfx.y = nx, dy + S(8); gfx.drawstr(before, 0, nx + nw, dy + ROW_H)
            local before_w = gfx.measurestr(before)
            gfx.set(1, 0.9, 0.3); gfx.x, gfx.y = nx + before_w, dy + S(8); gfx.drawstr(match, 0, nx + nw, dy + ROW_H)
            local match_w = gfx.measurestr(match)
            gfx.set(s.use and 0.95 or 0.45, s.use and 0.95 or 0.45, s.use and 0.95 or 0.45)
            gfx.x, gfx.y = nx + before_w + match_w, dy + S(8); gfx.drawstr(after, 0, nx + nw, dy + ROW_H)
        else
            gfx.set(s.use and 0.95 or 0.45, s.use and 0.95 or 0.45, s.use and 0.95 or 0.45)
            gfx.x, gfx.y = nx, dy + S(8); gfx.drawstr(s.name, 0, nx + nw, dy + ROW_H)
        end

        if pressed and in_box(mx, my, nx, ry, nw, ROW_H) and not drag_idx and not playing then
            if locked then if s.use then selected_idx = i; schedule({"goto", s.start}) end
            else selected_idx = i; schedule({"goto", s.start}); if s.use then start_drag(i, my) end end
        end

        gfx.setfont(10); gfx.set(s.use and 0.8 or 0.4, s.use and 0.8 or 0.4, s.use and 0.8 or 0.4)
        local ds = fmt(s.duration); local dw = gfx.measurestr(ds)
        gfx.x, gfx.y = gfx.w - S(185) - dw, dy + S(9); gfx.drawstr(ds)

        if s.tempo and s.tempo > 0 then
            local tempo_str = string.format("%d", math.floor(s.tempo + 0.5))
            gfx.setfont(10); gfx.set(s.use and 0.55 or 0.35, s.use and 0.75 or 0.5, s.use and 0.55 or 0.35)
            local tempo_w = gfx.measurestr(tempo_str)
            gfx.x, gfx.y = gfx.w - S(125) - tempo_w, dy + S(9); gfx.drawstr(tempo_str)
        end

        if s.use and i ~= last_use_idx then
            local cx0, cw, ch, cy0 = gfx.w - S(110), S(40), ROW_H - S(6), dy + S(3)
            if s.combine then gfx.set(0.9, 0.75, 0.1, 0.95); gfx.rect(cx0, cy0, cw, ch, 1); gfx.set(0, 0, 0)
            else gfx.set(0.25, 0.25, 0.3); gfx.rect(cx0, cy0, cw, ch, 1); gfx.set(0.65, 0.65, 0.7) end
            draw_arrow_down(cx0 + cw / 2, cy0 + ch / 2, S(6))
            if pressed and in_box(mx, my, cx0, cy0, cw, ch) and not drag_idx then s.combine = not s.combine end
        end
    end

    if released and drag_idx then end_drag(drop) end

    if locked and first_selected and last_selected then
        local top_y = LIST_TOP + (first_selected - scroll_pos) * ROW_H
        local bottom_y = LIST_TOP + (last_selected - scroll_pos) * ROW_H + ROW_H - 2
        gfx.set(0.9, 0.15, 0.15, 0.95)
        gfx.rect(S(33), top_y - 2, gfx.w - S(66), bottom_y - top_y + 4, 0)
        gfx.rect(S(34), top_y - 1, gfx.w - S(68), bottom_y - top_y + 2, 0)
        gfx.rect(S(35), top_y, gfx.w - S(70), bottom_y - top_y, 0)
        gfx.rect(S(36), top_y + 1, gfx.w - S(72), bottom_y - top_y - 2, 0)
    end

    if filtered_count > vis then
        local bh = LIST_H - S(4); local th = math.max(S(20), bh * vis / filtered_count)
        local ty = LIST_TOP + S(2) + (bh - th) * (scroll_pos - 1) / math.max(1, filtered_count - vis)
        gfx.set(0.3, 0.3, 0.35); gfx.rect(gfx.w - S(45), LIST_TOP + S(2), S(10), bh, 0)
        gfx.set(0.5, 0.5, 0.55); gfx.rect(gfx.w - S(44), ty, S(8), th, 1)
    end

    gfx.set(0.12, 0.12, 0.15); gfx.rect(S(30), PROG_Y, gfx.w - S(60), PROG_H, 1)
    gfx.set(0.4, 0.4, 0.45); gfx.rect(S(30), PROG_Y, gfx.w - S(60), PROG_H, 0)
    if cur >= 1 and playing then
        local s = songs[cur]; local el = math.max(0, pos - s.start); local rem = math.max(0, s.finish - pos)
        local pr = math.max(0, math.min(1, el / math.max(0.01, s.duration)))
        gfx.setfont(3); gfx.set(0.7, 0.7, 0.7); gfx.x, gfx.y = S(50), PROG_Y + S(10); gfx.drawstr("CURRENT REGION PROGRESS")
        local bx2, by2, bw2, bh2 = S(50), PROG_Y + S(30), gfx.w - S(100), S(20)
        gfx.set(0.2, 0.2, 0.25); gfx.rect(bx2, by2, bw2, bh2, 1)
        gfx.set(0.25, 0.95, 0.45); gfx.rect(bx2, by2, bw2 * pr, bh2, 1)
        gfx.set(0.6, 0.6, 0.65); gfx.rect(bx2, by2, bw2, bh2, 0)
        gfx.setfont(6); gfx.set(0.9, 0.9, 0.95); gfx.x, gfx.y = bx2, by2 + bh2 + S(5); gfx.drawstr("Elapsed: " .. fmt(el))
        local rtxt = "Remaining: " .. fmt(rem); gfx.x, gfx.y = bx2 + bw2 - gfx.measurestr(rtxt), by2 + bh2 + S(5); gfx.drawstr(rtxt)
    else
        gfx.setfont(3); gfx.set(0.5, 0.5, 0.55); local t = "No region playing"
        gfx.x, gfx.y = (gfx.w - gfx.measurestr(t)) / 2, PROG_Y + S(35); gfx.drawstr(t)
    end

    gfx.update()
    reaper.defer(draw)
end

reaper.defer(draw)

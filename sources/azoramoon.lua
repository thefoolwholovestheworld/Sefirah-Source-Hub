-- Azora Moon (azorafly.com) — v0.2.2
local logger = require("logger")
local BASE = "https://azorafly.com"
local CONT = "novel-reader-content"
local UA = "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Mobile Safari/537.36"

-- ── Diagnostic ──
local function write_debug(text)
    pcall(function()
        local DataStorage = require("datastorage")
        local dir = DataStorage:getSettingsDir() .. "/sefirah"
        local lfs = require("libs/libkoreader-lfs")
        if lfs.attributes(dir, "mode") ~= "directory" then lfs.mkdir(dir) end
        local f = io.open(dir .. "/azoramoon_last_error.txt", "w")
        if f then f:write(text); f:close() end
    end)
end

local function get(p)
    local url = p:match("^https?://") and p or (BASE .. p)
    local body, code = require("core.net").get(url, { headers = { ["User-Agent"] = UA, ["Referer"] = BASE .. "/" }, timeout = 15 })
    if body and #body > 2 then return body end
    logger.warn("Azora: échec", url, tostring(code))
    return nil, tostring(code)
end

local function cp2utf8(c)
    if not c or c <= 0 or c > 0x10FFFF then return nil end
    if c < 0x80 then return string.char(c) end
    if c < 0x800 then return string.char(0xC0 + math.floor(c / 64), 0x80 + c % 64) end
    if c < 0x10000 then return string.char(0xE0 + math.floor(c / 4096), 0x80 + math.floor(c / 64) % 64, 0x80 + c % 64) end
    return string.char(0xF0 + math.floor(c / 262144), 0x80 + math.floor(c / 4096) % 64, 0x80 + math.floor(c / 64) % 64, 0x80 + c % 64)
end
local ENT = { amp = "&", lt = "<", gt = ">", quot = '"', apos = "'", nbsp = " ",
    rsquo = "’", lsquo = "‘", ldquo = "“", rdquo = "”", hellip = "…", ndash = "–", mdash = "—",
    laquo = "«", raquo = "»", eacute = "é", egrave = "è", agrave = "à", ccedil = "ç" }
local function dec(s)
    if not s then return s end
    return (s:gsub("&(#?%w+);", function(e)
        local n = e:match("^#[xX](%x+)$"); if n then return cp2utf8(tonumber(n, 16)) end
        n = e:match("^#(%d+)$"); if n then return cp2utf8(tonumber(n)) end
        return ENT[e]
    end))
end
local function txt(h)
    h = (h or ""):gsub("<[^>]+>", " ")
    h = dec(h):gsub("\226\128[\142\143]", ""):gsub("%s+", " ")
    return (h:match("^%s*(.-)%s*$"))
end
local NL = string.char(10)
local function para(h)
    h = (h or ""):gsub("<script.-</script>", ""):gsub("<style.-</style>", "")
    h = h:gsub("</p>", NL .. NL):gsub("<br%s*/?>", NL):gsub("<[^>]+>", "")
    h = dec(h):gsub(string.char(13), ""):gsub(" +", " ")
    h = h:gsub(" *" .. NL .. " *", NL):gsub(NL .. NL .. "+", NL .. NL)
    return (h:match("^%s*(.-)%s*$"))
end
local function attr(tag, n)
    local k = "%f[%w_%-]" .. n:gsub("%-", "%%-") .. "%s*=%s*"
    return tag:match(k .. '"([^"]*)"') or tag:match(k .. "'([^']*)'")
end
local function abs(u) if not u then return nil end if u:sub(1,2)=="//" then return "https:"..u end if u:sub(1,1)=="/" then return BASE..u end return u end
local function enc(s) return (tostring(s):gsub("([^%w%-%._~])", function(c) return string.format("%%%02X", c:byte()) end)) end
local function rel(h) return (h:gsub("^"..BASE:gsub("%p","%%%0"), "")) end
local function norm(h) return (h:gsub("^https?://[^/]+", ""):gsub("[?#].*$", ""):gsub("/+$", ""):lower()) end
local function unnext(u)
    local q = u:match("/_next/image%?url=([^&]+)")
    if not q then return u end
    return (q:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end
local function cover_of(img)
    if not img then return nil end
    for _, k in ipairs({ "data-src", "data-lazy-src", "data-original", "src", "srcset" }) do
        local u = attr(img, k)
        if k == "srcset" and u then u = u:match("^%s*(%S+)") end
        if u and u ~= "" and not u:match("^data:") and not u:lower():find("placeholder", 1, true)
           and not u:lower():find("blank", 1, true) then
            return abs(unnext(dec(u)))
        end
    end
    return nil
end
local function inner(html, from, tn)
    local open, close = "<" .. tn, "</" .. tn
    local depth, p = 1, from
    while true do
        local a = html:find(open, p, true); local b = html:find(close, p, true)
        if not b then return nil end
        if a and a < b then
            if not html:sub(a + #open, a + #open):match("%w") then depth = depth + 1 end
            p = a + #open
        else
            if not html:sub(b + #close, b + #close):match("%w") then
                depth = depth - 1
                if depth == 0 then return html:sub(from, b - 1) end
            end
            p = b + #close
        end
    end
end
local function grab(html, cls)
    local pos = 1
    while true do
        local s, e, tn, attrs = html:find("<(%a%w*)(%s[^>]*)>", pos)
        if not s then return nil end
        local c = attr(attrs, "class")
        if c and c:find(cls, 1, true) then
            local out = inner(html, e + 1, tn)
            if out and #out > 50 then return out end
        end
        pos = e + 1
    end
end

-- ─── parse_list ROBUSTE (accepte plusieurs patterns d'URL + détection par <a><img>) ─
-- azorafly peut utiliser /series/, /novel/, /book/, /books/ ou même /رواية/
-- On accepte tout lien qui contient un de ces patterns, SAUF s'il contient un motif de chapitre.
local LIST_PATTERNS = { "/series/", "/novel/", "/book/", "/books/", "/story/", "/stories/", "/روايات/" }
local CHAP_PATTERNS = { "/chapter-", "/chapter/", "/chapters/", "/chapitre-", "/chapitre/", "/فصل/" }

local function is_series_href(href)
    local clean = href:gsub("[?#].*$", "")
    local found = false
    for _, p in ipairs(LIST_PATTERNS) do
        if clean:find(p, 1, true) then found = true; break end
    end
    if not found then return false end
    for _, p in ipairs(CHAP_PATTERNS) do
        if clean:find(p, 1, true) then return false end
    end
    return true
end

local function parse_list(html)
    local out, idx = {}, {}
    for tag, inner_html in html:gmatch("(<a%s[^>]->)(.-)</a>") do
        local href = attr(tag, "href")
        if href and is_series_href(href) then
            local k = norm(href)
            local img = inner_html:match("<img[^>]->")
            local name = attr(tag, "title") or (img and attr(img, "alt"))
            if name and name ~= "" then name = txt(name) else name = txt(inner_html) end
            local cover = cover_of(img)
            local it = idx[k]
            if it then
                if it.name == "" and name ~= "" then it.name = name end
                if not it.cover and cover then it.cover = cover end
            else
                it = { name = name, path = rel(href), cover = cover }
                idx[k] = it; out[#out+1] = it
            end
        end
    end
    local res = {}
    for _, it in ipairs(out) do if it.name ~= "" then res[#res+1] = it end end
    return res
end

local ext = { id = "azoramoon", name = "Azora Moon", site = BASE, lang = "ar", version = "0.2.2",
    hasReviews = false, chapterCommentsPanel = false }

-- ── Filtres (simplifiés : genre + statut) ──
local FILTERS = {
    { key = "status", label = "الحالة / Statut", default = "", options = {
        { id = "", label = "Tous" },
        { id = "ONGOING", label = "مستمر (En cours)" },
        { id = "COMPLETED", label = "مكتمل (Terminé)" },
    } },
}
ext.popularFilters = FILTERS
ext.searchFilters  = FILTERS

local function has_filters(f) return f and ((f.status or "") ~= "") end
local function filter_url(p, f)
    p = tonumber(p) or 1
    local u = "/series?seriesType=NOVEL"
    if (f.status or "") ~= "" then u = u .. "&seriesStatus=" .. enc(f.status) end
    if p > 1 then u = u .. "&page=" .. p end
    return u
end

-- Essaie plusieurs URLs de catalogue dans l'ordre
local function list_page(p, f)
    if has_filters(f) then return get(filter_url(p, f)) end
    p = tonumber(p) or 1
    local suffix = (p > 1 and ("?page=" .. p) or "")
    local urls = {
        "/novels" .. suffix,
        "/series?seriesType=NOVEL" .. (p > 1 and ("&page=" .. p) or ""),
        "/series" .. suffix,
        "/novel" .. suffix,
        "/books" .. suffix,
    }
    for _, u in ipairs(urls) do
        local h = get(u)
        if h and #h > 3000 and #parse_list(h) > 0 then return h end
    end
    -- dernier recours : première réponse non vide, même si parse_list est vide
    for _, u in ipairs(urls) do
        local h = get(u); if h and #h > 3000 then return h end
    end
    return nil
end

function ext:popularNovels(page, options)
    local html, err = list_page(page, options and options.filters)
    if not html then return { novels = {}, error = "Site injoignable (" .. tostring(err) .. ")" } end
    local list = parse_list(html)
    if #list == 0 then
        local sample = {}
        for tag in html:gmatch("<a%s[^>]->") do
            local h = tag:match('href="([^"]+)"')
            if h and #sample < 20 then sample[#sample+1] = h end
        end
        write_debug("Azora popularNovels VIDE\n"
            .. "Taille : " .. #html
            .. "\nBalises <a : " .. select(2, html:gsub("<a%s", ""))
            .. "\n20 href :\n" .. table.concat(sample, "\n")
            .. "\n\nDébut HTML :\n" .. html:sub(1, 1500))
    end
    return { novels = list }
end

function ext:searchNovels(term, page, options)
    local f = options and options.filters
    term = tostring(term or ""):match("^%s*(.-)%s*$")
    if term == "" then return ext:popularNovels(page, options) end
    if (tonumber(page) or 1) > 1 then return { novels = {} } end
    local q, out, seen = term:lower(), {}, {}
    for p = 1, 5 do
        local html = list_page(p, f); if not html then break end
        local items = parse_list(html); if #items == 0 then break end
        for _, it in ipairs(items) do
            local k = norm(it.path)
            if not seen[k] and it.name:lower():find(q, 1, true) then seen[k] = true; out[#out+1] = it end
        end
    end
    return { novels = out }
end

local function meta(html, path)
    local t = html:match("<h1[^>]*>(.-)</h1>")
    local name = t and txt(t) or ""
    if name == "" then name = dec(html:match('property="og:title"[^>]-content="([^"]*)"') or "") end
    if name == "" then name = path end
    local og = html:match('property="og:description"[^>]-content="([^"]*)"') or ""
    local summary = dec(og)
    local info = {}
    for dt, dd in html:gmatch("<dt[^>]*>(.-)</dt>%s*<dd[^>]*>(.-)</dd>") do info[txt(dt)] = txt(dd) end
    local st = (info["الحالة"] or ""):upper()
    local status = st:find("ONGOING", 1, true) and "ongoing" or (st:find("COMPLETED", 1, true) and "completed" or "")
    return { name = name, path = path,
        cover = abs(dec(html:match('property="og:image"[^>]-content="([^"]*)"') or "")),
        summary = summary, author = info["الكاتب"] or "", status = status, genres = {},
        declared_total = tonumber((info["الفصول"] or ""):match("%d+")) }
end

function ext:parseNovelMeta(path)
    local html = get(path); if not html then return nil end
    local m = meta(html, path); m.total_chapters = m.declared_total or 0; m.declared_total = nil; return m
end

function ext:parseNovel(path)
    local html = get(path); if not html then return nil end
    local m, byn = meta(html, path), {}
    local base = norm(path)
    for tag, inner_html in html:gmatch("(<a%s[^>]->)(.-)</a>") do
        local href = attr(tag, "href")
        if href then
            local n = tonumber(href:match("/chapter%-(%d+)")) or tonumber(href:match("/chapters?/(%d+)"))
            if n and norm(href):find(base, 1, true) == 1 then
                local name = inner_html:match('title="([^"]+)"')
                name = name and txt(name) or ""
                if name == "" then name = "الفصل " .. n end
                byn[n] = { name = name, path = rel((href:gsub("[?#].*$", ""))), chapter_number = n }
            end
        end
    end
    local nums = {}; for n in pairs(byn) do nums[#nums+1] = n end; table.sort(nums)
    local ch = {}; local root = (path:gsub("/+$", ""))
    for i, n in ipairs(nums) do
        local prev = nums[i - 1]
        if prev and n - prev > 3 then
            for k = prev + 1, n - 1 do
                ch[#ch+1] = { name = "الفصل " .. k, path = root .. "/chapter-" .. k, chapter_number = k }
            end
        end
        ch[#ch+1] = byn[n]
    end
    m.declared_total = nil
    m.chapters, m.totalPages = ch, 1
    return m
end

function ext:parseChapter(path)
    local html = get(path); if not html then return "<p>Chapitre injoignable.</p>" end
    html = html:gsub("<script.-</script>", ""):gsub("<style.-</style>", "")
    local box = grab(html, CONT)
    local out = {}
    if box then
        local title = box:match("<h1[^>]*>(.-)</h1>")
        if title and txt(title) ~= "" then out[#out+1] = "<h2>" .. txt(title) .. "</h2>" end
        for p in box:gmatch("<p%f[%s>][^>]*>(.-)</p>") do
            local t = txt(p); if t ~= "" then out[#out+1] = "<p>" .. t .. "</p>" end
        end
    end
    if #out < 2 then return "<p>Texte du chapitre introuvable (classe « " .. CONT .. " »).</p>" end
    return table.concat(out, NL)
end

return ext
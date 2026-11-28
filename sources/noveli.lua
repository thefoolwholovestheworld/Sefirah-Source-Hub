-- Noveli.to — extension Sefirah écrite à la main (API JSON du site, pas de scraping HTML).
local logger = require("logger")
local BASE = "https://noveli.to"
local UA = "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Mobile Safari/537.36"
local LIMIT = 24

local okj, JSON = pcall(require, "rapidjson")
if not okj then JSON = require("json") end

local function get(p)
    local url = p:match("^https?://") and p or (BASE .. p)
    local body, code = require("core.net").get(url, {
        headers = { ["User-Agent"] = UA, ["Referer"] = BASE .. "/", ["Accept"] = "application/json, text/plain, */*" },
        timeout = 20 })
    if body and #body > 2 then return body end
    logger.warn("Noveli.to: échec", url, tostring(code))
    return nil, tostring(code)
end
local function jget(p)
    local body, err = get(p)
    if not body then return nil, err end
    local ok, data = pcall(JSON.decode, body)
    if not ok or type(data) ~= "table" then return nil, "JSON invalide" end
    return data
end

local function enc(s) return (tostring(s):gsub("([^%w%-%._~])", function(c) return string.format("%%%02X", c:byte()) end)) end
local function abs(u) if not u or u == "" then return nil end if u:sub(1,2)=="//" then return "https:"..u end if u:sub(1,1)=="/" then return BASE..u end return u end
local NL = string.char(10)
local function clean(h)
    h = tostring(h or ""):gsub("</p>", NL .. NL):gsub("<br%s*/?>", NL):gsub("<[^>]+>", "")
    h = h:gsub("&amp;", "&"):gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"'):gsub("&#39;", "'"):gsub("&nbsp;", " ")
    h = h:gsub(NL .. NL .. "+", NL .. NL)
    return (h:match("^%s*(.-)%s*$"))
end
local function str(v) if type(v) == "string" then return v end return "" end

local function to_item(n)
    if type(n) ~= "table" or not n.slug then return nil end
    local cover = n.cover_image
    if type(cover) ~= "string" or cover:find("default.jpg", 1, true) then cover = nil end
    return { name = str(n.title), path = "/novel/" .. n.slug, cover = abs(cover) }
end
local function list_from(url)
    local data, err = jget(url)
    if not data then return { novels = {}, error = "Site injoignable (" .. tostring(err) .. ")" } end
    local out = {}
    for _, n in ipairs(data.data or {}) do
        local it = to_item(n)
        if it and it.name ~= "" then out[#out+1] = it end
    end
    return { novels = out }
end

local GENRES = { "Action", "Adventure", "Comedy", "Drama", "Fantasy", "Harem", "Historical", "Horror", "Martial Arts",
    "Mystery", "Psychological", "Romance", "School Life", "Sci-fi", "Slice of Life", "Supernatural", "Tragedy", "Wuxia", "Xianxia", "Teen" }
local function genre_opts()
    local o = { { id = "all", label = "Tous" } }
    for _, g in ipairs(GENRES) do o[#o+1] = { id = g, label = g } end
    return o
end
local FILTERS = {
    { key = "genre", label = "Genre", default = "all", options = genre_opts() },
    { key = "status", label = "Statut", default = "all",
      options = { { id = "all", label = "Tous" }, { id = "Ongoing", label = "En cours" }, { id = "Completed", label = "Terminé" } } },
}
local function fval(f, k)
    local v = f and f[k]
    if v == nil or v == "" or v == "all" then return nil end
    return tostring(v)
end
local function filter_qs(f)
    local q = ""
    local g, st = fval(f, "genre"), fval(f, "status")
    if g then q = q .. "&genre=" .. enc(g) end
    if st then q = q .. "&status=" .. enc(st) end
    return q
end

local ext = { id = "noveli", name = "Noveli.to", site = BASE, lang = "en", version = "0.2.0",
    popularFilters = FILTERS, searchFilters = FILTERS, hasReviews = false, chapterCommentsPanel = false }

function ext:popularNovels(page, options)
    return list_from("/api/novels?page=" .. tostring(page or 1) .. "&limit=" .. LIMIT .. filter_qs(options and options.filters))
end

function ext:searchNovels(term, page, options)
    term = tostring(term or ""):match("^%s*(.-)%s*$")
    if term == "" then return ext:popularNovels(page, options) end
    return list_from("/api/novels?search=" .. enc(term) .. "&page=" .. tostring(page or 1) .. "&limit=" .. LIMIT .. filter_qs(options and options.filters))
end

local function slug_of(path) return path:match("/novel/([^/%?#]+)") end

local function meta(path)
    local slug = slug_of(path)
    if not slug then return nil end
    local res = jget("/api/novels/" .. slug)
    local n = res and res.data
    if type(n) ~= "table" then return nil end
    local genres = {}
    for _, g in ipairs(type(n.genres) == "table" and n.genres or {}) do genres[#genres+1] = tostring(g) end
    local cover = n.cover_image
    if type(cover) ~= "string" or cover:find("default.jpg", 1, true) then cover = nil end
    local st = str(n.status)
    return { name = str(n.title), path = "/novel/" .. slug, cover = abs(cover), summary = (function(t) t = t:gsub("^%s*[Ss]ummary%s*", ""):gsub("%s*[Ss]how [Mm]ore%s*$", ""); return t end)(clean(n.description)),
        author = str(n.author) == "Unknown Author" and "" or str(n.author), status = st, genres = genres,
        total_chapters = tonumber(n.chapter_count) or 0 }
end

function ext:parseNovelMeta(path) return meta(path) end

function ext:parseNovel(path)
    local m = meta(path); if not m then return nil end
    local slug = slug_of(path)
    local ch, seen = {}, {}
    local page, pages = 1, 1
    repeat
        local url = "/api/novels/" .. slug .. "/chapters" .. (page > 1 and ("?page=" .. page) or "")
        local data = jget(url)
        if not data or type(data.chapters) ~= "table" then break end
        local added = 0
        for _, c in ipairs(data.chapters) do
            local cs = c.slug or ("chapter-" .. tostring(c.chapter_number))
            if not seen[cs] then
                seen[cs] = true; added = added + 1
                local title = str(c.title); if title == "" then title = "Chapter " .. tostring(c.chapter_number) end
                ch[#ch+1] = { name = title, n = tonumber(c.chapter_number) or (#ch + 1),
                    path = "/novel/" .. slug .. "/" .. cs .. (c.id and ("?id=" .. tostring(c.id) .. (c.novel_id and ("&nid=" .. tostring(c.novel_id)) or "")) or "") }
            end
        end
        local pg = data.pagination
        if type(pg) == "table" then pages = tonumber(pg.totalPages or pg.total_pages or pg.pages) or 1 end
        if added == 0 then break end
        page = page + 1
    until page > pages or page > 400
    table.sort(ch, function(a, b) return a.n < b.n end)
    for i, c in ipairs(ch) do c.chapter_number = c.n; c.n = nil end
    m.chapters, m.totalPages = ch, 1
    return m
end

-- cherche le texte dans un JSON quelconque : clés usuelles d'abord, sinon la plus longue chaîne
local function find_text(v, best)
    best = best or { s = "" }
    if type(v) == "string" then
        if #v > #best.s then best.s = v end
    elseif type(v) == "table" then
        for k, x in pairs(v) do
            if type(x) == "string" and (k == "content" or k == "text" or k == "body" or k == "html") and #x > 200 then
                best.s = (#x > #best.s) and x or best.s
            end
        end
        for _, x in pairs(v) do find_text(x, best) end
    end
    return best.s
end

local function esc(t) return (tostring(t):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")) end
-- retire les caractères invisibles (espaces de largeur nulle) glissés dans le texte
local function nozw(t)
    return (t:gsub("\226\128[\139\140\141]", ""):gsub("\239\187\191", ""))
end

local function from_paragraphs(chap)
    local out = {}
    for _, p in ipairs(chap.paragraphs or {}) do
        if type(p) == "table" and not p.isHoneypot and not p.isWatermark and not (str(p.html):find("watermark-notice", 1, true)) then
            local h = str(p.html); if h == "" then h = esc(str(p.text)) end
            h = nozw(h)
            if h:match("^%s*<p[%s>]") then out[#out+1] = h
            elseif h:match("^%s*<") then out[#out+1] = "<p>" .. h .. "</p>"
            elseif h:match("%S") then out[#out+1] = "<p>" .. h .. "</p>" end
        end
    end
    if #out == 0 then
        for _, k in ipairs({ "content", "raw_content" }) do
            local c = chap[k]
            if type(c) == "string" and #c > 50 then
                if c:find("<p", 1, true) then return nozw(c) end
                for line in (c .. NL):gmatch("(.-)" .. NL) do
                    if line:match("%S") then out[#out+1] = "<p>" .. esc(nozw(line)) .. "</p>" end
                end
                break
            end
        end
    end
    return #out > 0 and table.concat(out, NL) or nil
end

function ext:parseChapter(path)
    local slug, cslug = path:match("/novel/([^/]+)/([^/%?#]+)")
    local id = path:match("[%?&]id=(%d+)")
    local nid = path:match("[&%?]nid=(%d+)")
    if not slug then return "<p>Adresse de chapitre invalide.</p>" end
    -- liste de chapitres en cache sans id d'œuvre : on le retrouve via la fiche
    if id and not nid then
        local res = jget("/api/novels/" .. slug)
        local n = res and res.data
        if type(n) == "table" and n.id then nid = tostring(n.id) end
    end
    local num = cslug:match("(%d+)$")
    local cands = {}
    if id and nid then cands[#cands+1] = "/api/novels/" .. nid .. "/chapters/" .. id end
    cands[#cands+1] = "/api/novels/" .. slug .. "/chapters/" .. cslug
    if num then cands[#cands+1] = "/api/novels/" .. slug .. "/chapters/" .. num end
    if id then cands[#cands+1] = "/api/chapters/" .. id end
    local tried = {}
    for _, u in ipairs(cands) do
        local data, err = jget(u)
        if data and type(data.chapter) == "table" then
            local html = from_paragraphs(data.chapter)
            if html then return html end
            tried[#tried+1] = "<p>" .. u .. " → chapitre vide</p>"
        else
            tried[#tried+1] = "<p>" .. u .. " → " .. tostring(err or "pas de champ chapter") .. "</p>"
        end
    end
    return "<p>Texte introuvable. Adresses essayées :</p>" .. table.concat(tried)
end

return ext
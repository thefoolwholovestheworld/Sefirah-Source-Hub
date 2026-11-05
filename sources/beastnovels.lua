-- Beast Novels — v0.2.0 (catalogue lu depuis /novels : vraies couvertures, vrais filtres Tri/Statut/Genres, recherche)
local logger = require("logger")
local BASE   = "https://beastnovels.com"
local SEARCH = "https://beastnovels.com/?s={q}"
local LISTP  = "/series/"
local CONT   = "chapter-content"
local UA = "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Mobile Safari/537.36"

local function get(p)
    local url = p:match("^https?://") and p or (BASE .. p)
    local body, code = require("core.net").get(url, { headers = { ["User-Agent"] = UA, ["Referer"] = BASE .. "/" }, timeout = 15 })
    if body and #body > 2 then return body end
    return nil, tostring(code)
end

-- ===== Décodage HTML =====
local function cp2utf8(c)
    if not c or c <= 0 or c > 0x10FFFF then return nil end
    if c < 0x80 then return string.char(c) end
    if c < 0x800 then return string.char(0xC0 + math.floor(c / 64), 0x80 + c % 64) end
    if c < 0x10000 then return string.char(0xE0 + math.floor(c / 4096), 0x80 + math.floor(c / 64) % 64, 0x80 + c % 64) end
    return string.char(0xF0 + math.floor(c / 262144), 0x80 + math.floor(c / 4096) % 64, 0x80 + math.floor(c / 64) % 64, 0x80 + c % 64)
end
local ENT = { amp = "&", lt = "<", gt = ">", quot = '"', apos = "'", nbsp = " ",
    rsquo = "’", lsquo = "‘", ldquo = "“", rdquo = "”", hellip = "…", ndash = "–", mdash = "—" }
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
    h = dec(h):gsub("%s+", " ")
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

-- FONCTION SPLIT MANQUANTE (c'est elle qui causait l'erreur)
local function split(s, sep)
    local t, i = {}, 1
    while true do
        local a = s:find(sep, i, true)
        if not a then t[#t + 1] = s:sub(i); break end
        t[#t + 1] = s:sub(i, a - 1)
        i = a + 1
    end
    return t
end

local function cover_of(img)
    if not img then return nil end
    for _, k in ipairs({ "data-src", "data-lazy-src", "data-original", "src" }) do
        local u = attr(img, k)
        if u and u ~= "" and not u:match("^data:") and not u:lower():find("placeholder") and not u:lower():find("blank") then
            return abs(dec(u))
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
            if out and #out > 20 then return out end
        end
        pos = e + 1
    end
end

-- Un lien de chapitre : finit par /nombre
local function is_chapter_href(href)
    local clean = href:gsub("[?#].*$", ""):gsub("/+$", "")
    local last = clean:match("/([^/]+)$")
    return last ~= nil and last:match("^%d+$") ~= nil
end

local function parse_list(html)
    local out, idx = {}, {}
    for tag, inner_html in html:gmatch("(<a%s[^>]->)(.-)</a>") do
        local href = attr(tag, "href")
        if href and href:find(LISTP, 1, true) and not is_chapter_href(href) then
            local k = norm(href)
            local img = inner_html:match("<img[^>]->")
            local name = attr(tag, "title") or (img and attr(img, "alt"))
            if name and name ~= "" then name = dec(name) else name = txt(inner_html) end
            if name ~= "" and name:lower() ~= "details" and name:lower() ~= "read" then
                local cover = cover_of(img)
                local it = idx[k]
                if it then
                    if it.name == "" and name ~= "" then it.name = name end
                    if not it.cover and cover then it.cover = cover end
                else
                    it = { name = name, path = rel(href), cover = cover }
                    idx[k] = it
                    out[#out+1] = it
                end
            end
        end
    end
    return out
end

-- ===== CATALOGUE =====
-- La page /novels embarque TOUT le catalogue en JSON (variable Alpine « allBooks »,
-- plus « allGenres ») et filtre côté navigateur. On lit donc ce JSON une fois, puis on
-- filtre/trie/pagine ici : vraies couvertures (image_url), vrais genres, statuts, tris.
local function json_decode(str)
    local ok_j, JSON = pcall(require, "rapidjson")
    if not ok_j then JSON = require("json") end
    local ok, data = pcall(JSON.decode, str)
    if not ok then return nil end
    return data
end

-- Extrait le littéral [..] ou {..} qui suit « key: » en respectant les chaînes JSON.
local function extract_literal(html, key, open, close)
    local _, e = html:find(key .. "%s*:%s*%" .. open)
    if not e then return nil end
    local start, depth, i, n = e, 1, e + 1, #html
    local in_str, esc = false, false
    while i <= n do
        local c = html:sub(i, i)
        if in_str then
            if esc then esc = false
            elseif c == "\\" then esc = true
            elseif c == '"' then in_str = false end
        else
            if c == '"' then in_str = true
            elseif c == open then depth = depth + 1
            elseif c == close then
                depth = depth - 1
                if depth == 0 then return html:sub(start, i) end
            end
        end
        i = i + 1
    end
    return nil
end

local function str(v) return type(v) == "string" and v or "" end
local function num(v) return tonumber(v) or 0 end

local catalog, by_slug, genre_names, catalog_t = nil, {}, {}, 0

local function iso_key(s) return str(s) end  -- ISO 8601 : l'ordre alphabétique = l'ordre chronologique

local function load_catalog(force)
    if catalog and not force and (os.time() - catalog_t) < 600 then return catalog end
    local html, err = get("/novels")
    if not html then return catalog, err end
    local arr = extract_literal(html, "allBooks", "[", "]")
    local list = arr and json_decode(arr)
    if type(list) ~= "table" or #list == 0 then return catalog, "catalogue illisible" end
    local gl = extract_literal(html, "allGenres", "{", "}")
    local g = gl and json_decode(gl)
    if type(g) == "table" then genre_names = g end
    local out, idx = {}, {}
    for _, b in ipairs(list) do
        if type(b) == "table" and str(b.bookslug) ~= "" then
            local genres, gn = {}, {}
            if type(b.genres) == "table" then for _, id in ipairs(b.genres) do genres[#genres + 1] = tostring(id) end end
            if type(b.genre_names) == "table" then for _, n in ipairs(b.genre_names) do gn[#gn + 1] = str(n) end end
            local tags = {}
            if type(b.tags) == "table" then for _, t in ipairs(b.tags) do tags[#tags + 1] = str(t) end end
            local it = {
                slug = str(b.bookslug), name = str(b.bookname), author = str(b.author),
                status = str(b.novel_status), type = str(b.novel_type),
                views = num(b.totalview), chapters = num(b.total_number_of_chapter),
                synopsis = str(b.synopsis), cover = abs(str(b.image_url) ~= "" and str(b.image_url) or nil),
                genres = genres, genre_names = gn, tags = tags,
                created = iso_key(b.created_at), updated = iso_key(b.updated_at),
                path = "/series/" .. str(b.bookslug),
            }
            out[#out + 1] = it
            idx[it.slug:lower()] = it
        end
    end
    catalog, by_slug, catalog_t = out, idx, os.time()
    return catalog
end

local function slug_of(path) return (norm(path):match("([^/]+)$") or ""):lower() end

local function pretty_status(s)
    s = str(s)
    if s == "" then return "" end
    return s:sub(1, 1):upper() .. s:sub(2)
end

-- ===== FILTRES =====
local FILTER_SORT = { key = "sort", label = "Tri", default = "latest", options = {
    { id = "latest", label = "Récents" }, { id = "updated", label = "Mis à jour" }, { id = "popular", label = "Populaires" } } }
local FILTER_STATUS = { key = "status", label = "Statut", default = "all", options = {
    { id = "all", label = "Tous" }, { id = "ongoing", label = "En cours" }, { id = "completed", label = "Terminés" },
    { id = "hiatus", label = "En pause" }, { id = "dropped", label = "Abandonnés" } } }
-- Genres : liste par défaut, remplacée par celle du site (ext:loadFilters).
local FILTER_GENRE = { key = "genre", label = "Genres", default = "", multi = true, options = {
    { id = "3", label = "Action" }, { id = "6", label = "Adventure" }, { id = "8", label = "Comedy" },
    { id = "5", label = "Fantasy" }, { id = "7", label = "Shounen" } } }
local POPULAR_FILTERS = { FILTER_SORT, FILTER_STATUS, FILTER_GENRE }

local function sorted_ids(map)
    local ids = {}
    for id in pairs(map) do ids[#ids + 1] = tostring(id) end
    table.sort(ids, function(a, b)
        return (map[a] or map[tonumber(a)] or a):lower() < (map[b] or map[tonumber(b)] or b):lower()
    end)
    return ids
end

local PER_PAGE = 20

local function query(term, page, options)
    local list, err = load_catalog()
    if not list then return { novels = {}, error = "Site injoignable (" .. tostring(err) .. ")" } end
    local f = options and options.filters or {}
    local status = f.status and f.status ~= "all" and f.status ~= "" and f.status or nil
    local want = {}
    if type(f.genre) == "string" and f.genre ~= "" then
        for id in f.genre:gmatch("[^,]+") do want[#want + 1] = id end
    end
    local q = term and term:lower() or ""
    local res = {}
    for _, b in ipairs(list) do
        local ok = true
        if q ~= "" and not b.name:lower():find(q, 1, true) then ok = false end
        if ok and status and b.status ~= status then ok = false end
        if ok and #want > 0 then
            local has = {}
            for _, g in ipairs(b.genres) do has[g] = true end
            for _, id in ipairs(want) do if not has[id] then ok = false; break end end
        end
        if ok then res[#res + 1] = b end
    end
    local sort = f.sort or "latest"
    if sort == "popular" then table.sort(res, function(a, b) return a.views > b.views end)
    elseif sort == "updated" then table.sort(res, function(a, b) return a.updated > b.updated end)
    else table.sort(res, function(a, b) return a.created > b.created end) end
    page = tonumber(page) or 1
    local out = {}
    for i = (page - 1) * PER_PAGE + 1, math.min(page * PER_PAGE, #res) do
        local b = res[i]
        out[#out + 1] = { name = b.name, path = b.path, cover = b.cover, author = b.author }
    end
    return { novels = out }
end

local ext = { id = "beastnovels", name = "Beast Novels", site = BASE, lang = "en", version = "0.2.0",
    popularFilters = POPULAR_FILTERS, searchFilters = POPULAR_FILTERS, hasReviews = false, chapterCommentsPanel = false }

-- Relit les genres sur le site à la 1re ouverture de « Filtrer ».
function ext:loadFilters()
    load_catalog(true)
    if next(genre_names) then
        local opts = {}
        for _, id in ipairs(sorted_ids(genre_names)) do
            opts[#opts + 1] = { id = id, label = genre_names[id] or genre_names[tonumber(id)] or id }
        end
        if #opts > 0 then FILTER_GENRE.options = opts end
    end
    self.filters_ready = true
end

function ext:popularNovels(page, options)
    local r = query(nil, page, options)
    if r.error then
        -- Repli : page d'accueil (ancienne méthode) si le catalogue est inaccessible.
        local html = get("/")
        if html and (tonumber(page) or 1) == 1 then
            local l = parse_list(html)
            if #l > 0 then return { novels = l } end
        end
    end
    return r
end

function ext:searchNovels(term, page, options)
    term = tostring(term or ""):match("^%s*(.-)%s*$")
    return query(term, page, options)
end

local function meta(html, path)
    local t = html:match("<h1[^>]*>(.-)</h1>")
    local name = t and txt(t) or ""
    if name == "" then name = dec(html:match('property="og:title"[^>]-content="([^"]*)"') or "") end
    if name == "" then name = path end
    
    local summary = dec(html:match('<meta name="description" content="([^"]+)"') or
                        html:match('<meta property="og:description" content="([^"]+)"') or "")
    if summary == "" then
        local desc_block = grab(html, "description") or grab(html, "summary") or grab(html, "synopsis")
        if desc_block then summary = para(desc_block) end
    end
    
    local cover = abs(dec(html:match('<meta property="og:image" content="([^"]+)"') or
                          html:match('<meta name="twitter:image" content="([^"]+)"') or ""))
    if not cover or cover == "" then
        for img_tag in html:sub(1, 15000):gmatch("<img[^>]->") do
            local u = cover_of(img_tag)
            if u and not u:find("logo") and not u:find("icon") then
                cover = u
                break
            end
        end
    end

    local m = { name = name, path = path, cover = cover, summary = summary, author = "", status = "", genres = {} }

    -- Le catalogue (/novels) connaît la vraie couverture, l'auteur, le statut et les genres :
    -- on s'en sert en priorité (la fiche n'a pas toujours d'og:image exploitable).
    pcall(load_catalog)
    local b = by_slug[slug_of(path)]
    if b then
        if b.cover and b.cover ~= "" then m.cover = b.cover end
        if b.name ~= "" and (m.name == "" or m.name == path) then m.name = b.name end
        if b.author ~= "" then m.author = b.author end
        if b.status ~= "" then m.status = pretty_status(b.status) end
        if #b.genre_names > 0 then m.genres = b.genre_names end
        if b.synopsis ~= "" then
            local syn = para(b.synopsis)
            if syn ~= "" then m.summary = syn end
        end
    end
    return m
end

function ext:parseNovelMeta(path)
    local html = get(path); if not html then return nil end
    local m = meta(html, path); m.total_chapters = 0; return m
end

function ext:parseNovel(path)
    local html = get(path); if not html then return nil end
    local m, ch, seen = meta(html, path), {}, {}
    local base = norm(path)
    for tag, inner_html in html:gmatch("(<a%s[^>]->)(.-)</a>") do
        local href = attr(tag, "href")
        if href then
            local k = norm(href)
            if k:sub(1, #base + 1) == base .. "/" and is_chapter_href(href) and not seen[k] then
                seen[k] = true
                local num = tonumber(href:match("/(%d+)/*$"))
                local name = "Chapitre " .. (num or (#ch + 1))
                
                local raw_name = txt(inner_html)
                local clean_name = raw_name:match("CHAPTER%s*(%d+)") or raw_name:match("^Ch%.%s*(%d+)")
                if clean_name then name = "Chapitre " .. clean_name end

                ch[#ch+1] = { name = name, path = rel(href), chapter_number = num or (#ch + 1) }
            end
        end
    end
    table.sort(ch, function(a, b) return (a.chapter_number or 0) < (b.chapter_number or 0) end)
    for i, c in ipairs(ch) do c.chapter_number = i end
    m.chapters, m.totalPages = ch, 1
    return m
end

function ext:parseChapter(path)
    local html = get(path); if not html then return "<p>Chapitre injoignable.</p>" end
    html = html:gsub("<script.-</script>", ""):gsub("<style.-</style>", "")
    
    local body = grab(html, CONT) 
    
    if not body then
        local ps, n = {}, 0
        for p in html:gmatch("<p%f[%s>][^>]*>(.-)</p>") do
            local t = txt(p)
            if #t > 1 then ps[#ps+1] = "<p>" .. p .. "</p>"; n = n + #t end
        end
        if #ps >= 3 and n > 300 then body = table.concat(ps) end
    end
    
    if not body or #body < 50 then return "<p>Texte du chapitre introuvable.</p>" end
    return body
end

return ext
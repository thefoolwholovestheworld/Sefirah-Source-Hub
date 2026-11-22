-- Sefirah est un FORK de Mythos (https://github.com/unitreign/Mythos)
-- par unitreign, sous licence GPL-3.0. Modifié par thefoolwholovestheworld.
-- Sefirah is a FORK of Mythos by unitreign (GPL-3.0), modified by thefoolwholovestheworld.

-- Chikari — source manga réécrite à la main (v0.7.1), via l'API JSON du site.
--   liste + recherche : /api/series?limit=24&offset=N&q=...&sort=...&type=...&genre=...&tag=...&status=...
--   genres : en dur (confirmés)      tags : /api/tags?novels=true (chargés une fois puis mis en cache sur la liseuse)
local logger = require("logger")
local BASE = "https://chikari.moe"
local UA = "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Mobile Safari/537.36"
local PER = 24

-- Façon d'envoyer les valeurs multiples (genres, types, tags) :
--   "repeat" -> genre=action&genre=comedy      "comma" -> genre=action,comedy
-- Si cocher plusieurs genres/types renvoie n'importe quoi ou rien, essaie "comma".
local MULTI_MODE = "repeat"

local JSON
do
    local ok, J = pcall(require, "rapidjson")
    if not ok then J = require("json") end
    JSON = J
end

local function get(p, extra)
    local url = p:match("^https?://") and p or (BASE .. p)
    local o = { headers = { ["User-Agent"] = UA, ["Referer"] = BASE .. "/", ["Accept"] = "application/json, text/plain, */*" }, timeout = 20 }
    for k, v in pairs(extra or {}) do o[k] = v end
    local body, code = require("core.net").get(url, o)
    if body and #body >= 2 then return body end -- « [] » (aucun résultat) fait 2 caractères
    logger.warn("Chikari: échec", url, tostring(code))
    return nil, tostring(code)
end
local function getjson(p, extra)
    local body, err = get(p, extra)
    if not body then return nil, err end
    local ok, d = pcall(JSON.decode, body)
    if ok and type(d) == "table" then return d end
    return nil, "réponse non JSON"
end

local function enc(s) return (tostring(s):gsub("([^%w%-%._~])", function(c) return string.format("%%%02X", c:byte()) end)) end
local function abs(u)
    if not u or u == "" then return nil end
    if u:sub(1, 2) == "//" then return "https:" .. u end
    if u:sub(1, 1) == "/" then return BASE .. u end
    return u
end
local function pick(t, names)
    if type(t) ~= "table" then return nil end
    for _, k in ipairs(names) do
        local v = t[k]
        if v ~= nil and v ~= "" and type(v) ~= "table" then return v end
    end
    return nil
end
local function find_list(d)
    if type(d) ~= "table" then return nil end
    if #d > 0 then return d end
    for _, k in ipairs({ "items", "results", "data", "series", "chapters", "pages", "images" }) do
        local v = d[k]
        if type(v) == "table" then
            if #v > 0 then return v end
            local s = find_list(v)
            if s then return s end
        end
    end
    return nil
end

-- le chemin d'une œuvre est son slug : « /series/<slug> »
local function slug_of(path) return tostring(path):match("/series/([^/?#]+)") end
local function to_novel(o)
    if type(o) ~= "table" or o.is_nsfw == true then return nil end
    local slug, title = pick(o, { "slug" }), pick(o, { "title", "name" })
    if not slug or not title then return nil end
    return { name = tostring(title), path = "/series/" .. slug, cover = abs(pick(o, { "cover_url", "cover", "image" })) }
end
local function to_list(d)
    local list = find_list(d)
    if not list then return nil end
    local out = {}
    for _, o in ipairs(list) do
        local n = to_novel(o)
        if n then out[#out + 1] = n end
    end
    return out
end

-- ===== Filtres (format de Sefirah : options = { {id, label} }, multi = « id1,id2 ») =====
local function opts(list)
    local o = {}
    for _, p in ipairs(list) do o[#o + 1] = { id = p[1], label = p[2] } end
    return o
end
-- liste multi-choix : « Tous » (id "") = rien de coché
local function multi_opts(list)
    local o = { { id = "", label = "Tous" } }
    for _, p in ipairs(list) do o[#o + 1] = { id = tostring(p[1]), label = p[2] } end
    return o
end

-- genres confirmés via /api/genres?novels=true (genres explicites retirés : is_nsfw est déjà masqué)
local GENRES = {
    { "action", "Action" }, { "adventure", "Adventure" }, { "award_winning", "Award Winning" },
    { "boys_love", "Boys Love" }, { "comedy", "Comedy" }, { "drama", "Drama" }, { "ecchi", "Ecchi" },
    { "fantasy", "Fantasy" }, { "gender_bender", "Gender Bender" }, { "girls_love", "Girls Love" },
    { "gourmet", "Gourmet" }, { "harem", "Harem" }, { "historical", "Historical" }, { "horror", "Horror" },
    { "josei", "Josei" }, { "mahou_shoujo", "Mahou Shoujo" }, { "martial_arts", "Martial Arts" },
    { "mature", "Mature" }, { "mecha", "Mecha" }, { "music", "Music" }, { "mystery", "Mystery" },
    { "psychological", "Psychological" }, { "romance", "Romance" }, { "school_life", "School Life" },
    { "sci-fi", "Sci-Fi" }, { "seinen", "Seinen" }, { "shoujo", "Shoujo" }, { "shoujo_ai", "Shoujo Ai" },
    { "shounen", "Shounen" }, { "shounen_ai", "Shounen Ai" }, { "slice_of_life", "Slice of Life" },
    { "sports", "Sports" }, { "supernatural", "Supernatural" }, { "suspense", "Suspense" },
    { "thriller", "Thriller" }, { "tragedy", "Tragedy" }, { "yaoi", "Yaoi" }, { "yuri", "Yuri" },
}

local FILTERS = {
    { key = "sort", label = "Tri", default = "popular",
      options = opts({ { "popular", "Populaires" }, { "top_rated", "Mieux notés" } }) },
    { key = "status", label = "Statut", default = "all",
      options = opts({ { "all", "Tous" }, { "ongoing", "En cours" }, { "completed", "Terminé" } }) }, -- « ongoing » non confirmé
    { key = "type", label = "Type", default = "", multi = true,
      options = multi_opts({ { "manga", "Manga" }, { "manhwa", "Manhwa" }, { "manhua", "Manhua" }, { "novel", "Novel" } }) },
    { key = "genre", label = "Genres", default = "", multi = true, options = multi_opts(GENRES) },
}

-- ===== Tags : chargés une fois, puis gardés dans un fichier de cache sur la liseuse =====
local TAG_MIN_COUNT = 50
local TAG_MAX_LIST = 100 -- seuls les tags les plus utilisés sont proposés
local ALL_TAGS = nil
local tags_added = false

local function cache_path()
    local ok, DS = pcall(require, "datastorage")
    if not ok or not DS then return nil end
    local ok2, dir = pcall(function() return DS:getSettingsDir() end)
    if not ok2 or not dir then return nil end
    return dir .. "/chikari_tags.json"
end
local function read_cache()
    local path = cache_path()
    if not path then return nil end
    local f = io.open(path, "r")
    if not f then return nil end
    local s = f:read("*a"); f:close()
    local ok, d = pcall(JSON.decode, s)
    if ok and type(d) == "table" and #d > 0 then return d end
    return nil
end
local function write_cache(all)
    local path = cache_path()
    if not path then return end
    local ok, s = pcall(JSON.encode, all)
    if not ok or type(s) ~= "string" then return end
    local f = io.open(path, "w")
    if f then f:write(s); f:close() end
end

local function add_tag_filter()
    if tags_added or not ALL_TAGS then return end
    local o = { { id = "", label = "Tous" } }
    for _, t in ipairs(ALL_TAGS) do
        if #o > TAG_MAX_LIST then break end
        if t.count >= TAG_MIN_COUNT then
            o[#o + 1] = { id = t.id, label = t.name .. (t.root and (" · " .. t.root) or "") }
        end
    end
    if #o > 1 then
        FILTERS[#FILTERS + 1] = { key = "tag", label = "Tags", default = "", multi = true, options = o }
        tags_added = true
    end
end

local function load_tags()
    if ALL_TAGS then add_tag_filter(); return true end
    local all = read_cache()
    if not all then
        local d = getjson("/api/tags?novels=true", { timeout = 30, deadline = 90, retries = 2 })
        local list = d and find_list(d)
        if not list then return false end
        all = {}
        for _, t in ipairs(list) do
            local id, name = tonumber(pick(t, { "id" })), pick(t, { "name" })
            if id and name then
                all[#all + 1] = { id = string.format("%d", id), name = tostring(name), root = pick(t, { "root_name" }), count = tonumber(t.count) or 0 }
            end
        end
        if #all == 0 then return false end
        table.sort(all, function(a, b) return a.count > b.count end)
        write_cache(all)
    end
    ALL_TAGS = all
    add_tag_filter()
    return true
end

-- valeurs « a,b » -> liste sans doublons ni vides
local function csv_list(s)
    local out, seen = {}, {}
    for raw in tostring(s or ""):gmatch("[^,]+") do
        local x = (raw:gsub("^%s+", ""):gsub("%s+$", ""))
        if x ~= "" and not seen[x] then seen[x] = true; out[#out + 1] = x end
    end
    return out
end
local function add_multi(q, key, values)
    if #values == 0 then return end
    if MULTI_MODE == "comma" then
        q[#q + 1] = key .. "=" .. enc(table.concat(values, ","))
    else
        for _, v in ipairs(values) do q[#q + 1] = key .. "=" .. enc(v) end
    end
end

-- sélection -> paramètres d'URL
local function build_query(filters)
    local q = {}
    filters = filters or {}
    local sort = tostring(filters.sort or "")
    if sort == "" or sort == "all" then sort = "popular" end
    q[#q + 1] = "sort=" .. enc(sort)
    local st = tostring(filters.status or "")
    if st ~= "" and st ~= "all" then q[#q + 1] = "status=" .. enc(st) end
    add_multi(q, "type", csv_list(filters.type))
    add_multi(q, "genre", csv_list(filters.genre))
    add_multi(q, "tag", csv_list(filters.tag))
    return "&" .. table.concat(q, "&")
end

local ext = { id = "chikari", name = "Chikari", site = BASE, lang = "en", version = "0.8.1",
    type = "manga", popularFilters = FILTERS, searchFilters = FILTERS, hasReviews = true, chapterCommentsPanel = false }

-- appelé par Sefirah à la 1re ouverture du panneau de filtres ; si les tags n'ont pas pu être chargés,
-- on ne marque pas les filtres « prêts » : la prochaine ouverture réessaie.
function ext:loadFilters()
    if load_tags() then self.filters_ready = true end
end

local function list_series(page, term, options)
    local filters = options and options.filters or {}
    local pg = math.max(tonumber(page) or 1, 1)
    local url = "/api/series?limit=" .. PER .. "&offset=" .. ((pg - 1) * PER)
    if term and term ~= "" then url = url .. "&q=" .. enc(term) end
    local d, err = getjson(url .. build_query(filters))
    if not d then
        if pg > 1 then return { novels = {} } end
        return { novels = {}, error = "Liste impossible (" .. tostring(err or "réponse inattendue") .. ")" }
    end
    return { novels = to_list(d) or {} }
end

function ext:popularNovels(page, options)
    return list_series(page, nil, options)
end

function ext:searchNovels(term, page, options)
    term = tostring(term or ""):match("^%s*(.-)%s*$")
    return list_series(page, term, options)
end

-- fiche : /api/series/<slug> (confirmé : id, description, genres, authors, chapter_count, chapters_head/tail…)
local function load_series(slug)
    local d = getjson("/api/series/" .. enc(slug))
    if type(d) == "table" and pick(d, { "title", "name" }) then return d end
    return nil
end

local function meta_of(path, j)
    local m = { path = path, genres = {} }
    if j then
        m.name = tostring(pick(j, { "title", "name" }) or path)
        m.summary = tostring(pick(j, { "description", "synopsis", "summary" }) or "")
        m.author = tostring(pick(j, { "author" }) or "")
        if m.author == "" and type(j.authors) == "table" then
            local names, seen = {}, {}
            for _, a in ipairs(j.authors) do
                if type(a) == "table" and a.name and not seen[a.name] then seen[a.name] = true; names[#names + 1] = a.name end
            end
            m.author = table.concat(names, ", ")
        end
        m.status = tostring(pick(j, { "status" }) or "")
        m.cover = abs(pick(j, { "cover_url", "cover" }))
        if type(j.genres) == "table" then
            for _, g in ipairs(j.genres) do
                local gv = type(g) == "table" and pick(g, { "name", "title" }) or g
                if gv then m.genres[#m.genres + 1] = tostring(gv) end
            end
        end
    else
        m.name = path
    end
    return m
end

function ext:parseNovelMeta(path)
    local slug = slug_of(path); if not slug then return nil end
    local m = meta_of(path, load_series(slug))
    m.total_chapters = 0
    return m
end

local function fmtnum(n) return (n == math.floor(n)) and string.format("%d", n) or tostring(n) end

function ext:parseNovel(path)
    local slug = slug_of(path); if not slug then return nil end
    local j = load_series(slug)
    local m = meta_of(path, j)
    local nums, seen, titles = {}, {}, {}
    local function add(n, t)
        n = tonumber(n)
        if n and not seen[n] then seen[n] = true; nums[#nums + 1] = n end
        if n and t and t ~= "" then titles[n] = tostring(t) end
    end
    -- 1) liste complète, 100 chapitres par requête (maximum accepté par le site)
    local got, total = 0, nil
    for _ = 1, 80 do
        local d = getjson("/api/series/" .. enc(slug) .. "/chapters?order=desc&limit=100&offset=" .. got)
        local items = d and find_list(d)
        if not items or #items == 0 then break end
        for _, o in ipairs(items) do
            if type(o) == "table" then add(pick(o, { "number", "chapter", "chapter_number" }), pick(o, { "title" })) end
        end
        got = got + #items
        total = tonumber(d.total) or total
        if total and got >= total then break end
    end
    -- 2) repli : début/fin de la fiche + tous les entiers de 1 au dernier chapitre
    if #nums == 0 and j then
        for _, k in ipairs({ "chapters_head", "chapters_tail" }) do
            for _, o in ipairs(type(j[k]) == "table" and j[k] or {}) do add(type(o) == "table" and o.number or nil) end
        end
        local top = tonumber(j.latest_number) or tonumber(j.chapter_count) or 0
        for n = 1, math.floor(top) do add(n) end
    end
    table.sort(nums)
    local ch = {}
    for i, n in ipairs(nums) do
        ch[i] = { name = "Chapter " .. fmtnum(n) .. (titles[n] and (": " .. titles[n]) or ""), path = "/series/" .. slug .. "?chapter=" .. fmtnum(n), chapter_number = i }
    end
    m.chapters, m.totalPages, m.total_chapters = ch, 1, #ch
    return m
end

-- pages du chapitre : première liste d'adresses d'images trouvée dans la réponse JSON
local function image_url(v)
    if type(v) == "string" then return v end
    if type(v) == "table" then return pick(v, { "url", "src", "image", "image_url", "path" }) end
end
local function find_images(t, depth)
    depth = depth or 0
    if type(t) ~= "table" or depth > 6 then return nil end
    if #t > 0 then
        local out = {}
        for _, v in ipairs(t) do
            local u = image_url(v)
            if u and u:lower():match("%.[%a]+[%?]?") and (u:find("/", 1, true)) then out[#out + 1] = abs(u) end
        end
        if #out >= 1 and #out >= #t * 0.8 then return out end
    end
    for _, k in ipairs({ "pages", "images", "data", "chapter", "items" }) do
        local r = find_images(t[k], depth + 1)
        if r then return r end
    end
    for _, v in pairs(t) do
        if type(v) == "table" then
            local r = find_images(v, depth + 1)
            if r then return r end
        end
    end
    return nil
end

function ext:parseChapterImages(path)
    local slug, num = slug_of(path), tostring(path):match("[?&]chapter=([%d%.]+)")
    if not slug or not num then return nil, "chapter_unreachable" end
    local s1 = enc(slug)
    local tried = {}
    for _, u in ipairs({
        "/api/series/" .. s1 .. "/chapters/" .. num,
        "/api/series/" .. s1 .. "/chapters/" .. num .. "/pages",
        "/api/series/" .. s1 .. "/chapter/" .. num,
        "/api/series/" .. s1 .. "/chapter/" .. num .. "/pages",
        "/api/series/" .. s1 .. "/read/" .. num,
        "/api/chapters/" .. s1 .. "/" .. num,
    }) do
        local d, err = getjson(u)
        local imgs = d and find_images(d)
        if imgs then return { images = imgs, headers = { ["User-Agent"] = UA, ["Referer"] = BASE .. "/" } } end
        tried[#tried + 1] = u:gsub("^/api/series/[^/]+", "") .. " " .. (d and "sans images" or tostring(err))
    end
    return nil, "Pages introuvables: " .. table.concat(tried, " | ")
end

-- ===== Avis de la fiche =====
--   /api/series/<slug>/reviews?limit=20&offset=N&sort=top
-- Contrat Sefirah : ext:parseReviews(path, page, sort) -> { reviews = { {id, parent_id, author, avatar,
--   rating, content, likes, date} }, has_more = bool }   avec sort = "newest" | "oldest" | "mostliked".
local REVIEWS_PER = 20
local REVIEW_SORT = { newest = "new", oldest = "old", mostliked = "top" } -- seul « top » est confirmé

-- rapidjson décode le JSON null en une valeur truthy (userdata) : on ne garde que les vrais types.
local function str(v) return type(v) == "string" and v ~= "" and v or nil end
local function num(v) return type(v) == "number" and v or nil end

-- texte brut depuis body_json : spoilers masqués (« body » les laisse en clair), images signalées
local function body_text(j, fallback)
    if type(j) ~= "table" or type(j.content) ~= "table" then return str(fallback) or "" end
    local out = {}
    for _, para in ipairs(j.content) do
        if type(para) == "table" then
            if para.type == "image" then
                out[#out + 1] = "[image]"
            elseif para.type == "paragraph" then
                local line = {}
                for _, n in ipairs(type(para.content) == "table" and para.content or {}) do
                    local spoiler = false
                    for _, m in ipairs(type(n.marks) == "table" and n.marks or {}) do
                        if m.type == "spoiler" then spoiler = true end
                    end
                    line[#line + 1] = spoiler and "[spoiler]" or (str(n.text) or "")
                end
                out[#out + 1] = table.concat(line)
            end
        end
    end
    return (table.concat(out, "\n"):gsub("\n\n\n+", "\n\n"):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function to_review(o)
    if type(o) ~= "table" or o.is_deleted == true or o.is_blocked == true then return nil end
    local a = type(o.author) == "table" and o.author or {}
    local anon = o.is_anonymous == true
    local content = body_text(o.body_json, o.body)
    local title = str(o.title)
    if title then content = title .. (content ~= "" and ("\n\n" .. content) or "") end
    local id = num(o.id)
    local parent = num(o.parent_id)
    return {
        id = id and string.format("%d", id) or nil,
        parent_id = parent and string.format("%d", parent) or nil,
        author = anon and "Anonyme" or (str(a.username) or "Anonyme"),
        avatar = (not anon) and abs(str(a.avatar_url)) or nil,
        rating = num(o.rating), -- sur 10 côté site, affiché tel quel par Sefirah (« 9★ »)
        content = content,
        likes = num(o.score) or 0,
        date = str(o.created_at),
    }
end

function ext:parseReviews(path, page, sort)
    local slug = slug_of(path)
    if not slug then return { reviews = {}, has_more = false, error = "chemin invalide" } end
    local pg = math.max(tonumber(page) or 1, 1)
    local d, err = getjson("/api/series/" .. enc(slug) .. "/reviews?limit=" .. REVIEWS_PER
        .. "&offset=" .. ((pg - 1) * REVIEWS_PER) .. "&sort=" .. (REVIEW_SORT[sort or "mostliked"] or "top"))
    if not d then return { reviews = {}, has_more = false, error = tostring(err or "réponse inattendue") } end
    local list = type(d.reviews) == "table" and d.reviews or {}
    local out = {}
    for _, o in ipairs(list) do
        local r = to_review(o)
        if r then out[#out + 1] = r end
    end
    local total = num(d.total)
    return { reviews = out, has_more = #list >= REVIEWS_PER and (not total or pg * REVIEWS_PER < total) }
end

function ext:parseChapter() return "<p>Ce chapitre est un manga : il s'ouvre dans le lecteur d'images.</p>" end

return ext

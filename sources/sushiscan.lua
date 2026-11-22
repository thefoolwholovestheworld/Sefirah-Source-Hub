-- Sushiscan — source générée par Sefirah Source Hub (modèle sans IA). À relire et tester.
-- Contrat : voir extensions/mangapill.lua du plugin Sefirah.
local logger = require("logger")
local T = require("core.i18n").T
local BASE   = "https://sushiscan.net"
local SEARCH = "https://sushiscan.net/?s={q}"
local LISTP  = "/catalogue/"
local CHAPP  = "chapitre-"
local CONT   = ""
local UA = "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Mobile Safari/537.36"

local function get(p)
    local url = p:match("^https?://") and p or (BASE .. p)
    local body, code = require("core.net").get(url, { headers = { ["User-Agent"] = UA, ["Referer"] = BASE .. "/" }, timeout = 15 })
    if body and #body > 2 then return body end
    logger.warn("Sushiscan: échec", url, tostring(code))
    return nil, tostring(code)
end

-- ===== décodage des entités HTML (&#x27; &#39; &amp; &eacute; …) en une seule passe =====
local function cp2utf8(c)
    if not c or c <= 0 or c > 0x10FFFF then return nil end
    if c < 0x80 then return string.char(c) end
    if c < 0x800 then return string.char(0xC0 + math.floor(c / 64), 0x80 + c % 64) end
    if c < 0x10000 then return string.char(0xE0 + math.floor(c / 4096), 0x80 + math.floor(c / 64) % 64, 0x80 + c % 64) end
    return string.char(0xF0 + math.floor(c / 262144), 0x80 + math.floor(c / 4096) % 64, 0x80 + math.floor(c / 64) % 64, 0x80 + c % 64)
end
local ENT = { amp = "&", lt = "<", gt = ">", quot = '"', apos = "'", nbsp = " ",
    rsquo = "’", lsquo = "‘", ldquo = "“", rdquo = "”", hellip = "…", ndash = "–", mdash = "—", laquo = "«", raquo = "»",
    eacute = "é", egrave = "è", ecirc = "ê", euml = "ë", agrave = "à", acirc = "â", ccedil = "ç", icirc = "î", iuml = "ï",
    ocirc = "ô", ugrave = "ù", ucirc = "û", uuml = "ü", oelig = "œ", Eacute = "É", Egrave = "È", Agrave = "À", Ccedil = "Ç" }
local function dec(s)
    if not s then return s end
    return (s:gsub("&(#?%w+);", function(e)
        local n = e:match("^#[xX](%x+)$")
        if n then return cp2utf8(tonumber(n, 16)) end
        n = e:match("^#(%d+)$")
        if n then return cp2utf8(tonumber(n)) end
        return ENT[e]
    end))
end
local function txt(h)
    h = (h or ""):gsub("<[^>]+>", " ")
    h = dec(h):gsub("%s+", " ")
    return (h:match("^%s*(.-)%s*$"))
end
local NL = string.char(10)
local function para(h) -- texte avec paragraphes (descriptions)
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
-- clé de comparaison d'un lien : sans domaine, sans ?query, sans # ni / final, en minuscules
local function norm(h)
    h = h:gsub("^https?://[^/]+", ""):gsub("[?#].*$", ""):gsub("/+$", "")
    return h:lower()
end
-- /_next/image?url=XXX&w=… (Next.js) -> l'image d'origine XXX
local function unnext(u)
    local q = u:match("/_next/image%?url=([^&]+)")
    if not q then return u end
    return (q:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end
-- adresse d'image inutilisable (img/None, null, undefined…)
local function bad_cover(u)
    local last = (u:gsub("[?#].*$", ""):match("([^/]*)$") or ""):lower()
    return last == "" or last == "none" or last == "null" or last == "undefined" or last == "nan" or last == "false"
end
local function cover_of(img)
    if not img then return nil end
    for _, k in ipairs({ "data-src", "data-lazy-src", "data-original", "src", "srcset" }) do
        local u = attr(img, k)
        if k == "srcset" and u then u = u:match("^%s*(%S+)") end
        if u and u ~= "" and not u:match("^data:") and not u:lower():find("placeholder", 1, true) and not u:lower():find("blank", 1, true) and not bad_cover(u) then
            return abs(unnext(dec(u)))
        end
    end
    return nil
end

-- contenu (équilibré) de la balise ouverte en position "from" : gère les <div> imbriquées
local function inner(html, from, tn)
    local open, close = "<" .. tn, "</" .. tn
    local depth, p = 1, from
    while true do
        local a = html:find(open, p, true)
        local b = html:find(close, p, true)
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
-- premier élément (div, article, section…) dont la classe contient cls ; renvoie son contenu complet
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

-- contenu de l'élément dont l'attribut id vaut `id` (ex. la liste #chapterlist)
local function block_by_id(html, id)
    local p = html:find('id="' .. id .. '"', 1, true) or html:find("id='" .. id .. "'", 1, true)
    if not p then return nil end
    local ts = p
    while ts > 1 and html:sub(ts, ts) ~= "<" do ts = ts - 1 end
    local tn = html:match("^<(%a%w*)", ts)
    local _, e = html:find(">", p, true)
    if not (tn and e) then return nil end
    return inner(html, e + 1, tn)
end

-- Masqués dans les listes : faux « mangas » sans chapitres et contenu +18 (liste modifiable)
local HIDE_TITLES = { ["catalogue textuel"] = true, ["velvet kiss"] = true, ["i want to see u shy"] = true }
local ADULT_WORDS = { "18+", "+18", "hentai", "adult" }
local function hidden_card(name, card_html)
    if HIDE_TITLES[(name or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")] then return true end
    local low = (card_html or ""):lower()
    for _, w in ipairs(ADULT_WORDS) do
        if low:find(w, 1, true) then return true end
    end
    return false
end

-- liste et chapitres sous le même préfixe (ex. /read/123/ et /read/123/p4.html) : l'œuvre est le lien court, le chapitre le lien long
local function after_list(h)
    local s, e = norm(h):find(LISTP:lower(), 1, true)
    if not s then return nil end
    return norm(h):sub(e + 1)
end
local function is_work(h)
    if LISTP == "" or not h:find(LISTP, 1, true) then return false end
    if CHAPP ~= "" and h:find(CHAPP, 1, true) then
        if CHAPP ~= LISTP then return false end
        local a = after_list(h)
        return a ~= nil and a ~= "" and not a:find("/", 1, true)
    end
    return true
end
local function is_chap(h)
    if CHAPP == "" or not h:find(CHAPP, 1, true) then return false end
    if CHAPP == LISTP then
        local a = after_list(h)
        return a ~= nil and a:find("/", 1, true) ~= nil
    end
    return true
end

local function parse_list(html)
    local out, idx = {}, {}
    for tag, inner_html in html:gmatch("(<a%s[^>]->)(.-)</a>") do
        local href = attr(tag, "href")
        if href and is_work(href) then
            local k = norm(href)
            local img = inner_html:match("<img[^>]->")
            local title = attr(tag, "title")
            if title == "" then title = nil end
            local name = title or (img and attr(img, "alt"))
            if name and name ~= "" then name = dec(name) else name = txt(inner_html) end
            -- un alt d'image se termine souvent par « 封面 » (couverture) : on l'enlève
            if not title then name = name:gsub("封面$", ""):gsub("%s+$", "") end
            local cover = cover_of(img)
            if hidden_card(name, inner_html) then goto continue end
            local it = idx[k]
            if it then -- même œuvre déjà vue (autre lien, autre forme d'URL) : on complète seulement
                if title and not it.titled then it.name = dec(title); it.titled = true end
                if it.name == "" and name ~= "" then it.name = name end
                if not it.cover and cover then it.cover = cover end
            else
                it = { name = name, path = rel(href), cover = cover, titled = title ~= nil }
                idx[k] = it
                out[#out+1] = it
            end
        end
        ::continue::
    end
    local res = {}
    for _, it in ipairs(out) do if it.name ~= "" then res[#res+1] = it end end
    -- couvertures manquantes (liste sans image, image invalide) : og:image de la fiche, 8 au maximum pour rester rapide
    local budget = 8
    for _, it in ipairs(res) do
        if not it.cover and budget > 0 then
            budget = budget - 1
            local ok, page = pcall(get, it.path)
            if ok and page then
                local og = page:match('property="og:image"[^>]-content="([^"]*)"') or page:match('content="([^"]*)"[^>]-property="og:image"')
                if og and og ~= "" and not bad_cover(og) then it.cover = abs(dec(og)) end
            end
        end
    end
    return res
end

-- ===== FILTRES : l'adresse de la liste est construite à partir des choix de l'utilisateur =====
-- Une valeur vide ou « all » = pas de filtre : le paramètre est retiré de l'adresse.
local BROWSE = "https://sushiscan.net/genres/{genres}/page/{page}/"
local FJOIN  = {  }

local POPULAR_FILTERS = {
    { key = "genres", label = "Genres", default = "all", multi = false,
      options = {
        { id = "all", label = "Tous" },
        { id = "romance", label = "Romance" },
        { id = "school-life", label = "School-Life" },
        { id = "action", label = "Action" },
        { id = "aventure", label = "Aventure" },
        { id = "comedie", label = "Comédie" },
        { id = "drame", label = "Drame" },
        { id = "fantastique", label = "Fantastique" },
        { id = "histoires-courtes", label = "Histoires courtes" },
        { id = "fantasy", label = "Fantasy" },
        { id = "nekketsu", label = "Nekketsu" },
        { id = "surnaturel", label = "Surnaturel" },
        { id = "historique", label = "Historique" },
        { id = "horreur", label = "Horreur" },
        { id = "tragique", label = "Tragique" },
        { id = "sport", label = "Sport" },
        { id = "shojo-ai", label = "Shôjo-aï" },
        { id = "mystere", label = "Mystère" },
      } },
}

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
-- valeur choisie pour un filtre (nil si vide ou « all »)
local function fval(sel, key)
    local v = sel and sel[key]
    if v == nil or v == "" or v == "all" then return nil end
    return tostring(v)
end
-- remplace {genre}, {page}, {q}… dans une adresse ; retire ce qui dépend d'un filtre vide
local function expand(tpl, sel, term, page)
    tpl = tpl:gsub("#.*$", "")
    local origin, rest = tpl:match("^(https?://[^/?]+)(.*)$")
    if not origin then origin, rest = "", tpl end
    local path, query = rest:match("^([^?]*)%??(.*)$")
    local function sub(s)
        local ok = true
        local r = s:gsub("{([%w_%-]+)}", function(k)
            if k == "page" then return tostring(page or 1) end
            if k == "q" then return enc(term or "") end
            local v = fval(sel, k)
            if not v then ok = false; return "" end
            local t = {}
            for x in v:gmatch("[^,]+") do t[#t + 1] = enc(x) end
            return table.concat(t, ",")
        end)
        return r, ok
    end
    local segs = {}
    for _, seg in ipairs(split(path, "/")) do
        local r, ok = sub(seg)
        if ok then segs[#segs + 1] = r end
    end
    local out = origin .. table.concat(segs, "/")
    local ps = {}
    if query ~= "" then
        for _, p in ipairs(split(query, "&")) do
            local name, key = p:match("^([^=]*)={([%w_%-]+)}$")
            local v = (key and key ~= "page" and key ~= "q") and fval(sel, key) or nil
            if v and FJOIN[key] == "rep" and v:find(",", 1, true) then
                for x in v:gmatch("[^,]+") do ps[#ps + 1] = name .. "=" .. enc(x) end
            else
                local r, ok = sub(p)
                if ok then ps[#ps + 1] = r end
            end
        end
    end
    if #ps > 0 then out = out .. "?" .. table.concat(ps, "&") end
    return out
end
local function browse_url(page, options)
    if BROWSE == "" then return BASE .. "/" end
    local sel = {}
    for k, v in pairs((options and options.filters) or {}) do sel[k] = v end
    -- aucun choix de l'utilisateur : valeurs par défaut des filtres (sinon /sort/{genre}/ perdrait son genre)
    for _, f in ipairs(POPULAR_FILTERS) do
        if sel[f.key] == nil or sel[f.key] == "" then sel[f.key] = f.default end
    end
    -- sans genre : le catalogue complet (/genres/ seul est la liste des genres, pas des œuvres)
    if not fval(sel, "genres") then
        return BASE .. "/catalogue/?order=popular&page=" .. tostring(page or 1)
    end
    return expand(BROWSE, sel, "", page)
end

local ext = { id = "sushiscan", name = "Sushiscan", site = BASE, lang = "fr", version = "0.1.0",
    type = "manga",
    popularFilters = POPULAR_FILTERS, searchFilters = {}, hasReviews = false, chapterCommentsPanel = false }

function ext:popularNovels(page, options)
    local html, err = get(browse_url(page, options))
    if not html then return { novels = {}, error = T("Site injoignable (") .. tostring(err) .. ")" } end
    return { novels = parse_list(html) }
end

function ext:searchNovels(term, page, options)
    term = tostring(term or ""):match("^%s*(.-)%s*$")
    if term == "" then return ext:popularNovels(page, options) end
    local url = expand(SEARCH, options and options.filters, term, page)
    local html, err = get(url)
    if not html then return { novels = {}, error = T("Recherche impossible (") .. tostring(err) .. ")" } end
    return { novels = parse_list(html) }
end

local function meta(html, path)
    local t = html:match("<h1[^>]*>(.-)</h1>")
    local name = t and txt(t) or ""
    if name == "" then name = dec(html:match('property="og:title"[^>]-content="([^"]*)"') or "") end
    if name == "" then name = path end
    local og = html:match('property="og:description"[^>]-content="([^"]*)"')
        or html:match('content="([^"]*)"[^>]-property="og:description"')
        or html:match('name="description"[^>]-content="([^"]*)"') or ""
    og = dec(og)
    local summary = og
    -- description souvent tronquée (« … ») dans og:description : on cherche la version complète dans la page
    if og == "" or og:sub(-3) == "..." or og:sub(-3) == "…" or #og < 200 then
        local head = (og:gsub("%s+", " ")):sub(1, 25)
        for _, k in ipairs({ "synopsis", "summary", "description", "resume", "intro", "story", "desc" }) do
            local b = grab(html, k)
            if b and select(2, b:gsub("<a%s", "")) <= 3 then
                local d = para(b)
                if #d > #og and #d > 60 and #d < 4000 and (head == "" or (d:gsub("%s+", " ")):find(head, 1, true)) then
                    summary = d
                    break
                end
            end
        end
    end
    local function ogp(p) return dec(html:match('property="' .. p .. '"[^>]-content="([^"]*)"') or html:match('content="([^"]*)"[^>]-property="' .. p .. '"') or "") end
    local cv = abs(dec(html:match('property="og:image"[^>]-content="([^"]*)"')))
    if cv and bad_cover(cv) then cv = nil end
    local cat = ogp("og:novel:category")
    return { name = name, path = path, cover = cv,
        summary = summary, author = ogp("og:novel:author"), status = ogp("og:novel:status"), genres = cat ~= "" and { cat } or {} }
end

function ext:parseNovelMeta(path)
    local html = get(path); if not html then return nil end
    local m = meta(html, path); m.total_chapters = 0; return m
end

function ext:parseNovel(path)
    local html = get(path); if not html then return nil end
    local m, ch, seen = meta(html, path), {}, {}
    -- thème MangaThemesia : tous les chapitres ET volumes sont dans #chapterlist
    local list_html = block_by_id(html, "chapterlist")
    for tag, inner_html in (list_html or html):gmatch("(<a%s[^>]->)(.-)</a>") do
        local href = attr(tag, "href")
        local ok = href and href ~= ""
        if ok and list_html then
            ok = not tag:find("download", 1, true) and not href:find("[?#]")
        elseif ok then
            ok = is_chap(href)
        end
        if ok then
            local k = norm(href)
            local num = inner_html:match('class="chapternum"[^>]*>(.-)</span>')
            local name = txt(num or inner_html)
            if name == "" then name = dec(attr(tag, "title") or "") end
            if seen[k] then
                if #name > #seen[k].name then seen[k].name = name end
            else
                if name == "" then name = "Chapitre " .. (#ch + 1) end
                seen[k] = { name = name, path = rel(href) }
                ch[#ch+1] = seen[k]
            end
        end
    end
    local function first_num(c) return tonumber((c.name or ""):match("(%d+%.?%d*)")) end
    if list_html then
        -- ordre du site conservé ; on le retourne s'il est décroissant (le plus récent d'abord)
        local a1, b1 = first_num(ch[1] or {}), first_num(ch[#ch] or {})
        if not (a1 and b1 and a1 < b1) then
            for i = 1, math.floor(#ch/2) do ch[i], ch[#ch+1-i] = ch[#ch+1-i], ch[i] end
        end
    else
        local sorted = #ch > 1
        local nums = {}
        for _, c in ipairs(ch) do
            local n = tonumber(norm(c.path):match("(%d+)[^%d]*$"))
            if not n or nums[n] then sorted = false break end
            nums[n] = true; c.n = n
        end
        if sorted then table.sort(ch, function(x, y) return x.n < y.n end) end
        if not sorted then for i = 1, math.floor(#ch/2) do ch[i], ch[#ch+1-i] = ch[#ch+1-i], ch[i] end end
    end
    for i, c in ipairs(ch) do c.chapter_number = i end
    m.chapters, m.totalPages = ch, 1
    return m
end

-- Sites au thème « MangaThemesia / ts-reader » : les pages sont dans le <div id="readerarea">
-- (balises <img>, parfois en chargement différé) et, selon les chapitres, seulement dans le script
-- ts_reader.run({... "images":["https://…/1.jpg", …] ...}). On lit les deux et on garde le plus complet.
local function unescape_json(u)
    u = u:gsub("\\u(%x%x%x%x)", function(h) return cp2utf8(tonumber(h, 16)) end)
    return (u:gsub("\\/", "/"))
end

function ext:parseChapterImages(path)
    local html, err = get(path); if not html then return nil, "chapter_unreachable" end

    local function clean(u)
        u = u and abs(dec(u:match("^%s*(.-)%s*$")))
        if not u or not u:match("^https?://") or u:find("logo", 1, true) then return nil end
        return u
    end

    -- 1) balises <img> du lecteur
    local from_html, seen = {}, {}
    local ra = html:find('id="readerarea"', 1, true) or html:find("id='readerarea'", 1, true)
    if ra then
        local ts = ra
        while ts > 1 and html:sub(ts, ts) ~= "<" do ts = ts - 1 end
        local tn = html:match("^<(%a%w*)", ts)
        local _, e = html:find(">", ra, true)
        local block = (tn and e) and inner(html, e + 1, tn) or nil
        for tag in (block or ""):gmatch("<img[^>]->") do
            local raw = attr(tag, "data-src") or attr(tag, "data-lazy-src") or attr(tag, "data-original") or attr(tag, "src")
            local u = clean(raw)
            if u and not seen[u] then seen[u] = true; from_html[#from_html + 1] = u end
        end
    end

    -- 2) liste d'images du script ts_reader
    local from_script, seen2 = {}, {}
    local arr = html:match('"images"%s*:%s*(%b[])')
    if arr then
        for raw in arr:gmatch('"(.-)"') do
            local u = clean(unescape_json(raw))
            if u and not seen2[u] then seen2[u] = true; from_script[#from_script + 1] = u end
        end
    end

    local images = from_html
    if #from_html < 2 and #from_script > #from_html then images = from_script end
    if #images == 0 then return nil, "no_pages" end
    return { images = images, headers = { ["User-Agent"] = UA, ["Referer"] = BASE .. "/" } }
end

function ext:parseChapter(path) return "<p>Ce chapitre est un manga : il s'ouvre dans le lecteur d'images.</p>" end

return ext

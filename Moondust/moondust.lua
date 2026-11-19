-- moondust.lua
-- Drop this file next to your script, then:
--
--   local moondust = require("moondust")
--   local tf  = moondust("thegamingmahi/tinyfiles")          -- latest version
--   local old = moondust("thegamingmahi/tinyfiles@1.0.0")    -- exact version
--
-- First run downloads the package into ./lua_modules/author/package.lua, later runs reuse it.
-- It also creates a small .luarc.json so editors that use LuaLS (VS Code, Neovim, Zed)
-- autocomplete moondust("...") like a normal require. Set MOONDUST_NO_LUARC=1 to skip that.
-- Needs `curl` (built into macOS, Linux and Windows 10+).
-- Written for Lua 5.1 to 5.5 and LuaJIT (tested on 5.1 and 5.4).
-- In LÖVE 12+ it uses LÖVE's built-in https module instead of curl, and saves
-- packages in the game's save folder. Call it from love.load (downloads block).
--
-- Also usable as a command:
--   lua moondust.lua install thegamingmahi/tinyfiles[@1.0.0]   download a package
--   lua moondust.lua update [thegamingmahi/tinyfiles]          update one package, or all
--   lua moondust.lua list                                      show installed packages
--   lua moondust.lua verify                                    check files against moondust.lock
--   lua moondust.lua uninstall thegamingmahi/tinyfiles         remove a package
-- moondust.lock also stores a sha256 checksum of every package it installs.

local SITE = "https://thegamingmahi.github.io/Moondust/"
local DIR = "lua_modules"
local LOCK = "moondust.lock"

local M = { version = "0.3.0" }
local loaded = {}

local function fail(msg)
  error("moondust: " .. msg, 0)
end

local function sh(cmd)
  local p = io.popen(cmd, "r")
  if not p then return nil end
  local out = p:read("*a")
  p:close()
  return out
end

-- LÖVE has no curl/io.popen, so it uses its own filesystem and https module
local LOVE = type(love) == "table" and type(love.filesystem) == "table"

local function get(url)
  if LOVE then
    local ok, https = pcall(require, "https")
    if not ok then fail("LÖVE 12 or newer is needed (it includes the https module)") end
    local code, body = https.request(url)
    if code == 200 then return body end
    return nil
  end
  return sh('curl -fsSL "' .. url .. '"')
end

local function exists(path)
  if LOVE then return love.filesystem.getInfo(path) ~= nil end
  local f = io.open(path, "r")
  if f then f:close() return true end
  return false
end

local function read_text(path)
  if LOVE then return love.filesystem.read(path) end
  local f = io.open(path, "r")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

local function write_text(path, s)
  if LOVE then return love.filesystem.write(path, s) and true or false end
  local f = io.open(path, "w")
  if not f then return false end
  f:write(s)
  f:close()
  return true
end

local function download_to(url, path)
  if LOVE then
    local body = get(url)
    if not body then return false end
    love.filesystem.createDirectory((path:match("^(.*)/[^/]*$")))
    return write_text(path, body)
  end
  local ok = os.execute('curl -fsSL --create-dirs -o "' .. path .. '" "' .. url .. '"')
  return ok == true or ok == 0
end

local function load_file(path)
  if LOVE then return love.filesystem.load(path) end
  return loadfile(path)
end

local function remove_file(path)
  if LOVE then return love.filesystem.remove(path) end
  return os.remove(path)
end

-- sha256 of a file as hex, or nil when this machine has no way to compute one
local sha_cmd
local function sha256_file(path)
  if LOVE then
    local data = love.filesystem.read(path)
    if not data then return nil end
    local ok, hex = pcall(function()
      return love.data.encode("string", "hex", love.data.hash("sha256", data))
    end)
    return ok and hex or nil
  end
  local cmds = {
    'sha256sum "' .. path .. '" 2>&1',
    'shasum -a 256 "' .. path .. '" 2>&1',
    'openssl dgst -sha256 "' .. path .. '" 2>&1',
    'certutil -hashfile "' .. (path:gsub("/", "\\")) .. '" SHA256 2>&1',
  }
  for _, i in ipairs(sha_cmd and { sha_cmd } or { 1, 2, 3, 4 }) do
    local out = sh(cmds[i]) or ""
    for tok in out:gmatch("%x+") do
      if #tok == 64 then sha_cmd = i; return tok:lower() end
    end
    for line in out:gmatch("[^\r\n]+") do        -- old certutil prints the hash with spaces
      local compact = line:gsub("%s", "")
      if #compact == 64 and compact:match("^%x+$") then sha_cmd = i; return compact:lower() end
    end
  end
  return nil
end

-- "author/package" or "author/package@1.2.3"
local function parse_spec(spec)
  if type(spec) ~= "string" then fail("package must be a string") end
  local name, ver = spec:match("^([%w_%-]+/[%w_%-]+)@(%d+%.%d+%.%d+)$")
  if not name then name = spec:match("^([%w_%-]+/[%w_%-]+)$") end
  if not name then
    fail("bad package '" .. spec .. "' (use author/package or author/package@1.2.3)")
  end
  return name, ver
end

-- values from the registry go into shell commands, so check them first
local function safe(s, pattern)
  return type(s) == "string" and s:match(pattern) ~= nil and not s:find("..", 1, true)
end

local function split3(v)
  local a, b, c = v:match("^(%d+)%.(%d+)%.(%d+)$")
  return tonumber(a), tonumber(b), tonumber(c)
end

local function newer(a, b)
  local a1, a2, a3 = split3(a)
  local b1, b2, b3 = split3(b)
  if a1 ~= b1 then return a1 > b1 end
  if a2 ~= b2 then return a2 > b2 end
  return a3 > b3
end

-- index.txt: one line per version
--   author/package 1.2.0 repo-owner/repo-name <40 char commit> main.lua 5.1,5.3,5.4
local function fetch_index()
  local text = get(SITE .. "index.txt")
  if not text or text == "" then fail("could not reach the registry") end
  local entries = {}
  for line in text:gmatch("[^\r\n]+") do
    local name, ver, repo, commit, main, lua =
      line:match("^(%S+)%s+(%S+)%s+(%S+)%s+(%S+)%s+(%S+)%s+(%S+)$")
    if name then
      entries[name] = entries[name] or {}
      table.insert(entries[name], {
        version = ver, repo = repo, commit = commit, main = main, lua = lua,
      })
    end
  end
  return entries
end

local function resolve(name, wanted)
  local list = fetch_index()[name]
  if not list then fail("package not found: " .. name) end
  local best
  for _, e in ipairs(list) do
    if safe(e.version, "^%d+%.%d+%.%d+$") then
      if wanted then
        if e.version == wanted then best = e end
      elseif not best or newer(e.version, best.version) then
        best = e
      end
    end
  end
  if not best then
    fail(name .. (wanted and ("@" .. wanted) or "") .. " has no matching version")
  end
  return best
end

local function check_lua(name, e)
  if e.lua == "*" then return end
  local current = _VERSION:match("%d+%.%d+")
  for v in e.lua:gmatch("[^,]+") do
    if v == current then return end
  end
  fail(name .. " " .. e.version .. " needs Lua " .. (e.lua:gsub(",", " or "))
    .. " (you are running " .. current .. ")")
end

-- the project's current version of a package lives at a plain path, so editors can find it
local function stable_path(name)
  return DIR .. "/" .. name .. ".lua"
end

-- other exact versions are kept next to it
local function versioned_path(name, ver)
  return DIR .. "/" .. name .. "@" .. ver .. ".lua"
end

-- moondust.lock: one line per package   author/package 1.2.0 sha256:<hex>   (the checksum is optional)
local function read_lock()
  local versions, hashes = {}, {}
  for line in (read_text(LOCK) or ""):gmatch("[^\r\n]+") do
    local n, v, h = line:match("^(%S+)%s+(%S+)%s*(%S*)$")
    if n then
      versions[n] = v
      hashes[n] = h:match("^sha256:(%x+)$")
    end
  end
  return versions, hashes
end

local function write_lock(versions, hashes)
  local names, out = {}, {}
  for n in pairs(versions) do names[#names + 1] = n end
  table.sort(names)
  for _, n in ipairs(names) do
    out[#out + 1] = n .. " " .. versions[n] .. (hashes[n] and (" sha256:" .. hashes[n]) or "") .. "\n"
  end
  if not write_text(LOCK, table.concat(out)) then fail("could not write " .. LOCK) end
end

local function sorted_names(t)
  local names = {}
  for n in pairs(t) do names[#names + 1] = n end
  table.sort(names)
  return names
end

local function forget(name)
  for k in pairs(loaded) do
    if k:sub(1, #name + 1) == name .. "@" then loaded[k] = nil end
  end
end

-- tells LuaLS (the engine behind most Lua editor plugins) to treat moondust("...") like require
local EDITOR_CONFIG = '{\n  "runtime.special": { "moondust": "require" },\n  "runtime.path": ["?.lua", "?/init.lua", "'
  .. DIR .. '/?.lua"],\n  "workspace.library": ["' .. DIR .. '"]\n}\n'
local told = false

local function editor_config()
  if LOVE or told or os.getenv("MOONDUST_NO_LUARC") then return end
  told = true
  local current = read_text(".luarc.json")
  if current == nil then
    if write_text(".luarc.json", EDITOR_CONFIG) then
      io.stderr:write("moondust: created .luarc.json so your editor can autocomplete moondust(...)\n")
    end
  elseif not current:find("moondust", 1, true) then
    io.stderr:write("moondust: for editor autocomplete, add these settings to your .luarc.json:\n" .. EDITOR_CONFIG)
  end
end

local no_tool_warned = false

local function download(name, wanted, current)
  local e = resolve(name, wanted)
  check_lua(name, e)

  if not safe(e.repo, "^[%w_%-%.]+/[%w_%-%.]+$") then fail("bad repo in registry entry") end
  if not (#e.commit == 40 and e.commit:match("^%x+$")) then fail("bad commit in registry entry") end
  if not safe(e.main, "^[%w_%-%.]+%.lua$") then fail("bad main file in registry entry") end

  -- pinned to an exact commit, so the author can't change the code later
  local url = "https://raw.githubusercontent.com/" .. e.repo .. "/" .. e.commit .. "/" .. e.main
  local path = current and stable_path(name) or versioned_path(name, e.version)
  if not download_to(url, path) then fail("download failed for " .. name) end

  -- checksum: if this exact version is already in moondust.lock, the download must match it
  local hash = sha256_file(path)
  if current then
    local versions, hashes = read_lock()
    if hash and hashes[name] and versions[name] == e.version and hashes[name] ~= hash then
      remove_file(path)
      fail("checksum mismatch for " .. name .. " " .. e.version .. " (moondust.lock has "
        .. hashes[name]:sub(1, 12) .. "..., the download is " .. hash:sub(1, 12) .. "...). The file was removed.")
    end
    if not hash and not no_tool_warned then
      no_tool_warned = true
      io.stderr:write("moondust: no sha256 tool found (sha256sum, shasum, openssl or certutil), checksums are skipped\n")
    end
  end
  return path, e.version, hash
end

-- downloads the project's current version of a package and remembers it in moondust.lock
local function fetch(name, wanted, current)
  local path, ver, hash = download(name, wanted, current)
  if current then
    local versions, hashes = read_lock()
    versions[name], hashes[name] = ver, hash
    write_lock(versions, hashes)
    editor_config()
  end
  return path, ver
end

function M.install(spec)
  local name, wanted = parse_spec(spec)
  forget(name)
  return fetch(name, wanted, true)
end

-- update("author/package") updates one package, update() updates everything in moondust.lock
function M.update(spec)
  if spec then return M.install(spec) end
  local versions = read_lock()
  local results = {}
  for _, n in ipairs(sorted_names(versions)) do
    local ok, path, ver = pcall(M.install, n)
    results[#results + 1] = { name = n, old = versions[n], new = ok and ver or nil, err = (not ok) and tostring(path) or nil }
  end
  return results
end

function M.list()
  local versions, hashes = read_lock()
  local out = {}
  for _, n in ipairs(sorted_names(versions)) do
    out[#out + 1] = { name = n, version = versions[n], sha256 = hashes[n], installed = exists(stable_path(n)) }
  end
  return out
end

-- checks every installed file against the checksum in moondust.lock; returns results and a problem count
function M.verify()
  local results, bad = {}, 0
  for _, p in ipairs(M.list()) do
    local state = "OK"
    if not p.installed then
      state = "MISSING"
    elseif not p.sha256 then
      state = "NO CHECKSUM"
    else
      local h = sha256_file(stable_path(p.name))
      if not h then state = "CANNOT CHECK" elseif h ~= p.sha256 then state = "CHANGED" end
    end
    if state ~= "OK" then bad = bad + 1 end
    results[#results + 1] = { name = p.name, version = p.version, state = state }
  end
  return results, bad
end

function M.uninstall(spec)
  local name = parse_spec(spec)
  local versions, hashes = read_lock()
  local had = versions[name] ~= nil or exists(stable_path(name))
  remove_file(stable_path(name))
  versions[name], hashes[name] = nil, nil
  write_lock(versions, hashes)
  forget(name)
  return had
end

function M.use(spec)
  local name, wanted = parse_spec(spec)
  local key = name .. "@" .. (wanted or "latest")
  if loaded[key] ~= nil then return loaded[key] end

  local versions, hashes = read_lock()
  local locked = versions[name]
  local path
  if wanted and wanted ~= locked then
    -- an exact version that isn't the project's current one is kept separately
    path = versioned_path(name, wanted)
    if not exists(path) then download(name, wanted, false) end
  else
    -- the project's current version: the locked one, or the latest on first use
    path = stable_path(name)
    if not (locked and exists(path)) then
      fetch(name, locked, true)
    elseif hashes[name] and os.getenv("MOONDUST_VERIFY") then
      local h = sha256_file(path)
      if h and h ~= hashes[name] then
        fail("checksum mismatch: " .. path .. " was changed (restore it with: lua moondust.lua install "
          .. name .. "@" .. locked .. ")")
      end
    end
  end

  local chunk, err = load_file(path)
  if not chunk then fail("could not load " .. path .. ": " .. tostring(err)) end
  local mod = chunk(name)
  if mod == nil then mod = true end
  loaded[key] = mod
  return mod
end

-- lets you write moondust("thegamingmahi/tinyfiles")
setmetatable(M, { __call = function(_, spec) return M.use(spec) end })

-- command line mode: lua moondust.lua <command>
if arg and arg[0] and arg[0]:match("moondust%.lua$") then
  local cmd, spec = arg[1], arg[2]
  local function die(err) io.stderr:write(tostring(err), "\n") os.exit(1) end
  if (cmd == "install" or cmd == "update") and spec then
    local ok, path, ver = pcall(M.install, spec)
    if not ok then die(path) end
    print("installed " .. spec .. " (" .. ver .. ") -> " .. path)
  elseif cmd == "update" then
    local results, failed = M.update(), false
    if #results == 0 then print("no packages in " .. LOCK) end
    for _, r in ipairs(results) do
      if r.err then failed = true; print(r.name .. ": FAILED " .. r.err)
      elseif r.old == r.new then print(r.name .. ": already the latest (" .. r.new .. ")")
      else print(r.name .. ": " .. tostring(r.old) .. " -> " .. r.new) end
    end
    if failed then os.exit(1) end
  elseif cmd == "list" then
    local list = M.list()
    if #list == 0 then print("no packages in " .. LOCK) end
    for _, p in ipairs(list) do
      print(p.name .. " " .. p.version .. (p.sha256 and ("  sha256:" .. p.sha256:sub(1, 12) .. "...") or "")
        .. (p.installed and "" or "  (file missing)"))
    end
  elseif cmd == "verify" then
    local results, bad = M.verify()
    if #results == 0 then print("no packages in " .. LOCK) end
    for _, r in ipairs(results) do print(string.format("%-12s %s %s", r.state, r.name, r.version)) end
    if bad > 0 then os.exit(1) end
  elseif cmd == "uninstall" and spec then
    local ok, had = pcall(M.uninstall, spec)
    if not ok then die(had) end
    print(had and ("removed " .. spec) or ("nothing to remove for " .. spec))
  elseif cmd == "login" or cmd == "register" or cmd == "publish" then
    print("moondust: '" .. cmd .. "' is coming soon (it needs the registry server)")
  else
    print("moondust " .. M.version)
    print("usage:")
    print("  lua moondust.lua install author/package[@version]   download a package")
    print("  lua moondust.lua update [author/package]            update one package, or all of them")
    print("  lua moondust.lua list                               show installed packages")
    print("  lua moondust.lua verify                             check files against moondust.lock")
    print("  lua moondust.lua uninstall author/package           remove a package")
  end
end

return M

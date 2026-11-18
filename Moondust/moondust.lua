-- moondust.lua
-- Drop this file next to your script, then:
--
--   local moondust = require("moondust")
--   local tf  = moondust("thegamingmahi/tinyfiles")          -- latest version
--   local old = moondust("thegamingmahi/tinyfiles@1.0.0")    -- exact version
--
-- First run downloads the package into ./lua_modules/, later runs reuse it.
-- Needs `curl` (built into macOS, Linux and Windows 10+).
-- Works on Lua 5.1 to 5.5 and LuaJIT.
-- In LÖVE 12+ it uses LÖVE's built-in https module instead of curl, and saves
-- packages in the game's save folder. Call it from love.load (downloads block).
--
-- Also usable as a command:
--   lua moondust.lua install thegamingmahi/tinyfiles
--   lua moondust.lua update thegamingmahi/tinyfiles

local SITE = "https://thegamingmahi.github.io/Moondust/"
local DIR = "lua_modules"
local LOCK = "moondust.lock"

local M = { version = "0.1.0" }
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

local function path_for(name, ver)
  return DIR .. "/" .. name .. "@" .. ver .. ".lua"
end

local function read_lock()
  local t = {}
  for line in (read_text(LOCK) or ""):gmatch("[^\r\n]+") do
    local n, v = line:match("^(%S+)%s+(%S+)$")
    if n then t[n] = v end
  end
  return t
end

local function write_lock(t)
  local names, out = {}, {}
  for n in pairs(t) do names[#names + 1] = n end
  table.sort(names)
  for _, n in ipairs(names) do out[#out + 1] = n .. " " .. t[n] .. "\n" end
  if not write_text(LOCK, table.concat(out)) then fail("could not write " .. LOCK) end
end

local function download(name, wanted)
  local e = resolve(name, wanted)
  check_lua(name, e)

  if not safe(e.repo, "^[%w_%-%.]+/[%w_%-%.]+$") then fail("bad repo in registry entry") end
  if not (#e.commit == 40 and e.commit:match("^%x+$")) then fail("bad commit in registry entry") end
  if not safe(e.main, "^[%w_%-%.]+%.lua$") then fail("bad main file in registry entry") end

  -- pinned to an exact commit, so the author can't change the code later
  local url = "https://raw.githubusercontent.com/" .. e.repo .. "/" .. e.commit .. "/" .. e.main
  local path = path_for(name, e.version)
  if not download_to(url, path) then fail("download failed for " .. name) end
  return path, e.version
end

-- downloads a package; "latest" requests are remembered in moondust.lock
local function fetch(name, wanted)
  local path, ver = download(name, wanted)
  if not wanted then
    local lock = read_lock()
    lock[name] = ver
    write_lock(lock)
  end
  return path, ver
end

function M.install(spec)
  local name, wanted = parse_spec(spec)
  loaded[name .. "@" .. (wanted or "latest")] = nil
  return fetch(name, wanted)
end

M.update = M.install

function M.use(spec)
  local name, wanted = parse_spec(spec)
  local key = name .. "@" .. (wanted or "latest")
  if loaded[key] ~= nil then return loaded[key] end

  -- an exact version wins, then the version in moondust.lock, then latest
  local target = wanted or read_lock()[name]
  local path
  if target and exists(path_for(name, target)) then
    path = path_for(name, target)
  else
    path = fetch(name, target)
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
  if (cmd == "install" or cmd == "update") and spec then
    local ok, path, ver = pcall(M.install, spec)
    if not ok then
      io.stderr:write(tostring(path), "\n")
      os.exit(1)
    end
    print("installed " .. spec .. " (" .. ver .. ") -> " .. path)
  elseif cmd == "login" or cmd == "register" or cmd == "publish" then
    print("moondust: '" .. cmd .. "' is coming soon (it needs the registry server)")
  else
    print("moondust " .. M.version)
    print("usage:")
    print("  lua moondust.lua install author/package[@version]")
    print("  lua moondust.lua update author/package")
  end
end

return M

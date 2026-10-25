--- Official Lua SDK for Movoa (https://movoa.ai), the AI video generator with sound.
--
--   local movoa = require("movoa")
--   local url, err = movoa.generate_video("a lighthouse in a storm, thunder")
--   if url then print(url) else print(err.kind, err.message) end
--
-- Pass opts.api_key or set MOVOA_API_KEY; create a key at
-- https://movoa.ai/settings/apikeys. Runs cost credits on your Movoa account,
-- at the prices on https://movoa.ai/pricing.
--
-- Failures come back as nil plus an error table
--   { kind = ..., message = ..., status = ..., reason = ..., task_id = ... }
-- where kind is "auth", "rejected", "quota", "plan", "busy", "failed",
-- "timeout" or "other". tostring(err) gives the message.

local json = require("dkjson")

local M = { _VERSION = "0.1.0", base_url = "https://movoa.ai" }

M.KEYS_URL = "https://movoa.ai/settings/apikeys"
M.DEFAULT_MODEL = "minimax-h3"
local KEY_HINT = "Create a key at " .. M.KEYS_URL .. " and set MOVOA_API_KEY."

-- Options that belong to the SDK; every other key in opts goes to the model.
local OWN = {
  model = true, image_url = true, options = true, api_key = true, base_url = true,
  poll_every = true, timeout = true,
}

local Error = { __tostring = function(e) return "movoa: " .. e.message end }

local function fail(kind, message, extra)
  local e = setmetatable({ kind = kind, message = message }, Error)
  for k, v in pairs(extra or {}) do e[k] = v end
  return nil, e
end

--- POST a JSON body; return HTTP status and the decoded body (nil when not JSON). Replaceable in tests.
function M.transport(url, body, key)
  local https = require("ssl.https")
  local ltn12 = require("ltn12")
  local out = {}
  local payload = json.encode(body)
  local _, code = https.request({
    url = url,
    method = "POST",
    headers = {
      ["Content-Type"] = "application/json",
      ["Content-Length"] = tostring(#payload),
      ["Authorization"] = "Bearer " .. key,
      ["User-Agent"] = "movoa-lua/" .. M._VERSION,
    },
    source = ltn12.source.string(payload),
    sink = ltn12.sink.table(out),
  })
  if type(code) ~= "number" then return nil, nil, tostring(code) end
  return code, json.decode(table.concat(out))
end

--- Sleep between polls. Replaceable in tests.
function M.sleep(seconds)
  local ok, socket = pcall(require, "socket")
  if ok then socket.sleep(seconds) else os.execute("sleep " .. tonumber(seconds)) end
end

--- Map one answer to its data, or nil plus the error that says what to do next.
-- movoa.ai answers almost every refusal as HTTP 200 with a non-zero code and a
-- data.reason, so the status code alone reads a refusal as success.
function M.check(status, body)
  if status == 401 then
    local msg = type(body) == "table" and type(body.message) == "string" and body.message
    return fail("auth", msg or ("Invalid API key. " .. KEY_HINT), { status = 401 })
  end
  if type(body) ~= "table" then
    return fail("other", "movoa.ai returned a non-JSON response (HTTP " .. tostring(status) .. ")", { status = status })
  end
  if body.code == 0 then return body.data or {} end
  local msg = type(body.message) == "string" and body.message or ("request failed (HTTP " .. tostring(status) .. ")")
  if body.code == -2 or body.code == -3 then return fail("rejected", msg, { status = status }) end
  local reason = type(body.data) == "table" and body.data.reason or nil
  if reason == "insufficient_credits" then return fail("quota", msg, { status = status, reason = reason }) end
  if reason == "plan_required" then return fail("plan", msg, { status = status, reason = reason }) end
  if reason == "concurrency" then return fail("busy", msg, { status = status, reason = reason }) end
  if msg:lower():find("no auth", 1, true) then return fail("auth", msg .. ". " .. KEY_HINT, { status = status }) end
  return fail("other", msg, { status = status, reason = reason })
end

local function key_of(opts)
  local k = opts.api_key
  if not k or k == "" then k = os.getenv("MOVOA_API_KEY") end
  if k and k:find("%S") then return (k:gsub("^%s+", ""):gsub("%s+$", "")) end
  return nil
end

local function base_of(opts)
  local b = opts.base_url
  if not b or b == "" then b = os.getenv("MOVOA_BASE_URL") end
  if not b or b == "" then b = M.base_url end
  return (b:gsub("/+$", ""))
end

local function call(path, body, opts)
  local key = key_of(opts)
  if not key then return fail("auth", "No API key set. " .. KEY_HINT) end
  local status, data, terr = M.transport(base_of(opts) .. path, body, key)
  if not status then return fail("other", "Could not reach movoa.ai: " .. tostring(terr or "no answer")) end
  return M.check(status, data)
end

--- Start a run and return its id without waiting.
-- opts.model (default "minimax-h3"), opts.image_url (photo to video), opts.options (table),
-- and any other key such as duration, resolution or aspect_ratio go to the model as-is.
function M.submit(prompt, opts)
  opts = opts or {}
  assert(type(prompt) == "string" and prompt:find("%S"), "prompt is required")
  local options = {}
  for k, v in pairs(opts.options or {}) do options[k] = v end
  for k, v in pairs(opts) do if not OWN[k] then options[k] = v end end
  options.sound = true
  local i2v = type(opts.image_url) == "string" and opts.image_url ~= ""
  if i2v then options.image_input = { opts.image_url } end
  local data, err = call("/api/ai/generate", {
    provider = "auto", -- the service routes by model; this only has to be non-empty
    mediaType = "video",
    model = opts.model or M.DEFAULT_MODEL,
    scene = i2v and "image-to-video" or "text-to-video",
    prompt = prompt,
    options = options,
  }, opts)
  if not data then return nil, err end
  if data.id == nil then return fail("other", "movoa.ai accepted the run but returned no id") end
  return tostring(data.id)
end

--- Return the run's record: { id, status = "pending"|"processing"|"success"|"failed"|"canceled",
-- videos = { url, ... }, errorMessage, failureKind, queued, queueEta }.
function M.status(id, opts)
  return call("/api/ai/query", { taskId = id }, opts or {})
end

--- Credits left on the account.
function M.credits(opts)
  local data, err = call("/api/user/get-user-credits", setmetatable({}, { __jsontype = "object" }), opts or {})
  if not data then return nil, err end
  if type(data.remainingCredits) ~= "number" then return fail("other", "movoa.ai returned no credit balance") end
  return math.floor(data.remainingCredits)
end

--- Poll a submitted run every opts.poll_every seconds (10) until it succeeds, or opts.timeout (1800) passes.
-- Returns the run's record; kind "failed" when it failed or was canceled, "timeout" (with task_id) when the wait ran out.
function M.wait(id, opts)
  opts = opts or {}
  local every, limit, waited = opts.poll_every or 10, opts.timeout or 1800, 0
  while true do
    local rec, err = M.status(id, opts)
    if rec then
      local url = type(rec.videos) == "table" and rec.videos[1] or nil
      if rec.status == "success" and url then return rec end
      if rec.status == "success" or rec.status == "failed" or rec.status == "canceled" then
        local why = rec.errorMessage and (": " .. tostring(rec.errorMessage)) or (url and "" or " with no video")
        return fail("failed", "run " .. id .. " " .. rec.status .. why,
          { task_id = id, error_message = rec.errorMessage, failure_kind = rec.failureKind })
      end
    elseif err.kind ~= "other" then
      return nil, err
    end -- only a dropped poll is retried
    if waited + every > limit then
      return fail("timeout", "run " .. id .. " is still generating; check it later with movoa.status(id)", { task_id = id })
    end
    M.sleep(every)
    waited = waited + math.max(every, 0.001)
  end
end

--- Generate one clip with sound and return its URL. Same opts as submit, plus poll_every and timeout.
function M.generate_video(prompt, opts)
  opts = opts or {}
  local id, err = M.submit(prompt, opts)
  if not id then return nil, err end
  local rec, werr = M.wait(id, opts)
  if not rec then return nil, werr end
  return rec.videos[1]
end

return M

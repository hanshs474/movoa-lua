-- lua spec/run.lua          unit tests against movoa.ai's real response shapes (no network)
-- lua spec/run.lua live     plus two live checks that start no run (needs MOVOA_API_KEY)
package.path = "src/?.lua;" .. package.path
local movoa = require("movoa")
local function check(ok, what) if not ok then error("FAIL " .. what, 2) end print("ok  " .. what) end

local real_transport = movoa.transport
local calls, script = {}, {}
movoa.sleep = function() end
movoa.transport = function(url, body, key)
  calls[#calls + 1] = { url = url, body = body, key = key }
  local r = #script > 1 and table.remove(script, 1) or script[1]
  return r[1], r[2]
end
local function ok(data) return { 200, { code = 0, message = "ok", data = data } } end
local O = { api_key = "sk-test", base_url = "https://t/", poll_every = 0 }
local function with(extra) local o = {} for k, v in pairs(O) do o[k] = v end for k, v in pairs(extra or {}) do o[k] = v end return o end

-- text to video: submit -> queued -> success
script = {
  ok({ id = "t1", status = "pending" }),
  ok({ id = "t1", status = "processing", queued = true, queueEta = 60 }),
  ok({ id = "t1", status = "success", videos = { "https://cdn.movoa.ai/v.mp4" } }),
}
check(movoa.generate_video("a fox in snow", with()) == "https://cdn.movoa.ai/v.mp4", "success returns videos[1]")
local b = calls[1].body
check(calls[1].url == "https://t/api/ai/generate" and calls[1].key == "sk-test", "submit path and bearer key")
check(b.provider == "auto" and b.mediaType == "video", "provider auto, mediaType video")
check(b.model == "minimax-h3" and b.scene == "text-to-video" and b.prompt == "a fox in snow", "default model, text-to-video")
local n = 0 for _ in pairs(b.options) do n = n + 1 end
check(b.options.sound == true and n == 1, "options: sound only")
check(calls[2].url == "https://t/api/ai/query" and calls[2].body.taskId == "t1", "query by taskId")
check(#calls == 3, "polled through the queue until success")

-- photo to video, options passed through
calls = {}
script = { ok({ id = "t2", status = "pending" }) }
check(movoa.submit("the statue turns", with({ model = "seedance-2-5", image_url = "https://x/y.jpg", duration = 10,
  options = { aspect_ratio = "9:16" } })) == "t2", "submit returns id")
b = calls[1].body
check(b.scene == "image-to-video" and b.model == "seedance-2-5", "image_url switches to image-to-video")
check(b.options.image_input[1] == "https://x/y.jpg" and b.options.duration == 10 and b.options.aspect_ratio == "9:16"
  and b.options.sound == true and b.options.api_key == nil, "options passed through, SDK keys kept out")

script = { ok({ id = "t3", status = "processing", queued = true, queueEta = 120 }) }
local rec = movoa.status("t3", with())
check(rec.id == "t3" and rec.queued == true and rec.queueEta == 120, "status record")
script = { ok({ remainingCredits = 42 }) }
check(movoa.credits(with()) == 42, "credits")

script = { ok({ id = "t4", status = "failed", errorMessage = "provider down", failureKind = "upstream" }) }
local _, err = movoa.wait("t4", with())
check(err.kind == "failed" and err.task_id == "t4" and err.error_message == "provider down"
  and err.message:find("provider down", 1, true), "failed -> kind failed with errorMessage")
script = { ok({ id = "t5", status = "canceled" }) }
_, err = movoa.wait("t5", with())
check(err.kind == "failed" and err.task_id == "t5", "canceled -> kind failed")
script = { ok({ id = "t6", status = "processing", queued = true, queueEta = 60 }) }
_, err = movoa.wait("t6", with({ poll_every = 0.005, timeout = 0.001 }))
check(err.kind == "timeout" and err.task_id == "t6", "timeout carries the task id")

local cases = {
  { 401, { code = -1, message = "Invalid API key. Create one at https://movoa.ai/settings/apikeys", data = { reason = "invalid_api_key" } }, "auth" },
  { 200, { code = -1, message = "insufficient credits", data = { reason = "insufficient_credits" } }, "quota" },
  { 200, { code = -1, message = "This model or quality needs a plan.", data = { reason = "plan_required" } }, "plan" },
  { 200, { code = -1, message = "busy", data = { reason = "concurrency" } }, "busy" },
  { 200, { code = -2, message = "blocked" }, "rejected" },
  { 200, { code = -3, message = "cooldown" }, "rejected" },
  { 200, { code = -1, message = "generation failed, please try again" }, "other" },
  { 502, nil, "other" },
}
for _, c in ipairs(cases) do
  script = { { c[1], c[2] } }
  local id, e = movoa.submit("x", with())
  check(id == nil and e.kind == c[3] and e.status == c[1], c[1] .. " " .. tostring(c[2] and (c[2].data and c[2].data.reason or c[2].code)) .. " -> " .. c[3])
end

script = { { 200, { code = -1, message = "no auth, please sign in" } } }
local left, ce = movoa.credits(with())
check(left == nil and ce.kind == "auth" and ce.message:find("/settings/apikeys", 1, true), "credits code -1 no auth -> auth with key hint")
check(tostring(ce):find("^movoa: "), "tostring(err)")

if not os.getenv("MOVOA_API_KEY") then
  calls = {}
  local _, ke = movoa.credits({ api_key = "", base_url = "https://t" })
  check(ke.kind == "auth" and #calls == 0, "no key -> auth without a request")
end

if arg[1] == "live" then
  movoa.transport = real_transport
  local live, lerr = movoa.credits()
  check(type(live) == "number", "live credits() " .. (lerr and lerr.message or ""))
  local id, werr = movoa.submit("live check", { api_key = "sk-wrong-key" })
  check(id == nil and werr.kind == "auth", "live wrong key -> auth (" .. tostring(werr and werr.status) .. ")")
end
print("all tests passed")

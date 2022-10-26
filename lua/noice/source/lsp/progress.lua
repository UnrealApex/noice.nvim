local require = require("noice.util.lazy")

local Message = require("noice.message")
local Manager = require("noice.message.manager")
local Router = require("noice.message.router")
local Format = require("noice.text.format")
local Config = require("noice.config")
local Util = require("noice.util")

local M = {}

---@type table<string, NoiceMessage>
M._progress = {}
M._running = false

---@class ProgressBegin
---@field kind "begin"
---@field title string
---@field message? string
---@field percentage integer

---@class ProgressReport
---@field kind "report"
---@field message? string
---@field percentage integer

---@class ProgressEnd
---@field kind "end"
---@field message? string

---@param info {client_id: integer}
---@param msg {token: integer, value:ProgressBegin|ProgressReport|ProgressEnd}
function M.progress(_, msg, info)
  local id = info.client_id .. "." .. msg.token

  local message = M._progress[id]
  if not message then
    message = Message("lsp", "progress")
    message.opts.progress = {
      client_id = info.client_id,
      ---@type string
      client = vim.lsp.get_active_clients({ id = info.client_id })[1].name,
    }
    -- message.once = true
    M._progress[id] = message
  end

  message.opts.progress = vim.tbl_deep_extend("force", message.opts.progress, msg.value)
  message.opts.progress.id = id

  if msg.value.kind == "end" then
    if message.opts.progress.percentage then
      message.opts.progress.percentage = 100
    end
    vim.defer_fn(function()
      M.update()
      Router.update()
      Manager.remove(message)
      M._progress[id] = nil
    end, 100)
  end

  M.update()
end

function M._update()
  if not vim.tbl_isempty(M._progress) then
    for _, message in pairs(M._progress) do
      if message.opts.progress.kind == "end" then
        Manager.add(Format.format(message, Config.options.lsp.progress.format_done))
      else
        Manager.add(Format.format(message, Config.options.lsp.progress.format))
      end
    end
    return
  end
end

function M.update()
  error("should never be called")
end

function M.setup()
  M.update = Util.interval(Config.options.lsp.progress.throttle, M._update, {
    enabled = function()
      return not vim.tbl_isempty(M._progress)
    end,
  })
  local orig = vim.lsp.handlers["$/progress"]
  vim.lsp.handlers["$/progress"] = function(...)
    local args = { ... }
    Util.try(function()
      M.progress(unpack(args))
    end)
    orig(...)
  end
end

return M

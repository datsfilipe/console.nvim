local M = {}

local api = vim.api
local split = vim.split
local tbl_insert = table.insert

local config = {
  command_name = 'ConsoleRun',
  hijack_bang = true,
  close_key = ';q',
  window = {
    height_ratio = 0.45,
    min_height = 6,
  },
  interactive = {},
}

local wrapper_id = os.getenv('CONSOLE_ID')
local is_wrapper_session = wrapper_id ~= nil
local session_id = wrapper_id or tostring(vim.fn.getpid())

local state = {
  buf = nil,
  win = nil,
  job = nil,
  queue = {},
  remainder = '',
  keep_alive = false,
  cmd_file = '/tmp/nvim_console_cmd_' .. session_id,
  out_file = '/tmp/nvim_console_out_' .. session_id,
}

local augroup = api.nvim_create_augroup('ConsoleRun', { clear = true })

local function strip_ansi(text) return text:gsub('\27%[[0-9;?]*[a-zA-Z]', '') end

local function reset_buffer()
  if not (state.buf and api.nvim_buf_is_valid(state.buf)) then state.buf = api.nvim_create_buf(false, true) end
  local bo = vim.bo[state.buf]; bo.modifiable = true; bo.buftype = 'nofile'; bo.swapfile = false; bo.bufhidden = 'hide'; bo.filetype = 'console'
  api.nvim_buf_set_lines(state.buf, 0, -1, false, {})
  bo.modifiable = false
end

local function ensure_window()
  reset_buffer()
  local total_lines = vim.o.lines
  local height = math.max(config.window.min_height, math.floor(total_lines * config.window.height_ratio))
  if state.win and api.nvim_win_is_valid(state.win) then api.nvim_win_set_buf(state.win, state.buf); pcall(api.nvim_win_set_height, state.win, height); return end
  vim.cmd(string.format('botright %dsplit', height))
  state.win = api.nvim_get_current_win()
  api.nvim_win_set_buf(state.win, state.buf)
  local wo = vim.wo[state.win]; wo.number = false; wo.relativenumber = false; wo.signcolumn = 'no'; wo.wrap = false; wo.cursorline = false; wo.winfixheight = true
  vim.keymap.set('n', 'q', M.close, { buffer = state.buf, silent = true, nowait = true })
  if config.close_key then vim.keymap.set('n', config.close_key, M.close, { buffer = state.buf, silent = true, nowait = true }) end
end

local function flush_queue()
  local queue_len = #state.queue; if queue_len == 0 then return end
  if not (state.buf and api.nvim_buf_is_valid(state.buf)) then state.queue = {}; state.remainder = ''; return end
  local bo = vim.bo[state.buf]; bo.modifiable = true
  api.nvim_buf_set_lines(state.buf, -1, -1, false, state.queue)
  local total_lines = api.nvim_buf_line_count(state.buf)
  if total_lines > 10000 then api.nvim_buf_set_lines(state.buf, 0, total_lines - 9000, false, {}) end
  bo.modifiable = false
  if state.win and api.nvim_win_is_valid(state.win) then local new_count = api.nvim_buf_line_count(state.buf); api.nvim_win_set_cursor(state.win, { new_count, 0 }); vim.cmd 'redraw' end
  state.queue = {}
end

local function schedule_flush() vim.schedule(flush_queue) end

local function append_stream(data)
  if not data or data == '' then return end
  data = data:gsub('\r', ''); data = strip_ansi(data)
  local text = state.remainder .. data
  if not text:find('\n', 1, true) then state.remainder = text; return end
  local lines = split(text, '\n', { plain = true })
  state.remainder = lines[#lines]; lines[#lines] = nil
  for _, line in ipairs(lines) do tbl_insert(state.queue, line) end
  schedule_flush()
end

local function append_direct(lines) for _, line in ipairs(lines) do tbl_insert(state.queue, line) end; schedule_flush() end

local function stop_job() if state.job then pcall(vim.fn.jobstop, state.job); state.job = nil end end

function M.close()
  stop_job(); api.nvim_clear_autocmds { group = augroup }; state.keep_alive = false
  if state.win and api.nvim_win_is_valid(state.win) then api.nvim_win_close(state.win, true); state.win = nil end
end

local function send_input(input)
  if state.job then
    append_direct({ '$ ' .. input })
    vim.fn.chansend(state.job, input .. '\r')
  else
    vim.notify('No active job to receive input', vim.log.levels.WARN)
  end
end

local function run_interactive(cmdline, handler)
  os.remove(state.cmd_file); os.remove(state.out_file)
  local f = io.open(state.cmd_file, 'w')
  if f then f:write(cmdline .. ' > ' .. state.out_file); f:flush(); f:close() else vim.notify('Failed to write IPC command file', vim.log.levels.ERROR); return end

  local resume_group = api.nvim_create_augroup('ConsoleResume', { clear = true })
  api.nvim_create_autocmd('VimResume', {
    group = resume_group,
    once = true,
    callback = function()
      local out_f = io.open(state.out_file, 'r')
      if out_f then local content = out_f:read '*a'; out_f:close(); os.remove(state.out_file); if handler then handler(content) end end
      os.remove(state.cmd_file)
    end,
  })
  vim.cmd 'suspend'
end

function M.run(cmdline)
  if not cmdline or cmdline == '' then vim.notify(config.command_name .. ' requires a command', vim.log.levels.WARN); return end

  local trimmed = cmdline:match("^%s*(.+)") or cmdline
  local interactive_handler = nil
  for key, handler in pairs(config.interactive) do
    if trimmed == key or trimmed:sub(1, #key + 1) == (key .. ' ') then interactive_handler = handler; break end
  end

  if interactive_handler then
    if is_wrapper_session then
      vim.schedule(function() run_interactive(cmdline, interactive_handler) end)
      return
    else
      vim.notify("Console wrapper not active. Suspend disabled for '" .. trimmed .. "'.", vim.log.levels.WARN)
    end
  end

  local current_win = api.nvim_get_current_win()
  ensure_window()
  if current_win ~= state.win and api.nvim_win_is_valid(current_win) then api.nvim_set_current_win(current_win) end

  stop_job(); api.nvim_clear_autocmds { group = augroup }
  state.queue = {}; state.remainder = ''; append_direct { '$ ' .. cmdline }

  state.job = vim.fn.jobstart(cmdline, {
    pty = true,
    on_stdout = function(_, data, _) if data then append_stream(table.concat(data, '\n')) end end,
    on_stderr = function(_, data, _) if data then append_stream(table.concat(data, '\n')) end end,
    on_exit = function(_, code, _)
      state.job = nil; state.keep_alive = false
      if state.remainder ~= '' then table.insert(state.queue, state.remainder); state.remainder = '' end
      table.insert(state.queue, string.format('[exit %d]', code or -1))
      vim.schedule(flush_queue)
    end,
  })

  api.nvim_create_autocmd('CmdlineLeave', {
    group = augroup,
    callback = function() vim.schedule(function() if state.job and not state.keep_alive then M.close() end end) end,
  })
end

function M.setup(opts)
  config = vim.tbl_deep_extend('force', config, opts or {})

  api.nvim_create_user_command(config.command_name, function(cmd_opts) M.run(cmd_opts.args) end, { nargs = '+', complete = 'shellcmd' })

  if config.hijack_bang then
    vim.keymap.set('c', '<CR>', function()
      local cmdtype = vim.fn.getcmdtype(); local cmdline = vim.fn.getcmdline()
      if cmdtype == ':' and cmdline:match '^!' then
        local command_str = cmdline:sub(2); vim.fn.histadd('cmd', cmdline)
        if state.job then
           vim.schedule(function() state.keep_alive = true; send_input(command_str); api.nvim_feedkeys(':!', 'n', false); vim.defer_fn(function() state.keep_alive = false end, 500) end)
        else
           vim.schedule(function() M.run(command_str); if state.job then api.nvim_feedkeys(':!', 'n', false) end end)
        end
        return api.nvim_replace_termcodes('<C-c>', true, false, true)
      end
      return '<CR>'
    end, { expr = true })
  end
end

return M

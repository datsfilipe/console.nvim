local M = {}

local api = vim.api
local fn = vim.fn
local uv = vim.loop

local config = {
  command_name = 'ConsoleRun',
  grep_command_name = 'LiveGrep',
  find_command_name = 'LiveFiles',
  close_key = ';q',
  window = {
    height_ratio = 0.45,
    min_height = 6,
  },
}

local state = {
  buf = nil,
  win = nil,
  input_buf = nil,
  input_win = nil,
  origin_win = nil,
  job = nil,
  timer = nil,
  queue = {},
  remainder = '',
  ns_id = api.nvim_create_namespace 'ConsoleHighlights',
}

local augroup = api.nvim_create_augroup('ConsoleRun', { clear = true })

local function stop_active_processes()
  if state.job then
    pcall(fn.jobstop, state.job)
    state.job = nil
  end
  if state.timer then
    state.timer:stop()
    if not state.timer:is_closing() then
      state.timer:close()
    end
    state.timer = nil
  end
end

local function strip_ansi(text)
  return text:gsub('\27%[[0-9;?]*[a-zA-Z]', '')
end

local function resolve_valid_path(text)
  if not text or #text < 2 or text == '.' or text == '..' then
    return nil
  end

  if uv.fs_stat(text) then
    return text
  end

  local found = fn.findfile(text)
  if found ~= '' then
    return found
  end

  found = fn.finddir(text)
  if found ~= '' then
    return found
  end

  return nil
end

local function apply_syntax(buf)
  api.nvim_buf_call(buf, function()
    vim.cmd [[
      syntax clear
      syntax match ConsolePrompt /^\$ .*/
      syntax match ConsoleExit /^\[exit \d\+\]/
      syntax match ConsoleLine /:\d\+:\d\+:/
      syntax match ConsoleLine /:\d\+:/
      
      highlight default link ConsolePrompt Statement
      highlight default link ConsoleExit Comment
      highlight default link ConsoleLine Constant
    ]]
  end)
end

local function apply_search_highlight(query)
  ---@diagnostic disable-next-line: param-type-mismatch
  pcall(vim.cmd, 'syntax clear ConsoleMatch')
  if not query or query == '' then
    return
  end

  local regex = '\\c' .. fn.escape(query, '\\/.*$^~[]')
  vim.cmd(string.format('syntax match ConsoleMatch /%s/', regex))
  vim.cmd 'highlight default link ConsoleMatch Search'
end

local function apply_extmarks(start_line, end_line)
  if not (state.buf and api.nvim_buf_is_valid(state.buf)) then
    return
  end

  api.nvim_buf_call(state.buf, function()
    local lines = api.nvim_buf_get_lines(state.buf, start_line, end_line, false)

    for i, line in ipairs(lines) do
      local line_idx = start_line + i - 1

      local s, _, grep_file = line:find '^([^: ]+):%d+:'
      if s and grep_file and resolve_valid_path(grep_file) then
        api.nvim_buf_set_extmark(state.buf, state.ns_id, line_idx, s - 1, {
          end_col = s - 1 + #grep_file,
          hl_group = 'Directory',
          priority = 100,
        })
      else
        local init = 1
        while true do
          local ws, we = line:find('%S+', init)
          if not ws then
            break
          end

          local word = line:sub(ws, we)
          local clean_word = word:gsub('[\'",:;]$', '')

          if resolve_valid_path(clean_word) then
            api.nvim_buf_set_extmark(state.buf, state.ns_id, line_idx, ws - 1, {
              end_col = ws - 1 + #clean_word,
              hl_group = 'Directory',
              priority = 100,
            })
          end
          init = we + 1
        end
      end
    end
  end)
end

local function flush_queue()
  if
    #state.queue == 0 or not (state.buf and api.nvim_buf_is_valid(state.buf))
  then
    state.queue = {}
    return
  end

  local bo = vim.bo[state.buf]
  bo.modifiable = true

  local start_line = api.nvim_buf_line_count(state.buf)
  api.nvim_buf_set_lines(state.buf, -1, -1, false, state.queue)
  local end_line = api.nvim_buf_line_count(state.buf)

  if end_line > 10000 then
    api.nvim_buf_set_lines(state.buf, 0, end_line - 9000, false, {})
  end

  bo.modifiable = false
  state.queue = {}

  apply_extmarks(start_line, end_line)

  if state.win and api.nvim_win_is_valid(state.win) then
    api.nvim_win_set_cursor(
      state.win,
      { api.nvim_buf_line_count(state.buf), 0 }
    )
    vim.cmd 'redraw'
  end
end

local function append_data(data)
  if not data or data == '' then
    return
  end

  data = strip_ansi(data:gsub('\r', ''))
  local text = state.remainder .. data

  if not text:find('\n', 1, true) then
    state.remainder = text
    return
  end

  local lines = vim.split(text, '\n', { plain = true })
  state.remainder = lines[#lines]
  lines[#lines] = nil

  vim.list_extend(state.queue, lines)
  vim.schedule(flush_queue)
end

local function open_file(file, row, col)
  M.close()

  local target = (state.origin_win and api.nvim_win_is_valid(state.origin_win))
      and state.origin_win
    or api.nvim_get_current_win()

  api.nvim_set_current_win(target)
  ---@diagnostic disable-next-line: param-type-mismatch
  pcall(vim.cmd, 'edit ' .. fn.fnameescape(file))

  if row then
    pcall(api.nvim_win_set_cursor, 0, { tonumber(row), tonumber(col or 1) - 1 })
    vim.cmd 'normal! zz'
  end
end

local function jump_to_result()
  local line = api.nvim_get_current_line()

  local file, row, col = line:match '^([^: ]+):(%d+):(%d+):'
  if not file then
    file, row = line:match '^([^: ]+):(%d+):'
  end

  if file then
    local path = resolve_valid_path(file)
    if path then
      return open_file(path, row, col)
    end
  end

  local cfile = fn.expand '<cfile>'
  if cfile ~= '' and resolve_valid_path(cfile) then
    return open_file(cfile)
  end

  for word in line:gmatch '%S+' do
    local clean = word:gsub('[\'",:;]$', '')
    local path = resolve_valid_path(clean)
    if path then
      return open_file(path)
    end
  end
end

local function set_common_buf_opts(buf)
  local bo = vim.bo[buf]
  bo.buftype = 'nofile'
  bo.swapfile = false
  bo.bufhidden = 'hide'
  bo.filetype = 'console'
end

local function ensure_output_window()
  local current_win = api.nvim_get_current_win()
  if current_win ~= state.win and current_win ~= state.input_win then
    state.origin_win = current_win
  end

  if not (state.buf and api.nvim_buf_is_valid(state.buf)) then
    state.buf = api.nvim_create_buf(false, true)
    set_common_buf_opts(state.buf)
    apply_syntax(state.buf)

    local opts = { buffer = state.buf, silent = true }
    vim.keymap.set('n', '<CR>', jump_to_result, opts)
    vim.keymap.set('n', 'q', M.close, opts)
    if config.close_key then
      vim.keymap.set('n', config.close_key, M.close, opts)
    end
  end

  if not (state.win and api.nvim_win_is_valid(state.win)) then
    local wins = fn.win_findbuf(state.buf)
    if #wins > 0 then
      state.win = wins[1]
    else
      local height = math.max(
        config.window.min_height,
        math.floor(vim.o.lines * config.window.height_ratio)
      )
      vim.cmd('botright ' .. height .. 'split')
      state.win = api.nvim_get_current_win()
    end
  end

  api.nvim_win_set_buf(state.win, state.buf)

  local wo = vim.wo[state.win]
  wo.winfixheight = true
  wo.number = false
  wo.signcolumn = 'no'
  wo.statusline = ' '
  wo.fillchars = 'eob: '
end

function M.close()
  stop_active_processes()
  api.nvim_clear_autocmds { group = augroup }

  if state.win and api.nvim_win_is_valid(state.win) then
    api.nvim_win_close(state.win, true)
    state.win = nil
  end

  if state.input_win and api.nvim_win_is_valid(state.input_win) then
    api.nvim_win_close(state.input_win, true)
    state.input_win = nil
  end
end

function M.run(cmdline)
  if not cmdline or cmdline == '' then
    return
  end

  ensure_output_window()
  stop_active_processes()
  state.queue = {}
  state.remainder = ''

  local bo = vim.bo[state.buf]
  bo.modifiable = true
  api.nvim_buf_set_lines(state.buf, 0, -1, false, { '$ ' .. cmdline })
  bo.modifiable = false

  for part in cmdline:gmatch '%S+' do
    if part:match '/' and uv.fs_stat(part) then
      vim.opt_local.path:append(part)
    end
  end

  state.job = fn.jobstart(cmdline, {
    pty = true,
    on_stdout = function(_, d)
      append_data(table.concat(d, '\n'))
    end,
    on_stderr = function(_, d)
      append_data(table.concat(d, '\n'))
    end,
    on_exit = function(_, code)
      state.job = nil
      if state.remainder ~= '' then
        table.insert(state.queue, state.remainder)
        state.remainder = ''
      end
      table.insert(state.queue, string.format('[exit %d]', code or -1))
      vim.schedule(flush_queue)
    end,
  })
end

local function start_live_session(cmd_generator)
  ensure_output_window()
  stop_active_processes()

  vim.bo[state.buf].modifiable = true
  api.nvim_buf_set_lines(state.buf, 0, -1, false, {})
  api.nvim_buf_clear_namespace(state.buf, state.ns_id, 0, -1)
  vim.bo[state.buf].modifiable = false

  state.input_buf = api.nvim_create_buf(false, true)
  vim.bo[state.input_buf].buftype = 'nofile'
  vim.bo[state.input_buf].bufhidden = 'wipe'

  if state.input_win and api.nvim_win_is_valid(state.input_win) then
    api.nvim_set_current_win(state.input_win)
  else
    vim.cmd 'botright 1split'
    state.input_win = api.nvim_get_current_win()
  end

  api.nvim_win_set_buf(state.input_win, state.input_buf)

  local wo = vim.wo[state.input_win]
  wo.winfixheight = true
  wo.number = false
  wo.signcolumn = 'no'
  wo.statusline = ' '
  wo.fillchars = 'eob: '

  local map_opts = { buffer = state.input_buf }
  vim.keymap.set({ 'n', 'i' }, '<Esc>', M.close, map_opts)
  vim.keymap.set('i', '<CR>', function()
    vim.cmd 'stopinsert'
    if state.win and api.nvim_win_is_valid(state.win) then
      api.nvim_set_current_win(state.win)
    end
  end, map_opts)

  api.nvim_create_autocmd('TextChangedI', {
    buffer = state.input_buf,
    callback = function()
      if state.timer then
        state.timer:stop()
      end
      state.timer = uv.new_timer()
      state.timer:start(
        150,
        0,
        vim.schedule_wrap(function()
          local lines = api.nvim_buf_get_lines(state.input_buf, 0, 1, false)
          local query = lines[1] or ''

          if state.job then
            fn.jobstop(state.job)
          end

          api.nvim_buf_call(state.buf, function()
            apply_search_highlight(query)
          end)

          vim.bo[state.buf].modifiable = true
          api.nvim_buf_set_lines(state.buf, 0, -1, false, {})
          vim.bo[state.buf].modifiable = false
          state.queue = {}
          state.remainder = ''

          if query == '' then
            return
          end

          local cmd = cmd_generator(query)

          state.job = fn.jobstart(cmd, {
            on_stdout = function(_, d)
              append_data(table.concat(d, '\n'))
            end,
            on_stderr = function(_, d)
              append_data(table.concat(d, '\n'))
            end,
          })
        end)
      )
    end,
  })

  vim.cmd 'startinsert'
end

function M.live_grep()
  start_live_session(function(query)
    return string.format(
      'rg --vimgrep --smart-case --color=never "%s" .',
      query:gsub('"', '\\"')
    )
  end)
end

function M.live_files()
  start_live_session(function(query)
    local escaped_query = query:gsub('"', '\\"')

    return {
      'sh',
      '-c',
      string.format(
        'rg --files --color=never . | rg --smart-case --color=never "%s"',
        escaped_query
      ),
    }
  end)
end

function M.setup(opts)
  config = vim.tbl_deep_extend('force', config, opts or {})

  api.nvim_create_user_command(config.command_name, function(o)
    M.run(o.args)
  end, { nargs = '+', complete = 'shellcmd' })

  if config.grep_command_name then
    api.nvim_create_user_command(config.grep_command_name, M.live_grep, {})
  end

  if config.find_command_name then
    api.nvim_create_user_command(config.find_command_name, M.live_files, {})
  end
end

return M

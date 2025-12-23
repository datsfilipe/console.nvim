vim.cmd [[set runtimepath=$VIMRUNTIME]]

local current_dir = vim.fn.getcwd()
vim.opt.rtp:prepend(current_dir)

local status, plugin = pcall(require, 'console')
if not status then
  vim.print 'shit happens'
else
  plugin.setup {
    command_name = 'TestRun',
    grep_command_name = 'TestGrep',
    find_command_name = 'TestFind',
  }
end

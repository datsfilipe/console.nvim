vim.opt.number = true
vim.opt.relativenumber = true

vim.cmd [[set runtimepath=$VIMRUNTIME]]

local current_dir = vim.fn.getcwd()
vim.opt.rtp:prepend(current_dir)

local status, plugin = pcall(require, 'console')
if not status then
  vim.print 'shit happens'
else
  plugin.setup {}
end

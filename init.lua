package.path = './?.lua;' .. package.path

package.loaded['lua.console.init'] = nil
package.loaded['console'] = nil

local console = require 'lua.console.init'

console.setup {
  interactive = {
    fzf = function(output)
      local path = output:gsub('^%s*(.-)%s*$', '%1')
      if path ~= '' then
        print('Opening: ' .. path)
        vim.cmd('edit ' .. vim.fn.fnameescape(path))
      else
        print 'No file selected.'
      end
    end,
    lazygit = function()
      vim.cmd 'checktime'
    end,
  },
}

<div align="center">

# `console.nvim`

Terminal interaction on Neovim. Might be a useless plugin, but I kinda like the aesthetics of it. Based on [@tsoding](https://github.com/rexim) workflow on Emacs (I never used Emacs, and probably never will).

</div>

## Installation

- **lazy.nvim**:

```lua
{
  "datsfilipe/console.nvim",
  config = function()
    require("console").setup()
  end
}
```

- **vim.pack.add**:

```lua
vim.pack.add({
  'https://github.com/datsfilipe/console.nvim',
})

require("console").setup()
```

## Configuration

You can customize the plugin by passing a table to the setup function. The default configuration is:

```lua
require("console").setup({
  -- The name of the user command
  command_name = 'ConsoleRun',
  -- Hijacks the standard :! command to use console.nvim
  hijack_bang = true, 
  -- Global and buffer-local mapping to close the window
  -- Set to false or nil to disable
  close_key = ';q',
  window = {
    height_ratio = 0.45,
    min_height = 6,
  },
})
```

## License

Refer to [LICENSE](./LICENSE).

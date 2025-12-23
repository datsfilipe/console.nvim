<div align="center">

# console.nvim

Async command runner, live grep, and file searcher for Neovim.

</div>

## Requirements

- `ripgrep` (required for grep)
- `fd` (optional, for file find)

## Installation

```lua
vim.pack.add 'user/console.nvim'

require("console").setup({
  command_name = "ConsoleRun",
  grep_command_name = "LiveGrep",
  find_command_name = "LiveFiles",
  close_key = ";q",
  window = { height_ratio = 0.45, min_height = 6 },
})
```

## Usage

| command       |  action                                                       |
|---------------|---------------------------------------------------------------|
| `:ConsoleRun` | run shell command asynchronously (e.g., `:ConsoleRun make`).  |
| `:LiveGrep`   | Open live grep input.                                         |
| `:LiveFiles`  | Open live file finder.                                        |

## License

Refer to [LICENSE](./LICENSE).

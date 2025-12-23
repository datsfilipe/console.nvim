<div align="center">

# console.nvim

Async command runner, live grep, and file searcher for Neovim.

</div>

## Requirements

- `ripgrep` (required for grep)
- `fd` (optional, for file find)

## Installation

```lua
vim.pack.add "user/console.nvim"

require("console").setup({
  command_name = "ConsoleRun",
  close_command_name = "ConsoleClose",
  grep_command_name = "LiveGrep",
  find_command_name = "LiveFiles",
  window = { height_ratio = 0.45, min_height = 6 },
})
```

## Usage

| command         |  action                                                       |
|-----------------|---------------------------------------------------------------|
| `:ConsoleRun`   | run shell command asynchronously (e.g., `:ConsoleRun make`).  |
| `:ConsoleClose` | close it.                                                     |
| `:LiveGrep`     | open live grep input.                                         |
| `:LiveFiles`    | open live file finder.                                        |

## License

Refer to [LICENSE](./LICENSE).

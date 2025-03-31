# bouncer

A Neovim plugin for managing Terraform module sources between local and registry references.

This plugin simplifies the workflow when developing Terraform modules by allowing you to quickly switch between local module references and registry sources.

## Features

Switch terraform module references between local and registry paths across your project

Auto-detect the appropriate registry path based on your repository name

Automatically fetch and apply the latest module version constraints

Consistent formatting of module source and version attributes

## Usage

To configure the plugin with [lazy.nvim](https://github.com/folke/lazy.nvim), use the following setup:

```lua
return {
  "dkooll/bouncer.nvim",
  dependencies = { "nvim-lua/plenary.nvim" },
  lazy = true,
  cmd = { "BounceModuleToLocal", "BounceModuleToRegistry", "BounceModulesToRegistry" },
  keys = {
    { "<leader>bl", ":BounceModuleToLocal<CR>",     desc = "Bouncer: Change Current Module to Local" },
    { "<leader>br", ":BounceModuleToRegistry<CR>",  desc = "Bouncer: Change Current Module to Registry" },
    { "<leader>ba", ":BounceModulesToRegistry<CR>", desc = "Bouncer: Change All Modules to Registry" },
  },
  config = function()
    require("bouncer").setup({
      namespace = "cloudnationhq"
    })
  end,
}
```

## Configuration

The setup function accepts the following options:

`namespace (required)`

The registry namespace for your Terraform modules

## Commands

`:BounceModuleToLocal`

Changes the current module's source to local (../../)

`:BounceModuleToRegistry`

Changes the current module's source to registry and updates its version

`:BounceModulesToRegistry`

Updates all modules with registry sources to use the latest available versions

## Notes

This plugin works by analyzing your project structure and follows these assumptions:

Your repository follows the naming convention: terraform-{provider}-{module}

It will search for all main.tf files in your project sub directories in the examples folder

Registry modules should follow the format: {namespace}/{module}/{provider}

When switching to local development, it uses the relative path "../../"

Version constraints follow the Terraform convention ~> X.0 for major versions

## Contributors

We welcome contributions from the community! Whether it's reporting a bug, suggesting a new feature, or submitting a pull request, your input is highly valued. <br><br>

<a href="https://github.com/dkooll/bouncer.nvim/graphs/contributors">
  <img src="https://contrib.rocks/image?repo=dkooll/bouncer.nvim" />
</a>

## Requirements

[Neovim](https://neovim.io/) 0.7.0 or higher

[plenary.nvim](https://github.com/nvim-lua/plenary.nvim)

Either [fd](https://github.com/sharkdp/fd) or the find command (for locating Terraform files)

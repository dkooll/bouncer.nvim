local M = {}

-- Helper function to manage LSP
local function with_lsp_management(callback)
  -- Store original notify function
  local old_notify = vim.notify
  vim.notify = function(msg, level, opts)
    if not msg:match("LSP") and not msg:match("Buffer") then
      old_notify(msg, level, opts)
    end
  end

  -- Find and stop terraform LSP client
  local clients = vim.lsp.get_active_clients()
  for _, client in ipairs(clients) do
    if client.name == "terraformls" then
      vim.lsp.stop_client(client.id, true)
      break
    end
  end

  -- Execute the callback
  callback()

  -- Restore vim state silently
  vim.cmd('silent! bufdo e!')

  -- Restart terraform LSP client after a short delay
  vim.defer_fn(function()
    vim.cmd('silent! LspStart terraformls')
    -- Restore original notify function
    vim.notify = old_notify
  end, 1000)
end

-- Function to process file content
local function process_file(file_path, module_config, is_local)
  -- Read the file
  local lines = vim.fn.readfile(file_path)
  if not lines then
    vim.notify("Failed to read file: " .. file_path, vim.log.levels.ERROR)
    return false
  end

  local modified = false
  local in_module_block = false
  local new_lines = {}

  for i, line in ipairs(lines) do
    -- Changed this line to use the lowercase module key instead of name
    if line:match('module%s*"rg"%s*{') then -- Changed from name:lower() to actual module name
      in_module_block = true
      table.insert(new_lines, line)
    elseif in_module_block and line:match('^%s*}') then
      in_module_block = false
      table.insert(new_lines, line)
    elseif in_module_block then
      if line:match('%s*source%s*=') then
        if is_local then
          table.insert(new_lines, '  source = "../../"')
        else
          table.insert(new_lines, string.format('  source  = "%s"', module_config.registry_source))
        end
        modified = true
      elseif is_local and line:match('%s*version%s*=') then
        modified = true
      elseif not is_local and not line:match('%s*version%s*=') and lines[i - 1]:match('%s*source%s*=') then
        table.insert(new_lines, string.format('  version = "%s"', module_config.version))
        table.insert(new_lines, line)
        modified = true
      else
        table.insert(new_lines, line)
      end
    else
      table.insert(new_lines, line)
    end
  end

  if modified then
    if vim.fn.writefile(new_lines, file_path) == -1 then
      vim.notify("Failed to write file: " .. file_path, vim.log.levels.ERROR)
      return false
    end
    return true
  end

  return false
end

local function create_module_commands(module_config)
  vim.api.nvim_create_user_command("Switch" .. module_config.name .. "ModulesToLocal", function()
    with_lsp_management(function()
      local find_cmd = "find . -name main.tf"
      local files = vim.fn.systemlist(find_cmd)

      local modified_count = 0
      for _, file in ipairs(files) do
        if process_file(file, module_config, true) then
          modified_count = modified_count + 1
          vim.notify("Modified " .. file, vim.log.levels.INFO)
        end
      end

      if modified_count > 0 then
        vim.notify(string.format("Modified %d files", modified_count), vim.log.levels.INFO)
      else
        vim.notify("No files were modified", vim.log.levels.WARN)
      end
    end)
  end, {})

  vim.api.nvim_create_user_command("Switch" .. module_config.name .. "ModulesToRegistry", function()
    with_lsp_management(function()
      local find_cmd = "find . -name main.tf"
      local files = vim.fn.systemlist(find_cmd)

      local modified_count = 0
      for _, file in ipairs(files) do
        if process_file(file, module_config, false) then
          modified_count = modified_count + 1
          vim.notify("Modified " .. file, vim.log.levels.INFO)
        end
      end

      if modified_count > 0 then
        vim.notify(string.format("Modified %d files", modified_count), vim.log.levels.INFO)
      else
        vim.notify("No files were modified", vim.log.levels.WARN)
      end
    end)
  end, {})
end

function M.setup(opts)
  -- Default configuration
  local default_modules = {
    storage = {
      name = "Storage",
      registry_source = "cloudnationhq/sa/azure",
      version = "~> 2.0"
    }
  }

  -- Merge user config with defaults
  local modules = vim.tbl_deep_extend("force", default_modules, opts or {})

  -- Setup LSP handling
  vim.api.nvim_create_autocmd("FileType", {
    pattern = "terraform",
    callback = function()
      vim.b.terraform_ignore_single_file_warning = true
    end,
  })

  -- Create commands for each module
  for _, module_config in pairs(modules) do
    create_module_commands(module_config)
  end
end

return M

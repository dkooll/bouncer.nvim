local M = {}

-- Function to process file content
local function process_file(file_path, module_key, module_config, is_local)
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
    -- Match the exact module key (e.g., "rg", "storage", etc.)
    if line:match(string.format('module%%s*"%s"%%s*{', module_key)) then
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

local function create_module_commands(module_key, module_config)
  vim.api.nvim_create_user_command("Switch" .. module_config.name .. "ModulesToLocal", function()
    local find_cmd = "find . -name main.tf"
    local files = vim.fn.systemlist(find_cmd)

    local modified_count = 0
    for _, file in ipairs(files) do
      if process_file(file, module_key, module_config, true) then
        modified_count = modified_count + 1
        vim.notify("Modified " .. file, vim.log.levels.INFO)
      end
    end

    if modified_count > 0 then
      vim.notify(string.format("Modified %d files", modified_count), vim.log.levels.INFO)
    else
      vim.notify("No files were modified", vim.log.levels.WARN)
    end

    -- Reload current buffer if it was modified
    vim.cmd('edit')
  end, {})

  vim.api.nvim_create_user_command("Switch" .. module_config.name .. "ModulesToRegistry", function()
    local find_cmd = "find . -name main.tf"
    local files = vim.fn.systemlist(find_cmd)

    local modified_count = 0
    for _, file in ipairs(files) do
      if process_file(file, module_key, module_config, false) then
        modified_count = modified_count + 1
        vim.notify("Modified " .. file, vim.log.levels.INFO)
      end
    end

    if modified_count > 0 then
      vim.notify(string.format("Modified %d files", modified_count), vim.log.levels.INFO)
    else
      vim.notify("No files were modified", vim.log.levels.WARN)
    end

    -- Reload current buffer if it was modified
    vim.cmd('edit')
  end, {})
end

function M.setup(opts)
  -- Create commands for each module
  for module_key, module_config in pairs(opts) do
    create_module_commands(module_key, module_config)
  end
end

return M

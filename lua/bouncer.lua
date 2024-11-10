local M = {}

-- Helper function to extract module name from registry source
local function get_module_name(registry_source)
  local module_name = registry_source:match("^[^/]+/([^/]+)/")
  if not module_name then
    error("Invalid registry source format: " .. registry_source)
  end
  -- Print for debugging
  vim.notify("Extracted module name: " .. module_name, vim.log.levels.INFO)
  return module_name:lower(), module_name:sub(1,1):upper() .. module_name:sub(2):lower()
end

-- Function to process file content
local function process_file(file_path, module_names, module_config, is_local)
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
    -- Check for both lowercase and capitalized module names
    local module_pattern = string.format('module%%s*"[%s%s]"%%s*{', module_names[1], module_names[2])
    if line:match(module_pattern) then
      vim.notify("Found module block: " .. line, vim.log.levels.INFO)
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

local function create_module_commands(_, module_config)
  local module_name_lower, module_name_cap = get_module_name(module_config.registry_source)

  vim.notify(string.format("Creating commands for module: %s and %s", module_name_lower, module_name_cap), vim.log.levels.INFO)

  for _, name in ipairs({module_name_lower, module_name_cap}) do
    vim.api.nvim_create_user_command("Switch" .. name .. "ModulesToLocal", function()
      local find_cmd = "find . -name main.tf"
      local files = vim.fn.systemlist(find_cmd)
      vim.notify("Searching in files: " .. vim.inspect(files), vim.log.levels.INFO)

      local modified_count = 0
      for _, file in ipairs(files) do
        if process_file(file, {module_name_lower, module_name_cap}, module_config, true) then
          modified_count = modified_count + 1
          vim.notify("Modified " .. file, vim.log.levels.INFO)
        end
      end
      if modified_count > 0 then
        vim.notify(string.format("Modified %d files", modified_count), vim.log.levels.INFO)
      else
        vim.notify("No files were modified", vim.log.levels.WARN)
      end
      vim.cmd('edit')
    end, {})

    vim.api.nvim_create_user_command("Switch" .. name .. "ModulesToRegistry", function()
      local find_cmd = "find . -name main.tf"
      local files = vim.fn.systemlist(find_cmd)
      local modified_count = 0
      for _, file in ipairs(files) do
        if process_file(file, {module_name_lower, module_name_cap}, module_config, false) then
          modified_count = modified_count + 1
          vim.notify("Modified " .. file, vim.log.levels.INFO)
        end
      end
      if modified_count > 0 then
        vim.notify(string.format("Modified %d files", modified_count), vim.log.levels.INFO)
      else
        vim.notify("No files were modified", vim.log.levels.WARN)
      end
      vim.cmd('edit')
    end, {})
  end
end

function M.setup(opts)
  for _, module_config in pairs(opts) do
    create_module_commands(_, module_config)
  end
end

return M


--local M = {}

---- Helper function to extract module name from registry source
--local function get_module_name(registry_source)
  --local module_name = registry_source:match("^[^/]+/([^/]+)/")
  --if not module_name then
    --error("Invalid registry source format: " .. registry_source)
  --end
  ---- Return both lowercase and capitalized versions
  --return module_name:lower(), module_name:sub(1, 1):upper() .. module_name:sub(2):lower()
--end

---- Function to process file content
--local function process_file(file_path, module_names, module_config, is_local)
  ---- Read the file
  --local lines = vim.fn.readfile(file_path)
  --if not lines then
    --vim.notify("Failed to read file: " .. file_path, vim.log.levels.ERROR)
    --return false
  --end

  --local modified = false
  --local in_module_block = false
  --local new_lines = {}

  --for i, line in ipairs(lines) do
    ---- Check for both lowercase and capitalized module names
    --local module_pattern = string.format('module%%s*"[%s%s]"%%s*{', module_names[1], module_names[2])
    --if line:match(module_pattern) then
      --in_module_block = true
      --table.insert(new_lines, line)
    --elseif in_module_block and line:match('^%s*}') then
      --in_module_block = false
      --table.insert(new_lines, line)
    --elseif in_module_block then
      --if line:match('%s*source%s*=') then
        --if is_local then
          --table.insert(new_lines, '  source = "../../"')
        --else
          --table.insert(new_lines, string.format('  source  = "%s"', module_config.registry_source))
        --end
        --modified = true
      --elseif is_local and line:match('%s*version%s*=') then
        --modified = true
      --elseif not is_local and not line:match('%s*version%s*=') and lines[i - 1]:match('%s*source%s*=') then
        --table.insert(new_lines, string.format('  version = "%s"', module_config.version))
        --table.insert(new_lines, line)
        --modified = true
      --else
        --table.insert(new_lines, line)
      --end
    --else
      --table.insert(new_lines, line)
    --end
  --end

  --if modified then
    --if vim.fn.writefile(new_lines, file_path) == -1 then
      --vim.notify("Failed to write file: " .. file_path, vim.log.levels.ERROR)
      --return false
    --end
    --return true
  --end

  --return false
--end

--local function create_module_commands(_, module_config)
  --local module_name_lower, module_name_cap = get_module_name(module_config.registry_source)

  --for _, name in ipairs({ module_name_lower, module_name_cap }) do
    --vim.api.nvim_create_user_command("Switch" .. name .. "ModulesToLocal", function()
      --local find_cmd = "find . -name main.tf"
      --local files = vim.fn.systemlist(find_cmd)
      --local modified_count = 0
      --for _, file in ipairs(files) do
        --if process_file(file, { module_name_lower, module_name_cap }, module_config, true) then
          --modified_count = modified_count + 1
          --vim.notify("Modified " .. file, vim.log.levels.INFO)
        --end
      --end
      --if modified_count > 0 then
        --vim.notify(string.format("Modified %d files", modified_count), vim.log.levels.INFO)
      --else
        --vim.notify("No files were modified", vim.log.levels.WARN)
      --end
      --vim.cmd('edit')
    --end, {})

    --vim.api.nvim_create_user_command("Switch" .. name .. "ModulesToRegistry", function()
      --local find_cmd = "find . -name main.tf"
      --local files = vim.fn.systemlist(find_cmd)
      --local modified_count = 0
      --for _, file in ipairs(files) do
        --if process_file(file, { module_name_lower, module_name_cap }, module_config, false) then
          --modified_count = modified_count + 1
          --vim.notify("Modified " .. file, vim.log.levels.INFO)
        --end
      --end
      --if modified_count > 0 then
        --vim.notify(string.format("Modified %d files", modified_count), vim.log.levels.INFO)
      --else
        --vim.notify("No files were modified", vim.log.levels.WARN)
      --end
      --vim.cmd('edit')
    --end, {})
  --end
--end

--function M.setup(opts)
  --for _, module_config in pairs(opts) do
    --create_module_commands(_, module_config)
  --end
--end

--return M

--local M = {}

---- Function to process file content
--local function process_file(file_path, module_key, module_config, is_local)
---- Read the file
--local lines = vim.fn.readfile(file_path)
--if not lines then
--vim.notify("Failed to read file: " .. file_path, vim.log.levels.ERROR)
--return false
--end

--local modified = false
--local in_module_block = false
--local new_lines = {}

--for i, line in ipairs(lines) do
---- Match the exact module key (e.g., "rg", "storage", etc.)
--if line:match(string.format('module%%s*"%s"%%s*{', module_key)) then
--in_module_block = true
--table.insert(new_lines, line)
--elseif in_module_block and line:match('^%s*}') then
--in_module_block = false
--table.insert(new_lines, line)
--elseif in_module_block then
--if line:match('%s*source%s*=') then
--if is_local then
--table.insert(new_lines, '  source = "../../"')
--else
--table.insert(new_lines, string.format('  source  = "%s"', module_config.registry_source))
--end
--modified = true
--elseif is_local and line:match('%s*version%s*=') then
--modified = true
--elseif not is_local and not line:match('%s*version%s*=') and lines[i - 1]:match('%s*source%s*=') then
--table.insert(new_lines, string.format('  version = "%s"', module_config.version))
--table.insert(new_lines, line)
--modified = true
--else
--table.insert(new_lines, line)
--end
--else
--table.insert(new_lines, line)
--end
--end

--if modified then
--if vim.fn.writefile(new_lines, file_path) == -1 then
--vim.notify("Failed to write file: " .. file_path, vim.log.levels.ERROR)
--return false
--end
--return true
--end

--return false
--end

--local function create_module_commands(module_key, module_config)
--vim.api.nvim_create_user_command("Switch" .. module_config.name .. "ModulesToLocal", function()
--local find_cmd = "find . -name main.tf"
--local files = vim.fn.systemlist(find_cmd)

--local modified_count = 0
--for _, file in ipairs(files) do
--if process_file(file, module_key, module_config, true) then
--modified_count = modified_count + 1
--vim.notify("Modified " .. file, vim.log.levels.INFO)
--end
--end

--if modified_count > 0 then
--vim.notify(string.format("Modified %d files", modified_count), vim.log.levels.INFO)
--else
--vim.notify("No files were modified", vim.log.levels.WARN)
--end

---- Reload current buffer if it was modified
--vim.cmd('edit')
--end, {})

--vim.api.nvim_create_user_command("Switch" .. module_config.name .. "ModulesToRegistry", function()
--local find_cmd = "find . -name main.tf"
--local files = vim.fn.systemlist(find_cmd)

--local modified_count = 0
--for _, file in ipairs(files) do
--if process_file(file, module_key, module_config, false) then
--modified_count = modified_count + 1
--vim.notify("Modified " .. file, vim.log.levels.INFO)
--end
--end

--if modified_count > 0 then
--vim.notify(string.format("Modified %d files", modified_count), vim.log.levels.INFO)
--else
--vim.notify("No files were modified", vim.log.levels.WARN)
--end

---- Reload current buffer if it was modified
--vim.cmd('edit')
--end, {})
--end

--function M.setup(opts)
---- Create commands for each module
--for module_key, module_config in pairs(opts) do
--create_module_commands(module_key, module_config)
--end
--end

--return M
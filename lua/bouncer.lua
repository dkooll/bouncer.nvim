local M = {}

-- Helper function to extract module name from registry source
local function get_module_name(registry_source)
  local module_name = registry_source:match("^[^/]+/([^/]+)/")
  if not module_name then
    error("Invalid registry source format: " .. registry_source)
  end
  return {
    module_name:lower(),
    module_name:sub(1, 1):upper() .. module_name:sub(2),
  }
end


local function get_latest_major_version(registry_source, desired_major)
  local plenary_http = require("plenary.curl")

  -- Parse the registry source into namespace, name, and provider
  local namespace, name, provider = registry_source:match("^([^/]+)/([^/]+)/([^/]+)$")
  if not (namespace and name and provider) then
    vim.notify("Invalid registry source format: " .. registry_source, vim.log.levels.ERROR)
    return nil
  end

  -- Build the correct URL for fetching versions
  local registry_url = string.format("https://registry.terraform.io/v1/modules/%s/%s/%s/versions", namespace, name,
    provider)
  local result = plenary_http.get({ url = registry_url, accept = "application/json" })

  if result and result.status == 200 and result.body then
    local data = vim.fn.json_decode(result.body)
    if data and data.modules and data.modules[1] and data.modules[1].versions then
      local latest_version = nil
      local major_prefix = tostring(desired_major) .. "%."

      -- Filter versions to find the latest matching the desired major version
      for _, version_info in ipairs(data.modules[1].versions) do
        if version_info.version:match("^" .. major_prefix) then
          if not latest_version or version_info.version > latest_version then
            latest_version = version_info.version
          end
        end
      end

      if latest_version then
        return "~> " .. desired_major .. ".0" -- Format the version constraint as "~> X.0"
      end
    else
      vim.notify("Failed to parse JSON or 'modules'/'versions' field not found.", vim.log.levels.ERROR)
    end
  else
    vim.notify(
    "Failed to fetch latest version for " .. registry_source .. ": " .. (result and result.status or "No response"),
      vim.log.levels.ERROR)
  end

  return nil -- Return nil if no version found or an error occurred
end



-- Function to process file content
local function process_file(file_path, module_config, is_local)
  local lines = vim.fn.readfile(file_path)
  if not lines then
    vim.notify("Failed to read file: " .. file_path, vim.log.levels.ERROR)
    return false
  end

  local modified = false
  local in_module_block = false
  local new_lines = {}

  for i, line in ipairs(lines) do
    if not in_module_block then
      table.insert(new_lines, line)
      -- Detect start of module block
      if line:match('module%s*"[^"]*"%s*{') and lines[i + 1] then
        if lines[i + 1]:match('source%s*=%s*"' .. module_config.registry_source .. '"') or
            lines[i + 1]:match('source%s*=%s*"../../"') then
          in_module_block = true
        end
      end
    elseif line:match('^%s*}') then
      in_module_block = false
      table.insert(new_lines, line)
    else
      -- Replace source with local or registry source
      if line:match('%s*source%s*=') then
        if is_local then
          table.insert(new_lines, '  source = "../../"')
        else
          table.insert(new_lines, string.format('  source  = "%s"', module_config.registry_source))
        end
        modified = true

      -- Remove version line if switching to local
      elseif is_local and line:match('%s*version%s*=') then
        modified = true

      -- Add version constraint if switching to registry and no version is present
      elseif not is_local and not line:match('%s*version%s*=') and lines[i - 1]:match('%s*source%s*=') then
        local latest_version_constraint = get_latest_major_version(module_config.registry_source, 7)  -- Specify desired major version
        if latest_version_constraint then
          table.insert(new_lines, string.format('  version = "%s"', latest_version_constraint))
        end
        table.insert(new_lines, line)
        modified = true

      else
        table.insert(new_lines, line)
      end
    end
  end

  -- Write back modified lines if there were changes
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
  local module_names = get_module_name(module_config.registry_source)

  for _, name in ipairs(module_names) do
    vim.api.nvim_create_user_command("Bounce" .. name .. "ToLocal", function()
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
      vim.cmd('edit')
    end, {})

    vim.api.nvim_create_user_command("Bounce" .. name .. "ToRegistry", function()
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

--local function get_module_name(registry_source)
--local module_name = registry_source:match("^[^/]+/([^/]+)/")
--if not module_name then
--error("Invalid registry source format: " .. registry_source)
--end
--return {
--module_name:lower(),
--module_name:sub(1, 1):upper() .. module_name:sub(2),
--}
--end

--local function process_file(file_path, module_config, is_local)
--local lines = vim.fn.readfile(file_path)
--if not lines then
--vim.notify("Failed to read file: " .. file_path, vim.log.levels.ERROR)
--return false
--end

--local modified = false
--local in_module_block = false
--local new_lines = {}

--for i, line in ipairs(lines) do
--if not in_module_block then
--table.insert(new_lines, line)
--if line:match('module%s*"[^"]*"%s*{') and lines[i + 1] then
--if lines[i + 1]:match('source%s*=%s*"' .. module_config.registry_source .. '"') or
--lines[i + 1]:match('source%s*=%s*"../../"') then
--in_module_block = true
--end
--end
--elseif line:match('^%s*}') then
--in_module_block = false
--table.insert(new_lines, line)
--else
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
--local module_names = get_module_name(module_config.registry_source)

--for _, name in ipairs(module_names) do
--vim.api.nvim_create_user_command("Bounce" .. name .. "ToLocal", function()
--local find_cmd = "find . -name main.tf"
--local files = vim.fn.systemlist(find_cmd)

--local modified_count = 0
--for _, file in ipairs(files) do
--if process_file(file, module_config, true) then
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

--vim.api.nvim_create_user_command("Bounce" .. name .. "ToRegistry", function()
--local find_cmd = "find . -name main.tf"
--local files = vim.fn.systemlist(find_cmd)
--local modified_count = 0
--for _, file in ipairs(files) do
--if process_file(file, module_config, false) then
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

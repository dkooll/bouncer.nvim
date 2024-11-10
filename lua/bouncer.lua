local M = {}

-- Add telescope requirements at the top
local has_telescope, telescope = pcall(require, "telescope")
if has_telescope then
  local pickers = require "telescope.pickers"
  local finders = require "telescope.finders"
  local conf = require("telescope.config").values
  local actions = require "telescope.actions"
  local action_state = require "telescope.actions.state"
end

-- Helper function to extract module name from registry source
local function get_module_name(registry_source)
  local module_name = registry_source:match("^[^/]+/([^/]+)/")
  if not module_name then
    error("Invalid registry source format: " .. registry_source)
  end
  return {
    module_name:lower(),                                -- e.g., "vnet"
    module_name:sub(1, 1):upper() .. module_name:sub(2), -- e.g., "Vnet"
  }
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
      if line:match('module%s*"[^"]*"%s*{') and lines[i + 1] then
        -- Match both registry source and local source
        if lines[i + 1]:match('source%s*=%s*"' .. module_config.registry_source .. '"') or
            lines[i + 1]:match('source%s*=%s*"../../"') then
          in_module_block = true
        end
      end
    elseif line:match('^%s*}') then
      in_module_block = false
      table.insert(new_lines, line)
    else
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

function M.show_commands()
  if not has_telescope then
    return
  end

  local commands = {}
  for name, cmd in pairs(vim.api.nvim_get_commands({})) do
    if name:match("^Switch.*ModulesTo") then
      -- Extract direction
      local direction = name:match("ModulesTo(.+)$")

      -- Find matching module config to get registry source
      local registry_source = ""
      for _, config in pairs(_G.bouncer_configs or {}) do
        local module_names = get_module_name(config.registry_source)
        for _, mname in ipairs(module_names) do
          if name:match("^Switch" .. mname) then
            registry_source = config.registry_source
            break
          end
        end
      end

      local display = string.format("%-40s %s",
        registry_source,
        direction
      )

      table.insert(commands, {
        name = name,
        display = display
      })
    end
  end

  pickers.new({}, {
    prompt_title = "Bouncer Commands",
    finder = finders.new_table {
      results = commands,
      entry_maker = function(entry)
        return {
          value = entry.name,
          display = entry.display,
          ordinal = entry.display,
        }
      end,
    },
    sorter = conf.generic_sorter({}),
    attach_mappings = function(prompt_bufnr, _)
      actions.select_default:replace(function()
        actions.close(prompt_bufnr)
        local selection = action_state.get_selected_entry()
        vim.cmd(selection.value)
      end)
      return true
    end,
  }):find()
end

local function create_module_commands(_, module_config)
  local module_names = get_module_name(module_config.registry_source)

  for _, name in ipairs(module_names) do
    vim.api.nvim_create_user_command("Switch" .. name .. "ModulesToLocal", function()
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

    vim.api.nvim_create_user_command("Switch" .. name .. "ModulesToRegistry", function()
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
  -- Store configs globally for the picker to access
  _G.bouncer_configs = opts

  for _, module_config in pairs(opts) do
    create_module_commands(_, module_config)
  end

  -- Register telescope extension
  if has_telescope then
    telescope.register_extension({
      exports = {
        bouncer = M.show_commands
      },
    })
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
--return {
--module_name:lower(),                                -- e.g., "vnet"
--module_name:sub(1, 1):upper() .. module_name:sub(2), -- e.g., "Vnet"
--}
--end

---- Function to process file content
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
---- Match both registry source and local source
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
--vim.api.nvim_create_user_command("Switch" .. name .. "ModulesToLocal", function()
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

--vim.api.nvim_create_user_command("Switch" .. name .. "ModulesToRegistry", function()
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

local M = {}

---@class LayoutGroup<T>
---@field layout 'above'|'below'|'left'|'right'
---@field elems T[]


---@alias LayoutPlan LayoutGroup<number>[]
---@alias LayoutSpec number|LayoutGroup<LayoutSpec>


---@alias LayoutCtor fun(elems: LayoutSpec[]): LayoutGroup


---@param layout 'above'|'below'|'left'|'right'
---@return LayoutCtor
local function mkLayoutGroup(layout)
  return function(elems)
    return { layout = layout, elems = elems }
  end
end


---Parses the output of `vim.fn.winlayout()` into a LayoutSpec, using the
---provided windows array to map window IDs to their corresponding indices.
---@param windows number[]
---@return fun(expr: vim.fn.winlayout.ret): nil|LayoutSpec
function M._parse_winlayout(windows)
  local windowTable =
    vim.iter(windows)
      :enumerate()
      :fold({}, function(acc, ix, windowId)
        acc[windowId] = ix
        return acc
      end)

  local function recur(expr)
    local tag, val = unpack(expr)
    if tag == "leaf" then
      return windowTable[val]
    end
    if tag == "row" then
      return mkLayoutGroup("right")(
        vim.iter(val):map(recur):totable()
      )
    end
    if tag == "col" then
      return mkLayoutGroup("below")(
        vim.iter(val):map(recur):totable()
      )
    end
  end

  return recur
end


---Renders a LayoutSpec back into a string that the user can edit.
---This is not guaranteed to produce the same string that was originally input by
---the user, but it should produce a string that evaluates to an equivalent LayoutSpec.
---@param expr LayoutSpec? The layout specification to render.
---@return string?
function M._render_spec(expr)
  local function recur(current_expr)
    if current_expr == nil then return "" end

    if type(current_expr) == "number" then
      return tostring(current_expr)
    end

    if type(current_expr) == "table" then
      local parts =
        vim.iter(current_expr.elems)
          :map(recur)
          :totable()

      if #parts == 0 then return end

      local op = ({
        above = "u",
        below = "v",
        left = "l",
        right = "h",
      })[current_expr.layout]

      return string.format(
        "%s{%s}",
        op,
        vim.iter(parts):join(",")
      )
    end
  end

  return recur(expr)
end


---The environment in which layout specifications are evaluated.
---@type table<string, LayoutCtor>
local eval_env = {
  h = mkLayoutGroup("right"),
  v = mkLayoutGroup("below"),
  u = mkLayoutGroup("above"),
  d = mkLayoutGroup("below"),
  l = mkLayoutGroup("left"),
  r = mkLayoutGroup("right"),
}


---Evaluates the given code string in a restricted environment and returns the
---resulting value.
---@param code string The code to evaluate. Should represent a layout specification.
---@return any The value resulting from evaluating the code, or nil if there was an error.
function M._eval_code_in_spec_env(code)
  local chunk, err = loadstring("return " .. code)
  if not chunk then
    vim.notify(vim.inspect(err))
    return nil
  end
  setfenv(chunk, eval_env)
  local result = nil
  pcall(function() result = chunk() end)
  return result
end


---Gathers IDs for the current windows in the active tab, filtering out
---non-focusable and floating windows.
---@return number[]
function M._gather_windows()
  local tabId = vim.api.nvim_win_get_tabpage(0)
  return vim.iter(vim.api.nvim_tabpage_list_wins(tabId))
    :map(function(windowId)
      local config = vim.api.nvim_win_get_config(windowId)
      if not config.focusable then return end
      if config.relative ~= "" then return end
      return windowId
    end)
    :totable()
end


---@class LabelInfo
---@field labelBufferId number
---@field labelWindowId number


---Creates a label window for the given window ID, displaying the given index.
---The label is a small floating window positioned near the center of the target
---window.
---@param index number The index to display in the label.
---@param windowId number The ID of the window to label.
---@return LabelInfo?
function M._make_label_window(index, windowId)
  if not vim.api.nvim_win_is_valid(windowId) then
    return
  end

  local text = string.format(" %d ", index)

  local labelBufferId = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(labelBufferId, 0, -1, false, { text })

  local labelWindowId = vim.api.nvim_open_win(labelBufferId, false, {
    relative = "win",
    win = windowId,
    width = vim.api.nvim_strwidth(text),
    height = 1,
    row = (vim.api.nvim_win_get_height(windowId) / 2) - 1,
    col = (vim.api.nvim_win_get_width(windowId) / 2) - vim.api.nvim_strwidth(text) - 1,
    focusable = false,
    style = "minimal",
    border = "rounded",
    noautocmd = true,
  })

  return {
    labelBufferId = labelBufferId,
    labelWindowId = labelWindowId,
  }
end


---Destroys the given label window, closing it and deleting its buffer.
---@param label LabelInfo
function M._destroy_label_window(label)
  vim.api.nvim_win_close(label.labelWindowId, true)
  vim.api.nvim_buf_delete(label.labelBufferId, { force = true })
end


---Overlays labels on the given windows to indicate their indices, then runs the
---given continuation function, passing it a cleanup function to remove the labels when
---done. The labels are also automatically cleaned up if the continuation throws an error.
---@param windows number[] The windows to label.
---@param cont fun(clean_up: fun())
function M._label_windows(windows, cont)
  local labels =
    vim.iter(windows)
      :enumerate()
      :map(M._make_label_window)
      :totable()

  local to_clean_up = true
  local function clean_up()
    if not to_clean_up then return end
    to_clean_up = false
    vim.iter(labels):each(M._destroy_label_window)
  end

  if not pcall(cont, clean_up) then
    clean_up()
  end
end


---Compiles an arbitrarily nested layout specification into a flat plan.
---The plan is a list of commands to execute, where each command specifies a
---split direction and the indices of the windows to split.
---@param expr LayoutSpec The layout specification to compile.
---@return LayoutPlan? The compiled layout plan, or nil if the input was invalid.
function M._compile_spec_to_plan(expr)
  local function recur(current_expr)
    if type(current_expr) == "number" then
      return {
        leader = current_expr,
        groups = {},
      }
    end

    if type(current_expr) == "table" then
      local parts =
        vim.iter(current_expr.elems)
          :map(recur)
          :totable()

      if #parts == 0 then return end

      local group = mkLayoutGroup(current_expr.layout)(
        vim.tbl_map(function(part) return part.leader end, parts)
      )

      local follow_up_commands =
        vim.iter(parts)
          :map(function (part) return part.groups end)
          :flatten(1)
          :totable()

      return {
        leader = parts[1].leader,
        groups = vim.list_extend({ group }, follow_up_commands),
      }
    end
  end

  local result = recur(expr)
  if result == nil then return end
  return result.groups
end


---Prompts the user to enter a layout specification, evaluates it, and passes the resulting
---spec to the given continuation function. The user can cancel the prompt or enter an invalid
---spec, in which case the continuation will be called with nil.
---@param existingLayout LayoutSpec?
---@param cont fun(spec: LayoutSpec?)
function M._prompt_for_spec(existingLayout, cont)
  vim.ui.input({
    prompt = "Enter layout: ",
    default = M._render_spec(existingLayout),
  }, function(code)
    if code == nil then return cont(nil) end

    if code == "" then return cont(nil) end

    if not code:match("^[hvudlr{},%s%d]+$") then
      vim.notify("Invalid layout code. Only 'hvudlr,{}', digits, and whitespace are allowed.")
      return cont(nil)
    end

    local spec = M._eval_code_in_spec_env(code)
    if spec == nil then
      vim.notify("No spec!")
      return cont(nil)
    end

    return cont(spec)
  end)
end


---Applies a given layout plan to the given windows.
---@param windows number[] The windows to apply the layout to.
---@param plan LayoutPlan The layout plan to apply.
function M._apply_layout_plan(windows, plan)
  vim.iter(plan):each(function(group)
    local winIds = vim.iter(group.elems)
      :map(function(index)
        if not (index >= 1 and index <= #windows) then
          vim.notify("Invalid layout code. Number out of range: " .. tostring(index))
          return
        end

        if not vim.api.nvim_win_is_valid(windows[index]) then
          vim.notify("Window " .. tostring(index) .. " is no longer valid")
          return
        end

        return windows[index]
      end)
      :totable()

    if #winIds == 0 then return end

    local head = winIds[1]
    local rest = vim.list_slice(winIds, 2)

    vim.iter(rest):fold(head, function(prev, windowId)
      vim.api.nvim_win_set_config(windowId, {
        split = group.layout,
        win = prev,
      })
      return windowId
    end)
  end)
end

---Applies the given layout specification to the given windows.
---@param windows number[] The windows to apply the layout to.
---@param spec LayoutSpec The layout specification to apply.
function M._apply_layout_spec(windows, spec)
  local plan = M._compile_spec_to_plan(spec)
  if plan == nil then return end
  M._apply_layout_plan(windows, plan)
end


---The main command function. Gathers the current windows, labels them, prompts
---the user for a layout spec, and applies it.
function M.Lay_command()
  local windows = M._gather_windows()

  if #windows == 0 then
    vim.notify("No windows available to layout")
    return
  end

  local existingLayout =
    M._parse_winlayout(windows)(vim.fn.winlayout())

  M._label_windows(windows, function(clean_up_labels)
    M._prompt_for_spec(existingLayout, function(spec)
      clean_up_labels()
      if spec == nil then return end
      M._apply_layout_spec(windows, spec)
    end)
  end)
end


M.setup = function()

  vim.api.nvim_create_user_command("Lay", M.Lay_command, {
    desc = "Layout windows by editing an expression. See `:help lay.nvim`."
  })

end

return M

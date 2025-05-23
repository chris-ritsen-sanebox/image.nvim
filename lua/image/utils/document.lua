---@diagnostic disable: duplicate-doc-field
local utils = require("image/utils")

local popup_window = nil

local resolve_absolute_path = function(document_file_path, image_path)
  if string.sub(image_path, 1, 1) == "/" then return image_path end
  if string.sub(image_path, 1, 1) == "~" then return vim.fn.fnamemodify(image_path, ":p") end
  local document_dir = vim.fn.fnamemodify(document_file_path, ":h")
  local absolute_image_path = document_dir .. "/" .. image_path
  absolute_image_path = vim.fn.fnamemodify(absolute_image_path, ":p")
  return absolute_image_path
end

local resolve_base64_image = function(document_file_path, image_path)
  local tmp_b64_path = vim.fn.tempname()
  local base64_part = image_path:gsub("^data:image/[%w%+]+;base64,", "")
  local decoded = vim.base64.decode(base64_part)

  local file = io.open(tmp_b64_path, "wb")
  if file ~= nil then
    file:write(decoded)
    file:close()
  end

  return tmp_b64_path
end

local is_remote_url = function(url)
  return string.sub(url, 1, 7) == "http://" or string.sub(url, 1, 8) == "https://"
end

---@param ctx IntegrationContext
---@param filetype string
---@return boolean
local has_valid_filetype = function(ctx, filetype)
  return vim.tbl_contains(ctx.options.filetypes or {}, filetype)
end

---@class DocumentIntegrationConfig
---@field name string
---@field query_buffer_images fun(buffer: number): { node: any, range: { start_row: number, start_col: number, end_row: number, end_col: number }, url: string }[]
---@field default_options? DocumentIntegrationOptions
---@field debug? boolean

---@param config DocumentIntegrationConfig
local create_document_integration = function(config)
  local trace = function(...)
    if config.debug then utils.log("[" .. config.name .. "]", ...) end
  end

  local render = vim.schedule_wrap(
    ---@param ctx IntegrationContext
    function(ctx)
      if not ctx.state.enabled then return end

      local windows = utils.window.get_windows({ normal = true, floating = ctx.options.floating_windows })
      local image_queue = {}

      for _, window in ipairs(windows) do
        if has_valid_filetype(ctx, window.buffer_filetype) then
          local matches = config.query_buffer_images(window.buffer)
          local previous_images = ctx.api.get_images({
            window = window.id,
            buffer = window.buffer,
            namespace = config.name,
          })
          local new_image_ids = {}
          local file_path = vim.api.nvim_buf_get_name(window.buffer)
          local cursor_row = vim.api.nvim_win_get_cursor(window.id)[1] - 1 -- 0-indexed row

          for _, match in ipairs(matches) do
            local id = string.format(
              "%d:%d:%d:%s",
              window.id,
              window.buffer,
              match.range.start_row,
              utils.hash.sha256(match.url)
            )

            if ctx.options.only_render_image_at_cursor and match.range.start_row ~= cursor_row then goto continue end

            local to_render = {
              id = id,
              match = match,
              window = window,
              file_path = file_path,
            }
            table.insert(image_queue, to_render)
            table.insert(new_image_ids, id)

            ::continue::
          end

          -- clear old images
          for _, image in ipairs(previous_images) do
            if not vim.tbl_contains(new_image_ids, image.id) then image:clear() end
          end
        end
      end

      -- render images from queue
      for _, item in ipairs(image_queue) do
        local render_image = function(image)
          if ctx.options.only_render_image_at_cursor and ctx.options.only_render_image_at_cursor_mode == "popup" then
            if popup_window ~= nil then return end

            -- Create a floating window for the image
            local term_size = utils.term.get_size()
            local width, height = utils.math.adjust_to_aspect_ratio(
              term_size,
              image.image_width,
              image.image_height,
              math.floor(term_size.screen_cols / 2),
              0
            )
            local win_config = {
              relative = "cursor",
              row = 1,
              col = 0,
              width = width,
              height = height,
              style = "minimal",
              border = "single",
            }
            local buf = vim.api.nvim_create_buf(false, true)
            vim.bo[buf].filetype = "image_nvim_popup"
            local win = vim.api.nvim_open_win(buf, false, win_config)
            popup_window = win

            image.ignore_global_max_size = true
            image.window = win
            image.buffer = buf
            image:render({
              x = 0,
              y = 1,
              width = width,
              height = height,
            })
            -- close the floating window when the cursor moves
            vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
              callback = function()
                if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
                image:clear()
                popup_window = nil
              end,
              once = true,
            })
          else
            image:render({
              x = item.match.range.start_col,
              y = item.match.range.start_row,
            })
          end
        end

        if is_remote_url(item.match.url) then
          if ctx.options.download_remote_images then
            pcall(ctx.api.from_url, item.match.url, {
              id = item.id,
              window = item.window.id,
              buffer = item.window.buffer,
              with_virtual_padding = true,
              namespace = config.name,
            }, function(image)
              if not image then return end
              render_image(image)
            end)
          end
        else
          local path
          if ctx.options.resolve_image_path then
            path = ctx.options.resolve_image_path(item.file_path, item.match.url, resolve_absolute_path)
          elseif string.sub(item.match.url, 1, 10) == "data:image" then
            path = resolve_base64_image(item.file_path, item.match.url)
          else
            path = resolve_absolute_path(item.file_path, item.match.url)
          end
          local ok, image = pcall(ctx.api.from_file, path, {
            id = item.id,
            window = item.window.id,
            buffer = item.window.buffer,
            with_virtual_padding = true,
            namespace = config.name,
          })
          if ok and image then render_image(image) end
        end
      end
    end
  )

  local text_change_watched_buffers = {}
  local setup_text_change_watcher = function(ctx, buffer)
    if vim.tbl_contains(text_change_watched_buffers, buffer) then return end
    vim.api.nvim_buf_attach(buffer, false, {
      on_lines = function()
        render(ctx)
      end,
    })
    table.insert(text_change_watched_buffers, buffer)
  end

  ---@type fun(ctx: IntegrationContext)
  local setup_autocommands = function(ctx)
    local group_name = ("image.nvim:%s"):format(config.name)
    local group = vim.api.nvim_create_augroup(group_name, { clear = true })

    -- watch for window changes
    vim.api.nvim_create_autocmd({ "WinNew", "BufWinEnter", "TabEnter" }, {
      group = group,
      callback = function(args)
        if not has_valid_filetype(ctx, vim.bo[args.buf].filetype) then return end
        render(ctx)
      end,
    })

    -- watch for text changes
    vim.api.nvim_create_autocmd({ "BufAdd", "BufNew", "BufNewFile", "BufWinEnter" }, {
      group = group,
      callback = function(args)
        if not has_valid_filetype(ctx, vim.bo[args.buf].filetype) then return end
        setup_text_change_watcher(ctx, args.buf)
        render(ctx)
      end,
    })
    if has_valid_filetype(ctx, vim.bo.filetype) then setup_text_change_watcher(ctx, vim.api.nvim_get_current_buf()) end

    if ctx.options.only_render_image_at_cursor then
      vim.api.nvim_create_autocmd({ "CursorMoved" }, {
        group = group,
        callback = function(args)
          if not has_valid_filetype(ctx, vim.bo[args.buf].filetype) then return end
          render(ctx)
        end,
      })
    end

    if ctx.options.clear_in_insert_mode then
      vim.api.nvim_create_autocmd({ "InsertEnter" }, {
        group = group,
        callback = function(args)
          if not has_valid_filetype(ctx, vim.bo[args.buf].filetype) then return end
          local current_window = vim.api.nvim_get_current_win()
          local images = ctx.api.get_images({ window = current_window, namespace = config.name })
          for _, image in ipairs(images) do
            image:clear()
          end
        end,
      })

      vim.api.nvim_create_autocmd({ "InsertLeave" }, {
        group = group,
        callback = function(args)
          if not has_valid_filetype(ctx, vim.bo[args.buf].filetype) then return end
          render(ctx)
        end,
      })
    end
  end

  ---@type fun(api: API, options: IntegrationOptions, state: State)
  local setup = function(api, options, state)
    ---@diagnostic disable-next-line: missing-fields
    local opts = vim.tbl_deep_extend("force", config.default_options or {}, options or {})
    local context = {
      api = api,
      options = opts,
      state = state,
    }

    vim.schedule(function()
      setup_autocommands(context)
      render(context)
    end)
  end

  return { setup = setup }
end

return {
  create_document_integration = create_document_integration,
}

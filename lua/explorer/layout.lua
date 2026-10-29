-- Barra lateral: explorador arriba y outline abajo, a la izquierda o a la derecha.

local config = require("explorer.config")

local M = {}

local S = {
	explorer = nil, ---@type integer?
	outline = nil, ---@type integer?
	editor = nil, ---@type integer?  última ventana del editor
	outline_height = nil, ---@type integer?
}

local function valid(win)
	return win ~= nil and vim.api.nvim_win_is_valid(win)
end

function M.explorer_win()
	return valid(S.explorer) and S.explorer or nil
end

function M.outline_win()
	return valid(S.outline) and S.outline or nil
end

---@param win? integer
function M.is_sidebar(win)
	return win ~= nil and (win == S.explorer or win == S.outline)
end

function M.is_open()
	return M.explorer_win() ~= nil
end

--- Ventana normal del editor (no flotante, no barra lateral, no terminal).
function M.is_editor_win(win)
	if not valid(win) or M.is_sidebar(win) or vim.api.nvim_win_get_config(win).relative ~= "" then
		return false
	end
	local buf = vim.api.nvim_win_get_buf(win)
	local bt = vim.bo[buf].buftype
	return bt == "" or bt == "acwrite" and vim.bo[buf].filetype ~= "explorer"
end

---@param win integer
function M.remember_editor(win)
	if M.is_editor_win(win) then
		S.editor = win
	end
end

--- Ventana del editor donde abrir archivos. Con `create`, crea una si no hay.
---@param create? boolean
---@return integer?
function M.editor_win(create)
	if M.is_editor_win(S.editor) then
		return S.editor
	end
	for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
		if M.is_editor_win(win) then
			S.editor = win
			return win
		end
	end
	if create then
		-- Solo queda la barra lateral (u otras ventanas especiales): abrir una
		local side = config.options.position == "left" and "right" or "left"
		S.editor = vim.api.nvim_open_win(vim.api.nvim_create_buf(true, false), false, {
			split = side,
			win = M.explorer_win() or -1,
		})
		return S.editor
	end
end

local function title(text)
	return "%#ExplorerTitle# " .. text:gsub("%%", "%%%%") .. "%*"
end

local function setup_win(win)
	local wo = vim.wo[win][0]
	wo.number = false
	wo.relativenumber = false
	wo.signcolumn = "no"
	wo.foldcolumn = "0"
	wo.statuscolumn = ""
	wo.spell = false
	wo.list = false
	wo.wrap = false
	wo.cursorline = true
	wo.winfixwidth = true
	wo.fillchars = "eob: "
	wo.winhighlight = "Normal:ExplorerNormal,NormalNC:ExplorerNormal,WinBar:ExplorerWinBar,WinBarNC:ExplorerWinBar"
end

local function update_titles()
	local files = require("explorer.files")
	if M.explorer_win() then
		local root = files.root()
		vim.wo[S.explorer][0].winbar = title(root and vim.fs.basename(root):upper() or "EXPLORADOR")
	end
	if M.outline_win() then
		vim.wo[S.outline][0].winbar = title("OUTLINE")
	end
end
M.update_titles = update_titles

--- Abre la barra lateral (sin cambiar el foco, salvo `focus`).
---@param opts? {focus?: boolean}
function M.open(opts)
	opts = opts or {}
	local files = require("explorer.files")
	local outline = require("explorer.outline")
	M.remember_editor(vim.api.nvim_get_current_win())

	if not M.explorer_win() then
		S.explorer = vim.api.nvim_open_win(files.buf(), false, {
			split = config.options.position,
			win = -1,
			width = config.options.width,
		})
		setup_win(S.explorer)
	end

	if config.options.outline.enabled and not M.outline_win() then
		local total = vim.api.nvim_win_get_height(S.explorer)
		local height = config.options.outline.height
		if height > 0 and height <= 1 then
			height = math.floor(total * height)
		end
		S.outline = vim.api.nvim_open_win(outline.buf(), false, {
			split = "below",
			win = S.explorer,
			height = math.max(3, math.floor(S.outline_height or height)),
		})
		setup_win(S.outline)
	end

	update_titles()
	files.render()
	files.refresh_git()
	if M.outline_win() then
		local editor = M.editor_win()
		outline.set_source(editor and vim.api.nvim_win_get_buf(editor) or nil)
		outline.refresh()
	end
	local current = M.editor_win() and vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(M.editor_win()))
	if current and current ~= "" then
		files.set_current(current)
	end

	if opts.focus then
		vim.api.nvim_set_current_win(S.explorer)
	end
end

--- Cierra la barra lateral.
function M.close()
	if M.outline_win() then
		S.outline_height = vim.api.nvim_win_get_height(S.outline)
	end
	local wins = vim.tbl_filter(valid, { S.explorer, S.outline })
	if #wins == 0 then
		return
	end
	-- No se puede cerrar la última ventana: dejar una del editor
	M.editor_win(true)
	if vim.tbl_contains(wins, vim.api.nvim_get_current_win()) and M.editor_win() then
		vim.api.nvim_set_current_win(M.editor_win())
	end
	for _, win in ipairs(wins) do
		pcall(vim.api.nvim_win_close, win, false)
	end
	S.explorer, S.outline = nil, nil
	require("explorer.files").stop_watchers()
end

--- Ventana flotante con la ayuda.
---@param lines string[]
function M.help(lines)
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false
	local width = 0
	for _, line in ipairs(lines) do
		width = math.max(width, vim.fn.strdisplaywidth(line))
	end
	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		row = math.floor((vim.o.lines - #lines) / 2),
		col = math.floor((vim.o.columns - width - 2) / 2),
		width = width + 2,
		height = #lines,
		border = "rounded",
		style = "minimal",
		title = " Ayuda ",
	})
	for _, key in ipairs({ "q", "<Esc>", "g?" }) do
		vim.keymap.set("n", key, function()
			pcall(vim.api.nvim_win_close, win, true)
		end, { buffer = buf, nowait = true })
	end
	vim.api.nvim_create_autocmd("WinLeave", {
		buffer = buf,
		once = true,
		callback = function()
			pcall(vim.api.nvim_win_close, win, true)
		end,
	})
end

return M

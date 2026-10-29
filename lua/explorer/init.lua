-- Explorador de archivos y outline en una barra lateral, al estilo VSCode.
--
-- API (global `Explorer`, al estilo de `Snacks`). No hay comandos ni atajos globales:
--   Explorer.open(opts?)  Explorer.close()  Explorer.toggle()  Explorer.is_open()
--   Explorer.focus()  Explorer.focus_outline()  Explorer.reveal(path?)
-- Las teclas del árbol y del outline solo existen dentro de esas ventanas.

local config = require("explorer.config")
local layout = require("explorer.layout")
local files = require("explorer.files")
local outline = require("explorer.outline")

local M = {}

local function root()
	return config.options.root or vim.fn.getcwd()
end

local function ensure_root()
	if not files.root() then
		files.set_root(root())
	end
end

--- Abre la barra lateral.
---@param opts? {focus?: boolean}
function M.open(opts)
	M._init()
	ensure_root()
	layout.open(opts)
end

--- Cierra la barra lateral.
function M.close()
	layout.close()
end

--- Abre o cierra la barra lateral.
function M.toggle()
	if layout.is_open() then
		M.close()
	else
		M.open({ focus = true })
	end
end

---@return boolean
function M.is_open()
	return layout.is_open()
end

--- Enfoca el explorador (lo abre si hace falta).
function M.focus()
	M.open({ focus = true })
end

--- Enfoca el outline (lo abre si hace falta).
function M.focus_outline()
	M.open()
	local win = layout.outline_win()
	if win then
		vim.api.nvim_set_current_win(win)
	end
end

--- Muestra un archivo en el árbol (por defecto el abierto en el editor).
---@param path? string
function M.reveal(path)
	M.open()
	files.reveal(path)
	vim.api.nvim_set_current_win(layout.explorer_win())
end

-- Colores -------------------------------------------------------------------------

local function set_highlights()
	local links = {
		ExplorerNormal = "Normal",
		ExplorerWinBar = "WinBar",
		ExplorerTitle = "Title",
		ExplorerDirectory = "Directory",
		ExplorerFile = "Normal",
		ExplorerIndent = "NonText",
		ExplorerChevron = "Comment",
		ExplorerModified = "Title",
		ExplorerCut = "Comment",
		ExplorerCopied = "Special",
		ExplorerGitModified = "Changed",
		ExplorerGitAdded = "Added",
		ExplorerGitUntracked = "Added",
		ExplorerGitRenamed = "Added",
		ExplorerGitDeleted = "Removed",
		ExplorerGitConflict = "DiagnosticError",
		ExplorerGitIgnored = "Comment",
		ExplorerOutlineName = "Normal",
		ExplorerOutlineKind = "Special",
		ExplorerOutlineDetail = "Comment",
		ExplorerOutlineMessage = "Comment",
	}
	for group, link in pairs(links) do
		vim.api.nvim_set_hl(0, group, { link = link, default = true })
	end
	vim.api.nvim_set_hl(0, "ExplorerCurrent", { bold = true, default = true })
end

-- Eventos -----------------------------------------------------------------------

-- Opciones de ventana que pone la barra lateral
local win_options = { "number", "relativenumber", "signcolumn", "foldcolumn", "statuscolumn", "spell", "list", "wrap", "cursorline", "winfixwidth", "winhighlight", "winbar" }

--- Si entra otro buffer en una ventana de la barra (`:e`, clic en la tabline...),
--- devolverle su buffer y abrir el otro en el editor.
local function guard_sidebar(args)
	local win = vim.api.nvim_get_current_win()
	local expected
	if win == layout.explorer_win() then
		expected = files.buf()
	elseif win == layout.outline_win() then
		expected = outline.buf()
	end
	if not expected or args.buf == expected then
		return
	end
	local buf = args.buf
	vim.schedule(function()
		if vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_win_set_buf(win, expected)
		end
		if not vim.api.nvim_buf_is_valid(buf) then
			return
		end
		local target = layout.editor_win(true)
		vim.api.nvim_win_set_buf(target, buf)
		-- El buffer pudo traer las opciones de la barra (sin números, etc.)
		for _, name in ipairs(win_options) do
			local value = vim.api.nvim_get_option_value(name, { win = target, scope = "global" })
			vim.api.nvim_set_option_value(name, value, { win = target, scope = "local" })
		end
		vim.api.nvim_set_current_win(target)
	end)
end

--- `nvim <carpeta>` o `:e <carpeta>`: abrir el explorador en esa carpeta.
local function hijack_directory(args)
	local path = vim.api.nvim_buf_get_name(args.buf)
	if path == "" or vim.fn.isdirectory(path) == 0 or vim.bo[args.buf].buftype ~= "" then
		return
	end
	local win = vim.api.nvim_get_current_win()
	vim.schedule(function()
		if not vim.api.nvim_buf_is_valid(args.buf) then
			return
		end
		if not config.options.root then
			files.set_root(path)
			layout.update_titles()
		end
		if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == args.buf then
			local alt = vim.fn.bufnr("#")
			local replacement = (alt > 0 and alt ~= args.buf and vim.api.nvim_buf_is_loaded(alt)) and alt
				or vim.api.nvim_create_buf(true, false)
			vim.api.nvim_win_set_buf(win, replacement)
		end
		pcall(vim.api.nvim_buf_delete, args.buf, { force = true })
		M.open({ focus = true })
	end)
end

local initialized = false

--- Autocmds y colores (se llama solo, con o sin setup()).
function M._init()
	if initialized then
		return
	end
	initialized = true
	set_highlights()

	local group = vim.api.nvim_create_augroup("ExplorerNvim", { clear = true })
	local au = function(event, callback, opts)
		vim.api.nvim_create_autocmd(event, vim.tbl_extend("force", { group = group, callback = callback }, opts or {}))
	end

	au("ColorScheme", set_highlights)

	-- Seguir el archivo y el buffer del editor
	au("BufEnter", function(args)
		local win = vim.api.nvim_get_current_win()
		if not layout.is_editor_win(win) then
			return
		end
		layout.remember_editor(win)
		if vim.bo[args.buf].buftype == "" then
			local name = vim.api.nvim_buf_get_name(args.buf)
			if name ~= "" and vim.fn.isdirectory(name) == 0 then
				files.set_current(name)
			end
			outline.set_source(args.buf)
		end
	end)

	au("BufWinEnter", guard_sidebar)

	-- Git y el ● de sin guardar
	au("BufWritePost", function()
		if layout.is_open() then
			files.refresh_git()
			files.schedule_render()
		end
	end)
	-- BufModifiedSet no siempre llega al editar: revisar también al cambiar texto
	au({ "BufModifiedSet", "TextChanged", "TextChangedI", "BufWritePost", "BufDelete" }, function()
		if layout.is_open() then
			files.check_unsaved()
		end
	end)
	au({ "FocusGained", "TermLeave", "ShellCmdPost" }, function()
		if layout.is_open() then
			files.refresh_git()
			files.schedule_render()
		end
	end)

	-- Outline
	au({ "TextChanged", "InsertLeave", "BufWritePost" }, function(args)
		if args.buf == outline.source() and layout.outline_win() then
			outline.schedule_refresh()
		end
	end)
	au("LspAttach", function(args)
		if args.buf == outline.source() and layout.outline_win() then
			vim.defer_fn(function()
				outline.refresh()
			end, 100)
		end
	end)
	au("CursorMoved", function(args)
		if args.buf == outline.source() and layout.outline_win() then
			outline.follow()
		end
	end)

	-- Cambio de carpeta de trabajo: cambia la raíz (si no está fija en la config)
	au("DirChanged", function(args)
		if not config.options.root and args.match ~= "window" then
			files.set_root(vim.fn.getcwd())
			layout.update_titles()
		end
	end)

	-- Al cerrar la última ventana del editor, cerrar también la barra para poder salir
	au("QuitPre", function()
		-- Solo al salir desde el editor (desde la barra, `:q` ya cierra esa ventana)
		if not layout.is_open() or layout.is_sidebar(vim.api.nvim_get_current_win()) then
			return
		end
		local others = 0
		for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
			if not layout.is_sidebar(win) and vim.api.nvim_win_get_config(win).relative == "" then
				others = others + 1
			end
		end
		if others <= 1 then
			for _, win in ipairs({ layout.explorer_win(), layout.outline_win() }) do
				pcall(vim.api.nvim_win_close, win, true)
			end
		end
	end)

	if config.options.hijack_directories then
		-- Desactivar netrw para carpetas
		if vim.fn.exists("#FileExplorer") == 1 then
			vim.api.nvim_del_augroup_by_name("FileExplorer")
		end
		au("BufEnter", hijack_directory, { nested = true })
	end
end

--- Configura el plugin. No crea atajos globales: abrí el explorador con tus propios
--- keymaps sobre la API, p. ej. `vim.keymap.set("n", "<A-e>", function() Explorer.toggle() end)`.
---@param opts? explorer.Config
function M.setup(opts)
	config.set(opts)
	M._init()
end

-- Global al estilo de `Snacks`: Explorer.toggle(), Explorer.reveal()...
_G.Explorer = M

return M

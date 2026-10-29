-- Árbol de archivos (solo lectura). Se navega con h/j/k/l y se crean, borran,
-- renombran, mueven y copian archivos con teclas, como en VSCode:
--   a  crear     ("archivo.rs", "carpeta/", "carpeta/sub/archivo.rs")
--   d  borrar    r  renombrar
--   m  cortar    c  copiar     p  pegar
-- d, m y c también funcionan sobre una selección visual.

local config = require("explorer.config")
local fs = require("explorer.fs")
local git = require("explorer.git")
local icons = require("explorer.icons")

local uv = vim.uv or vim.loop

local M = {}

local ns = vim.api.nvim_create_namespace("explorer.files")

local chevron_open, chevron_closed = "\u{eab4}", "\u{eab6}"

---@class explorer.Node
---@field path string
---@field name string
---@field type "file"|"directory"
---@field depth integer

local S = {
	root = nil, ---@type string?
	buf = nil, ---@type integer?
	expanded = {}, ---@type table<string, boolean>
	order = {}, ---@type explorer.Node[]  nodo de cada línea
	watchers = {}, ---@type table<string, uv.uv_fs_event_t>
	show_hidden = nil, ---@type boolean?
	current = nil, ---@type string?  archivo abierto en el editor
	clipboard = nil, ---@type {mode: "copy"|"move", paths: string[]}?
	unsaved_key = nil, ---@type string?
	render_timer = nil, ---@type uv.uv_timer_t?
}

-- Utilidades ------------------------------------------------------------------

local function layout()
	return require("explorer.layout")
end

local function normalize(path)
	return (vim.fs.normalize(vim.fn.fnamemodify(path, ":p")):gsub("/$", ""))
end

local function is_under_root(path)
	return S.root ~= nil and (path == S.root or vim.startswith(path, S.root .. "/"))
end

local function relative(path)
	if path == S.root then
		return "."
	end
	return is_under_root(path) and path:sub(#S.root + 2) or path
end

local function show_hidden()
	if S.show_hidden == nil then
		return config.options.show_hidden
	end
	return S.show_hidden
end

local function notify(msg, level)
	vim.notify("explorer.nvim: " .. msg, level or vim.log.levels.INFO)
end

---@param dir string
---@return {name: string, path: string, type: string}[]
local function scan(dir)
	local entries = {}
	local handle = uv.fs_scandir(dir)
	if not handle then
		return entries
	end
	local exclude = {}
	for _, name in ipairs(config.options.exclude) do
		exclude[name] = true
	end
	while true do
		local name, type = uv.fs_scandir_next(handle)
		if not name then
			break
		end
		if not exclude[name] and (show_hidden() or name:sub(1, 1) ~= ".") then
			local path = dir .. "/" .. name
			if type == "link" then
				local stat = uv.fs_stat(path)
				type = stat and stat.type or "file"
			end
			table.insert(entries, { name = name, path = path, type = type == "directory" and "directory" or "file" })
		end
	end
	table.sort(entries, function(a, b)
		if a.type ~= b.type then
			return a.type == "directory"
		end
		local la, lb = a.name:lower(), b.name:lower()
		if la ~= lb then
			return la < lb
		end
		return a.name < b.name
	end)
	return entries
end

-- Buffer ----------------------------------------------------------------------

--- Buffer del explorador (se crea una sola vez).
function M.buf()
	if S.buf and vim.api.nvim_buf_is_valid(S.buf) then
		return S.buf
	end
	local buf = vim.api.nvim_create_buf(false, true)
	S.buf = buf
	vim.bo[buf].bufhidden = "hide"
	vim.bo[buf].filetype = "explorer"
	vim.bo[buf].modifiable = false

	-- El cursor siempre al inicio del nombre (no en la sangría)
	vim.api.nvim_create_autocmd("CursorMoved", {
		buffer = buf,
		callback = function()
			local row, col = unpack(vim.api.nvim_win_get_cursor(0))
			local node = S.order[row]
			local start = node and node.depth * config.options.indent or 0
			if col ~= start then
				pcall(vim.api.nvim_win_set_cursor, 0, { row, start })
			end
		end,
	})

	M._set_mappings(buf)
	return buf
end

-- Dibujo ----------------------------------------------------------------------

local function unsaved_paths()
	local set = {}
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].modified and vim.bo[buf].buftype == "" then
			local name = vim.api.nvim_buf_get_name(buf)
			if name ~= "" then
				set[vim.fs.normalize(name)] = true
			end
		end
	end
	return set
end

local git_hl = {
	conflict = "ExplorerGitConflict",
	modified = "ExplorerGitModified",
	deleted = "ExplorerGitDeleted",
	renamed = "ExplorerGitRenamed",
	added = "ExplorerGitAdded",
	untracked = "ExplorerGitUntracked",
	ignored = "ExplorerGitIgnored",
}

local function find_row(path)
	for i, node in ipairs(S.order) do
		if node.path == path then
			return i
		end
	end
end

--- Pone el cursor del explorador en `path` (al inicio del nombre).
local function set_cursor(path)
	local win = layout().explorer_win()
	local row = path and find_row(path)
	if win and row then
		vim.api.nvim_win_set_cursor(win, { row, S.order[row].depth * config.options.indent })
	end
end

--- Nodo bajo el cursor del explorador.
---@return explorer.Node?
function M.node_at_cursor()
	local win = layout().explorer_win()
	return win and S.order[vim.api.nvim_win_get_cursor(win)[1]]
end

local function sync_watchers()
	local wanted = { [S.root] = true }
	for path in pairs(S.expanded) do
		if fs.is_dir(path) then
			wanted[path] = true
		end
	end
	for path, handle in pairs(S.watchers) do
		if not wanted[path] then
			handle:stop()
			handle:close()
			S.watchers[path] = nil
		end
	end
	for path in pairs(wanted) do
		if not S.watchers[path] then
			local handle = uv.new_fs_event()
			if handle then
				local ok = handle:start(path, {}, function()
					vim.schedule(function()
						M.schedule_render()
					end)
				end)
				if ok then
					S.watchers[path] = handle
				else
					handle:close()
				end
			end
		end
	end
end

--- Deja de vigilar las carpetas (al cerrar el explorador).
function M.stop_watchers()
	for path, handle in pairs(S.watchers) do
		handle:stop()
		handle:close()
		S.watchers[path] = nil
	end
end

--- Dibuja el árbol.
---@param opts? {cursor?: string}
function M.render(opts)
	opts = opts or {}
	local buf = M.buf()
	if not S.root then
		return
	end

	-- Recordar en qué archivo estaba el cursor
	local win = layout().explorer_win()
	local keep = opts.cursor
	local keep_row
	if not keep and win then
		keep_row = vim.api.nvim_win_get_cursor(win)[1]
		local node = S.order[keep_row]
		keep = node and node.path
	end

	local indent = config.options.indent
	local lines, order = {}, {}
	local function walk(dir, depth)
		for _, entry in ipairs(scan(dir)) do
			local node = { path = entry.path, name = entry.name, type = entry.type, depth = depth }
			table.insert(order, node)
			table.insert(lines, string.rep(" ", depth * indent) .. node.name)
			if node.type == "directory" and S.expanded[node.path] then
				walk(node.path, depth + 1)
			end
		end
	end
	walk(S.root, 0)
	S.order = order

	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false
	vim.bo[buf].modified = false
	vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)

	local unsaved = unsaved_paths()
	local clip = {}
	for _, path in ipairs(S.clipboard and S.clipboard.paths or {}) do
		clip[path] = S.clipboard.mode
	end
	local use_git = config.options.git
	for row0, node in ipairs(order) do
		local row = row0 - 1
		local is_dir = node.type == "directory"
		local col = node.depth * indent

		-- Guías de sangría
		for level = 0, node.depth - 1 do
			vim.api.nvim_buf_set_extmark(buf, ns, row, level * indent, {
				virt_text = { { "│", "ExplorerIndent" } },
				virt_text_pos = "overlay",
			})
		end

		local icon, icon_hl = icons.file(node.path, is_dir)
		local chevron = is_dir and (S.expanded[node.path] and chevron_open or chevron_closed) or " "
		vim.api.nvim_buf_set_extmark(buf, ns, row, col, {
			virt_text = { { chevron .. " ", "ExplorerChevron" }, { icon .. " ", icon_hl } },
			virt_text_pos = "inline",
			right_gravity = false,
		})

		local status = use_git and git.status(node.path, is_dir) or nil
		local name_hl = (status and git_hl[status]) or (is_dir and "ExplorerDirectory" or "ExplorerFile")
		if clip[node.path] then
			name_hl = clip[node.path] == "move" and "ExplorerCut" or "ExplorerCopied"
		end
		vim.api.nvim_buf_set_extmark(buf, ns, row, col, { end_col = #lines[row0], hl_group = name_hl })
		if node.path == S.current then
			vim.api.nvim_buf_set_extmark(buf, ns, row, col, {
				end_col = #lines[row0],
				hl_group = "ExplorerCurrent",
				priority = 4200,
			})
		end

		-- Derecha: ● sin guardar, letra de git (o punto en carpetas con cambios)
		local right = {}
		if unsaved[node.path] then
			table.insert(right, { "● ", "ExplorerModified" })
		end
		if status and status ~= "ignored" then
			if is_dir and status ~= "untracked" then
				table.insert(right, { "•", git_hl[status] })
			else
				table.insert(right, { git.letters[status], git_hl[status] })
			end
		end
		if #right > 0 then
			vim.api.nvim_buf_set_extmark(buf, ns, row, 0, { virt_text = right, virt_text_pos = "right_align" })
		end
	end

	if win and #order > 0 then
		local row = (keep and find_row(keep)) or math.min(keep_row or 1, #order)
		pcall(vim.api.nvim_win_set_cursor, win, { row, order[row].depth * indent })
	end
	sync_watchers()
end

--- Redibujo diferido (cambios en disco, buffers modificados...).
function M.schedule_render()
	if S.render_timer then
		S.render_timer:stop()
	else
		S.render_timer = uv.new_timer()
	end
	S.render_timer:start(
		150,
		0,
		vim.schedule_wrap(function()
			if layout().explorer_win() then
				M.render()
			end
		end)
	)
end

--- Redibuja si cambió qué archivos tienen cambios sin guardar (para el ●).
function M.check_unsaved()
	local paths = vim.tbl_keys(unsaved_paths())
	table.sort(paths)
	local key = table.concat(paths, "\n")
	if key ~= S.unsaved_key then
		S.unsaved_key = key
		M.schedule_render()
	end
end

--- Actualiza el estado de git y redibuja si cambió.
function M.refresh_git()
	if config.options.git and S.root then
		git.refresh(S.root, function()
			if layout().explorer_win() then
				M.render()
			end
		end)
	end
end

-- Raíz y archivo actual -----------------------------------------------------------

---@param path string
function M.set_root(path)
	path = normalize(path)
	if path == S.root then
		return
	end
	S.root = path
	S.expanded = {}
	S.clipboard = nil
	M.render()
	M.refresh_git()
end

function M.root()
	return S.root
end

--- Archivo abierto en el editor (para resaltarlo y revelarlo).
---@param path? string
function M.set_current(path)
	path = path and path ~= "" and normalize(path) or nil
	if path == S.current then
		return
	end
	S.current = path
	if layout().explorer_win() then
		if config.options.follow_current_file and path and is_under_root(path) then
			M.reveal(path, { quiet = true })
		else
			M.render()
		end
	end
end

--- Expande las carpetas hasta `path` y pone el cursor ahí.
---@param path? string  por defecto el archivo abierto en el editor
---@param opts? {quiet?: boolean}
function M.reveal(path, opts)
	opts = opts or {}
	path = path and normalize(path) or S.current
	if not path or not is_under_root(path) then
		if not opts.quiet then
			notify("el archivo no está dentro de " .. (S.root or "?"))
		end
		return
	end
	local dir = vim.fs.dirname(path)
	while dir and is_under_root(dir) and dir ~= S.root do
		S.expanded[dir] = true
		dir = vim.fs.dirname(dir)
	end
	M.render({ cursor = path })
end

-- Navegación ------------------------------------------------------------------------

---@param path string
---@param focus_editor boolean
local function open_file(path, focus_editor)
	local explorer = layout().explorer_win()
	local win = layout().editor_win(true)
	vim.api.nvim_set_current_win(win)
	if vim.fs.normalize(vim.api.nvim_buf_get_name(0)) ~= path then
		vim.cmd.edit(vim.fn.fnameescape(path))
	end
	if not focus_editor and explorer then
		vim.api.nvim_set_current_win(explorer)
	end
end

--- `l`: expande la carpeta y entra en ella, o abre el archivo (el foco queda en el explorador).
function M.go_in()
	local node = M.node_at_cursor()
	if not node then
		return
	end
	if node.type == "file" then
		return open_file(node.path, false)
	end
	S.expanded[node.path] = true
	M.render({ cursor = node.path })
	local row = find_row(node.path)
	local next_node = row and S.order[row + 1]
	if next_node and next_node.depth > node.depth then
		set_cursor(next_node.path)
	end
end

--- `L` / `<CR>`: como `l`, pero al abrir un archivo pasa al editor.
function M.go_in_plus()
	local node = M.node_at_cursor()
	if node and node.type == "file" then
		return open_file(node.path, true)
	end
	M.go_in()
end

--- `h`: colapsa la carpeta abierta, o sube a la carpeta padre. No sale de la raíz.
function M.go_out()
	local node = M.node_at_cursor()
	if not node then
		return
	end
	if node.type == "directory" and S.expanded[node.path] then
		S.expanded[node.path] = nil
		return M.render({ cursor = node.path })
	end
	local parent = vim.fs.dirname(node.path)
	if parent ~= S.root and is_under_root(parent) then
		set_cursor(parent)
	end
end

--- `H`: colapsa todo el árbol.
function M.go_out_plus()
	local node = M.node_at_cursor()
	S.expanded = {}
	M.render({ cursor = node and S.root .. "/" .. relative(node.path):match("^[^/]+") })
end

--- `R`: vuelve a leer el disco y git.
function M.refresh()
	M.render()
	M.refresh_git()
end

function M.toggle_hidden()
	S.show_hidden = not show_hidden()
	M.render()
end

-- Operaciones de archivos -------------------------------------------------------------

--- Carpeta donde crear/pegar: la carpeta bajo el cursor, o la del archivo bajo el cursor.
local function target_dir()
	local node = M.node_at_cursor()
	if not node then
		return S.root
	end
	if node.type == "directory" then
		return node.path
	end
	return vim.fs.dirname(node.path)
end

--- Nodos de la selección visual, o el del cursor.
---@param visual? boolean
---@return explorer.Node[]
local function selected(visual)
	if not visual then
		local node = M.node_at_cursor()
		return node and { node } or {}
	end
	local a, b = vim.fn.line("v"), vim.fn.line(".")
	vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
	local nodes = {}
	for row = math.min(a, b), math.max(a, b) do
		if S.order[row] then
			table.insert(nodes, S.order[row])
		end
	end
	-- Si se seleccionó una carpeta y algo de su interior, basta con la carpeta
	return vim.tbl_filter(function(node)
		for _, other in ipairs(nodes) do
			if other.type == "directory" and vim.startswith(node.path, other.path .. "/") then
				return false
			end
		end
		return true
	end, nodes)
end

--- Valida un nombre escrito por el usuario (relativo, sin "." ni "..").
---@return string? path_relativo, boolean? es_carpeta
local function parse_name(input)
	input = vim.trim(input or "")
	if input == "" then
		return
	end
	local is_dir = input:sub(-1) == "/"
	local clean = input:gsub("^/+", ""):gsub("/+$", ""):gsub("/+", "/")
	for part in clean:gmatch("[^/]+") do
		if part == "." or part == ".." then
			notify(("nombre inválido: %q"):format(input), vim.log.levels.ERROR)
			return
		end
	end
	if clean == "" then
		return
	end
	return clean, is_dir
end

--- Expande las carpetas hasta `path` (sin incluirlo).
local function expand_to(path)
	local dir = vim.fs.dirname(path)
	while dir and is_under_root(dir) and dir ~= S.root do
		S.expanded[dir] = true
		dir = vim.fs.dirname(dir)
	end
end

--- Después de una operación: mostrar el resultado y actualizar git.
local function done(cursor)
	if cursor then
		expand_to(cursor)
	end
	M.render({ cursor = cursor })
	M.refresh_git()
end

--- `a`: crear archivo o carpeta. "nombre.rs", "carpeta/", "carpeta/sub/archivo.rs".
function M.add()
	local dir = target_dir()
	local where = dir == S.root and "" or (relative(dir) .. "/")
	vim.ui.input({ prompt = "Crear en " .. vim.fs.basename(S.root) .. "/" .. where .. ": " }, function(input)
		local name, is_dir = parse_name(input)
		if not name then
			return
		end
		local path = dir .. "/" .. name
		local ok, err = fs.create(path, is_dir)
		if not ok then
			return notify(err, vim.log.levels.ERROR)
		end
		done(path)
		if not is_dir and config.options.open_on_create then
			open_file(path, false)
		end
	end)
end

--- `r`: renombrar. Con "/" en el nombre se mueve a una subcarpeta (que se crea si no existe).
function M.rename()
	local node = M.node_at_cursor()
	if not node then
		return
	end
	vim.ui.input({ prompt = "Renombrar " .. relative(node.path) .. ": ", default = node.name }, function(input)
		local name = parse_name(input)
		if not name or name == node.name then
			return
		end
		local path = vim.fs.dirname(node.path) .. "/" .. name
		local ok, err = fs.move(node.path, path)
		if not ok then
			return notify(err, vim.log.levels.ERROR)
		end
		if S.expanded[node.path] then
			S.expanded[path] = true
		end
		done(path)
	end)
end

--- `d`: borrar (con confirmación).
---@param visual? boolean
function M.delete(visual)
	local nodes = selected(visual)
	if #nodes == 0 then
		return
	end
	if config.options.confirm then
		local trash = fs.can_trash(config.options.delete_to_trash)
		local names = {}
		for _, node in ipairs(nodes) do
			table.insert(names, "  " .. relative(node.path) .. (node.type == "directory" and "/" or ""))
		end
		local msg = ("¿Borrar %s?\n%s"):format(trash and "(a la papelera)" or "para siempre", table.concat(names, "\n"))
		if vim.fn.confirm(msg, "&Sí\n&No", 2, "Question") ~= 1 then
			return
		end
	end
	local errors = {}
	for _, node in ipairs(nodes) do
		local ok, err = fs.delete(node.path, config.options.delete_to_trash)
		if not ok then
			table.insert(errors, relative(node.path) .. ": " .. tostring(err))
		end
	end
	if #errors > 0 then
		notify("no se pudo borrar:\n" .. table.concat(errors, "\n"), vim.log.levels.ERROR)
	end
	done()
end

---@param mode "copy"|"move"
---@param visual? boolean
local function to_clipboard(mode, visual)
	local nodes = selected(visual)
	if #nodes == 0 then
		return
	end
	S.clipboard = { mode = mode, paths = vim.tbl_map(function(node)
		return node.path
	end, nodes) }
	local what = #nodes == 1 and relative(nodes[1].path) or (#nodes .. " elementos")
	notify(("%s %s (p para pegar)"):format(mode == "move" and "Cortado:" or "Copiado:", what))
	M.render()
end

--- `m`: cortar (para mover con `p`).
function M.cut(visual)
	to_clipboard("move", visual)
end

--- `c`: copiar (para pegar con `p`).
function M.copy(visual)
	to_clipboard("copy", visual)
end

--- Nombre libre para una copia: "archivo copy.rs", "archivo copy 2.rs"...
local function free_name(path)
	if not fs.exists(path) then
		return path
	end
	local dir, name = vim.fs.dirname(path), vim.fs.basename(path)
	local base, ext = name:match("^(.+)(%.[^.]+)$")
	if not base or fs.is_dir(path) then
		base, ext = name, ""
	end
	local candidate = ("%s/%s copy%s"):format(dir, base, ext)
	local n = 2
	while fs.exists(candidate) do
		candidate = ("%s/%s copy %d%s"):format(dir, base, n, ext)
		n = n + 1
	end
	return candidate
end

--- `p`: pegar lo copiado/cortado en la carpeta bajo el cursor.
function M.paste()
	local clip = S.clipboard
	if not clip or #clip.paths == 0 then
		return notify("no hay nada copiado ni cortado (c / m)", vim.log.levels.WARN)
	end
	local dir = target_dir()
	local errors, last = {}, nil
	for _, from in ipairs(clip.paths) do
		local to = dir .. "/" .. vim.fs.basename(from)
		local ok, err
		if not fs.exists(from) then
			ok, err = false, "ya no existe"
		elseif clip.mode == "move" then
			if to == from then
				ok = true
			elseif dir == from or vim.startswith(dir, from .. "/") then
				ok, err = false, "no se puede mover una carpeta dentro de sí misma"
			else
				ok, err = fs.move(from, to)
				if ok and S.expanded[from] then
					S.expanded[to] = true
				end
			end
		else
			if dir == from or vim.startswith(dir, from .. "/") then
				ok, err = false, "no se puede copiar una carpeta dentro de sí misma"
			else
				to = free_name(to)
				ok, err = fs.copy(from, to)
			end
		end
		if ok then
			last = to
		else
			table.insert(errors, relative(from) .. ": " .. tostring(err))
		end
	end
	if clip.mode == "move" then
		S.clipboard = nil -- lo cortado se pega una sola vez; lo copiado, las veces que se quiera
	end
	if #errors > 0 then
		notify("no se pudo pegar:\n" .. table.concat(errors, "\n"), vim.log.levels.ERROR)
	end
	done(last)
end

-- Ayuda y atajos ----------------------------------------------------------------

local descriptions = {
	close = "Cerrar",
	go_in = "Expandir carpeta / abrir archivo",
	go_in_plus = "Expandir carpeta / abrir archivo y pasar al editor",
	open = "Abrir y pasar al editor",
	go_out = "Colapsar / ir a la carpeta padre",
	go_out_plus = "Colapsar todo",
	add = "Crear (archivo, carpeta/ o ruta/completa.rs)",
	delete = "Borrar",
	rename = "Renombrar",
	move = "Cortar (para mover con pegar)",
	copy = "Copiar",
	paste = "Pegar",
	refresh = "Recargar",
	reveal = "Mostrar el archivo actual",
	show_help = "Ayuda",
	toggle_hidden = "Mostrar/ocultar archivos ocultos",
}

local actions = {
	close = function()
		layout().close()
	end,
	go_in = M.go_in,
	go_in_plus = M.go_in_plus,
	open = M.go_in_plus,
	go_out = M.go_out,
	go_out_plus = M.go_out_plus,
	add = M.add,
	delete = M.delete,
	rename = M.rename,
	move = M.cut,
	copy = M.copy,
	paste = M.paste,
	refresh = M.refresh,
	reveal = function()
		M.reveal()
	end,
	show_help = function()
		M.help()
	end,
	toggle_hidden = M.toggle_hidden,
}

-- Acciones que también funcionan sobre una selección visual
local visual_actions = { delete = M.delete, move = M.cut, copy = M.copy }

function M._set_mappings(buf)
	for action, lhs in pairs(config.options.mappings) do
		if lhs and lhs ~= "" and actions[action] then
			vim.keymap.set("n", lhs, function()
				actions[action]()
			end, { buffer = buf, nowait = true, desc = descriptions[action] })
			if visual_actions[action] then
				vim.keymap.set("x", lhs, function()
					visual_actions[action](true)
				end, { buffer = buf, nowait = true, desc = descriptions[action] })
			end
		end
	end
end

function M.help()
	local lines = { " Explorador", "" }
	local items = {}
	for action, lhs in pairs(config.options.mappings) do
		if lhs and lhs ~= "" then
			table.insert(items, { lhs, descriptions[action] or action })
		end
	end
	table.sort(items, function(a, b)
		return a[1] < b[1]
	end)
	for _, item in ipairs(items) do
		table.insert(lines, (" %-6s %s"):format(item[1], item[2]))
	end
	vim.list_extend(lines, { "", " d, m y c también funcionan con una selección visual (V)" })
	layout().help(lines)
end

return M

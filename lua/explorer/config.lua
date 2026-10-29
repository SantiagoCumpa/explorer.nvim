local M = {}

---@class explorer.Config
---@field position? "left"|"right"  Lado de la barra lateral
---@field width? integer  Ancho de la barra lateral
---@field root? string  Carpeta raíz. Por defecto el cwd (o la carpeta pasada a `nvim <carpeta>`)
---@field follow_current_file? boolean  Mostrar en el árbol el archivo abierto en el editor
---@field hijack_directories? boolean  Abrir el explorador al editar una carpeta (`nvim .`)
---@field show_hidden? boolean  Mostrar archivos ocultos (que empiezan con punto)
---@field exclude? string[]  Nombres que no se muestran nunca
---@field indent? integer  Espacios por nivel del árbol
---@field git? boolean  Estado de git
---@field confirm? boolean  Pedir confirmación antes de borrar
---@field delete_to_trash? boolean  Borrar a la papelera (gio/trash-put) en vez de borrar para siempre
---@field open_on_create? boolean  Abrir en el editor los archivos creados con `a`
---@field outline? explorer.OutlineConfig
---@field mappings? table<string, string|false>  Atajos dentro del explorador

---@class explorer.OutlineConfig
---@field enabled? boolean
---@field height? number  Alto del outline. Entre 0 y 1 es una fracción de la barra
---@field follow_cursor? boolean  Resaltar el símbolo donde está el cursor
---@field expand? boolean  Mostrar los símbolos expandidos
---@field mappings? table<string, string|false>

M.defaults = {
	position = "left",
	width = 30,
	root = nil,
	follow_current_file = true,
	hijack_directories = true,
	show_hidden = true,
	exclude = { ".git", ".DS_Store" },
	indent = 2,
	git = true,
	confirm = true,
	delete_to_trash = true,
	open_on_create = true,
	outline = {
		enabled = true,
		height = 0.4,
		follow_cursor = true,
		expand = true,
		mappings = {
			jump = "<CR>",
			go_in = "l",
			jump_focus = "L",
			go_out = "h",
			collapse_all = "H",
			close = "q",
			show_help = "g?",
		},
	},
	-- Atajos dentro del explorador. false desactiva uno
	mappings = {
		-- Navegación
		close = "q",
		go_in = "l",
		go_in_plus = "L",
		open = "<CR>",
		go_out = "h",
		go_out_plus = "H",
		reveal = "@",
		refresh = "R",
		toggle_hidden = "g.",
		show_help = "g?",
		-- Archivos
		add = "a",
		delete = "d",
		rename = "r",
		move = "m",
		copy = "c",
		paste = "p",
	},
}

---@type explorer.Config
M.options = vim.deepcopy(M.defaults)

---@param opts? explorer.Config
function M.set(opts)
	opts = opts or {}
	M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts)
	if M.options.position ~= "right" then
		M.options.position = "left"
	end
end

return M

-- Estado de git de los archivos (git status), calculado de forma asíncrona.

local M = {}

---@alias explorer.GitStatus "conflict"|"modified"|"deleted"|"added"|"renamed"|"untracked"|"ignored"

-- Prioridad para decidir qué estado muestra una carpeta con varios cambios dentro
local priority = { conflict = 7, modified = 6, deleted = 5, renamed = 4, added = 3, untracked = 2, ignored = 1 }

M.letters = { conflict = "!", modified = "M", deleted = "D", renamed = "R", added = "A", untracked = "U", ignored = "" }

local state = {
	files = {}, ---@type table<string, explorer.GitStatus>  ruta absoluta -> estado
	dirs = {}, ---@type table<string, explorer.GitStatus>  carpetas con cambios dentro
	toplevel = nil, ---@type string?
	running = false,
	pending = false,
}

---@param xy string  dos letras de `git status --porcelain`
---@return explorer.GitStatus?
local function parse_xy(xy)
	local x, y = xy:sub(1, 1), xy:sub(2, 2)
	if xy == "??" then
		return "untracked"
	elseif xy == "!!" then
		return "ignored"
	elseif x == "U" or y == "U" or xy == "AA" or xy == "DD" then
		return "conflict"
	elseif x == "M" or y == "M" or y == "T" or x == "T" then
		return "modified"
	elseif x == "D" or y == "D" then
		return "deleted"
	elseif x == "R" or x == "C" then
		return "renamed"
	elseif x == "A" then
		return "added"
	end
end

local function parse(toplevel, output)
	local files, dirs = {}, {}
	local parts = vim.split(output, "\0", { plain = true })
	local i = 1
	while i <= #parts do
		local entry = parts[i]
		if #entry > 3 then
			local xy, rel = entry:sub(1, 2), entry:sub(4)
			local status = parse_xy(xy)
			-- En renombres/copias el siguiente campo es la ruta original
			if xy:sub(1, 1) == "R" or xy:sub(1, 1) == "C" then
				i = i + 1
			end
			if status then
				local path = vim.fs.normalize(toplevel .. "/" .. rel:gsub("/$", ""))
				files[path] = status
				if status ~= "ignored" then
					-- Marcar las carpetas que contienen el cambio
					local dir = vim.fs.dirname(path)
					while dir and #dir >= #toplevel do
						if not dirs[dir] or priority[status] > priority[dirs[dir]] then
							dirs[dir] = status
						end
						if dir == toplevel then
							break
						end
						dir = vim.fs.dirname(dir)
					end
				end
			end
		end
		i = i + 1
	end
	return files, dirs
end

--- Estado de un archivo o carpeta. Hereda el de una carpeta no seguida o ignorada.
---@param path string
---@param is_dir boolean
---@return explorer.GitStatus?
function M.status(path, is_dir)
	local own = state.files[path]
	if own then
		return own
	end
	if is_dir and state.dirs[path] then
		return state.dirs[path]
	end
	-- Dentro de una carpeta "??" o "!!" (git la lista entera, no archivo por archivo)
	local dir = vim.fs.dirname(path)
	while state.toplevel and dir and #dir >= #state.toplevel do
		local st = state.files[dir]
		if st == "untracked" or st == "ignored" then
			return st
		end
		if dir == state.toplevel then
			break
		end
		dir = vim.fs.dirname(dir)
	end
end

--- Si una carpeta tiene cambios dentro (para el punto de VSCode).
function M.has_changes(dir)
	return state.dirs[dir] ~= nil
end

--- Vuelve a leer el estado de git y llama a `on_done` si cambió.
---@param root string
---@param on_done fun()
function M.refresh(root, on_done)
	if state.running then
		state.pending = true
		return
	end
	state.running = true
	local function finish(files, dirs, toplevel)
		state.running = false
		local changed = not vim.deep_equal(files, state.files) or not vim.deep_equal(dirs, state.dirs)
		state.files, state.dirs, state.toplevel = files, dirs, toplevel
		if changed then
			on_done()
		end
		if state.pending then
			state.pending = false
			M.refresh(root, on_done)
		end
	end

	vim.system({ "git", "-C", root, "rev-parse", "--show-toplevel" }, { text = true }, function(top)
		if top.code ~= 0 then
			return vim.schedule(function()
				finish({}, {}, nil)
			end)
		end
		local toplevel = vim.fs.normalize(vim.trim(top.stdout))
		vim.system(
			{ "git", "-C", root, "status", "--porcelain=v1", "-z", "--ignored=matching", "-unormal" },
			{ text = true },
			function(res)
				vim.schedule(function()
					if res.code ~= 0 then
						return finish({}, {}, toplevel)
					end
					local files, dirs = parse(toplevel, res.stdout or "")
					finish(files, dirs, toplevel)
				end)
			end
		)
	end)
end

return M

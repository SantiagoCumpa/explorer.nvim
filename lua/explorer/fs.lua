-- Operaciones de sistema de archivos que aplica la sincronización del explorador.

local uv = vim.uv or vim.loop

local M = {}

---@param path string
function M.exists(path)
	return uv.fs_lstat(path) ~= nil
end

---@param path string
function M.is_dir(path)
	local stat = uv.fs_stat(path)
	return stat ~= nil and stat.type == "directory"
end

local function mkdirp(dir)
	if not M.is_dir(dir) then
		vim.fn.mkdir(dir, "p")
	end
end

local function copy(from, to)
	local stat = uv.fs_lstat(from)
	if not stat then
		return false, "no existe " .. from
	end
	if stat.type == "directory" then
		mkdirp(to)
		for name in vim.fs.dir(from) do
			local ok, err = copy(from .. "/" .. name, to .. "/" .. name)
			if not ok then
				return false, err
			end
		end
		return true
	end
	if stat.type == "link" then
		return uv.fs_symlink(uv.fs_readlink(from), to)
	end
	return uv.fs_copyfile(from, to)
end

--- Cambia el nombre de los buffers abiertos de un archivo o carpeta movida.
local function rename_buffers(from, to)
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].buftype == "" then
			local name = vim.fs.normalize(vim.api.nvim_buf_get_name(buf))
			if name == from or vim.startswith(name, from .. "/") then
				vim.api.nvim_buf_set_name(buf, to .. name:sub(#from + 1))
				-- Evitar el aviso "el archivo ya existe" al guardar con el nombre nuevo
				vim.api.nvim_buf_call(buf, function()
					vim.cmd("silent! write! | edit")
				end)
			end
		end
	end
end

--- Cierra los buffers sin cambios de un archivo o carpeta borrada.
local function wipe_buffers(path)
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		local name = vim.fs.normalize(vim.api.nvim_buf_get_name(buf))
		if (name == path or vim.startswith(name, path .. "/")) and not vim.bo[buf].modified then
			pcall(vim.api.nvim_buf_delete, buf, { force = false })
		end
	end
end

---@param path string
---@param is_dir boolean
function M.create(path, is_dir)
	if M.exists(path) then
		return false, "ya existe " .. path
	end
	if is_dir then
		mkdirp(path)
		return true
	end
	mkdirp(vim.fs.dirname(path))
	local fd, err = uv.fs_open(path, "w", 420)
	if not fd then
		return false, err
	end
	uv.fs_close(fd)
	return true
end

function M.copy(from, to)
	if M.exists(to) then
		return false, "ya existe " .. to
	end
	mkdirp(vim.fs.dirname(to))
	return copy(from, to)
end

function M.move(from, to)
	if M.exists(to) then
		return false, "ya existe " .. to
	end
	mkdirp(vim.fs.dirname(to))
	local ok, err, code = uv.fs_rename(from, to)
	if not ok and code == "EXDEV" then
		-- Distinto disco: copiar y borrar
		ok, err = copy(from, to)
		if ok then
			vim.fs.rm(from, { recursive = true, force = true })
		end
	end
	if ok then
		rename_buffers(from, to)
	end
	return ok, err
end

--- Herramienta para mandar a la papelera, si hay alguna.
local function trash_cmd(path)
	if vim.fn.executable("gio") == 1 then
		return { "gio", "trash", path }
	elseif vim.fn.executable("trash-put") == 1 then
		return { "trash-put", path }
	elseif vim.fn.executable("trash") == 1 then
		return { "trash", path }
	end
end

---@return boolean usará la papelera
function M.can_trash(to_trash)
	return to_trash and trash_cmd("") ~= nil
end

function M.delete(path, to_trash)
	local cmd = to_trash and trash_cmd(path)
	local ok, err
	if cmd then
		local res = vim.system(cmd):wait()
		ok, err = res.code == 0, res.stderr
	else
		ok, err = pcall(vim.fs.rm, path, { recursive = true, force = true })
	end
	if ok then
		wipe_buffers(path)
	end
	return ok, err
end

return M

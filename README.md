# explorer.nvim

Explorador de archivos y outline en una barra lateral, al estilo VSCode, manejado con el teclado.

```
 PROYECTO                    │
 > docs                      │
 v src                     • │
 │ > utils                 • │
 │   main.lua                │
   .gitignore                │
   README.md             ● M │
   new.txt                 U │
 OUTLINE                     │
 v  M                        │
 │    hello                  │
```

- **Explorador de archivos**: árbol de la carpeta del proyecto. Con `nvim ~/proyecto` la raíz es esa carpeta y no se puede subir más
- **Gestion de archivos**: `a` crear, `d` borrar, `r` renombrar, `m` mover, `c` copiar, `p` pegar
- **Estados de git**: modificado `M`, nuevo `U`, agregado `A`, renombrado `R`, conflicto `!`, ignorados atenuados y `•` en carpetas con cambios
- **Sin guardar**: `●` en los archivos con cambios sin guardar
- **Outline**: funciones, clases, variables, etc. del archivo actual según el LSP. Sigue al cursor

## Instalación

Requiere Neovim 0.11+, `git` para el estado de git y una [Nerd Font](https://www.nerdfonts.com/) para los íconos.
Si tienes [mini.icons](https://github.com/nvim-mini/mini.nvim/blob/main/readmes/mini-icons.md) o
[nvim-web-devicons](https://github.com/nvim-tree/nvim-web-devicons), usa sus íconos.

[vim.pack](https://neovim.io/doc/user/pack.html#vim.pack) (Neovim 0.12+):

```lua
vim.pack.add({ "https://github.com/SantiagoCumpa/explorer.nvim" })
require("explorer").setup()
```

## Uso

No hay comandos ni atajos globales por defecto: el explorador se maneja con la API Lua del
global `Explorer` (como `Snacks`). Define tus propios atajos:

```lua
vim.keymap.set("n", "<A-e>", function() Explorer.toggle() end, { desc = "Explorador" })
vim.keymap.set("n", "<leader>o", function() Explorer.focus_outline() end, { desc = "Outline" })
```

| Función | Qué hace |
|-----|-----|
| `Explorer.open()` | Abre la barra lateral |
| `Explorer.close()` | Cierra la barra lateral |
| `Explorer.toggle()` | Abre o cierra la barra lateral |
| `Explorer.focus()` | Va al explorador (lo abre si hace falta) |
| `Explorer.focus_outline()` | Va al outline |
| `Explorer.reveal(path?)` | Muestra un archivo en el árbol (por defecto el abierto) |
| `Explorer.is_open()` | `true` si la barra está abierta |

También se puede llamar desde la línea de comandos: `:lua Explorer.open()`.

Las teclas de las secciones siguientes solo existen dentro del explorador y del outline:
no interfieren con el editor ni con otros plugins.

## Explorador

| Tecla | Acción |
|-----|-----|
| `j` / `k` | Bajar / subir |
| `l` | Expandir carpeta / abrir archivo (el foco queda en el explorador) |
| `L`, `Enter` | Expandir carpeta / abrir archivo y pasar al editor |
| `h` | Colapsar la carpeta, o subir a la carpeta padre (sin salir de la raíz) |
| `H` | Colapsar todo |
| `a` | Crear archivo o carpeta |
| `d` | Borrar (pide confirmación) |
| `r` | Renombrar |
| `m` | Cortar, para mover con `p` |
| `c` | Copiar, para pegar con `p` |
| `p` | Pegar en la carpeta bajo el cursor |
| `@` | Mostrar el archivo abierto en el editor |
| `R` | Recargar |
| `g.` | Mostrar / ocultar archivos ocultos |
| `g?` | Ayuda |
| `q` | Cerrar |

### Crear con `a`

Se crea dentro de la carpeta bajo el cursor, o junto al archivo bajo el cursor:

| Escribes | Resultado |
|-----|-----|
| `testing.rs` | Crea el archivo |
| `testdir/` | Crea la carpeta (termina en `/`) |
| `testdir/sub/test.rs` | Crea toda la ruta y el archivo |

Los archivos creados se abren en el editor (`open_on_create`).

### Renombrar, mover, copiar y borrar

- `r` renombra. Con `/` en el nombre lo mueve a una subcarpeta: `sub/nombre.rs`
- `m` corta y `c` copia; `p` pega en la carpeta bajo el cursor (o en la del archivo bajo el cursor).
  Lo cortado se pega una vez; lo copiado, las veces que quieras. Si ya existe, la copia se llama `nombre copy.rs`
- `d` borra, a la papelera si hay `gio`, `trash-put` o `trash`
- `d`, `m` y `c` también funcionan con una selección visual (`V` + `j`/`k`) para varios a la vez
- Los buffers abiertos de archivos renombrados o movidos se actualizan

## Outline

| Tecla | Acción |
|-----|-----|
| `Enter`, `L` | Ir al símbolo y pasar al editor |
| `l` | Expandir el símbolo, o ir a él sin dejar el outline |
| `h` | Colapsar el símbolo, o ir al símbolo padre |
| `H` | Colapsar todo |
| `g?` | Ayuda |
| `q` | Cerrar |

Se actualiza al cambiar de archivo, al editar y al guardar. Necesita un LSP con `textDocument/documentSymbol`.

## Configuración

Valores por defecto:

```lua
require("explorer").setup({
	-- "left" | "right"
	position = "left",
	width = 30,
	-- Carpeta raíz. Por defecto el cwd (o la carpeta de `nvim <carpeta>`)
	root = nil,
	-- Mostrar en el árbol el archivo abierto en el editor
	follow_current_file = true,
	-- Abrir el explorador al editar una carpeta (`nvim .`), en vez de netrw
	hijack_directories = true,
	show_hidden = true,
	-- Nombres que no se muestran nunca
	exclude = { ".git", ".DS_Store" },
	-- Espacios por nivel del árbol
	indent = 2,
	git = true,
	-- Pedir confirmación antes de borrar
	confirm = true,
	-- Borrar a la papelera (si hay gio/trash-put/trash) en vez de borrar para siempre
	delete_to_trash = true,
	-- Abrir en el editor los archivos creados con `a`
	open_on_create = true,
	outline = {
		enabled = true,
		-- Alto. Entre 0 y 1 es una fracción de la barra
		height = 0.4,
		-- Resaltar el símbolo donde está el cursor
		follow_cursor = true,
		-- Mostrar los símbolos expandidos
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
	-- Atajos del explorador. false desactiva uno
	mappings = {
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
		add = "a",
		delete = "d",
		rename = "r",
		move = "m",
		copy = "c",
		paste = "p",
	},
})
```

## Colores

| Grupo | Por defecto | Uso |
|-----|-----|-----|
| `ExplorerNormal` | `Normal` | Fondo de la barra |
| `ExplorerTitle` | `Title` | Títulos (`PROYECTO`, `OUTLINE`) |
| `ExplorerDirectory` | `Directory` | Carpetas |
| `ExplorerFile` | `Normal` | Archivos |
| `ExplorerCurrent` | negrita | Archivo abierto en el editor |
| `ExplorerIndent` | `NonText` | Guías de sangría |
| `ExplorerChevron` | `Comment` | `>` / `v` de las carpetas |
| `ExplorerModified` | `Title` | `●` sin guardar |
| `ExplorerCut` / `ExplorerCopied` | `Comment` / `Special` | Elementos cortados / copiados |
| `ExplorerGitModified` | `Changed` | Modificado |
| `ExplorerGitAdded` / `ExplorerGitUntracked` / `ExplorerGitRenamed` | `Added` | Agregado / nuevo / renombrado |
| `ExplorerGitDeleted` | `Removed` | Borrado |
| `ExplorerGitConflict` | `DiagnosticError` | Conflicto |
| `ExplorerGitIgnored` | `Comment` | Ignorado |
| `ExplorerOutlineName` / `ExplorerOutlineDetail` | `Normal` / `Comment` | Nombre / detalle del símbolo |



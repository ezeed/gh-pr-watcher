# Instalar gh-pr-watcher desde un agente

Guía para un agente de código (Claude Code, Codex, Cursor…) que instala o reconfigura la
extensión por pedido de una persona. El agente no tiene terminal interactiva: todo va por
`detect` (lectura, JSON) e `install` con flags (escritura). Sin flags ni terminal, `install` no
pregunta: usa la config existente más los defaults.

## 1. Chequear dependencias

```bash
command -v gh && gh auth status        # sin sesión: la persona corre `gh auth login` (interactivo)
command -v jq                          # si falta: brew install jq
gh extension list | grep pr-watcher || gh extension install ezeed/gh-pr-watcher
```

`gh auth login` y `brew install` cambian la máquina: pedí permiso antes de correrlos.

## 2. Leer el estado

```bash
gh pr-watcher detect            # o: detect --user LOGIN, para ver orgs y repos de otra cuenta
```

Devuelve un JSON como este:

```json
{
  "os": "Darwin", "scheduler": "launchd",
  "deps": {"gh": "/opt/homebrew/bin/gh", "jq": "/usr/bin/jq", "terminal_notifier": null},
  "accounts": [{"login": "ana", "active": true}],
  "account": "ana",
  "orgs": ["AcmeCorp"],
  "repos_with_prs": ["AcmeCorp/api", "AcmeCorp/web", "ana/dotfiles"],
  "config": {"path": "...", "exists": false,
             "values": {"GH_USER": "", "OWNERS": "", "REPOS": "", "EVERY_HOURS": 6,
                        "INCLUDE_DRAFTS": false, "SKIP_LABEL": ""}},
  "installed": {"plist_exists": false, "agent_loaded": false, ...},
  "last_run_error": null,
  "other_watcher_agents": [],
  "errors": []
}
```

- `repos_with_prs` son los repos con PRs de la cuenta, abiertos o entre los 100 más recientes.
  Son los candidatos a vigilar.
- `config.values` es lo que hay en el archivo. Si `exists` es false, son los defaults.
- Si `installed.agent_loaded` es true, ya está instalado: `install` lo reprograma sin duplicarlo.
- `errors` no vacío significa que algo de lo anterior no se pudo leer (sin `gh`, sin sesión, sin
  red). Un `orgs` vacío con errores **no** quiere decir "sin orgs": resolvé el error antes de decidir.
- `last_run_error` es el motivo por el que falló la última vuelta programada, si falló.
- `other_watcher_agents` lista otros LaunchAgents con "pr-watcher" o "babysitter" en el nombre (por ejemplo, un
  script casero anterior). Si hay alguno, avisá: los dos correrían a la vez.

## 3. Decidir o preguntar

Decidí vos, sin preguntar, lo que sale de `detect`:

| Situación | Decisión |
|---|---|
| Una sola cuenta en `accounts` | No pases `--user`. |
| Ninguna org en `orgs` | No pases `--owners`: vigila todos los PRs de la cuenta. |
| `repos_with_prs` cae entero dentro de una sola org | `--owners <org>`. |
| La persona no mencionó frecuencia, drafts ni etiqueta | Los defaults: cada 6 hs, sin drafts, sin etiqueta. |

Preguntale a la persona, en una sola pregunta y con las opciones de `detect` a la vista:

- **Qué cuenta**, si hay más de una en `accounts`.
- **Qué vigilar**, si tiene orgs o repos repartidos en varios owners. Mostrá `orgs`,
  `repos_with_prs` y la opción de sus repos personales.
- **Si reemplaza a un watcher previo**, cuando `other_watcher_agents` no está vacío.
  Nunca lo descargues sin su OK.
- **Si le sirve con el costo de CI**, cuando va a vigilar repos compartidos. Cada actualización
  dispara CI: con "require up to date", cada merge a la base suma una corrida por cada PR suyo.

No preguntes por las notificaciones: el aviso de conflicto siempre está y no se configura.

## 4. Instalar

Primero mostrá qué va a escribir, después instalá:

```bash
gh pr-watcher install --dry-run --owners "AcmeCorp" --every-hours 6 --no-drafts --no-skip-label
gh pr-watcher install           --owners "AcmeCorp" --every-hours 6 --no-drafts --no-skip-label
```

| Flag | Clave | Valor |
|---|---|---|
| `--user LOGIN` | `GH_USER` | Una de `accounts[].login`. Vacío = la activa en cada corrida. |
| `--owners "A B"` | `OWNERS` | Orgs o usuarios, separados por espacio. `""` = todos los PRs. |
| `--repos "o/r o/r"` | `REPOS` | Sólo esos repos. **Reemplaza** a `OWNERS` (la búsqueda de GitHub combina org y repo con Y). |
| `--every-hours N` | `EVERY_HOURS` | 1 a 24, contando desde las 0 hs. |
| `--drafts` / `--no-drafts` | `INCLUDE_DRAFTS` | |
| `--skip-label L` / `--no-skip-label` | `SKIP_LABEL` | La convención es `no-autoupdate`. |
| `--notify-image PATH` | `NOTIFY_IMAGE` | Imagen adjunta a las notificaciones. `""` = la incluida. |

`install` valida antes de escribir nada: el formato de cada valor, que la sesión de `gh` sea válida
y tenga el permiso `repo`, y que cada owner y repo exista. Si algo falla, no queda nada a medias.
Los flags que no pases conservan el valor de la config existente. `--yes` fuerza el modo sin
preguntas aunque haya terminal.

Instalar es cargar un LaunchAgent en la sesión de la persona: pedí su OK antes de correr el
`install` sin `--dry-run`.

## 5. Verificar

```bash
gh pr-watcher doctor --json     # ok: true; si no, los checks con status "fail" dicen cómo arreglarlo
gh pr-watcher run --dry-run     # lista qué PRs actualizaría, sin tocar ninguno
```

Recién instalado, el check `last_run` dice que todavía no le tocó correr: es lo esperado.

`run --dry-run` no actualiza ramas, no notifica y no guarda estado: se puede correr sin avisar.
`test-notify` sí manda una notificación (para comprobar que macOS las muestra): pedí permiso.

## Errores

Ante cualquier problema (la persona dice que no anda, o `detect` trae `last_run_error`), empezá por:

```bash
gh pr-watcher doctor --json
```

```json
{"ok": false, "checks": [
  {"id": "session", "status": "fail", "message": "al token de 'ana' le falta el permiso repo; corré gh auth refresh -h github.com -s repo", "fix": null},
  {"id": "last_run", "status": "fail", "message": "tenía que correr a las 2026-09-29 12:00 y no corrió (última: nunca)", "fix": "revisá launchctl print …"}
]}
```

`status` es `ok`, `warn` (anda, con una salvedad) o `fail`. El arreglo va en `fix`, o dentro de
`message` cuando el mensaje ya trae el comando. `doctor` no cambia nada ni notifica: se puede
correr sin avisar. Aplicar un `fix` sí cambia cosas: pedí permiso como con `install`.

Fuera de `doctor`, todo error sale por stderr con el prefijo `error:` y termina con código distinto de 0. Los más
comunes:

| Mensaje | Qué hacer |
|---|---|
| `falta jq` / `falta gh` / `tu gh es muy viejo` | `brew install jq`, `brew install gh` o `brew upgrade gh`, con permiso. |
| `gh no tiene sesión en github.com` / `gh no tiene sesión como 'X'` | La persona corre `gh auth login`. |
| `la sesión de gh de 'X' no es válida` / `le falta el permiso repo` | La persona corre el `gh auth refresh …` que indica el mensaje. |
| `no pude conectar con GitHub` | Sin red o con un proxy: reintentá; no es un problema de config. |
| `no existe el usuario u org` / `el repo … no existe o tu cuenta no tiene acceso` | Corregí `--owners`/`--repos` con los valores de `detect`. |
| `… separado por espacios, no por comas` / `REPOS tiene un repo inválido` | Owners y repos van separados por espacio; los repos, `owner/repo`. |
| `EVERY_HOURS tiene que ser …` | Un entero entre 1 y 24. |
| `NOTIFY_IMAGE no es un archivo que se pueda leer` | Una ruta local existente, o `--notify-image ""`. |
| `launchctl bootstrap falló` | Revisá con `plutil -lint` el plist que indica `detect.installed.plist`. |

## Desinstalar

```bash
gh pr-watcher uninstall && gh extension remove pr-watcher
```

La config queda en `config.path` y el log en `~/.local/state/gh-pr-watcher/`. Borrarlos es
inocuo.

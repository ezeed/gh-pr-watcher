<p align="center">
  <img src="assets/logo.png" alt="gh-pr-watcher" width="160">
</p>

<h1 align="center">gh-pr-watcher</h1>

<p align="center">
  Mantiene al día tus PRs abiertos y te avisa cuando uno entra en conflicto.<br>
  Una extensión de <a href="https://cli.github.com">GitHub CLI</a> que corre sola unas veces por día.
</p>

---

Hace lo mismo que el botón **"Update branch"** de GitHub, pero por vos y en todos tus PRs a la vez.
No hace falta cambiar nada en el repo: ni Actions, ni bots, ni permisos nuevos.

Pensado para repos con la regla *"Require branches to be up to date before merging"*: cada merge a
la base deja atrasados a todos los PRs abiertos, y hay que actualizarlos uno por uno antes de mergear.

## Instalar

```bash
gh extension install ezeed/gh-pr-watcher
gh pr-watcher install          # te pregunta la config y programa la corrida
gh pr-watcher run --dry-run    # prueba: informa qué haría, sin actualizar ninguna rama
```

### Requisitos

- **macOS** para la programación automática (launchd). En Linux, `run` funciona igual e `install`
  te da la línea para `crontab`.
- [`gh`](https://cli.github.com) autenticado (`gh auth login`), con permiso de escritura sobre la
  rama de cada PR. Con tus PRs en el repo de la org ya lo tenés. Desde un fork, el PR necesita
  *"Allow edits from maintainers"*.
- `jq` (`brew install jq`).
- Opcional: `terminal-notifier` (`brew install terminal-notifier`), para que el click en la
  notificación abra el PR. Sin él, las notificaciones salen por `osascript` y sin click.

### El instalador

`install` pregunta solo lo que tu cuenta hace necesario. Se elige con las flechas (espacio marca,
enter sigue), y si ya lo habías instalado, cada pregunta arranca en tu config actual:

| Pregunta | Cuándo aparece |
|---|---|
| **Cuenta** | Si `gh` tiene más de una cuenta en github.com. Con una, la usa y listo. |
| **¿Qué PRs vigilar?** | Si pertenecés a alguna org. Lista tus orgs, tus repos personales y "todos tus PRs, en cualquier repo". |
| **¿Sólo algunos repos?** | Si dentro de lo elegido tenés PRs (abiertos o recientes) en más de un repo. |
| **¿Cada cuántas horas?** | Siempre. Cada opción muestra a qué horas corre. |
| **Drafts y etiqueta** | Siempre: si actualiza los drafts y si excluye los PRs con la etiqueta `no-autoupdate`. |
| **¿Instalar con esta config?** | Siempre. Con "No" sale sin tocar nada. |

En una terminal sin soporte (`TERM=dumb`) las mismas preguntas salen como menús numerados, y
`NO_COLOR=1` apaga los colores.

¿Lo instala un agente (Claude Code, Codex…)? Pasale [`AGENTS.md`](AGENTS.md): usa
`gh pr-watcher detect` para leer cuentas, orgs y repos en JSON y después `install` con flags, sin
preguntas por consola.

## Qué hace en cada vuelta

Busca tus PRs abiertos (`gh search prs --author @me`) en las orgs o repos que configuraste y, por
cada uno:

| Estado del PR | Qué hace |
|---|---|
| Draft | Nada (salvo `INCLUDE_DRAFTS=true`). |
| Tiene la etiqueta `SKIP_LABEL` | Nada. |
| Mergeable y atrasado respecto de la base | `PUT /repos/{repo}/pulls/{n}/update-branch`: hace merge de la base en la rama, y eso corre CI. |
| Mergeable y al día | Nada. |
| En conflicto | Notificación (el click abre el PR). Avisa **una sola vez**, cuando el PR pasa a conflicto. |
| GitHub todavía calcula si es mergeable | Reintenta unos segundos; si no hay respuesta, queda para la próxima vuelta. |

**No resuelve conflictos.** Si el merge de tres vías de GitHub entra limpio, actualiza la rama. Si
choca una sola línea, GitHub marca el PR en conflicto y el watcher solo avisa: lo resolvés vos, con
"Resolve conflicts" en la web o con `git merge` local. Cuando el PR vuelve a ser mergeable no avisa;
si está atrasado, lo actualiza como a cualquier otro.

Nunca fuerza nada, no hace rebase y no pushea desde tu máquina. Usa `expected_head_sha`: si
pusheaste algo entre la lectura y la actualización, GitHub rechaza el cambio y el PR queda para la
próxima vuelta.

### Avisos

Hay solo dos, y no se configuran:

- **Conflicto:** un PR tuyo entró en conflicto. El click abre el PR.
- **Dejó de andar:** la vuelta entera falló (sesión de `gh` vencida, config inválida, un owner que
  no existe). Trae el motivo y el click abre el log. No se repite mientras el error sea el mismo.

Sin red no avisa nada: lo anota en el log y sigue en la próxima vuelta. `gh pr-watcher test-notify`
manda uno de prueba para ver si macOS los deja pasar.

## Configuración

Vive en `~/.config/gh-pr-watcher/config`. Son líneas `KEY=VALUE` que se leen sin ejecutarse. Los
cambios valen desde la próxima vuelta; solo `EVERY_HOURS` necesita `gh pr-watcher install --yes`
para reprogramar.

| Clave | Default | Qué controla |
|---|---|---|
| `GH_USER` | *(vacío)* | Cuenta de `gh` a usar, aunque la activa sea otra. Vacío = la cuenta activa de `gh` en cada corrida. |
| `OWNERS` | *(vacío)* | Orgs o usuarios cuyos repos se vigilan, separados por espacio. Vacío = todos tus PRs abiertos, en cualquier repo. El instalador propone tus orgs. |
| `REPOS` | *(vacío)* | Repos puntuales `owner/repo`, separados por espacio. Si hay alguno, se vigilan **solo esos** y `OWNERS` no cuenta (la búsqueda de GitHub combina org y repo con Y, no con O). |
| `EVERY_HOURS` | `6` | Cada cuántas horas corre (1 a 24), contando desde las 0 hs: `6` = 0, 6, 12 y 18 hs. Si la máquina está dormida a esa hora, launchd corre la vuelta al despertar. |
| `INCLUDE_DRAFTS` | `false` | `true` = también actualiza los drafts. |
| `SKIP_LABEL` | *(vacío)* | Los PRs con esta etiqueta no se tocan. El instalador ofrece `no-autoupdate`; en el archivo podés poner cualquiera. |
| `NOTIFY_IMAGE` | *(el logo)* | Imagen local (PNG o JPG) que va a la derecha de la notificación. Solo con `terminal-notifier`. El ícono de la izquierda no se puede cambiar: macOS lo toma de la app que notifica. |

Una clave mal escrita (`OWNER=`) o una línea que no es `KEY=VALUE` no se ignora en silencio: se
avisa, con una sugerencia si se parece a una clave real. `install` además verifica que cada owner
y cada repo existan y que tu cuenta los vea.

El log y el estado quedan en `~/.local/state/gh-pr-watcher/`. El estado solo sirve para no repetir
avisos: borrarlo es inocuo.

## Comandos

| Comando | Qué hace |
|---|---|
| `install [opciones]` | Guarda la config y programa la corrida (launchd en macOS; en Linux imprime la línea de `crontab`). Sin opciones y con terminal, pregunta. |
| `run [--dry-run]` | Corre una vuelta ahora. Con `--dry-run` informa qué haría, sin actualizar ramas, sin notificar y sin guardar estado. |
| `status [--json]` | Config, si el agente está cargado, la última vuelta, el último error y el final del log. |
| `doctor [--json]` | Revisa todo lo que hace falta para que una vuelta ande y dice cómo arreglar cada problema. No cambia nada. |
| `log [N]` | Las últimas N líneas del log (30 por default). |
| `config` | La ruta y el contenido del archivo de config. |
| `test-notify` | Manda una notificación de prueba. |
| `detect [--user LOGIN]` | JSON con cuentas, orgs, repos con PRs tuyos, dependencias, config e instalación actual. Es para agentes. |
| `uninstall` | Quita la programación. La config y el log quedan. |
| `version` · `help` | Versión y ayuda. |

Un comando mal escrito sugiere el correcto (`rub` → `run`). Los errores salen por stderr con el
prefijo `error:` y un código de salida distinto de 0.

### Opciones de `install`

Con cualquiera de estas opciones (salvo `--dry-run`), `install` no pregunta nada: las opciones
pisan la config que ya tenías y lo que falte sale de los defaults.

| Opción | Qué hace |
|---|---|
| `--user LOGIN` | Cuenta de `gh` a usar (`GH_USER`). |
| `--owners "A B"` | Orgs o usuarios a vigilar (`OWNERS`). `""` = todos tus PRs. |
| `--repos "o/r o/r"` | Solo estos repos (`REPOS`); reemplaza a `--owners`. |
| `--every-hours N` | Cada cuántas horas corre, de 1 a 24 (`EVERY_HOURS`). |
| `--drafts` · `--no-drafts` | Actualiza o no los drafts (`INCLUDE_DRAFTS`). |
| `--skip-label L` · `--no-skip-label` | Excluye o no los PRs con la etiqueta L (`SKIP_LABEL`). |
| `--notify-image PATH` | Imagen de las notificaciones (`NOTIFY_IMAGE`). `""` = el logo. |
| `--yes` | No pregunta: usa la config existente y los defaults. Sirve para reprogramar después de editar el archivo. |
| `--dry-run` | Muestra la config y el LaunchAgent que escribiría, sin tocar nada. Sola, igual hace las preguntas. |

## Si algo no anda

```bash
gh pr-watcher doctor
```

Marca cada problema con el comando que lo arregla y termina con código distinto de 0 si algo
falla. No cambia nada ni manda notificaciones. Revisa:

- `gh` y `jq` instalados, y `terminal-notifier` (solo como aviso).
- La config: claves mal escritas y valores inválidos.
- La sesión de `gh`, el permiso `repo`, y que cada owner y repo exista y tu cuenta lo vea.
- La programación: que el LaunchAgent esté cargado, que apunte a un `gh` que todavía existe (brew a
  veces lo mueve) y que sus horas coincidan con `EVERY_HOURS`.
- **Que haya corrido.** Es lo único que ninguna notificación avisa: si launchd deja de disparar, no
  hay error. `doctor` compara la última vuelta con la última hora programada; si la máquina estaba
  apagada a esa hora no lo marca, y si estaba dormida espera a que launchd la corra al despertar.
- Otro watcher corriendo a la vez, el último error de una vuelta y un estado dañado.

`doctor --json` devuelve lo mismo para un agente: `{ok, checks: [{id, status, message, fix}]}`.

## Actualizar y desinstalar

```bash
gh extension upgrade pr-watcher     # la programación sigue andando, no hace falta reinstalar
gh pr-watcher uninstall && gh extension remove pr-watcher
```

`uninstall` deja la config y el log; para empezar de cero, borrá también `~/.config/gh-pr-watcher`
y `~/.local/state/gh-pr-watcher`.

## Para tener en cuenta

- **Merge, no rebase.** El endpoint de GitHub hace merge de la base en tu rama. Con squash merge no
  deja rastro; si el repo exige historia lineal, esos merges estorban.
- **Tu `git push` puede rebotar.** Si el watcher actualizó una rama que tenés checkouteada, el
  próximo push es non-fast-forward: `git pull` y listo.
- **Cada actualización dispara CI.** Antes de repartirlo en un equipo, hacé la cuenta: con la regla
  de "up to date", cada merge a la base puede terminar en una corrida de CI extra por cada PR ready
  de cada persona que lo use. El tope es la cantidad de vueltas por día (`EVERY_HOURS`).
- `gh` lee el token del keychain, y eso funciona bajo launchd. Si el log dice "not logged in",
  corré `gh pr-watcher doctor`.

## Licencia

[MIT](LICENSE).

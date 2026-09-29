# gh-pr-watcher

Extensión de [GitHub CLI](https://cli.github.com) que mantiene al día tus PRs abiertos y te avisa
cuando uno entra en conflicto. Corre sola unas veces por día (launchd en macOS) y hace lo mismo
que el botón **"Update branch"** de GitHub, así que no hace falta que nadie cambie nada en el repo.

Pensado para repos con la regla *"Require branches to be up to date before merging"*: cada merge a
la base deja atrasados a todos los PRs abiertos, y hay que actualizarlos uno por uno antes de mergear.

## Qué hace en cada vuelta

Busca tus PRs abiertos (`gh search prs --author @me`) en las orgs o repos que configures y, por cada uno:

| Estado del PR | Qué hace |
|---|---|
| Draft | Nada (salvo `INCLUDE_DRAFTS=true`). |
| Tiene la etiqueta `SKIP_LABEL` | Nada. |
| Mergeable y atrasado respecto de la base | `PUT /repos/{repo}/pulls/{n}/update-branch`: hace merge de la base en la rama y corre CI. |
| Mergeable y al día | Nada. |
| En conflicto | Notificación (el click abre el PR). Avisa **una sola vez**, cuando el PR pasa a conflicto; si sigue en conflicto no repite. |
| GitHub todavía calcula si es mergeable | Reintenta unos segundos; si no hay respuesta, lo deja para la próxima vuelta. |

Si la vuelta entera falla (sesión de `gh` vencida, config inválida, un owner que no existe), manda
**una** notificación "dejó de andar" con el motivo, y el click abre el log. No la repite mientras
el error sea el mismo, y cuando una vuelta vuelve a andar lo anota en el log sin avisar. Sin red no
avisa nada: lo anota y sigue en la próxima vuelta. `status` muestra el último error arriba de todo,
y `doctor` dice cómo arreglarlo.

**No resuelve conflictos.** Si el merge de tres vías de GitHub entra limpio, no hay conflicto y
actualiza la rama. Si una sola línea choca, GitHub marca el PR como en conflicto (trivial o no, da
igual) y el watcher solo avisa. Lo resolvés vos: "Resolve conflicts" en la web para los chicos,
`git merge` local para los otros. Cuando el PR vuelve a ser mergeable no avisa (lo resolviste
vos): lo anota en el log y, si está atrasado, lo actualiza como a cualquier otro. Nunca fuerza nada, no hace rebase y no pushea
desde tu máquina. Usa `expected_head_sha`: si pusheaste algo entre la lectura
y la actualización, GitHub rechaza el cambio y el PR queda para la próxima vuelta.

## Requisitos

- **macOS** para la programación automática (launchd). En Linux, `run` funciona igual y `install`
  te da la línea para `crontab`.
- [`gh`](https://cli.github.com) autenticado (`gh auth login`), con permiso de escritura sobre la
  rama de cada PR. Con tus PRs en el repo de la org ya lo tenés. Desde un fork, el PR necesita
  *"Allow edits from maintainers"*.
- `jq` (`brew install jq`).
- Opcional: `terminal-notifier` (`brew install terminal-notifier`) para que el click en la
  notificación abra el PR. Sin él, las notificaciones salen por `osascript`, sin click.

## Instalar

```bash
gh extension install ezeed/gh-pr-watcher
gh pr-watcher install          # te pregunta la config y programa la corrida
gh pr-watcher run --dry-run    # prueba: informa sin actualizar ninguna rama
```

`install` pregunta solo lo que tu cuenta hace necesario, y Enter conserva lo que está entre corchetes:

- **Cuenta:** solo si `gh` tiene más de una cuenta en github.com. Con una, la usa y listo.
- **Qué PRs vigilar:** solo si pertenecés a alguna org. Lista tus orgs y tus repos personales, y se
  eligen por número (`1 2`); `*` = todos tus PRs, en cualquier repo.
- **Sólo algunos repos:** lista los repos donde tenés PRs (abiertos o recientes) dentro de lo que
  elegiste. Solo aparece si hay más de uno. `*` = todos.
- **Cada cuántas horas corre**, **si toca los drafts** y **si excluye los PRs con la etiqueta
  `no-autoupdate`**.

¿Lo instala un agente (Claude Code, Codex…)? Pasale [`AGENTS.md`](AGENTS.md): usa
`gh pr-watcher detect` para leer cuentas, orgs y repos en JSON y después `install` con flags,
sin preguntas por consola.

Los avisos no se configuran: siempre llegan el de conflicto y el de "dejó de andar".
`gh pr-watcher test-notify` manda uno de prueba para ver si macOS los deja pasar. Si volvés a correr
`install`, los defaults son tu config actual. Para reprogramar sin preguntas (por ejemplo, después
de editar `EVERY_HOURS`): `gh pr-watcher install --yes`. Para ver qué escribiría sin tocar
nada: `install --dry-run`.

## Configuración

Vive en `~/.config/gh-pr-watcher/config`. Son líneas `KEY=VALUE` que el script lee sin
ejecutar. Los cambios se toman en la próxima vuelta; solo `EVERY_HOURS` necesita `install --yes`.

| Clave | Default | Qué controla |
|---|---|---|
| `GH_USER` | la de `gh` | Cuenta de `gh` a usar, aunque la activa sea otra. Vacío = la activa en cada corrida. |
| `OWNERS` | tus orgs | Orgs o usuarios, separados por espacio. Vacío = todos tus PRs abiertos en GitHub. |
| `REPOS` | *(vacío)* | Repos puntuales `owner/repo`, separados por espacio. Si hay alguno, se vigilan **solo esos** y `OWNERS` no cuenta (la búsqueda de GitHub combina org y repo con Y, no con O). |
| `EVERY_HOURS` | `6` | Cada cuántas horas corre (1-24), contando desde las 0 hs: `6` = 0, 6, 12 y 18 hs. Si la máquina está dormida, launchd corre la vuelta al despertar. |
| `INCLUDE_DRAFTS` | `false` | `true` = también actualiza los drafts. |
| `SKIP_LABEL` | *(vacío)* | Los PRs con esta etiqueta no se tocan. `install` ofrece `no-autoupdate`; en el archivo podés poner cualquiera. |
| `NOTIFY_IMAGE` | *(la incluida)* | Imagen local (PNG o JPG) que se adjunta a la derecha de la notificación. Solo con `terminal-notifier`. El ícono de la izquierda no se puede cambiar: macOS lo toma siempre de la app que notifica. |

Una clave mal escrita (`OWNER=`) o una línea que no es `KEY=VALUE` no se ignoran en silencio: se
avisan, con una sugerencia si se parece a una clave real. `install` además verifica que cada owner
y cada repo existan y que tu cuenta los vea.

## Comandos

```
gh pr-watcher install [--yes] [--dry-run] [--user L] [--owners "A B"] [--repos "o/r"]
                         [--every-hours N] [--drafts|--no-drafts] [--skip-label L|--no-skip-label]
                         [--notify-image PATH]
gh pr-watcher detect [--user L]   # JSON: cuentas, orgs, repos con PRs, config e instalación
gh pr-watcher run [--dry-run]     # --dry-run: no actualiza, no notifica, no guarda estado
gh pr-watcher test-notify
gh pr-watcher doctor [--json]     # qué está mal y cómo se arregla; no cambia nada
gh pr-watcher status [--json]     # config, si el agente está cargado y el final del log
gh pr-watcher log [N]
gh pr-watcher config
gh pr-watcher uninstall     # quita la programación; config y log quedan
```

Con cualquier flag, con `--yes` o sin terminal, `install` no pregunta nada: los flags pisan la
config existente y lo que falte sale de los defaults. Los errores salen por stderr con `error:` y
un código de salida distinto de 0.

El log y el estado quedan en `~/.local/state/gh-pr-watcher/`. El estado solo sirve para no
repetir avisos: borrarlo es inocuo.

## Si algo no anda

```bash
gh pr-watcher doctor
```

Revisa todo lo que hace falta para que una vuelta ande y marca cada problema con el comando que lo
arregla. No cambia nada ni manda notificaciones, y termina con código distinto de 0 si algo falla:

- `gh` y `jq` instalados, y `terminal-notifier` (solo como aviso).
- La config: claves mal escritas, valores inválidos.
- La sesión de `gh`, el permiso `repo`, y que cada owner y repo exista y sea visible para tu cuenta.
- La programación: que el LaunchAgent esté cargado, que apunte a un `gh` que todavía existe (brew
  a veces lo mueve) y que sus horas coincidan con `EVERY_HOURS`.
- **Que haya corrido.** Es lo único que ninguna notificación te avisa: si launchd deja de disparar,
  no hay error. `doctor` compara la última vuelta con la última hora programada. Si la máquina
  estaba apagada a esa hora no lo marca, y si estaba dormida espera a que launchd la corra al
  despertar.
- Otro watcher corriendo a la vez, el último error de una vuelta y un estado dañado.

`doctor --json` devuelve lo mismo para un agente: `{ok, checks: [{id, status, message, fix}]}`.

## Actualizar y desinstalar

```bash
gh extension upgrade pr-watcher      # la programación sigue apuntando bien, no hace falta reinstalar
gh pr-watcher uninstall && gh extension remove pr-watcher
```

## Para tener en cuenta

- **Merge, no rebase.** El endpoint de GitHub hace merge de la base en tu rama. Con squash merge no
  deja rastro. Si el repo exige historia lineal, esos merges estorban.
- **Tu `git push` puede rebotar.** Si el watcher actualizó una rama que tenés checkouteada, el
  próximo push es non-fast-forward: `git pull` y listo.
- **Cada actualización dispara CI.** Antes de repartirlo en un equipo, hacé la cuenta: con la regla
  de "up to date", cada merge a la base puede terminar en una corrida de CI extra por cada PR ready
  de cada persona que lo use. El tope es la cantidad de vueltas por día (`EVERY_HOURS`).
- `gh` lee el token del keychain y eso funciona bajo launchd. Si el log dice "not logged in",
  corré `gh pr-watcher doctor`.

## Licencia

[MIT](LICENSE).

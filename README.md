# macOS RAM Guardian

Protección local y configurable contra presión de memoria sostenida. Solicita salida normal de aplicaciones inactivas autorizadas; no modifica el kernel ni oculta los avisos de macOS.

## Instalación

Requiere macOS con sesión gráfica y las herramientas de línea de comandos de Xcode (`xcode-select --install`). Probado en macOS 26.5.1 con Apple Silicon; otras versiones y arquitecturas aún no están verificadas.

```sh
git clone https://github.com/shadownrx/macos-ram-guardian.git
cd macos-ram-guardian
./install.sh
```

Se compila desde el código fuente. No requiere sudo ni permisos de Accesibilidad, Grabación de pantalla o acceso a documentos. Si ya existe una configuración, el instalador la conserva. No aplica automáticamente cambios a otros servicios de inicio del usuario.

Para desactivarlo conservando configuración y registros:

```sh
./uninstall.sh
```

Para probarlo localmente:

```sh
./scripts/test.sh
```

Las pruebas de integración abren una aplicación desechable propia y comprueban tanto salida normal como rechazo a salir. No crean presión artificial ni cierran aplicaciones reales.

## Comportamiento

Servicio local para macOS, ejecutado al iniciar sesión mediante `local.codex.ram-guardian`.

- Consulta la presión real del kernel cada 15 segundos; el porcentaje de RAM ocupada por sí solo no dispara acciones.
- Ante advertencia durante 90 segundos: solicita salida normal de una aplicación autorizada que lleve 20 minutos sin estar en primer plano.
- Ante presión crítica durante 15 segundos: usa un mínimo de 5 minutos de inactividad.
- Espera al menos un minuto entre acciones y 30 minutos antes de volver a pedir salida al mismo proceso.
- Da 2 minutos de margen al iniciar y después de despertar de la suspensión.
- Nunca usa salida forzada, SIGKILL, borrado de swap, cambios de SIP ni cambios del kernel.
- Protege el primer plano, Codex, Orca, editores, terminales y Finder. No termina sesiones CLI ni servidores arbitrarios.
- La aplicación decide si acepta la salida. Puede conservar un diálogo de guardado o rechazarla.

Lista inicial: Slack, WhatsApp, Linear, Aside, Zen, Cotypist y DepotBar. Las aplicaciones cerradas deben abrirse de nuevo cuando se necesiten; esto no es suspensión transparente.

## Archivos instalados

`~/.local/share/codex-ram-guardian/config.json`: política editable, releída sin reiniciar.

`~/.local/share/codex-ram-guardian/status.json`: medición actual y aplicaciones elegibles.

`~/.local/share/codex-ram-guardian/events.jsonl`: historial acotado a dos archivos de aproximadamente 1 MB cada uno. Solo registra identificadores de aplicaciones, PIDs y métricas; no títulos de ventanas, documentos ni contenido.

`~/Library/LaunchAgents/local.codex.ram-guardian.plist`: inicio automático y reinicio si el monitor falla.

## Desactivar

```sh
launchctl bootout gui/$(id -u) "$HOME/Library/LaunchAgents/local.codex.ram-guardian.plist"
launchctl disable gui/$(id -u)/local.codex.ram-guardian
```

Alternativamente, cambiar `enabled` a `false` en la configuración: el servicio sigue midiendo, pero deja de cerrar aplicaciones.

## Alcance

Es una prevención automática y persistente, no una garantía de ausencia de OOM. No puede corregir una fuga de memoria de la aplicación activa, una asignación súbita mayor que la capacidad del sistema, ni una aplicación que rechaza salir. No oculta el aviso de macOS. App Nap reduce actividad, pero no garantiza liberar RAM; detener un proceso con SIGSTOP tampoco libera sus asignaciones.

La estabilidad a través de uso real y ciclos de suspensión requiere observar los registros durante el período en que antes ocurrían los fallos. Una prueba de política o una medición verde aislada no demuestra que la causa original desapareció.

## Referencias

- [App Nap: qué regula y cuándo se activa](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/AppNap.html).
- [Memoria y swap en Monitor de Actividad](https://support.apple.com/en-euro/guide/activity-monitor/actmntr1004/mac).
- [Conversión del nivel de presión del kernel al valor de sysctl](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/kern_memorystatus_notify.c). Los valores públicos usados son 1 = normal, 2 = advertencia, 4 = crítico.

Licencia MIT. Este proyecto es independiente de Apple y OpenAI.

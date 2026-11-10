# Nexo

App macOS personal (menubar, `LSUIElement`) que unifica utilidades: window switcher (fork de AltTab), keep awake, window snapping, input source por app, monitor de sistema, simuladores, menubar hider, port manager, clipboard, quit protection y audio mixer.

Licencia GPL-3.0 (incorpora AltTab). Créditos en `NOTICE.md`. Solo uso personal, no se distribuye.

## Build y tests
- `Scripts/build.sh [Debug|Release] [--run]`: regenera `Nexo.xcodeproj` con XcodeGen y compila. El log completo queda en `build/last-build.log`.
- `Scripts/test.sh`: tests unitarios (target `NexoTests`, se agrega en el sub-plan 10/14).
- **No** se edita `Nexo.xcodeproj` (gitignored): todo va en `project.yml`.
- Login item (`SMAppService.mainApp`) registra la ruta del bundle actual: actívalo solo desde la copia instalada en `/Applications`, no desde `build/`.
- Firma: identidad estable "Nexo Local Signing" (`Scripts/make-signing-cert.sh`). No cambiar el bundle id ni la identidad, porque TCC perdería los permisos de Accessibility y Screen Recording.

## Arquitectura
- `Core/NexoModule.swift`: cada feature es un `NexoModule`. Su `init` debe ser barato; observers, taps y timers solo arrancan en `start()`.
- `Core/ModuleRegistry.swift`: guarda el estado enabled en `module.<id>.enabled` y lo aplica en runtime.
- `Core/PermissionCenter.swift`: único lugar para chequear y pedir permisos.
- `App/StatusItemController.swift`: un solo status item; el menú se reconstruye al abrir con `menuItems()` de cada módulo habilitado.
- `App/SettingsWindow.swift`: sidebar con General + una página por módulo (`settingsView()`).
- Módulos en `Modules/<Nombre>/`; se registran en `NexoApp.registerModules()`.

## Convenciones (adaptadas de AGENTS.md de AltTab)
- Swift puro, sin Interface Builder. `Modules/Switcher` es AppKit puro, sin SwiftUI. Los módulos nuevos pueden usar SwiftUI en `settingsView()` vía `NSHostingView`.
- Código compacto, `guard` para separar el happy path, sub-métodos en vez de bloques separados por líneas en blanco.
- Baja latencia: reusar objetos y usar APIs de observers; no hacer polling salvo que no exista alternativa (documentarlo).
- Toda llamada AppKit que cambia first responder, ordena o redimensiona ventanas puede ser IPC síncrono: se hace en main thread, con lo visible primero y el bookkeeping después.
- Comentarios solo para lo que el código no muestra: comportamiento de macOS o APIs privadas, invariantes y mediciones.
- Procesos externos (`xcrun`, `adb`, `lsof`): `Process` con argumentos en array, nunca strings interpolados en shell.
- Archivos scratch: prefijos `_debug.*`, `_probe.*` o `.scratch.*`; nunca se commitean.
- Commits: Conventional Commits, sin atribución a herramientas de IA.

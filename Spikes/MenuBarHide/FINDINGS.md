# Spike: ocultar íconos de la menubar en macOS 27

Fecha: 2026-11-10 · macOS 27.2 (26B123) · MacBook arm64.

## 1. Separador `NSStatusItem` que se expande (técnica Hidden Bar / Dozer / Ice ≤ 26)

Probe: `separator_probe.swift`. Crea un separador y, a su izquierda, un ítem "P". Luego cambia la
longitud del separador de 20 a 10 000.

| Estado | probe.x | separador.x | ancho separador |
|---|---|---|---|
| antes | 1430 | 1468 | 36 |
| expandido | 1466 | 1468 | **5016** (recortado por el sistema) |
| colapsado | 1430 | 1468 | 36 |

Lo que muestra la captura de la franja de la menubar: el separador desaparece al expandirse y "P"
se corre ~36 px a la derecha, pero **sigue visible**. Los ítems de la izquierda no se empujan
fuera de pantalla.

**Conclusión:** la técnica clásica **no oculta nada en macOS 27**.

## 2. Orden con ⌘+arrastre

No se puede automatizar sin interacción del usuario. Según el PR #995 de Ice (mediciones sobre
27.0), `MenuBarAgent` **reordena los ítems por su cuenta**, así que el orden en la barra ya no es
una señal fiable ni persiste de forma estable.

## 3. Cómo lo resuelven Ice PR #995 y Thaw

Fuente: `jordanbaird/Ice#995` ("Restore hiding, the Ice Bar and the layout editor on macOS 27"),
sin mergear.

- Los ítems ya no son ventanas: `CGWindowList` no los ve. Se leen por **Accessibility** desde
  `MenuBarAgent`.
- Ocultar solo es posible con la aserción privada de **assessment mode** (`MenuBarClientCore`:
  `MBAssessmentModeConfiguration`, `MBAssessmentModeAssertion`), una allowlist por proceso.
- **Efecto colateral:** con la aserción activa, `MenuBarAgent` ignora los clics en sus propios
  ítems (reloj, batería, Wi-Fi) y atajos como Globe+N. Ice retiene el clic, levanta la aserción y
  reproduce el clic (`HIDEventManager`, `ItemClick27`).
- Accessibility sigue reportando los ítems ocultos en su último frame, así que el estado se lleva
  por proceso.
- Son unos 30 archivos nuevos (`MacOS27/*`), y depende de frameworks privados que pueden cambiar en
  cualquier 27.x.

Thaw (fork mantenido) sigue el mismo camino.

## 4. Alternativa nativa

macOS 26+ trae en Configuración del Sistema › Barra de menús la lista **"Permitir en la barra de
menús"** por app (vorssaint lo detecta en `MenuBarAllowanceSupport.swift`). Oculta íconos de
terceros de forma soportada, aunque sin "mostrar al hacer clic".

## Decisión para 12/14

**No** reimplementar el assessment mode. Su costo y su fragilidad son altos, y rompe los clics en
los ítems del sistema. El módulo **Menu Bar** de Nexo hará esto:

1. Controlar la visibilidad de los ítems propios de Nexo (monitor, etc.) desde un solo lugar.
2. Abrir directo la sección nativa "Permitir en la barra de menús" para ocultar íconos de terceros.
3. Mostrar el estado (macOS 27 detectado → explicar por qué no hay ocultado tipo Ice).

Si más adelante se quiere el comportamiento completo, la opción es usar Thaw o un build de Ice con
el PR #995 junto a Nexo, no integrarlo.

**Riesgo:** bajo para la opción nativa. El assessment mode queda descartado por inestable entre
versiones.

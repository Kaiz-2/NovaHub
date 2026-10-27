# Nova Hub · Blue Lock Farm

Hub para el juego de Roblox **Blue Lock Farm**. Reconstrucción limpia y legible
sobre **Rayfield Gen2** (la misma librería de UI que usa Aster), llamando a los
remotes reales del juego.

## Cargar

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/Kaiz-2/NovaHub/main/NovaHub.lua"))()
```

> Nota: el repo debe ser **público** para que `HttpGet` pueda bajar el raw sin token.

## Arquitectura

- La UI solo cambia `State.<flag>`.
- Bucles de fondo (`Engine`) leen esos flags y ejecutan la acción con su delay.
- Cada bucle escribe un `.status` que la píldora del toggle muestra.

## Pestañas

Overview · Farm · Economy · Units · Adventure (Halloween) · Webhook · Player · Settings

## Independencia de Aster ✓

Nova ya **no depende de Aster**. Carga su propia copia de **Rayfield Gen2 1.2.0**
(`Rayfield.lua`, el `bundled.luau` oficial de Sirius vendorizado aquí) y le aplica
el tema **"Aster"** (`aster_theme.lua`, extraído en vivo) para conservar el aspecto.

El stock usa `camelCase` pero acepta `PascalCase`, así que el resto de Nova
funciona igual; un adaptador fino en `NovaHub.lua` emula lo que la build de Aster
tenía de más (Groupbox, Status, ButtonRow, Theme/Config Manager y varios `Window:*`).

- `Rayfield.lua` — librería de UI vendorizada (Rayfield Gen2 v1.2.0, MPL-2.0).
- `aster_theme.lua` — paleta "Aster" de referencia (13 colores).

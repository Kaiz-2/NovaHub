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

## Dependencia de UI (en migración)

Actualmente Nova recupera la tabla de Rayfield Gen2 de la memoria del cliente
(`getgc`), por lo que **Aster tiene que estar abierto**. El objetivo de este repo
es eliminar esa dependencia cargando la librería de forma autónoma.

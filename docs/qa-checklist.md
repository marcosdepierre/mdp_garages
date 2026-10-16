# mdp_garages — Checklist de QA (producción)

Cada entrega se revisa contra esta lista. Los fallos se reportan a Senior Developer con: **severidad** (Crítica / Alta / Media / Baja), **archivo:línea**, **pasos para reproducir** y **arreglo sugerido**.

## 1. Rendimiento
- [ ] Resmon < 0.02 ms en reposo (cliente), medido con `resmon 1` lejos de cualquier garaje y sin menús abiertos.
- [ ] Resmon razonable cerca de un garaje (< 0.10 ms) y sin picos sostenidos.
- [ ] Ningún `Wait(0)` salvo cuando se dibuja/escucha input cada frame, y solo mientras el jugador está en rango.
- [ ] Loops de proximidad con sleep dinámico (p. ej. 1000–1500 ms lejos, 0 solo dentro del radio de interacción).
- [ ] Preferir ox_lib points/zones o target sobre loops de distancia propios.
- [ ] Sin consultas SQL dentro de loops ni por frame; consultas preparadas y con índices (`owner`, `plate`, `garage`).
- [ ] Sin `TriggerServerEvent`/callbacks en bucle; sin spam de eventos de red.

## 2. Vehículos: duplicados y sincronización
- [ ] Al sacar un vehículo, el estado pasa a "fuera" en BD **antes** o de forma atómica con el spawn (sin doble spawn por doble clic o lag).
- [ ] Bloqueo por matrícula en servidor: no se puede sacar un vehículo que ya está fuera.
- [ ] Spawn en servidor (`CreateVehicleServerSetter`) o, si es en cliente, red ID validado y `SetEntityAsMissionEntity`.
- [ ] Propiedades (mods, daño, fuel, matrícula) aplicadas y sincronizadas a todos los clientes.
- [ ] Al guardar se valida que el vehículo pertenece al jugador y existe; se borra la entidad y se actualiza la BD.
- [ ] Punto de spawn ocupado → se bloquea o se usa otro punto, nunca se apila.
- [ ] Sin entidades huérfanas tras guardar, morir o desconectar.

## 3. Reconexión y reinicio
- [ ] Al desconectar con el coche fuera: comportamiento definido en config (se queda, va a incautado o vuelve al garaje).
- [ ] Al reiniciar el recurso o el servidor: vehículos con estado "fuera" se normalizan (no quedan bloqueados para siempre).
- [ ] `onResourceStop` limpia blips, zonas, entidades y NUI.
- [ ] Al reconectar, el jugador puede recuperar su vehículo sin duplicarlo.
- [ ] Carga correcta si el jugador entra antes de que el framework esté listo (esperar player loaded).

## 4. Compatibilidad con frameworks (ESX, QBCore, Qbox)
- [ ] Detección automática del framework en `bridge/init.lua`, con override en config.
- [ ] Ningún código fuera de `bridge/` llama directamente a ESX/QBCore/Qbox.
- [ ] Las funciones del bridge tienen la misma firma y devuelven los mismos tipos en los tres.
- [ ] Esquema de BD correcto para cada uno (`owned_vehicles` vs `player_vehicles`, columnas `owner`/`citizenid`, `stored`/`state`).
- [ ] Dinero, trabajos (garajes de trabajo) y llaves funcionan en los tres.
- [ ] Probado arrancando con cada framework por separado sin errores en consola.

## 5. Seguridad básica (coordinar con Security Engineer)
- [ ] Todo evento de servidor valida jugador, propiedad, distancia al garaje y cooldown.
- [ ] Nunca se confía en matrícula, precio ni coordenadas enviadas por el cliente.
- [ ] Sin eventos que den dinero o vehículos sin comprobación.

## 6. Locales
- [ ] Todas las cadenas visibles (Lua y NUI) pasan por el sistema de locales; ningún texto hardcodeado.
- [ ] `en.lua` y `es.lua` tienen exactamente las mismas claves.
- [ ] Clave faltante → fallback a inglés y aviso en consola, nunca `nil` ni crash.

## 7. Código y config
- [ ] Variables locales; sin globals accidentales.
- [ ] Nombres claros y consistentes, prefijo `mdp_garages:` en eventos.
- [ ] Sin código muerto, prints de debug solo tras `Config.Debug`.
- [ ] `config.lua` comentado: cada opción con descripción, valores posibles y valor por defecto.
- [ ] `fxmanifest.lua` correcto (`lua54`, dependencias, archivos, `ui_page`).
- [ ] SQL de instalación incluido en `sql/` e idempotente.
- [ ] README con instalación, dependencias y configuración por framework.

## 8. Edge cases a probar
- [ ] Doble clic / spam en "sacar" y "guardar".
- [ ] Guardar un coche ajeno o robado.
- [ ] Jugador sin vehículos / garaje vacío.
- [ ] Inventario/dinero insuficiente para incautado.
- [ ] Matrículas con espacios o minúsculas (normalizar con trim/upper).
- [ ] Vehículo destruido o en el agua al guardar o desconectar.
- [ ] Varios jugadores en el mismo garaje a la vez.

## 9. UI (NUI)
- [ ] Toda la UI usa componentes de Untitled UI React (React + Tailwind + Vite), compilada en `web/dist`. Un componente hecho a mano o de otra librería cuenta como fallo.
- [ ] `web/dist` compilado y presente; `ui_page` apunta a él.
- [ ] Ningún `innerHTML` con datos sin escapar.

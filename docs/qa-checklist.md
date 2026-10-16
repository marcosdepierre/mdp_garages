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

---

# Fase 1 — Casos de prueba (base 1d13e0e)

Alcance: streamer por proximidad, guardar/aplicar props, llaves, fuel y salud al sacar, trigger de guardado en cliente, backlog de fase 1.
Bloquean solo Críticas y Altas; Medias y Bajas van a `docs/backlog-phase1.md`.

## F1-A. Streamer por proximidad (rendimiento)
- [ ] Resmon cliente < 0.02 ms en reposo con 50+ coches aparcados en el mapa y el jugador lejos.
- [ ] Spawn/despawn por radio con histéresis (radio de entrada < radio de salida) para evitar parpadeo en el borde.
- [ ] El servidor decide quién es el dueño de red del spawn; dos jugadores entrando a la vez en el radio no generan dos entidades.
- [ ] Sin `Wait(0)` en el streamer; ticks dinámicos según distancia.
- [ ] El despawn por distancia guarda posición, props, fuel y salud antes de borrar.
- [ ] Coche ocupado nunca se despawnea por distancia.
- [ ] Coche movido (remolcado, empujado) actualiza su posición guardada.

## F1-B. Duplicados
- [ ] Spam de "sacar" (doble clic, macro, dos clientes del mismo jugador) → una sola entidad.
- [ ] Dos jugadores con llave sacan/entran el mismo coche a la vez → una sola entidad.
- [ ] Streamer + takeOut simultáneos del mismo coche aparcado (estado 2) → una sola entidad.
- [ ] Guardar mientras el streamer lo despawnea → estado final coherente, sin entidad huérfana.
- [ ] Matrícula duplicada en el mundo (R6-1) → no pasa a GARAGED si quedan entidades vivas.
- [ ] Clon por otro script (misma matrícula y modelo) → no se puede guardar dos veces.

## F1-C. Reinicio del recurso y del servidor
- [ ] `restart mdp_garages` con coches aparcados (2), fuera (1→OUT) y en uso → ningún duplicado, ningún coche perdido, ocupados intactos.
- [ ] Reinicio completo del servidor → los aparcados reaparecen en su sitio con props, fuel y salud.
- [ ] Reinicio a mitad de un takeOut o store → se resuelve al arrancar (recovery), sin locks colgados.
- [ ] `onResourceStop` guarda estado de todas las entidades trackeadas y limpia blips, zonas y NUI.
- [ ] `MDP.Ready`: las peticiones antes de terminar la recuperación devuelven `not_ready`, no fallan.

## F1-D. Desconexión y reconexión
- [ ] Desconexión con el coche fuera, para cada valor de `Config.OnDisconnect` (keep, park, garage, impound) → comportamiento documentado; ocupado por otro nunca se borra.
- [ ] Crash del cliente (sin `playerDropped` limpio) → mismo resultado que una desconexión normal.
- [ ] Reconexión → el jugador recupera su coche (claimSpawns) sin duplicar, con llaves.
- [ ] Desconexión a mitad de takeOut → coche recuperable al reconectar.
- [ ] Jugador que entra antes de que el framework esté listo → espera a player loaded.

## F1-E. Props, llaves, fuel y salud
- [ ] Props guardadas = props aplicadas (mods, colores, neones, extras, livery, ruedas, tinte, matrícula y su estilo).
- [ ] Props aplicadas también para otros clientes (statebag o sync servidor), no solo para quien saca.
- [ ] Fuel restaurado con cada adaptador (ox_fuel statebag, LegacyFuel, cdn-fuel, nativo); valor fijado a 0–100.
- [ ] Salud de motor, carrocería y depósito restaurada; puertas, ventanas y ruedas si están en el alcance.
- [ ] Llaves dadas al sacar con qbx_vehiclekeys, qb-vehiclekeys y el adaptador común; revocadas al guardar o cambiar de dueño.
- [ ] Llaves compartidas persisten tras reinicio y se borran al restaurar (R5-4).

## F1-F. Props corruptas o maliciosas
- [ ] Props `NULL`, JSON vacío, JSON truncado o inválido en BD → el coche sale con props por defecto y se avisa en el log, sin error de Lua.
- [ ] Tipos incorrectos (string en vez de número, NaN, inf, negativos, índices de mod fuera de rango) → se ignoran o se fijan a valores válidos.
- [ ] Props enormes (>64 KB) o con claves extra → rechazadas o recortadas; tamaño máximo definido.
- [ ] Modelo de props distinto del modelo del vehículo → no se aplican.
- [ ] El cliente nunca puede escribir props de un coche que no es suyo ni fuera del flujo store; validación en servidor (propiedad, distancia, rate limit).
- [ ] Formato de props de ESX, QB y Qbox (ox_lib) importado correctamente, incluidas diferencias de nombres de campo.

## F1-G. Trigger de guardado en el cliente
- [ ] Solo se activa dentro de la zona de guardado, como conductor y solo.
- [ ] Debounce/cooldown: mantener o spamear la tecla no envía más de un `storeVehicle`.
- [ ] Respuesta de error (`occupied`, `not_owner`, `too_far`...) se muestra traducida.
- [ ] Sin bucle activo fuera de las zonas (ox_lib points/zones).

## F1-H. Matriz de frameworks
Cada caso de F1-B a F1-G se ejecuta en las tres variantes:
| Caso | qbx (Qbox + ox_lib) | qb (QBCore) | esx (ESX Legacy) |
|---|---|---|---|
| Tabla | `player_vehicles` (citizenid/state) | `player_vehicles` (citizenid/state) | `owned_vehicles` (owner/stored) |
| Props | `mods` JSON ox_lib | `mods` JSON QB | `vehicle` JSON ESX |
| Llaves | qbx_vehiclekeys (entidad) | qb-vehiclekeys (matrícula) | adaptador común |
| Fuel | ox_fuel | LegacyFuel / cdn-fuel | ox_fuel / LegacyFuel |
- [ ] Arranque limpio sin errores en consola en cada uno.
- [ ] Coche comprado en el concesionario del framework → aparece, sale, se guarda y se sincroniza.
- [ ] Venta o transferencia en el framework → cambia de dueño o pasa a REMOVED sin perder multas.

## F1-I. Backlog de fase 0 a verificar
- [ ] R6-1, R6-2, NUI-R4-1 a R4-4 y NUI-R5-1/R5-2 de `docs/backlog-phase1.md` cerrados o reclasificados.
- [ ] N11: transparencia de la NUI comprobada en el cliente FiveM real.

## F1-J. Solo vehículos propios (saltárselo = High)
La propiedad se valida SIEMPRE en el servidor, contra la BD (`owned_vehicles.owner` / `player_vehicles.citizenid`) y el identificador del jugador que hace la petición, nunca con datos que mande el cliente.
- [ ] Coche de NPC robado (sin fila en la BD): se rechaza al guardar y al aparcar.
- [ ] Coche de otro jugador (la fila existe con otro owner/citizenid): se rechaza aunque el jugador lo conduzca.
- [ ] Llave temporal o compartida (qbx_vehiclekeys, qb-vehiclekeys, llaves dadas o prestadas): tener llave NO cuenta como ser dueño; se rechaza.
- [ ] Matrícula falsificada: el cliente manda la matrícula de un coche propio pero está en otra entidad; el servidor valida la entidad (marca HMAC o netId) y que la matrícula real coincida.
- [ ] Props o modelo del cliente que no cuadran con la fila de la BD: se rechaza o se sanea, nunca se sobrescribe el modelo.
- [ ] Coche que ya no es del jugador (vendido o transferido mientras está fuera): se rechaza.
- [ ] Estados: no se puede guardar un coche incautado (3), retirado (4) o REMOVED (5) usando este camino.
- [ ] Todas las entradas pasan por la misma comprobación: zona del garaje, comando `/mdp_park`, NUI, exports y eventos de red llamados a mano (p. ej. con un executor de Lua).
- [ ] El rechazo tiene un código de error propio y la NUI muestra su mensaje (no un timeout genérico).
- [ ] Los mismos casos se prueban en ESX, QBCore y Qbox.

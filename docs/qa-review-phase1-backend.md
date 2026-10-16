# QA fase 1: backend (streamer, props, takeOut/store, parkWorld, Security H1–L4, c17d56c)

- Fecha: 16/10/2026, 22:45 (UTC+1). Base `1d13e0e` → HEAD `ac77923`.
  - Backend: `6c378e3`, `00fe000`, `e75117f`, `c5a8644`, `f77d546` y `c17d56c`.
  - Integraciones: `4bf7b64`, `ac77923`.
- No modifiqué código. El árbol tenía cambios sin commitear ajenos (`client/main.lua`, `client/props.lua`, `client/zones.lua` y otros): **revisé solo lo commiteado**.
- `luac -p`: **OK en todos los .lua**. Paridad de locales: **89/89** (en/es).
- Tests mock de `Security.SanitizeProps`: `/tmp/qa/p1/test.lua` (stubs de natives + JSON que rechaza NaN/inf). **35/35 PASS**. Casos cubiertos:
  - Entradas inválidas: nil, string (JSON inválido), tabla vacía (sin model).
  - Modelo: por nombre, hash con signo, float, erróneo, NaN, inf, modelo de la entidad distinto, entidad inexistente.
  - Matrícula falsificada: se reescribe con la del servidor.
  - Valores fuera de rango: NaN/inf en salud (se descartan), negativos y fuel 9999 (se fijan al rango), mod como string, fuera de rango o decimal (se descartan), -1 (válido).
  - Tablas: extras con índice 99 (se descarta), extras con claves string (ESX), neon 1-based (ESX), rgb válido y fuera de rango.
  - Claves desconocidas, profundidad mayor de 3 (rechazo), valores función.
  - **200k claves en 75 ms** (Lua 5.4 local).
  - Mileage: hacia atrás, NaN, 1e12 (se conserva el de BD).
  - Campos de daño de ESX/QB (`windowsBroken`/`doorsBroken`/`tyreBurst`): se descartan.

## Bloqueantes (Crítica/Alta)
**Ninguno.**

## Verificación por área (checklist F1)

| Área | Resultado |
|---|---|
| F1-A streamer | Histéresis 150/200 ✓, máximo 5 spawns por tick ✓, backoff exponencial de 2 s hasta 120 s ✓, sin `Wait(0)` (tick 1500 ms) ✓, spawn y despawn dentro de `WithLock` releyendo `state=2` ✓, nunca despawnea un coche ocupado ✓, guarda la posición si se movió más de 0,5 m ✓. Coste: registro (≤150) × jugadores por tick, unas 20k restas de vec3 con 128 jugadores, aceptable. SQL completo de refresco cada 30 s, no dentro de bucles. Ver M-3 (escaneo del mundo en cada spawn). **El resmon real no se puede medir aquí.** |
| F1-B duplicados | takeOut, streamer y store serializados por el lock. takeOut borra la entidad antigua solo tras un UPDATE condicional (M1) y hace rollback exacto (M2). El streamer no spawnea si hay una entidad trackeada. La adopción exige una única coincidencia. Ver M-1. |
| F1-C reinicio | R6-1 corregido en `persistence.lua` (duplicados → se queda en OUT). **Sigue PARCIAL en `server/vehicles.lua` (import/sync)**: ver L-1. |
| F1-E props/llaves/fuel | Props desde BD → `RequestApply` al dueño de red, con ack, reintento y migración de dueño. El dueño aplica `setVehicleProperties` y la red replica las props al resto ✓. Fuel: ox_fuel por statebag; el resto en el cliente, limitado a 0–100 y como máximo BD+2 ✓. Salud limitada (M4) ✓. Llaves con `GiveKeys` tras el spawn ✓ y `OnStore` con `RemoveKeysOnStore` ✓. |
| F1-F props corruptas | `Decode`: NULL, vacío, JSON inválido y más de 16 KB → nil sin error de Lua ✓. Props del cliente: whitelist ✓, máximo 16 KB ✓, modelo comprobado contra la BD y la entidad ✓. Con un modelo distinto en BD, el cliente devuelve NACK determinista (`ac77923`) ✓. |
| F1-G store | Hay que ser conductor y estar solo, dentro de la distancia y con rate limit de 1/s ✓. El debounce del cliente está en archivos sin commitear: no evaluado. |
| F1-H matriz | Los nombres de campo de ESX/QB/ox_lib son compatibles con la whitelist salvo los campos de daño (L-3). **La ejecución real qbx/qb/esx queda pendiente**. |
| Security H1–M6, L1, L2, L4 | H1 (spawn en pcall), H2 (sanitize dentro del lock con entidad), M1/M2, M3 (comprobaciones dentro del lock), M4 (clamp de salud), L2 (blobs grandes ignorados) y L4 (coords finitas dentro del mapa): **verificados**. |
| R6-2 | **FIXED**: `pcall` + log al borrar llaves en AddVehicle. |

### c17d56c
- **Snapshot de props antes del despawn:**
  - Se pide solo al **dueño de red**. Token aleatorio de un solo uso con TTL de 5 s, ligado a `veh` y `plate`.
  - Si responde otro jugador → `LogReject`. Un replay se ignora porque el token se borra al usarse.
  - Timeout de 2 s → conserva las últimas props guardadas ✓.
  - Si el dueño se ha desconectado (`owner <= 0`) se despawnea sin snapshot ✓.
  - El snapshot se sanea y solo se guarda con `state=2`.
  - Durante la espera la entidad sigue trackeada, así que el streamer no la re-spawnea (sin duplicado) ✓. Fallos: M-1 y M-2.
- **Tope de km por tiempo:**
  - Cálculo: `min(elapsed·400/3600 + 0,5; 50)` ✓.
  - NaN, menor que el de BD o nil → valor de BD ✓.
  - Reloj hacia atrás → `max(0, …)` ✓.
  - Problema: la marca de tiempo es solo de memoria (L-2).
- **Coches aparcados con las puertas cerradas:** está documentado (architecture.md:375), pero no siempre es coherente con las llaves (M-4).

## Hallazgos (Media/Baja → `docs/backlog-phase1.md`)

| # | Sev. | Archivo:línea | Descripción y reproducción | Arreglo |
|---|---|---|---|---|
| P1-M1 | Media | server/streamer.lua `despawnParked` | No comprueba de nuevo `state=2` ni la distancia dentro del lock, salvo en la rama con snapshot. Reproducción: el coche aparcado entra en despawn (espera de 2 s); en ese intervalo un jugador vuelve, sube (`becameDriven` → OUT) y se baja. Al vencer el timeout se borra la entidad con la fila en OUT: el coche desaparece y `takeOut` responde `already_out` hasta el siguiente reinicio. Si el jugador solo vuelve cerca, el coche parpadea (despawn + respawn). | Dentro del lock: `SELECT … state=2` (si no, return) y recalcular `nearest > despawnR` antes de borrar. |
| P1-M2 | Media | server/streamer.lua (evento `propsSnapshot`) | El dueño de red puede ser **cualquier** jugador cercano, no el propietario. Un cliente modificado puede responder con props válidas por whitelist pero falsas (todos los mods a -1, otro color) y **reescribir de forma persistente el tuning de coches ajenos**. | Aceptar el snapshot solo para los campos de daño/suciedad o solo si el que responde es el propietario o tiene llave. Si no, conservar `mod*`/colores de la BD (merge). |
| P1-M3 | Media (rendimiento) | server/streamer.lua:80 | Cada `spawnParked` llama a `Utils.WorldVehiclesByPlate()`, que recorre `GetAllVehicles()` + `GetVehicleNumberPlateText`: hasta 5 recorridos completos por tick. Con más de 1000 vehículos de tráfico se notará en el hilo del servidor. | Un solo mapa por tick que se pasa a los spawns, o adoptar solo si `mdp_plate` coincide. |
| P1-M4 | Media | server/streamer.lua:94, garages.lua parkWorld; docs/architecture.md:375 | Los coches aparcados quedan con las puertas cerradas (2). Con qb-vehiclekeys (llaves en memoria), después de un reinicio o una reconexión el propietario ya no tiene llave y no puede abrir su coche; con el adaptador común de ESX sin sistema de llaves, nadie puede. Solo queda la vía "traer al garaje" (takeOut desde el estado 2). | Al hacer spawn desde el streamer, `GiveKeys` al propietario si está conectado, o no cerrar cuando el adaptador de llaves no exista. |
| P1-L1 | Baja | server/vehicles.lua:~107 | R6-1 sigue parcial: en import/sync, un OUT con duplicados en el mundo (`UniqueWorldVehicle` → nil) pasa a GARAGED. | Usar `matches > 0` → mantener OUT. |
| P1-L2 | Baja | server/props.lua `mileageStamp` | La marca de tiempo es solo de memoria. Tras un `restart`, los coches OUT adoptados no tienen marca → límite de 0,5 km al primer store: se pierden km reales. | Marcar al adoptar en `onStart` (o persistir `mileage_at`). |
| P1-L3 | Baja | server/security.lua PROP_RULES | Se descartan `windowsBroken`, `doorsBroken` y `tyreBurst` (nombres de ESX/QB), y `modKit`/`modLivery` de algunos forks: el daño visual no persiste en qb/esx. | Mapear alias → `windows`/`doors`/`tyres`. |
| P1-L4 | Baja | server/garages.lua parkWorld:308-316 | Los contadores `MaxWorldParked*` se leen fuera del lock: dos `/mdp_park` simultáneos del mismo dueño pueden superar el límite en 1. | Volver a contar dentro del lock o usar un INSERT/UPDATE condicional. |
| P1-L5 | Baja | server/props.lua `doSpawn` | Las props de BD importadas del framework no se sanean en el servidor antes de replicarlas. Las mitiga el NACK del cliente (`ac77923`). | `SanitizeProps` en import/migrate. |

## Veredicto
**Fase 1 backend: SIN BLOQUEANTES (0 Crítica/Alta). Se puede cerrar**, con cuatro Medias y cinco Bajas en el backlog. Antes de producción recomiendo corregir **P1-M1** (pérdida temporal de un coche) y **P1-M2** (manipulación del tuning de coches ajenos). Siguen pendientes las pruebas en FiveM real: resmon de F1-A, matriz qbx/qb/esx de F1-H y transparencia de la NUI (N11).

---

# R2: delta `ede4002` (Security) + `ca4a415` + `078ac23` (Backend)

- Fecha: 16/10/2026, 22:50 (UTC+1). HEAD `078ac23`.
- `luac -p`: **OK en todos los .lua**. Paridad de locales: **89/89**. `/tmp/qa/p1/test.lua` repetido sobre HEAD: **35/35 PASS**.
- `client/main.lua` y `client/zones.lua` siguen **sin commitear** → **F1-G (debounce del trigger de guardado) no evaluado**. `client/props.lua` está commiteado sin cambios desde `c17d56c`.

## Afirmaciones

| Afirmación | Estado | Evidencia |
|---|---|---|
| Adopción de entidades más estricta (N1) | **FIXED** | `adoptable()` exige que el coche esté vacío, a ≤ `ParkedMoveTolerance` de las coords de la BD, y además un `mdp_plate` igual o haber sido creado por el servidor (`NetworkGetFirstEntityOwner` ≤ 0, en pcall). Si no, se aplica backoff. |
| Snapshot de un no propietario: solo campos permitidos (N2) → **P1-M2** | **FIXED** (residual → P1R2-L1) | `snap.partial = not IsOwner(src, plate, true)`: se hace merge sobre las props de la BD solo con `Security.PropSnapshotFields` = `bodyHealth, engineHealth, tankHealth, dirtLevel, fuelLevel, oilLevel, windows, doors, tyres`. **Los campos estéticos (mods, colores, neón, livery, extras, tinte, ruedas) ya no se pueden escribir.** Después pasa por `SanitizeProps`. En el spawn, `engine`/`body`/`fuel` de las columnas pisan los de las props, así que un extraño solo puede persistir de verdad `windows/doors/tyres/dirt/tankHealth`, el equivalente a dañar el coche en el juego. |
| Solo el propietario o quien tiene llave saca un aparcado (N4) | **FIXED** | `becameDriven`: si el conductor no es `IsOwner(..., true)`, el estado sigue en 2 (log limitado a uno por minuto) y no hay ClaimSpawn. El takeOut del dueño mientras otro lo conduce da `in_use`. |
| Nada se guarda sin `SanitizeProps` (N8) | **FIXED** | `MDP.Props.Sanitize` ya no tiene la vía permisiva (`sanitizer_missing`). `AddVehicle` también sanea (ver P1R2-L2). |
| `ClampHealth` (-4000..1000) en todas partes | **FIXED** | `MDP.Props.Health` → `Security.ClampHealth` siempre: store, parkWorld, despawn, desconexión (`healthOf`), arranque en modo `garage` e import del framework (`vehicles.lua:76`, `078ac23`). |
| Limpieza de tablas (N7) sin borrar entradas vivas | **OK** | `prune` solo en Forget, en filas que ya no están en estado 2 y tras becameDriven. La limpieza de `Refresh` afecta solo a `backoff` y `driveDenied` de matrículas que ya no están aparcadas. `snaps` se libera al terminar o cuando el dueño se desconecta. `mileageStamp` se purga a las 24 h, con respaldo en `mileage_ts` de la BD, y el spawn vuelve a marcar. Ninguna entrada viva se pierde. |
| Token impredecible (N6), handle no perdido en un spawn fallido (N3) | **FIXED** | Token string de 3 randoms mezclados con timers y un contador; spawn fallido → `DeleteEntity(holder.veh)`. |

## Estado del backlog P1

| # | Estado | Nota |
|---|---|---|
| P1-M1 | **FIXED** (residual Baja) | `despawnParked` relee `state=2` dentro del lock y comprueba vacío y entidad trackeada: ya no se borran coches en OUT. Queda que no recalcula la distancia → parpadeo si un jugador vuelve en los 2 s (P1R2-L3). |
| P1-M2 | **FIXED** | Ver arriba. |
| P1-M3 | **NOT FIXED** | `streamer.lua:100` sigue llamando a `WorldVehiclesByPlate()` en cada spawn. |
| P1-M4 | **NOT FIXED / aceptado** | Los aparcados siguen cerrados; está documentado y lo aceptó Senior. Sigue el problema con qb-vehiclekeys tras un reinicio y con ESX sin llaves. |
| P1-L1 | **FIXED** | `vehicles.lua:109-111`: GARAGED solo si `matches == 0`. |
| P1-L2 | **FIXED** | `ElapsedSec(plate, mileage_ts)` usa `UNIX_TIMESTAMP(COALESCE(parked_at, updated_at))` como respaldo. |
| P1-L3 | **NOT FIXED** | `windowsBroken/doorsBroken/tyreBurst` siguen descartándose (test). |
| P1-L4 | **NOT FIXED** | Contadores de `parkWorld` fuera del lock (garages.lua:310-316). |
| P1-L5 | **PARCIAL** | Se limita la salud importada, pero las props importadas del framework siguen sin sanear en el servidor (las mitiga el NACK del cliente). |

## Hallazgos nuevos (Bajas → backlog)
- **P1R2-L1:** un extraño que es dueño de red aún puede persistir `windows/doors/tyres/dirt` (rotos o reventados) en un coche ajeno.
- **P1R2-L2:** en `AddVehicle`, `json.encode(props)` y `SanitizeProps` van sin pcall: props con NaN o inf hacen fallar el export en lugar de devolver `invalid_props`.
- **P1R2-L3:** parpadeo al volver durante el snapshot (residuo de P1-M1).
- **P1R2-L4:** en un snapshot parcial, si la fila no tiene props (NULL), la base `{}` no tiene `model` → `SanitizeProps` lo rechaza y se pierde el desgaste del snapshot (solo log).

No hay regresiones: los callers de `ResolveMileage` y `Sanitize` reciben `mileage_ts`, la columna `updated_at` existe en `install.sql` y el cálculo del km cap delega en `Security.ClampMileage`, que gestiona NaN/inf y el reloj hacia atrás.

## Veredicto R2
**0 Crítica/Alta → el backend de la fase 1 sigue SIN BLOQUEANTES y se puede cerrar.**
- P1-M1 y P1-M2 quedan resueltos.
- Abiertas: Medias P1-M3 y P1-M4; Bajas P1-L3, P1-L4, P1-L5 (parcial) y P1R2-L1 a P1R2-L4.
- Pendiente: F1-G hasta que se commiteen `client/main.lua` y `client/zones.lua`, y las pruebas en FiveM real.

---

# R3: delta `99275a7` (Security) + `a8fda43` + `fecc05a` (Backend) — HEAD `fecc05a`

- Fecha: 16/10/2026, 22:55 (UTC+1). El HEAD incluye también los commits de NUI y locales (`f6f2495`…`ac529e3`).
- `luac -p`: **OK en todos los .lua**. Paridad de locales: **95/95**. `/tmp/qa/p1/test.lua`: **35/35 PASS**.
- `client/main.lua` y `client/zones.lua` ya están commiteados → **F1-G evaluado**: OK (ver tabla).

## Afirmaciones

| Afirmación | Estado | Evidencia |
|---|---|---|
| `MarkServerEntity` en todo spawn del servidor | **FIXED** | Una sola ruta: `MDP.Props.SpawnVehicle` (props.lua:114), que usan takeOut y el streamer. parkWorld no crea entidades: el coche ya viene marcado desde el takeOut. Si viene de un concesionario solo se trackea (correcto: no se marca lo que no es nuestro). |
| La marca sobrevive a un restart del recurso | **FIXED** | En memoria (`serverEnts`) + state bag `mdp_srv` **no replicada** = `joaat(secret..':'..plate)`. La state bag vive con la entidad, no con el recurso. El secreto viene de un convar o del KVP del recurso, persistente; un cliente no puede calcularlo. Documentado en el README (`server.cfg`, `sv_stateBagStrictMode`). |
| `CanAdopt` en el streamer y en la adopción al arrancar | **FIXED** | Comprueba entidad del servidor + modelo (u32) + vacía + a ≤ tolerancia de las coords de la BD. Un OUT propio se adopta aunque esté ocupado o movido. Lo rechazado y vacío → se borra; lo rechazado y ocupado → se ignora. |
| ¿Algún coche vivo de jugador rechazado o adoptado por error? | **NO: Alta (P1R3-H1)** | Ver abajo. |
| Sin `math.randomseed` | **FIXED** | Se usa la semilla aleatoria por defecto de Lua 5.4; el secreto se genera al cargar. |
| `model` antes de sanear (N2b) | **FIXED** | `mergeSnapshot`: `base.model = ModelHash(row.model)` → **P1R2-L4 cerrado**. |
| server.cfg y referencia de zones.lua en architecture.md | OK | |
| F1-G trigger de guardado | **OK** | `busy` + token por intento + timeout de seguridad de 15 s (xpcall): una sola petición a la vez, un resultado tardío no actúa, y el servidor limita a 1/s. Error → toast con código traducido. |
| takeOut cb (fecc05a) | OK | `UI.Close` en pcall; siempre se llama a cb. |

## Bloqueante

| # | Sev. | Archivo:línea | Descripción y reproducción | Arreglo |
|---|---|---|---|---|
| **P1R3-H1** | **Alta** (duplicado) | server/persistence.lua: bloque de adopción (≈l.20-29 + rama `elseif st == VS.OUT` ≈l.53-56 del bucle) | Un coche en OUT **sin marca de servidor** y **ocupado** (de un concesionario o de otro script aceptado por la vía R3-1, o **cualquier coche sacado antes de desplegar `a8fda43`**) cae en "not adoptable … occupied, ignored" → `ent = nil`. Como `matches == 1`, sigue a la rama "sin entidad" → **UPDATE a GARAGED con el coche vivo y conducido**. Reproducción: sacar un coche con la versión anterior (o crearlo con `AddVehicle(…'out')` desde un concesionario), conducirlo y hacer `restart mdp_garages` → abrir el garaje → aparece GARAGED → sacarlo da **dos coches**. Además, guardar el original falla con `invalid_state`. | En la rama "rechazado y ocupado" con `st == OUT`, mantener OUT (igual que con `matches > 1`). Por ejemplo, marcar `keepOut[plate] = true` y saltarse la conversión a GARAGED. Opcional: adoptarlo, trackearlo sin marca y marcarlo cuando el dueño lo guarde. |

## Hallazgos nuevos (Media/Baja → backlog)
- **P1R3-L1 (Baja):** un coche en OUT sin marca, **vacío**, se borra al arrancar y pasa a GARAGED con las props de la BD. Las props de un coche de concesionario quizá nunca se guardaron: se pierde el tuning hecho en la calle. Arreglo: snapshot o `Get` antes de borrarlo, o pasarlo a estado 2 en el sitio.
- **P1R3-L2 (Baja):** un cliente dueño de red puede escribir `mdp_srv` en su coche (si `sv_stateBagStrictMode` está desactivado) y romper su adopción. Solo afecta a su propio coche (DoS), no permite adoptar nada ajeno. Mitigado si se activa el modo estricto, que ya recomienda el README.

## Estado del backlog relacionado
- **P1-M3:** NOT FIXED (streamer.lua:90, `WorldVehiclesByPlate()` en cada spawn).
- **P1-M4 / P1I-M4:** NOT FIXED (streamer.lua:116, cierre de puertas sin `GiveKeys`).
- **P1I-M1, P1I-M2, P1I-M3:** no tocados (sin cambios en `bridge/` ni en `server/vehicles.lua`) → siguen abiertos.
- **P1R2-L4:** FIXED.

## Veredicto R3 (HEAD `fecc05a`)
**NO se puede cerrar: hay 1 Alta bloqueante (P1R3-H1, duplicado de un coche ocupado sin marca al reiniciar el recurso).** El arreglo son pocas líneas en `persistence.lua`. Corregido eso, el resto de la entrega R3 está bien (N1/N10 correctos, marca persistente con secreto, F1-G OK) y el backend quedaría sin bloqueantes.

---

# R4: verificación de `f7e1789` (+ `ec0c3b7`, `1e5104b`, `29d09a5`) — HEAD `29d09a5`

- Fecha: 16/10/2026, 23:00 (UTC+1).
- `luac -p`: **OK en todos los .lua**. Paridad de locales: **95/95**. `/tmp/qa/p1/test.lua`: **35/35 PASS**.

## P1R3-H1: **FIXED**
- persistence.lua: si la entidad coincide (matrícula + modelo) pero se rechaza y está ocupada → `keepOut[plate] = true` + log "row kept OUT". En el bucle, la rama `elseif st == OUT and keepOut[plate]` va **antes** de la conversión a GARAGED y no actualiza nada.
- El dueño puede guardarlo después: la fila sigue en OUT, la entidad no está trackeada y `storeVehicle` acepta coches no trackeados en OUT cuando coinciden dueño y modelo (R3-1) → **sin `invalid_state`**.
- La excepción "entidad propia en OUT ocupada o movida" ahora exige también `SameModel` y lo registra en el log (`ec0c3b7`).

## Barrido: ¿alguna rama pasa a GARAGED con una entidad ocupada que coincide?

| Rama | Resultado |
|---|---|
| Arranque, modo `garage` con adopción | Solo si `IsVehicleEmpty` ✓ |
| Arranque, entidad rechazada y ocupada | `keepOut` → se queda en OUT ✓ |
| Arranque, duplicados | Se queda en OUT ✓ |
| Arranque, sin entidad que coincida | GARAGED: correcto, no hay coche vivo |
| Desconexión `garage`/`impound` (`applyPolicy`) | Si está ocupado, ignorando al que se va → `keep`. `toGarage` vuelve a comprobar que esté vacío ✓ |
| Streamer | Nunca escribe GARAGED (solo 2 → 0 en `becameDriven`) ✓ |
| Sync/import (vehicles.lua:109-111) | GARAGED solo con `matches == 0` (cuenta también entidades ocupadas) ✓ |
| Restauración desde REMOVED | Un REMOVED nunca tiene una entidad ocupada (la retirada se aplaza mientras está ocupado) ✓ |
| storeVehicle | Exige conductor solo y el borrado de la entidad: es el flujo de guardar, correcto ✓ |
| takeOut (rollback) | Solo si el spawn falla, y la entidad nueva se borra (N3) ✓ |

**Ninguna rama manda a GARAGED un coche cuya entidad ocupada coincide.**

## `Utils.SameModel`
Tests en `/tmp/qa/sm.lua`:
- Coinciden: con signo y sin signo (`-1` vs `0xFFFFFFFF` → true), hash como string numérico (`"-1234"`) y float entero (`H+0.0`).
- `nil` en cualquiera de los dos lados → false ✓.
- Nombre de modelo como string (`'adder'`) → false: no se convierte. Todos los callers pasan `Utils.ModelHash(...)`, así que es correcto, pero conviene documentarlo.
- **Floats no enteros** (`1.5` vs `2.5`) → **true**: `math.tointeger` da nil → 0 en los dos lados. Baja (P1R4-L1). No se alcanza con natives reales.

## Release notes
README + `docs/release-notes.md` (instalación y migración de la fase 1, convar del secreto, `sv_stateBagStrictMode`) ✓.

## Regresiones
No encontré ninguna en el streamer, takeOut ni store. El único cambio de código fuera de persistence.lua es `SameModel` en `lockedVehicleChecks` y `UniqueWorldVehicle`, que admite más casos y no cambia el resto de la semántica.

## Veredicto R4 (HEAD `29d09a5`)
**0 Crítica/Alta → el backend de la fase 1 queda CERRADO (sin bloqueantes).** Sigue la deuda Media/Baja del backlog (P1-M3, P1-M4/P1I-M4, P1I-M1..M3, Bajas) y las pruebas en FiveM real.

---

# Propiedad (b17d813, f01f58d) + 53c2c56, 7de0844, 7ad284c

- Fecha: 16/10/2026, 23:10 (UTC+1). Revisado sobre árboles limpios (`git archive`) de `f01f58d`, `7de0844` y `7ad284c`. Los números de línea son de `7ad284c`, salvo que se indique otra cosa.
- El working tree tenía cambios sin commitear de otro agente mientras revisaba (`server/security.lua` con `CanStoreOwnVehicle`, que después entró en `8a4e3cf`). `8a4e3cf` **no** está revisado aquí: en `f01f58d`/`7de0844`/`7ad284c` no existe `Security.CanStoreOwnVehicle` y se usa el gemelo local `localCanStoreOwnVehicle`. Ojo: el `CanStoreOwnVehicle` de `8a4e3cf` espera `opts.requireDriver/requireEmpty/states`, pero `lockedOwnVehicle` le pasa `allowDriver/allowKeys`, así que la ocupación dentro del lock no se comprueba con ese contrato. Hay que revisarlo en la siguiente ronda.
- `luac54 -p`: OK en todos los .lua cambiados (los tres árboles). `/tmp/qa/p1/test.lua`: **35/35 PASS** en los tres. `node web/tests/error-codes.e2e.mjs`: PASS. `npm run test:e2e` (web): todo PASS.
- Harness nuevos (mocks de natives, MySQL, Bridge): `/tmp/qa/own/own.lua` (store/park/regularize, 23 casos), `/tmp/qa/own/own_t7.lua` (+adopción y SpawnOwnedVehicle, 32 casos) y `/tmp/qa/own/imp.lua` (`InsertBatch` adoptable, 7 casos). Resultado en `7ad284c`: 29/32 y 5/7. Todos los FAIL son hallazgos reales (ver abajo).

## F1-J: resultados

| Caso | Resultado | Evidencia |
|---|---|---|
| [x] Coche de NPC robado (sin fila) | **OK** | store y park → `not_owned_vehicle` (harness). |
| [x] Coche de otro jugador | **OK** | Marcado y trackeado a nombre de otro → `not_owner` al guardar y al aparcar. Adopción con fila de otro → `not_owner`. |
| [x] Llave temporal o compartida | **OK** | `IsOwner(src, plate, false)` → `not_owner`, también en la adopción. Las llaves externas (qbx/qb-vehiclekeys) nunca se consultan. Queda `Config.AllowSharedKeyStore` (ver L). |
| [x] Matrícula falsificada | **OK** | Bag `mdp_plate` + matrícula propia sobre un NPC → rechazado. Cambiar el texto de la matrícula de un coche marcado → `vehicle_mismatch`. Un clon marcado no trackeado → `vehicle_mismatch`. |
| [x] Props o modelo que no cuadran | **OK** | `model_mismatch` → `vehicle_mismatch`. En la adopción, las props salen de la BD/stock + campos de desgaste. |
| [ ] Vendido o transferido mientras está fuera | **FALLA (Alta, P1-OWN-H1)** | Una transferencia en `mdp_vehicles` se rechaza OK. Una venta en la tabla del framework se aplaza mientras está en OUT → el vendedor aún puede guardar o aparcar. |
| [x] Estados 2/3/4/5 | **OK** | 2/3/4 → `invalid_state` y 5 → `not_owned_vehicle`, sin escribir nada. Guardar desde el estado 2 ya no se permite. |
| [ ] Todas las entradas pasan por la misma comprobación | **Parcial** | Zona, `/mdp_park` y net events → los dos callbacks con los mismos checks. La NUI no tiene callback de guardar. **El export `SpawnOwnedVehicle` duplica coches (P1-OWN-H2).** |
| [x] Código de error propio y mensaje en la NUI | **OK** | `not_owned_vehicle`, `vehicle_mismatch` y `not_owner` están en constants, locales es/en, `i18n.tsx`, `types/index.ts` y `web/dist` (`index-CO3Zy9jA.js`, 169cb30). No hay gap de frontend. |
| [ ] ESX, QBCore y Qbox | **Pendiente (in-engine)** | La lógica es agnóstica: usa `mdp_vehicles.owner` y `Bridge.GetIdentifier`. Las fechas del framework difieren (ver M5). Falta probarlo en los tres servidores. |

## P1R3-H1 tras quitar la excepción
- `persistence.lua:160` `keepOut` sigue en su sitio → **no vuelve el duplicado** al reiniciar.
- Pero un coche en OUT **sin marca y ocupado** se queda en OUT sin trackear, y `storeVehicle`/`parkWorld` lo rechazan (`vehicle_mismatch`): el dueño se queda **atascado**. Vías de salida: (a) `/mdp_regularize <matrícula>` de un admin cuando el coche esté vacío (lo borra y lo pasa a GARAGED con las props de la BD, así que se pierde el tuning de calle, P1R3-L1); (b) el siguiente reinicio con el coche vacío. La adopción del primer guardado no lo salva fuera de la ventana de 30 min. No hay re-adopción para el jugador → **P1-OWN-M1**.
- Un coche marcado que esté ocupado o se haya movido se adopta y se trackea (excepción de `persistence.lua`), así que se puede guardar con normalidad ✓.

## Alta

| # | Sev. | Archivo:línea | Descripción y reproducción | Arreglo |
|---|---|---|---|---|
| **P1-OWN-H1** | **Alta** (bypass de "ya no es suyo") | server/vehicles.lua:147 (transferencia aplazada en OUT) + garages.lua:329 `lockedOwnVehicle` (solo mira `mdp_vehicles.owner`) | A saca su coche (OUT) y lo vende con un script del framework (`owned_vehicles.owner` / `player_vehicles.citizenid` → B). El sync aplaza la transferencia mientras la fila esté en OUT, así que `mdp_vehicles.owner` sigue siendo A. A lo guarda o lo aparca → **OK**, y B recibe `not_owner`. Después el sync lo pasa a B, pero mientras tanto el coche ya no es de A y se acepta igual. Lo mismo con `AddVehicle` → `transfer_deferred` (vehicles.lua:≈287/300). | Dentro del lock, si `Config.SyncFrameworkTables`, comprobar también el dueño en la tabla del framework (`owned_vehicles.owner` o `player_vehicles.citizenid` vía Bridge, o una consulta fija por framework), o aplicar la transferencia aunque esté en OUT (des-trackear la entidad y quitar las llaves). Depende de la decisión de Security sobre las filas importadas. |
| **P1-OWN-H2** | **Alta** (duplicado) | server/garages.lua:529-550 `SpawnOwnedVehicle` | Con estado OUT solo se mira `Security.GetSpawnedEntity(plate)`. Si la entidad viva **no está trackeada** (coche de concesionario tras `AddVehicle(...,'out')`, o un `keepOut` de P1R3-H1 tras reiniciar), se spawnea **una segunda copia** marcada. El dueño guarda la copia → GARAGED, la saca otra vez → 3 coches. Harness: `SpawnOwnedVehicle refuses while an unmarked entity…` → FAIL (spawned 1). Además lo puede llamar **cualquier** recurso, no solo `Config.TrustedResources`. | Con estado OUT, buscar la matrícula en el mundo (`Utils.WorldVehiclesByPlate`/`UniqueWorldVehicle`) y rechazar con `already_out` si hay alguna entidad, o adoptarla. Limitar el export a `Config.TrustedResources`, como `RegisterExternalVehicle`. |

## Revisión 53c2c56 / 7de0844 / 7ad284c (preguntas del encargo)
- **GetInvokingResource:** lo da el runtime de CFX y otro recurso no puede falsificarlo. El riesgo es **pasar a través de un recurso de confianza**: si un concesionario de confianza expone un evento de red que reenvía `netId/plate` del cliente a `RegisterExternalVehicle`, cualquier cliente puede registrar la fila OUT recién creada (<60 s) de **otro jugador** sobre una entidad tipo 7 creada por él con la misma matrícula y modelo. El export no recibe `src` ni comprueba el dueño (garages.lua:579-592). El escaneo de duplicados lo bloquea mientras el coche real del concesionario exista. Si no, el atacante "secuestra" la adopción: no puede guardarlo (no es el dueño), pero deja al comprador con `vehicle_mismatch` → **P1-OWN-M3**.
- **Ventana de 60 s:** un solo uso (`managed_at` condicional + rollback) ✓. Dentro de la ventana no está ligada al dueño (ver arriba).
- **Adopción de un NPC o de un coche ajeno:** ajeno → no (`requireOwnerSrc`). NPC ambiental → no (population type 2-6 rechazado en servidor, garages.lua:280; se lee con `GetEntityPopulationType` en el servidor, no lo manda el cliente). Pero un coche **creado por un script de cliente** (executor `CreateVehicle`) también es tipo 7: un tramposo puede fabricar su propio coche (misma matrícula y modelo) si su fila es OUT, nueva y sin gestionar y no hay otra entidad viva con esa matrícula. Solo afecta a coches suyos → Media (P1-OWN-M4). Falta comprobar en el motor si `SetEntityAsMissionEntity` en cliente cambia el tipo de población que ve el servidor.
- **Rate limit:** por `src` (`Security.RateLimit`, garages.lua:363). Al reconectar se recuperan los buckets por identificador solo durante `rateCarryMs` (30 s): un relog de más de 30 s lo resetea → Baja (P1-OWN-L5). Además se consume antes del lock, incluso en intentos fallidos (correcto).
- **Migración v5 (managed_at):** comprobada por `hasColumn` → idempotente. Se ejecuta dos veces sin problema, y si la columna ya existe (install.sql nuevo) no hace nada. Solo toca `mdp_vehicles`, así que es igual en ESX, QB y Qbox. Si se cae entre el ALTER y el backfill, el backfill no se repite (Baja, P1-OWN-L6). La ventana de 30 min por `created_at` lo mitiga.
- **7ad284c, filas importadas:** casos probados con `imp.lua`: primer sync → no adoptable ✓; incremental + dueño conocido + OUT + reciente → adoptable ✓; GARAGED importado → no ✓; fecha del framework de hace 2 h → no ✓; OUT sin entidad (R4-1 → GARAGED) → no ✓; **fecha NULL → adoptable ✗**; **fecha futura → adoptable ✗** (P1-OWN-M5).
  - **Seed en el upgrade:** solo si `mdp_synced_owners` no existía; `initial_import_done` solo si se sembró algo; en otro caso lo pone el arranque después de `SyncConnectedPlayers` ✓. Revisado leyendo el código (no hay harness de `upgradeSchema`, es local). Un jugador que entra **durante** el upgrade: `syncPlayer` no espera a `MDP.Ready`. Si las tablas aún no existen, el `scalar` sobre `mdp_meta` lanza un error fuera de pcall (el sync falla y no pasa nada más). Si existen pero el seed no ha corrido, su sync va con `adoptable=false` y luego queda marcado como conocido: el mismo resultado que un jugador existente. No obtiene adopciones de su primera importación ✓ (P1-OWN-L7 por el error sin pcall).
  - **Reabrir la ventana:** un jugador no puede tocar `created_at` ni la fecha del framework. Un admin o un script que **borre** la fila de `mdp_vehicles` hace que se reimporte como nueva (adoptable si está en OUT). El camino REMOVED → restaurar no toca `managed_at` ✓. Un script que escriba la columna `date` (lista genérica `DATE_COLS`, vehicles.lua:163) con NULL o con una fecha futura reabre la ventana (M5).
  - **Fechas ESX/QB/Qbox:** que yo sepa, los esquemas estándar de `owned_vehicles` (ESX) y `player_vehicles` (QB/Qbox) **no** tienen columna de fecha → `fw_created_ts` = nil → la ventana del framework no se aplica y solo cuenta `created_at` de mdp (la hora de la importación). Una compra antigua que aparece por primera vez en mdp es adoptable 30 min. Depende de Security. Hay que comprobarlo en cada framework.
  - **install.sql vs upgrade:** las mismas tablas, pero install.sql no siembra nada. Si se ejecuta install.sql sobre una BD v4 existente, las tablas ya existen → el upgrade no siembra → todos los dueños son "desconocidos" en el siguiente sync (falla de forma segura: no adoptable). Baja (P1-OWN-L8).
- **Pendiente de Security:** el comportamiento de las filas importadas (M5, H1, L8) puede cambiar. Lo dejo anotado y no bloquea.

## Media/Baja (detalle en backlog-phase1.md)
P1-OWN-M1 atascado sin re-adopción · M2 `/mdp_regularize` saca de incautado/retirado · M3 `RegisterExternalVehicle` sin ligar al dueño · M4 tipo 7 desde script de cliente · M5 fecha NULL o futura en la importación · L1 ocupación fuera del lock (TOCTOU) · L2 `AllowSharedKeyStore` reabre las llaves · L3 pcall que tapa errores como `vehicle_mismatch` · L4 adopción con efectos aunque el guardado falle después · L5 rate limit reseteado al reconectar · L6 backfill v5 no reintentable · L7 `syncPlayer` sin pcall en mdp_meta · L8 install.sql no siembra · L9 `/mdp_regularize` borra a medias y no filtra por modelo.

`/mdp_regularize`: restringido por ACE (`RegisterCommand(..., true)`) ✓, matrícula normalizada y validada ✓, **no cambia el dueño → no sirve para quedarse con el coche de otro** ✓.

## Veredicto (HEAD revisado `7ad284c`)
**NO se puede cerrar: 2 Altas** (P1-OWN-H1: vendido mientras está fuera se puede seguir guardando; P1-OWN-H2: `SpawnOwnedVehicle` duplica cuando hay una entidad sin trackear). El núcleo owner-only (NPC, coche ajeno, llaves, matrícula falsa, modelo, estados, códigos de error y NUI) está bien.

---

# Propiedad R2 (8a4e3cf, 677f577)

- Fecha: 16/10/2026, 23:20 (UTC+1). Árbol limpio de `677f577` (`git archive`), que incluye `8a4e3cf`, `926d58b` y `7ad284c`. Líneas de `677f577`.
- `luac54 -p`: OK en todos los .lua. `/tmp/qa/p1/test.lua`: **35/35**. `own_r2.lua` (own_t7 + 11 casos R2): **42/43** (FAIL = R2-M1). `imp_r2.lua`: **9/9**.

## Contrato CanStoreOwnVehicle ↔ lockedOwnVehicle
- `lockedOwnVehicle(…, isStore)` ahora pasa `states={[0]=true}`, `allowDriver`/`requireDriver = isStore`, `requireEmpty = not isStore`, `allowKeys`, `row`. Son los mismos nombres que `Security.CanStoreOwnVehicle` (security.lua:656-702) y que el gemelo local ✓.
- `STORE_ERR` mapea `not_driver` → `not_in_vehicle`, `occupied`, `invalid_source/entity` ✓.
- **L1 cerrado:** probé un pasajero que entra durante el lock al guardar → `occupied`, y alguien que entra durante el lock al aparcar → `occupied`, sin escribir nada.
- Pequeño detalle de 8a4e3cf: el dueño se compara con `row.owner == ident`. Solo se consulta `IsOwner` si `row.owner` es nil. Correcto.

## H1 (vendido mientras está fuera): **CERRADO**
- Transferencia inmediata (`ApplyTransfer`: UPDATE condicionado al dueño anterior, `state <> 5`) en el sync, en `AddVehicle` y dentro del lock de store/park (`FrameworkOwner` ≠ `row.owner` → `not_owner` + transferencia). Harness: guardar o aparcar tras una venta en el framework → `not_owner` y la fila pasa al comprador ✓. Una fila solo de mdp (sin fila en el framework) → guarda normalmente ✓.
- Casos límite:
  - **Venta durante el guardado (carrera):** si la venta llega después de la comprobación y dentro del lock, el vendedor guarda (GARAGED) y el siguiente sync pasa la fila al comprador. Ventana de ms, resultado final correcto → aceptado.
  - **Comprador offline:** la fila cambia de dueño; la entidad sigue trackeada con `src` del vendedor → R2-M2 (la política de desconexión del vendedor se aplica al coche del comprador). Al conectarse, `claimSpawns` se lo da al comprador ✓.
  - **Vendedor conduciendo:** la entidad **no se borra** y no se expulsa a los ocupantes. Se borran las llaves de la tabla y se llama a `Bridge.Keys.RemoveKeys(seller)` en vivo (si está online). El vendedor puede seguir conduciendo, pero no guardarlo ni aparcarlo (`not_owner`). Documentarlo (R2-M2).
  - **Venta a uno mismo:** `e.owner == r.owner` → no se hace nada; `AddVehicle` no entra en la rama de transferencia ✓.
  - **Estado 3 con multas:** se transfiere; las multas siguen siendo del vendedor (`mdp_fines.owner`) → R2-L2, decisión de Security.
  - **Formatos ESX/QB:** `FrameworkOwner` devuelve `owned_vehicles.owner` (ESX `char1:…`/`license:…`) o `player_vehicles.citizenid` (QB/Qbox), que es la misma columna que se importó a `mdp_vehicles.owner` → comparación coherente. Matrícula con `UPPER(TRIM())`: se cubre el relleno de ESX, pero no los espacios internos dobles (R2-L1) ni el índice (R2-M3).

## H2 (duplicado en SpawnOwnedVehicle/takeOut): **CERRADO**
- Escaneo del pool (`liveEntityConflict`, garages.lua:88) dentro del lock, antes de spawnear en `takeOut` (:130, excluye el coche aparcado trackeado) y en `SpawnOwnedVehicle` (:608). Harness: entidad sin marca viva → `vehicle_mismatch`, marcada sin trackear → `already_out`, 0 spawns ✓. Los dos exports pasan por `Config.TrustedResources`: con un recurso no listado o el propio recurso → `untrusted_resource` + mensaje con instrucciones ✓.
- Casos límite:
  - **Coste:** solo bajo demanda (takeOut limitado a 1/s, export a 3/10 s), O(n vehículos) por llamada, nunca por tick ✓. Sigue P1-M3 en el streamer.
  - **Normalización:** las dos matrículas pasan por `NormalizePlate` (trim, espacios colapsados, mayúsculas): `"tr 004 "` vs `"TR  004"` coinciden ✓.
  - **Routing buckets / culling:** `GetAllVehicles` ve todas las entidades de red de todos los buckets, sin importar el culling. Una entidad en otro bucket bloquea (correcto contra duplicados). Las entidades solo de cliente (no de red) no se ven, pero tampoco se pueden guardar.
  - **Falso `already_out`/`vehicle_mismatch`:** **sí** → R2-M1. Cualquier coche con la matrícula de la víctima (otro modelo, sin marca) bloquea que la víctima saque su coche del garaje. Harness FAIL.
- **Adaptadores:** ningún archivo de mdp_garages llama a los exports → nada interno se rompe. Los concesionarios externos dejan de funcionar hasta añadirlos a `TrustedResources` (R2-L4).

## Otros
- **M2 cerrado:** `/mdp_regularize` rechaza los estados 3/4 y las multas pendientes (por `plate`; ver R2-L2). Harness ✓.
- **M5 cerrado:** con una columna DATETIME/TIMESTAMP, una fecha NULL o futura (más de 5 min de desfase) ya no es adoptable ✓. **Sin columna de fecha (esquemas estándar) sigue siendo adoptable dentro de los 30 min de mdp → pendiente de Security.** Si la consulta con la columna de fecha falla, se reintenta sin ella y sin adopciones ✓.
- **Siguen abiertos:** M1 (atascado sin re-adopción), M3 (`RegisterExternalVehicle` sigue sin `ownerSrc`), M4 (tipo 7 desde cliente), L2, L4-L9.

## Veredicto R2 (HEAD `677f577`)
**H1 y H2 CERRADOS. 0 Crítica/Alta.** Quedan Medias nuevas: R2-M1 (bloqueo de takeOut poniendo una matrícula falsa, DoS), R2-M2 (transferencia con comprador offline: política de desconexión) y R2-M3 (full scan en `FrameworkOwner`). Siguen M1/M3/M4. Pendiente de Security: adopción sin columna de fecha y multas al vender un coche incautado.

---

# Propiedad R3 (2b60c36)

- Fecha: 16/10/2026, 23:25 (UTC+1). Árbol limpio de `2b60c36` (`git archive`). Líneas de `2b60c36`.
- `luac54 -p`: OK. `/tmp/qa/p1/test.lua`: **35/35**. `own_r3.lua` (own_r2 + 9 casos R3, con el mock de UPDATE adaptado a `AND owner = ?`): **50/51**. `tr3.lua` (nuevo: `ApplyTransfer`/`onOwnerChanged`/`FrameworkOwner`): **11/12**. `imp_r3.lua`: **9/9** (sin columna de fecha → no adoptable).

## Resultados
| Caso | Resultado |
|---|---|
| Venta (framework) → el vendedor guarda o aparca | **OK** `not_owner` + transferencia dentro del lock. |
| Venta (framework, sin sync aún) → el vendedor saca el coche (`takeOut` / `SpawnOwnedVehicle`) | **FALLA → P1-OWN-R3-H1** |
| Venta ya aplicada en mdp → el vendedor saca el coche | OK: `IsOwner` dentro del lock + `UPDATE … AND owner = ?` → `not_owner` (garages.lua:123, 142-148). |
| Llaves del vendedor revocadas | **OK**: borra `mdp_vehicle_keys` y llama a `RemoveKeys` para cada jugador online excepto el comprador; el comprador online hace `ClaimSpawn` (tr3). |
| Clon de la matrícula con el coche en GARAGED | **OK**: el dueño lo saca (R2-M1 cerrado). |
| Clon + coche real en el mundo, después | Store/park del clon (griefer o dueño, con o sin el bag `mdp_plate` falsificado) → rechazado; no se adopta (`managed_at` ya puesto, duplicado de matrícula). El coche real (marcado y trackeado) se guarda bien. **Pero en el reinicio → R3-M1.** |
| Venta durante el store | La venta llega después de la comprobación y dentro del lock → el vendedor guarda; el siguiente sync transfiere la fila GARAGED. Carrera aceptada. Si el store tiene el lock, el `ApplyTransfer` del sync devuelve false (lock ocupado) y se reintenta en el siguiente sync ✓. |
| Dos ventas seguidas A→B→C | OK: `UPDATE … AND owner = <anterior>`; una venta obsoleta A→C después de A→B se rechaza ✓; a uno mismo no hace nada ✓; REMOVED no se transfiere ✓. |
| `FrameworkOwner` | `plate = ? OR plate = ?` (normalizada + con relleno a 8): usa el índice (ESX `owned_vehicles.plate` es PK; en QB/Qbox hay que comprobar el índice de `player_vehicles.plate`). Relleno de ESX ✓. **Doble espacio interno → no coincide (R2-L1 sigue abierto, tr3 FAIL).** 2 filas → `nil, 'ambiguous'` → falla en abierto (R3-M2). |
| `/mdp_regularize` multas | Solo las del dueño actual en esa matrícula ✓. |
| Adopción de filas importadas | Falla cerrado sin una columna DATETIME/TIMESTAMP → en los esquemas estándar de ESX/QB/Qbox nunca es adoptable ✓. |

## Alta
| # | Sev. | Archivo:línea | Descripción y reproducción | Arreglo |
|---|---|---|---|---|
| **P1-OWN-R3-H1** | **Alta** (el vendedor usa un coche ya vendido) | server/garages.lua:100-148 (`takeOut`) y :600-620 (`SpawnOwnedVehicle`): sin `FrameworkOwner` | A vende un coche GARAGED con un script del framework (`owned_vehicles.owner`/`citizenid` → B). Hasta que mdp sincroniza, `mdp_vehicles.owner` sigue siendo A, y `takeOut`/`SpawnOwnedVehicle` solo comprueban mdp → **A lo saca**. Harness: `SpawnOwnedVehicle` del vendedor → spawneado. Cuándo se corrige solo: `SyncRemovals` del vendedor solo actúa en filas `source='framework'` y estados 1/2, y el sync de `getVehicles` va en un hilo aparte con caché de 60 s (A puede sacarlo antes). Para filas de concesionario (`source='mdp'`) dura hasta que B haga sync (B offline = indefinido). Store/park sí lo bloquean (y entonces transfieren), pero A ya está conduciendo un coche ajeno. | Llevar el mismo bloque de lockedOwnVehicle (`FrameworkOwner` ≠ `row.owner` → `ApplyTransfer(..., true)` + `not_owner`) a `takeOut` y `SpawnOwnedVehicle` dentro del lock, antes del UPDATE. |

## Aplazados (anotados)
R2-M2 (comprador offline / política de desconexión) y TR-3..TR-5 → backlog de fase 2, según Backend.

## Veredicto R3 (HEAD `2b60c36`)
**NO se puede cerrar: 1 Alta (P1-OWN-R3-H1)**, la misma clase que H1 pero en la salida del garaje (takeOut/SpawnOwnedVehicle sin la comprobación del dueño en el framework). Es un arreglo de pocas líneas reutilizando el bloque de `lockedOwnVehicle`. TR-1/TR-2, R2-M1, R2-M3 y fail-closed: correctos. Medias nuevas: R3-M1 (clon + reinicio → atascado) y R3-M2 (2 filas en el framework → falla en abierto).

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

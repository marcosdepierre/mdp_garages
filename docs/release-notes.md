# mdp_garages — Notas de versión

## Instalación y migración (fase 1)

### Secreto de entidades del servidor (R3-4)
Añade a `server.cfg` **antes** de `ensure mdp_garages`:

```cfg
set mdp_garages_entity_secret "<cadena aleatoria larga, ≥ 32 caracteres>"
```

- Se usa para la marca oculta que identifica los vehículos creados por el servidor (`Security.MarkServerEntity` / `IsServerEntity`). Sin ella, un vehículo no se puede adoptar tras un reinicio del recurso.
- Si no se define, se genera un secreto una vez y se guarda en el KVP del recurso. Funciona, pero cualquiera con acceso a los archivos del servidor puede leerlo. **Recomendado: definir el convar.**
- No lo cambies con el servidor en marcha: los vehículos marcados con el secreto anterior dejan de reconocerse en el siguiente reinicio (mismo efecto que la migración de abajo).
- No lo publiques ni lo subas a repositorios.

### Primer reinicio tras actualizar (R3-2)
Los vehículos que se spawnearon con una versión anterior (antes de `a8fda43`) no llevan la marca del servidor. En el primer reinicio del recurso tras actualizar:

| Situación de la entidad antigua | Resultado |
|---|---|
| Vacía | Se borra y queda registrado en el log. El vehículo vuelve a su garaje o lo vuelve a spawnear el streamer desde la base de datos. No se pierde ni se duplica. |
| Ocupada (alguien conduciendo) | Se ignora y queda registrado en el log. **La fila se mantiene en `OUT`** (arreglo P1R3-H1), así que no se crea un duplicado en el garaje. El vehículo sigue en el mundo sin trackear hasta que el jugador lo guarde o la entidad desaparezca. |

Recomendación: actualiza en un reinicio programado con pocos jugadores conectados, o pide que guarden los vehículos antes.

### Configuración del servidor recomendada
- `sv_entityLockdown relaxed` (o `strict` si no rompe otros recursos).
- `sv_filterRequestControl 2` (o `1`).
- `sv_stateBagStrictMode true` solo si ningún otro recurso escribe statebags desde el cliente.

### `ox:callbackTimeout` (opcional)
`setr ox:callbackTimeout <ms>` es un convar **global** de ox_lib que afecta a todos los recursos, así que mdp_garages **no lo exige**. Es **opcional**. El valor por defecto es 300 s (300000 ms); si lo cambias, es para **bajarlo** (por ejemplo, `setr ox:callbackTimeout 20000`), para que un callback colgado no deje la UI esperando minutos. Ten en cuenta que afecta también a los demás recursos que usan ox_lib. No hace falta por seguridad, porque el servidor ya protege contra el doble envío (lock por matrícula, UPDATE condicional por estado y rate limit por jugador), y el cliente ignora las respuestas que llegan tarde (L1 de Frontend).

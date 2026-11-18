-- =============================================================================
-- 01_usuarios_permisos.sql
-- Configuración de usuarios y permisos para acceso remoto vía Tailscale
--
-- PROBLEMA RAÍZ:  El usuario 'Compañero' existe solo para 'localhost'.
--                 Las conexiones desde pc.taile8f403.ts.net (IP Tailscale:
--                 100.x.x.x) no tienen un registro de privilegios coincidente,
--                 por lo que MariaDB retorna ERROR 1045.
--
-- SOLUCIÓN:       Crear el usuario para el wildcard '%' (cualquier host) o,
--                 de forma más restrictiva, para el rango 100.%.%.% de Tailscale.
--
-- INSTRUCCIONES:
--   Ejecutar este script en AMBAS máquinas como root de MariaDB:
--     mysql -u root -p < 01_usuarios_permisos.sql
--
--   Nodo 0 (Morelia)   IP Tailscale: 100.120.137.4  BD: sucursal_morelia
--   Nodo 1 (Pátzcuaro) IP Tailscale: 100.119.128.65 BD: suc_patzcuaro
-- =============================================================================

-- ── Paso 0: Diagnóstico inicial ───────────────────────────────────────────────
-- Ejecutar antes de hacer cambios para ver el estado actual:
-- SELECT user, host, plugin, password_expired
--   FROM mysql.user
--  WHERE user = 'Compañero';

-- ── Paso 1: Eliminar entradas antiguas restrictivas (si existen) ──────────────
-- Si el usuario fue creado solo para localhost, lo eliminamos para recrearlo
-- correctamente. SOLO ejecutar si el SELECT anterior lo confirma.

-- DROP USER IF EXISTS 'Compañero'@'localhost';
-- DROP USER IF EXISTS 'Compañero'@'127.0.0.1';
-- DROP USER IF EXISTS 'Compañero'@'::1';

-- ── Paso 2: Crear usuario para acceso remoto ──────────────────────────────────
-- Opción A — Wildcard total (recomendado para desarrollo):
CREATE USER IF NOT EXISTS 'Compañero'@'%'
    IDENTIFIED BY 'UnaContraseñaSegura123!';

-- Opción B — Restringido al rango de IPs de Tailscale (más seguro):
-- CREATE USER IF NOT EXISTS 'Compañero'@'100.%.%.%'
--     IDENTIFIED BY 'UnaContraseñaSegura123!';

-- Si el usuario ya existe pero con contraseña diferente o expirada:
ALTER USER IF EXISTS 'Compañero'@'%'
    IDENTIFIED BY 'UnaContraseñaSegura123!';

-- ── Paso 3: Otorgar permisos ──────────────────────────────────────────────────
-- EJECUTAR EN EL NODO 0 (Morelia, 100.120.137.4):
GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, DROP, INDEX, ALTER,
      CREATE TEMPORARY TABLES, LOCK TABLES, EXECUTE, SHOW VIEW
    ON `sucursal_morelia`.*
    TO 'Compañero'@'%';

-- EJECUTAR EN EL NODO 1 (Pátzcuaro, 100.119.128.65):
-- GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, DROP, INDEX, ALTER,
--       CREATE TEMPORARY TABLES, LOCK TABLES, EXECUTE, SHOW VIEW
--     ON `suc_patzcuaro`.*
--     TO 'Compañero'@'%';

-- ── Paso 4: Replicación — permisos adicionales ────────────────────────────────
-- Para la replicación bidireccional (binlog), el usuario de replicación
-- necesita permisos específicos. Estos se configuran en 02_replicacion.sql.

-- ── Paso 5: Aplicar cambios ───────────────────────────────────────────────────
FLUSH PRIVILEGES;

-- ── Verificación post-instalación ────────────────────────────────────────────
-- Ejecutar después para confirmar el resultado:
SELECT user, host, plugin, password_expired, account_locked
  FROM mysql.user
 WHERE user = 'Compañero'
 ORDER BY host;

SHOW GRANTS FOR 'Compañero'@'%';

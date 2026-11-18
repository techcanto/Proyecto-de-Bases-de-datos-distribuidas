-- =============================================================================
-- 02_replicacion_nodo0_morelia.sql
-- Configuración de replicación binlog en el NODO 0 (Morelia, 100.120.137.4)
--
-- Este script configura al Nodo 0 como:
--   • MASTER  → el Nodo 1 (Pátzcuaro) replicará desde aquí
--   • SLAVE   → replicará los cambios originados en el Nodo 1
--
-- PREREQ: El archivo /etc/mysql/mariadb.conf.d/50-server.cnf debe
--         tener las directivas del bloque [mariadb] indicadas en
--         03_my_cnf_nodo0.ini ANTES de ejecutar este script.
-- =============================================================================

-- ── 1. Crear usuario de replicación ──────────────────────────────────────────
-- Este usuario es usado por el Nodo 1 para conectarse y leer el binlog.
CREATE USER IF NOT EXISTS 'repl_morelia'@'100.%.%.%'
    IDENTIFIED BY 'ReplMorelia_Segura!2026';

GRANT REPLICATION SLAVE ON *.*
    TO 'repl_morelia'@'100.%.%.%';

FLUSH PRIVILEGES;

-- ── 2. Ver posición actual del binlog (anotar para configurar el Nodo 1) ──────
-- Ejecutar DESPUÉS de haber habilitado el binlog en my.cnf y reiniciado MariaDB.
-- Los valores File y Position son los que se pasan a CHANGE MASTER en el Nodo 1.
SHOW MASTER STATUS;

-- ── 3. Configurar este nodo como SLAVE del Nodo 1 (Pátzcuaro) ────────────────
-- Reemplazar MASTER_LOG_FILE y MASTER_LOG_POS con los valores del
-- SHOW MASTER STATUS ejecutado en el Nodo 1.
CHANGE MASTER TO
    MASTER_HOST        = '100.119.128.65',
    MASTER_PORT        = 3306,
    MASTER_USER        = 'repl_patzcuaro',
    MASTER_PASSWORD    = 'ReplPatzcuaro_Segura!2026',
    MASTER_LOG_FILE    = 'mariadb-bin.000001',   -- ← reemplazar con valor real
    MASTER_LOG_POS     = 4,                       -- ← reemplazar con valor real
    MASTER_CONNECT_RETRY = 10;

-- ── 4. Iniciar replicación ────────────────────────────────────────────────────
START SLAVE;

-- ── 5. Verificar estado de replicación ───────────────────────────────────────
-- Ambos valores deben ser 'Yes'. Si hay error, ver Last_Error.
SHOW SLAVE STATUS\G

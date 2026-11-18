-- =============================================================================
-- 03_replicacion_nodo1_patzcuaro.sql
-- Configuración de replicación binlog en el NODO 1 (Pátzcuaro, 100.119.128.65)
--
-- Este script configura al Nodo 1 como:
--   • MASTER  → el Nodo 0 (Morelia) replicará desde aquí
--   • SLAVE   → replicará los cambios originados en el Nodo 0
-- =============================================================================

-- ── 1. Crear usuario de replicación ──────────────────────────────────────────
CREATE USER IF NOT EXISTS 'repl_patzcuaro'@'100.%.%.%'
    IDENTIFIED BY 'ReplPatzcuaro_Segura!2026';

GRANT REPLICATION SLAVE ON *.*
    TO 'repl_patzcuaro'@'100.%.%.%';

FLUSH PRIVILEGES;

-- ── 2. Ver posición actual del binlog ────────────────────────────────────────
-- Anotar File y Position para configurar el Nodo 0 como slave de este nodo.
SHOW MASTER STATUS;

-- ── 3. Configurar este nodo como SLAVE del Nodo 0 (Morelia) ──────────────────
-- Reemplazar MASTER_LOG_FILE y MASTER_LOG_POS con los valores del
-- SHOW MASTER STATUS ejecutado en el Nodo 0.
CHANGE MASTER TO
    MASTER_HOST        = '100.120.137.4',
    MASTER_PORT        = 3306,
    MASTER_USER        = 'repl_morelia',
    MASTER_PASSWORD    = 'ReplMorelia_Segura!2026',
    MASTER_LOG_FILE    = 'mariadb-bin.000001',   -- ← reemplazar con valor real
    MASTER_LOG_POS     = 4,                       -- ← reemplazar con valor real
    MASTER_CONNECT_RETRY = 10;

-- ── 4. Iniciar replicación ────────────────────────────────────────────────────
START SLAVE;

-- ── 5. Verificar estado de replicación ───────────────────────────────────────
SHOW SLAVE STATUS\G

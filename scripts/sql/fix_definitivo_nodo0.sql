-- fix_definitivo_nodo0.sql
-- EJECUTAR EN EL NODO 0 (máquina del compañero, 100.120.137.4):
--
--   mariadb -u 'Compañero' -p'UnaContraseñaSegura123!' \
--       < scripts/sql/fix_definitivo_nodo0.sql
--
-- ════════════════════════════════════════════════════════════════
-- CAUSA RAÍZ CONFIRMADA:
--   PyMySQL codifica la contraseña en latin-1 durante el handshake.
--   La 'ñ' en latin-1 = 0xf1, pero el hash en la BD fue creado con
--   la 'ñ' en UTF-8 = 0xc3b1. Hashes SHA1 incompatibles → error 1045.
--
-- SOLUCIÓN: cambiar la contraseña a una sin caracteres non-ASCII.
--   Esto se puede hacer SIN root usando SET PASSWORD.
-- ════════════════════════════════════════════════════════════════

-- Cambiar la contraseña del usuario actual a una versión ASCII
SET PASSWORD = PASSWORD('UnaClaveSegura123!');

-- Verificar que el hash cambió
SELECT user, host, plugin FROM mysql.user WHERE user = 'Compañero';
SHOW GRANTS FOR current_user();

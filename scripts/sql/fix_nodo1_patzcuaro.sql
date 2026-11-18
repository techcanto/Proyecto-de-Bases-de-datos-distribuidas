-- fix_nodo1_patzcuaro.sql
-- Ejecutar en el Nodo 1 (100.119.128.65 — esta máquina) como root de MariaDB.
-- Corrige el error 1045 para conexiones remotas vía Tailscale.

-- 1. Ver estado actual (para diagnóstico)
SELECT user, host, plugin FROM mysql.user WHERE user = 'Compañero';

-- 2. Eliminar entradas restrictivas a localhost (si existen)
DROP USER IF EXISTS 'Compañero'@'localhost';
DROP USER IF EXISTS 'Compañero'@'127.0.0.1';
DROP USER IF EXISTS 'Compañero'@'::1';

-- 3. Crear usuario aceptando conexiones desde cualquier host
CREATE USER IF NOT EXISTS 'Compañero'@'%'
    IDENTIFIED BY 'UnaContraseñaSegura123!';

-- 4. Asegurar contraseña correcta (por si el usuario ya existía con otra)
ALTER USER 'Compañero'@'%'
    IDENTIFIED BY 'UnaContraseñaSegura123!';

-- 5. Otorgar permisos sobre la BD de este nodo
GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, DROP,
      INDEX, ALTER, LOCK TABLES, EXECUTE, SHOW VIEW
    ON `suc_patzcuaro`.*
    TO 'Compañero'@'%';

-- 6. Aplicar cambios
FLUSH PRIVILEGES;

-- 7. Verificar resultado
SELECT user, host, plugin FROM mysql.user WHERE user = 'Compañero';
SHOW GRANTS FOR 'Compañero'@'%';

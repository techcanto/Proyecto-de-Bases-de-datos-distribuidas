-- fix_nodo0_morelia.sql
-- Ejecutar en el Nodo 0 (100.120.137.4 — máquina del compañero) como root de MariaDB.
-- Corrige el error 1045 para conexiones remotas vía Tailscale.

DROP USER IF EXISTS 'Compañero'@'localhost';
DROP USER IF EXISTS 'Compañero'@'127.0.0.1';
DROP USER IF EXISTS 'Compañero'@'::1';

CREATE USER IF NOT EXISTS 'Compañero'@'%'
    IDENTIFIED BY 'UnaContraseñaSegura123!';

ALTER USER 'Compañero'@'%'
    IDENTIFIED BY 'UnaContraseñaSegura123!';

GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, DROP,
      INDEX, ALTER, LOCK TABLES, EXECUTE, SHOW VIEW
    ON `sucursal_morelia`.*
    TO 'Compañero'@'%';

FLUSH PRIVILEGES;

SELECT user, host, plugin FROM mysql.user WHERE user = 'Compañero';
SHOW GRANTS FOR 'Compañero'@'%';

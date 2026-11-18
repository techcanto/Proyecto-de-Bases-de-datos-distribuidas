-- fix_definitivo_nodo1.sql
-- EJECUTAR EN EL NODO 1 (esta máquina, 100.119.128.65) con:
--   mariadb -u 'Compañero' -p'UnaContraseñaSegura123!' < scripts/sql/fix_definitivo_nodo1.sql
--
-- CAUSA RAÍZ ENCONTRADA:
--   PyMySQL codifica la contraseña en latin-1 durante el handshake de autenticación.
--   La contraseña 'UnaContraseñaSegura123!' tiene 'ñ' que en latin-1 = 0xf1,
--   pero el hash almacenado en la BD fue creado con la 'ñ' en UTF-8 = 0xc3b1.
--   Esto produce hashes SHA1 incompatibles → error 1045.
--
-- SOLUCIÓN: nuevo usuario 'Companero' con contraseña ASCII (sin ñ ni acentos).

-- Nodo 1: suc_patzcuaro
CREATE USER IF NOT EXISTS 'Companero'@'%'
    IDENTIFIED BY 'UnaClaveSegura123!';

ALTER USER 'Companero'@'%'
    IDENTIFIED BY 'UnaClaveSegura123!';

GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, DROP,
      INDEX, ALTER, LOCK TABLES, EXECUTE, SHOW VIEW
    ON `suc_patzcuaro`.*
    TO 'Companero'@'%';

-- También otorgar sobre 'tienda' si existe (para compatibilidad)
GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, DROP,
      INDEX, ALTER, LOCK TABLES, EXECUTE, SHOW VIEW
    ON `tienda`.*
    TO 'Companero'@'%';

FLUSH PRIVILEGES;

-- Verificar
SELECT user, host, plugin FROM mysql.user WHERE user = 'Companero';
SHOW GRANTS FOR 'Companero'@'%';

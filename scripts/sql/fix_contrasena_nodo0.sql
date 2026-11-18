-- fix_contrasena_nodo0.sql
-- Ejecutar con:
--   mariadb -u 'Compañero' -p < scripts/sql/fix_contrasena_nodo0.sql
-- (MariaDB pedirá la contraseña actual de forma interactiva, sin problemas de bash)
--
-- Contraseña actual:  UnaContraseñaSegura123!
-- Contraseña nueva:   UnaClaveSegura123!

SET PASSWORD = PASSWORD('UnaClaveSegura123!');

SELECT 'Contraseña actualizada correctamente.' AS resultado;

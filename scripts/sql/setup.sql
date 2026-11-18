-- =============================================================================
-- setup.sql — Inicialización de la base de datos en cada nodo
--
-- Ejecutar en CADA nodo con los valores correspondientes.
-- Ver README.md para instrucciones completas.
--
-- Variables a reemplazar antes de ejecutar:
--   <nombre_bd>  → nombre de la base de datos de este nodo
--   <usuario>    → nombre del usuario de la aplicación
--   <contraseña> → contraseña ASCII (sin ñ ni acentos)
--   <ai_inicio>  → valor de AUTO_INCREMENT según el nodo:
--                  Nodo 0: 1
--                  Nodo 1: 1501
--                  Nodo 2: 3001  (y así sucesivamente)
-- =============================================================================

-- ── 1. Crear base de datos ────────────────────────────────────────────────────
CREATE DATABASE IF NOT EXISTS `<nombre_bd>`
    CHARACTER SET utf8mb4
    COLLATE utf8mb4_unicode_ci;

USE `<nombre_bd>`;

-- ── 2. Crear tablas ───────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS Clientes (
    Id              BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    Nombre          VARCHAR(80)     NOT NULL,
    ApellidoPaterno VARCHAR(80)     NOT NULL,
    ApellidoMaterno VARCHAR(80)     DEFAULT NULL,
    RFC             VARCHAR(13)     NOT NULL,
    IdDireccion     BIGINT UNSIGNED  DEFAULT NULL   COMMENT 'Referencia opcional a dirección principal',
    PRIMARY KEY (Id),
    UNIQUE KEY uq_rfc (RFC)
) ENGINE=InnoDB
  CHARACTER SET utf8mb4
  COLLATE utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS Direcciones (
    Id         BIGINT UNSIGNED  NOT NULL AUTO_INCREMENT,
    Calle      VARCHAR(120)     NOT NULL,
    Numero     VARCHAR(20)      NOT NULL,
    Colonia    VARCHAR(100)     NOT NULL,
    Estado     VARCHAR(100)     NOT NULL,
    CP         CHAR(5)          NOT NULL,
    IdCliente  BIGINT UNSIGNED  NOT NULL,
    PRIMARY KEY (Id),
    FOREIGN KEY (IdCliente) REFERENCES Clientes(Id)
        ON DELETE CASCADE
) ENGINE=InnoDB
  CHARACTER SET utf8mb4
  COLLATE utf8mb4_unicode_ci;

-- ── 3. Fijar AUTO_INCREMENT según el índice del nodo ─────────────────────────
-- IMPORTANTE: cada nodo debe tener un valor diferente para evitar colisiones.
-- Nodo 0 → 1       Nodo 1 → 1501     Nodo 2 → 3001  ...
ALTER TABLE Clientes AUTO_INCREMENT = <ai_inicio>;

-- ── 4. Crear usuario de la aplicación ────────────────────────────────────────
-- NOTA: La contraseña debe ser ASCII puro (sin ñ, acentos ni caracteres especiales
-- no-ASCII) para compatibilidad con el driver PyMySQL.
CREATE USER IF NOT EXISTS '<usuario>'@'%'
    IDENTIFIED BY '<contraseña>';

ALTER USER '<usuario>'@'%'
    IDENTIFIED BY '<contraseña>';

GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, DROP,
      INDEX, ALTER, LOCK TABLES, EXECUTE, SHOW VIEW
    ON `<nombre_bd>`.*
    TO '<usuario>'@'%';

FLUSH PRIVILEGES;

-- ── 5. Verificar ─────────────────────────────────────────────────────────────
SHOW TABLES;
SELECT AUTO_INCREMENT
  FROM information_schema.TABLES
 WHERE TABLE_SCHEMA = '<nombre_bd>'
   AND TABLE_NAME   = 'Clientes';
SHOW GRANTS FOR '<usuario>'@'%';

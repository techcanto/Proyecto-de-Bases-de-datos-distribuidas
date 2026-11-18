-- =============================================================================
-- 06_migracion_id_direccion.sql — Migración para agregar IdDireccion a Clientes
--
-- Ejecutar en CADA nodo (Nodo 0 y Nodo 1) si ya existe la BD.
-- Esta columna es NULLABLE para mantener compatibilidad con clientes existentes.
--
-- La columna establece una relación opcional entre un cliente y una dirección
-- principal; el cliente puede tener múltiples direcciones en la tabla Direcciones,
-- pero esta columna permite indicar una "dirección preferida".
-- =============================================================================

USE `<nombre_bd>`;

-- Agregar la columna solo si no existe ya
ALTER TABLE Clientes
  ADD COLUMN IF NOT EXISTS IdDireccion BIGINT UNSIGNED DEFAULT NULL
    COMMENT 'Referencia opcional a una dirección principal del cliente';

-- Verificar
DESCRIBE Clientes;

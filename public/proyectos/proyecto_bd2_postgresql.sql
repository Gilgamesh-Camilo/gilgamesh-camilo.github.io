-- ====================================================================================
-- PROYECTO FINAL - BASES DE DATOS 2 (UNIVERSIDAD EL BOSQUE)
-- SCRIPT COMPLETO UNIFICADO: DDL + LÓGICA (PL/pgSQL) + DML (DATOS SEMILLA)
-- Motor: PostgreSQL
-- ====================================================================================

-- ====================================================================================
-- 1. SECCIÓN DDL: ELIMINACIÓN PREVIA (LIMPIEZA DE ENTORNO)
-- ====================================================================================
DROP TRIGGER IF EXISTS trg_descontar_stock ON detalle_pedidos CASCADE;
DROP TRIGGER IF EXISTS trg_auditoria_productos ON productos CASCADE;

DROP PROCEDURE IF EXISTS sp_registrar_pedido(INT, INT, INT, INT, VARCHAR);
DROP FUNCTION IF EXISTS fn_calcular_total_pedido(INT);
DROP FUNCTION IF EXISTS trg_fn_actualizar_stock();
DROP FUNCTION IF EXISTS trg_fn_auditar_productos();

DROP TABLE IF EXISTS detalle_pedidos CASCADE;
DROP TABLE IF EXISTS pedidos CASCADE;
DROP TABLE IF EXISTS inventario CASCADE;
DROP TABLE IF EXISTS productos CASCADE;
DROP TABLE IF EXISTS categorias CASCADE;
DROP TABLE IF EXISTS perfil_usuario CASCADE;
DROP TABLE IF EXISTS clientes CASCADE;
DROP TABLE IF EXISTS logs_auditoria CASCADE;

-- ====================================================================================
-- 2. SECCIÓN DDL: CREACIÓN DE TABLAS (3FN - 8 ENTIDADES)
-- ====================================================================================

-- Entidad 1: Categorías
CREATE TABLE categorias (
    id_categoria SERIAL PRIMARY KEY,
    nombre VARCHAR(100) NOT NULL UNIQUE,
    descripcion TEXT,
    activo BOOLEAN DEFAULT TRUE,
    creado_en TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Entidad 2: Productos (Relación 1:N con Categorías)
CREATE TABLE productos (
    id_producto SERIAL PRIMARY KEY,
    id_categoria INT NOT NULL REFERENCES categorias(id_categoria) ON DELETE RESTRICT,
    codigo_sku VARCHAR(50) NOT NULL UNIQUE,
    nombre VARCHAR(150) NOT NULL,
    descripcion TEXT,
    precio NUMERIC(12, 2) NOT NULL CHECK (precio >= 0),
    creado_en TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Entidad 3: Inventario (Relación 1:1 con Productos)
CREATE TABLE inventario (
    id_producto INT PRIMARY KEY REFERENCES productos(id_producto) ON DELETE CASCADE,
    stock_actual INT NOT NULL CHECK (stock_actual >= 0),
    stock_minimo INT NOT NULL DEFAULT 5 CHECK (stock_minimo >= 0),
    ultima_actualizacion TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Entidad 4: Clientes
CREATE TABLE clientes (
    id_cliente SERIAL PRIMARY KEY,
    numero_documento VARCHAR(25) NOT NULL UNIQUE,
    nombres VARCHAR(100) NOT NULL,
    apellidos VARCHAR(100) NOT NULL,
    email VARCHAR(150) NOT NULL UNIQUE,
    telefono VARCHAR(20),
    creado_en TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Entidad 5: Perfil de Usuario (Relación 1:1 con Clientes)
CREATE TABLE perfil_usuario (
    id_cliente INT PRIMARY KEY REFERENCES clientes(id_cliente) ON DELETE CASCADE,
    direccion_residencia VARCHAR(255),
    ciudad VARCHAR(100) NOT NULL DEFAULT 'Bogotá',
    limite_credito NUMERIC(12, 2) DEFAULT 0.00 CHECK (limite_credito >= 0),
    nivel_fidelizacion VARCHAR(20) DEFAULT 'BRONCE'
);

-- Entidad 6: Pedidos (Relación 1:N con Clientes)
CREATE TABLE pedidos (
    id_pedido SERIAL PRIMARY KEY,
    id_cliente INT NOT NULL REFERENCES clientes(id_cliente) ON DELETE RESTRICT,
    fecha_pedido TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    estado VARCHAR(30) DEFAULT 'PENDIENTE' CHECK (estado IN ('PENDIENTE', 'PAGADO', 'CANCELADO', 'ENTREGADO')),
    total NUMERIC(12, 2) DEFAULT 0.00 CHECK (total >= 0)
);

-- Entidad 7: Detalle de Pedidos (Relación N:M entre Pedidos y Productos)
CREATE TABLE detalle_pedidos (
    id_detalle SERIAL PRIMARY KEY,
    id_pedido INT NOT NULL REFERENCES pedidos(id_pedido) ON DELETE CASCADE,
    id_producto INT NOT NULL REFERENCES productos(id_producto) ON DELETE RESTRICT,
    cantidad INT NOT NULL CHECK (cantidad > 0),
    precio_unitario NUMERIC(12, 2) NOT NULL CHECK (precio_unitario >= 0),
    subtotal NUMERIC(12, 2) NOT NULL CHECK (subtotal >= 0),
    CONSTRAINT uq_pedido_producto UNIQUE (id_pedido, id_producto)
);

-- Entidad 8: Logs de Auditoría
CREATE TABLE logs_auditoria (
    id_log SERIAL PRIMARY KEY,
    tabla_afectada VARCHAR(50) NOT NULL,
    operacion VARCHAR(20) NOT NULL,
    registro_id INT,
    detalle JSONB,
    fecha TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- ====================================================================================
-- 3. SECCIÓN DE PROGRAMABILIDAD (FUNCIONES, TRIGGERS Y PROCEDIMIENTOS)
-- ====================================================================================

-- 3.1 FUNCIÓN: Calcular el Total Acumulado de un Pedido
CREATE OR REPLACE FUNCTION fn_calcular_total_pedido(p_id_pedido INT)
RETURNS NUMERIC AS $$
DECLARE
    v_total NUMERIC(12, 2) := 0.00;
BEGIN
    SELECT COALESCE(SUM(subtotal), 0.00)
    INTO v_total
    FROM detalle_pedidos
    WHERE id_pedido = p_id_pedido;

    RETURN v_total;
END;
$$ LANGUAGE plpgsql;

-- 3.2 TRIGGER Y FUNCIÓN: Auditoría automática en la tabla PRODUCTOS
CREATE OR REPLACE FUNCTION trg_fn_auditar_productos()
RETURNS TRIGGER AS $$
BEGIN
    IF (TG_OP = 'INSERT') THEN
        INSERT INTO logs_auditoria(tabla_afectada, operacion, registro_id, detalle)
        VALUES ('productos', 'INSERT', NEW.id_producto, row_to_json(NEW)::jsonb);
    ELSIF (TG_OP = 'UPDATE') THEN
        INSERT INTO logs_auditoria(tabla_afectada, operacion, registro_id, detalle)
        VALUES ('productos', 'UPDATE', NEW.id_producto, json_build_object('antes', row_to_json(OLD), 'despues', row_to_json(NEW))::jsonb);
    ELSIF (TG_OP = 'DELETE') THEN
        INSERT INTO logs_auditoria(tabla_afectada, operacion, registro_id, detalle)
        VALUES ('productos', 'DELETE', OLD.id_producto, row_to_json(OLD)::jsonb);
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_auditoria_productos
AFTER INSERT OR UPDATE OR DELETE ON productos
FOR EACH ROW EXECUTE FUNCTION trg_fn_auditar_productos();

-- 3.3 TRIGGER Y FUNCIÓN: Control de Stock y Actualización de Totales en Pedidos
CREATE OR REPLACE FUNCTION trg_fn_actualizar_stock()
RETURNS TRIGGER AS $$
DECLARE
    v_stock_disp INT;
BEGIN
    SELECT stock_actual INTO v_stock_disp
    FROM inventario
    WHERE id_producto = NEW.id_producto;

    IF v_stock_disp IS NULL THEN
        RAISE EXCEPTION 'Error de Integridad: El producto ID % no posee registro de inventario', NEW.id_producto;
    END IF;

    IF v_stock_disp < NEW.cantidad THEN
        RAISE EXCEPTION 'Stock insuficiente para el producto ID %. Disponible: %, Solicitado: %', 
            NEW.id_producto, v_stock_disp, NEW.cantidad;
    END IF;

    -- Descontar existencias de inventario
    UPDATE inventario
    SET stock_actual = stock_actual - NEW.cantidad,
        ultima_actualizacion = CURRENT_TIMESTAMP
    WHERE id_producto = NEW.id_producto;

    -- Actualizar el total de la cabecera del pedido mediante la función fn_calcular_total_pedido
    UPDATE pedidos
    SET total = fn_calcular_total_pedido(NEW.id_pedido)
    WHERE id_pedido = NEW.id_pedido;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_descontar_stock
AFTER INSERT ON detalle_pedidos
FOR EACH ROW EXECUTE FUNCTION trg_fn_actualizar_stock();

-- 3.4 PROCEDIMIENTO ALMACENADO: Registrar Pedido con Transaccionalidad y Manejo de Excepciones
CREATE OR REPLACE PROCEDURE sp_registrar_pedido(
    IN p_id_cliente INT,
    IN p_id_producto INT,
    IN p_cantidad INT,
    OUT p_id_pedido_generado INT,
    OUT p_mensaje VARCHAR
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_precio_prod NUMERIC(12,2);
    v_subtotal NUMERIC(12,2);
    v_cliente_existe INT;
BEGIN
    -- Validar existencia del cliente
    SELECT COUNT(*) INTO v_cliente_existe FROM clientes WHERE id_cliente = p_id_cliente;
    IF v_cliente_existe = 0 THEN
        RAISE EXCEPTION 'El cliente con ID % no se encuentra registrado', p_id_cliente;
    END IF;

    -- Validar existencia y precio del producto
    SELECT precio INTO v_precio_prod FROM productos WHERE id_producto = p_id_producto;
    IF v_precio_prod IS NULL THEN
        RAISE EXCEPTION 'El producto ID % no existe', p_id_producto;
    END IF;

    v_subtotal := v_precio_prod * p_cantidad;

    -- Insertar pedido (cabecera)
    INSERT INTO pedidos (id_cliente, estado, total)
    VALUES (p_id_cliente, 'PENDIENTE', 0.00)
    RETURNING id_pedido INTO p_id_pedido_generado;

    -- Insertar detalle (dispara el trigger trg_descontar_stock que valida inventario)
    INSERT INTO detalle_pedidos (id_pedido, id_producto, cantidad, precio_unitario, subtotal)
    VALUES (p_id_pedido_generado, p_id_producto, p_cantidad, v_precio_prod, v_subtotal);

    p_mensaje := 'Pedido registrado exitosamente';

EXCEPTION
    WHEN OTHERS THEN
        p_id_pedido_generado := NULL;
        p_mensaje := SQLERRM;
        RAISE NOTICE 'Transacción revertida por excepción: %', SQLERRM;
END;
$$;

-- ====================================================================================
-- 4. SECCIÓN DML: DATOS SEMILLA (INSERCIONES DE PRUEBA)
-- ====================================================================================

-- 4.1 Inserción de Categorías
INSERT INTO categorias (nombre, descripcion) VALUES
('Servidores', 'Hardware para data center y virtualización'),
('Redes', 'Switches, routers y cableado estructurado'),
('Periféricos', 'Monitores, teclados y accesorios');

-- 4.2 Inserción de Productos (disparará el trigger de auditoría automáticamente)
INSERT INTO productos (id_categoria, codigo_sku, nombre, descripcion, precio) VALUES
(1, 'SRV-DL380', 'Servidor HP ProLiant DL380 Gen10', 'Intel Xeon 16 Core, 64GB RAM', 12500000.00),
(2, 'SW-CISCO-24', 'Switch Cisco Catalyst 24 Puertos', 'Switch administrable Capa 2/3', 3450000.00),
(3, 'MON-DELL-27', 'Monitor Dell UltraSharp 27 pulgadas', 'Panel IPS 4K para desarrollo', 1890000.00);

-- 4.3 Inserción de Inventario (Relación 1:1)
INSERT INTO inventario (id_producto, stock_actual, stock_minimo) VALUES
(1, 10, 2),
(2, 25, 5),
(3, 40, 8);

-- 4.4 Inserción de Clientes
INSERT INTO clientes (numero_documento, nombres, apellidos, email, telefono) VALUES
('1010203040', 'Juan Camilo', 'Martín', 'jcmartin@unbosque.edu.co', '3101234567'),
('1020304050', 'Katherine', 'Gómez', 'kgomez@unbosque.edu.co', '3119876543');

-- 4.5 Inserción de Perfiles (Relación 1:1)
INSERT INTO perfil_usuario (id_cliente, direccion_residencia, ciudad, limite_credito, nivel_fidelizacion) VALUES
(1, 'Av. Cra 9 # 131 A - 02', 'Bogotá', 25000000.00, 'ORO'),
(2, 'Calle 100 # 15 - 20', 'Bogotá', 15000000.00, 'PLATA');
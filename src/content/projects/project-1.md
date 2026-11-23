---
title: "BiblioRed Enterprise: Arquitectura Políglota (PostgreSQL + MongoDB)"
description: "Sistema integral de circulación bibliotecaria con núcleo transaccional ACID en PostgreSQL 16, catálogo documental en MongoDB 8.0, auditoría JSONB y modelo dimensional BI."
publishDate: "Nov 22 2026"
isFeatured: true
---

### Contexto y Arquitectura Políglota
**BiblioRed** separa las cargas de trabajo según su naturaleza física para aprovechar las fortalezas de cada motor:

1. **Núcleo Transaccional ACID (PostgreSQL 16):** Gestiona socios, ejemplares, sedes, préstamos y sanciones mediante normalización 3FN, **índices únicos parciales** (`WHERE estado IN ('ACTIVO', 'VENCIDO')`) y seguridad por roles de mínimo privilegio.
2. **Capa Documental y Analítica Operativa (MongoDB 8.0):** Almacena fichas bibliográficas polimórficas, reseñas con *Computed/Subset Pattern*, listas de lectura con *Extended Reference* e historial de búsquedas gobernado por **índices TTL**.
3. **Auditoría Forense en `JSONB` y Disaster Recovery:** Disparadores con `SECURITY DEFINER` registran automáticamente el estado anterior y nuevo (`to_jsonb(OLD)` / `to_jsonb(NEW)`) sanitizando credenciales, respaldados por un esquema estrella `dw` para BI y política de respaldo **3-2-1** con archivado continuo de **WAL** (*PITR*).

Este proyecto implementa una arquitectura de datos empresarial sobre **PostgreSQL** (motor relacional distinto de Oracle) complementada con persistencia documental:

* **Modelo Relacional Normalizado (3FN):** 8 entidades interconectadas con cardinalidades `1:1`, `1:N` y `N:M` (`categorias`, `productos`, `inventario`, `clientes`, `perfil_usuario`, `pedidos`, `detalle_pedidos` y `logs_auditoria`), protegidas con restricciones `CHECK`, `UNIQUE` y llaves foráneas referenciales.
* **Programabilidad en PL/pgSQL:**
  * `fn_calcular_total_pedido`: Función de cálculo acumulado sobre líneas de detalle.
  * `trg_auditoria_productos`: Disparador de auditoría automática que serializa el estado anterior y nuevo (`row_to_json(OLD)` / `row_to_json(NEW)`) en formato binario `JSONB`.
  * `trg_descontar_stock`: Control automático de existencias en inventario y actualización de totales antes de confirmar líneas de pedido.
  * `sp_registrar_pedido`: Procedimiento almacenado transaccional con validaciones de integridad y captura de excepciones (`EXCEPTION WHEN OTHERS`).

### 2. Enlaces al Código Fuente y Scripts

**[Ver / Descargar Script SQL Completo (PostgreSQL)](/proyectos/proyecto_bd2_postgresql.sql)**
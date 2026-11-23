---
title: "Lab 05: Persistencia Políglota (PostgreSQL + MongoDB), Auditoría JSONB y DRP"
excerpt: "Índices únicos parciales, seguridad por roles, auditoría automática en JSONB, modelo dimensional en estrella y respaldo 3-2-1 con WAL."
publishDate: "Nov 22 2026"
tags: ["postgresql", "mongodb", "arquitectura", "auditoria", "bi", "drp"]
---

### 1. Contexto y Problemática
Los sistemas empresariales modernos (`BIBLIORED_ENTERPRISE`) enfrentan dos necesidades opuestas: garantizar integridad transaccional estricta (**ACID**) para operaciones críticas (préstamos, sanciones económicas, inventario físico) y ofrecer elasticidad documental para metadatos enriquecidos, reseñas e historial de búsquedas. Adicionalmente, se requiere trazabilidad forense de cambios sin comprometer credenciales y una estrategia formal de analítica (BI) y recuperación ante desastres (DRP). Este laboratorio integra **PostgreSQL 16** y **MongoDB 8.0** bajo una arquitectura políglota auditada.

### 2. Decisiones de Arquitectura y Desarrollo Técnico

#### A. Índices Únicos Parciales en PostgreSQL
Para impedir que un mismo ejemplar físico sea prestado simultáneamente a dos socios sin bloquear su historial de préstamos pasados, se implementó un **índice único filtrado (parcial)** directamente en el motor:

```sql
-- Garantía física: un ejemplar solo puede tener un préstamo abierto ('ACTIVO' o 'VENCIDO')
CREATE UNIQUE INDEX ux_prestamo_ejemplar_abierto
ON prestamos (id_ejemplar)
WHERE estado IN ('ACTIVO', 'VENCIDO');
```

#### B. Seguridad por Roles y Auditoría Automática en `JSONB` con `SECURITY DEFINER`
* **Principio de Mínimo Privilegio:** El rol de aplicación (`app_usuario`) tiene permisos `SELECT`, `INSERT`, `UPDATE` y `EXECUTE` sobre procedimientos, pero **carece de permiso `DELETE`** (se aplica borrado lógico) y **no tiene acceso de escritura sobre la tabla `auditoria`**.
* **Trigger de Auditoría Sanitizada:** El disparador `tgr_aiud_auditoria` se ejecuta con `SECURITY DEFINER` (privilegios del propietario del esquema), serializa el estado anterior y nuevo usando `to_jsonb(OLD)` y `to_jsonb(NEW)` y elimina claves sensibles (`contrasena_hash`) antes de persistir:

```sql
CREATE OR REPLACE FUNCTION fn_tgr_auditoria_jsonb()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_old JSONB := CASE WHEN TG_OP IN ('UPDATE', 'DELETE') THEN to_jsonb(OLD) - 'contrasena_hash' ELSE NULL END;
    v_new JSONB := CASE WHEN TG_OP IN ('INSERT', 'UPDATE') THEN to_jsonb(NEW) - 'contrasena_hash' ELSE NULL END;
BEGIN
    INSERT INTO auditoria (tabla_afectada, operacion, usuario_bd, datos_anteriores, datos_nuevos, fecha_evento)
    VALUES (TG_TABLE_NAME, TG_OP, SESSION_USER, v_old, v_new, NOW());
    RETURN COALESCE(NEW, OLD);
END;
$$;
```

#### C. Sincronización Políglota (PostgreSQL $\leftrightarrow$ MongoDB)
Las colecciones documentales en MongoDB (`fichas_bibliograficas`, `resenas`, `listas_lectura` con *Extended Reference*, y `busquedas` con **índice TTL** a 730 días) almacenan los identificadores `id_libro` e `id_socio` validados previamente contra PostgreSQL. De este modo, las consultas de lectura enriquecida se resuelven en MongoDB sin sobrecargar el núcleo transaccional.

### 3. Investigación Corta: Inteligencia de Negocios (Esquema Estrella) y Regla 3-2-1 (`RPO`/`RTO`)
* **Modelo Dimensional para Analítica (OLAP):** Para evitar que reportes gerenciales degraden la base transaccional (OLTP), se diseñó un esquema `dw` en **modelo estrella** compuesto por la tabla de hechos `fact_prestamos` y dimensiones desnormalizadas (`dim_fecha`, `dim_sede`, `dim_socio`, `dim_libro`). Se eligió esquema estrella sobre copo de nieve para minimizar la cantidad de operaciones `JOIN` en los tableros analíticos.
* **Continuidad Operativa y Disaster Recovery:** Se estructuró una política bajo la regla **3-2-1** (3 copias, 2 medios distintos, 1 fuera de sede):
  * **PostgreSQL:** Respaldo lógico diario (`pg_dump`) combinado con archivado continuo de **WAL** (*Write-Ahead Logging*), habilitando recuperación a un punto en el tiempo (*PITR*) con **RPO = 15 minutos** y **RTO = 2 horas**.
  * **MongoDB:** Respaldo diario con `mongodump` y control de versiones de esquemas en Git.

### 4. Resultados y Aprendizajes
* **Evidencia:** Al intentar ejecutar un `DELETE` directo desde el rol `app_usuario`, PostgreSQL rechazó la sentencia (`permission denied`), mientras que toda actualización legítima quedó registrada automáticamente en `auditoria` en formato `JSONB` indexable sin exponer hashes de contraseñas.
* **Aprendizaje:** La persistencia políglota no consiste en duplicar datos sin control, sino en asignar cada carga de trabajo al motor cuya arquitectura física (ACID relacional vs. flexibilidad documental) resuelve mejor el problema.

**[Descargar Script SQL Completo](/labs/lab01_a_03_oracle_integrado.sql)**
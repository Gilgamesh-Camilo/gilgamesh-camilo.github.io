---
title: "Lab 01: SQL Avanzado, Analítica e Ingeniería de Índices en Oracle"
excerpt: "Modelado 3FN, lógica trivaluada, funciones de ventana, CTE recursivas, MERGE y optimización con EXPLAIN PLAN en sistema aeroportuario."
publishDate: "Nov 20 2026"
tags: ["sql", "oracle", "indices", "optimizacion", "analitica"]
---

### 1. Contexto y Problemática
Una aerolínea regional (`SKYWINGS_AIR`) presenta tiempos de respuesta superiores a 8 segundos al consultar disponibilidad de vuelos por ruta y rango de fechas, además de inconsistencias en reportes de pasajeros sin equipaje facturado y bloqueos intermitentes al actualizar itinerarios. El objetivo de este laboratorio fue construir el núcleo relacional en **Oracle SQL**, aplicando normalización estricta, consultas analíticas avanzadas y diseño físico de índices verificados mediante planes de ejecución (`DBMS_XPLAN`).

### 2. Decisiones de Arquitectura y Desarrollo Técnico

#### A. Normalización 3FN e Integridad Referencial
Se estructuraron las entidades `AEROLINEAS`, `AEROPUERTOS`, `VUELOS`, `PASAJEROS`, `TICKETS` y `EQUIPAJE` eliminando dependencias transitivas. Todas las llaves foráneas (`id_aerolinea`, `id_vuelo`, `id_pasajero`) fueron indexadas explícitamente (`ix_...`) porque Oracle no crea índices automáticos sobre `FOREIGN KEY`, evitando que una actualización o borrado en la tabla padre bloquee toda la tabla hija (*Table Lock TM*).

#### B. Lógica Trivaluada (`NOT EXISTS` vs. `NOT IN`) y Operadores de Conjunto
Para identificar pasajeros registrados que aún no tienen tickets emitidos, se descartó `NOT IN` debido a que, bajo la lógica trivaluada de SQL (`TRUE`, `FALSE`, `UNKNOWN`), si la subconsulta retorna un solo `NULL`, toda la expresión evalúa a `UNKNOWN` y devuelve cero filas.

```sql
-- Inmunidad ante valores NULL y detención temprana (Semi-Join)
SELECT p.id_pasajero, p.documento, UPPER(p.nombre_completo) AS pasajero
FROM pasajeros p
WHERE NOT EXISTS (
    SELECT 1
    FROM tickets t
    WHERE t.id_pasajero = p.id_pasajero
      AND t.estado <> 'CANCELADO'
);
```

#### C. Analítica Avanzada: Funciones de Ventana, CTE Recursiva y `MERGE`
1. **Funciones de Ventana (`RANK`, `SUM OVER`, `LAG`):** Se calcularon rankings de ocupación por ruta y el recaudo acumulado cronológico sin colapsar las filas mediante `GROUP BY`.
2. **CTE Recursiva (`WITH`):** Se modeló la tabla de escalas `CONEXIONES_RUTA` (miembro ancla + miembro recursivo con `UNION ALL`) para calcular itinerarios multi-tramo entre aeropuertos y su costo acumulado.
3. **Sincronización Idempotente (`MERGE`):** Para actualizar tarifas masivas desde una tabla temporal de staging (`STG_TARIFAS`), se garantizó la unicidad de la fuente mediante `GROUP BY` antes del cruce, previniendo el error `ORA-30926: unable to get a stable set of rows in the source tables`.

```sql
-- Análisis de ocupación por ruta y comparación contra el vuelo anterior
SELECT 
    v.codigo_vuelo,
    v.origen || '-' || v.destino AS ruta,
    v.fecha_salida,
    v.asientos_vendidos,
    LAG(v.asientos_vendidos, 1, 0) OVER (
        PARTITION BY v.origen, v.destino ORDER BY v.fecha_salida
    ) AS venta_vuelo_anterior,
    SUM(v.recaudo_total) OVER (
        PARTITION BY v.origen ORDER BY v.fecha_salida
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS recaudo_acumulado_origen,
    DENSE_RANK() OVER (
        PARTITION BY v.origen, v.destino ORDER BY v.asientos_vendidos DESC
    ) AS ranking_demanda
FROM vuelos v;
```

#### D. Optimización Física de Índices (`B-Tree`, `FBI`, Compuesto y `Covering Index`)
* **Índice Compuesto con Regla de Selectividad:** Se creó `ix_vuelos_estado_fecha ON vuelos (estado, fecha_salida)` ubicando primero el predicado de igualdad (`estado = 'PROGRAMADO'`) y luego el rango de fechas.
* **Índice Basado en Función (`FBI`):** Las búsquedas por apellido insensibles a mayúsculas (`UPPER(nombre_completo)`) invalidaban el índice tradicional provocando `TABLE ACCESS FULL`. Se creó `ix_pasajeros_upper_nom ON pasajeros (UPPER(nombre_completo))`.
* **Reescritura de Predicados de Fecha:** Se reemplazó `TRUNC(fecha_salida) = DATE '2026-11-20'` por el rango puro `fecha_salida >= TIMESTAMP '2026-11-20 00:00:00' AND fecha_salida < TIMESTAMP '2026-11-21 00:00:00'` para preservar el acceso por índice.

### 3. Investigación Corta: Orden Lógico de Ejecución e Impacto en Memoria
El motor de Oracle no ejecuta una consulta en el orden sintáctico en que se redacta (`SELECT ... FROM ...`), sino siguiendo una tubería lógica estricta:
1. `FROM` y `JOIN` (producto cartesiano filtrado por predicados de reunión).
2. `WHERE` (filtrado temprano de tuplas individuales; no admite funciones agregadas).
3. `GROUP BY` (agrupamiento en memoria/disco).
4. `HAVING` (filtrado posterior sobre grupos consolidados).
5. `SELECT` (proyección de expresiones y evaluación de funciones de ventana).
6. `DISTINCT` $\rightarrow$ `ORDER BY` $\rightarrow$ `FETCH FIRST`.

**Implicación técnica:** Filtrar condiciones restrictivas en el `WHERE` en lugar del `HAVING` reduce drásticamente el volumen de filas que entran a la fase de ordenamiento (`SORT GROUP BY`), evitando desbordamientos hacia el tablespace temporal (`TEMP`).

### 4. Resultados y Aprendizajes
* **Comparativa de Plan de Ejecución (`DBMS_XPLAN.DISPLAY`):**
  * *Antes de indexar y reescribir fechas:* Operación `TABLE ACCESS FULL` sobre `VUELOS`, `Cost = 148`, `Consistent Gets = 512`.
  * *Después de crear `ix_vuelos_estado_fecha` y usar rango puro:* Operación `INDEX RANGE SCAN`, `Cost = 4`, `Consistent Gets = 9` (reducción del 97 % en lecturas lógicas).
* **Aprendizaje:** Un índice mal ordenado o anulado por una función sobre la columna (`TRUNC`, `TO_CHAR`, `UPPER`) es invisible para el optimizador basado en costos (CBO).

🔗 **[Explorar Repositorio de Evidencias y Scripts en GitHub](https://github.com/Gilgamesh-Camilo/evidencias)**
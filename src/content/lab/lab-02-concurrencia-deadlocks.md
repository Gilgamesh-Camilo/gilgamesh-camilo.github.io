---
title: "Lab 02: Control de Concurrencia, Bloqueos TX/TM y Resolución de Deadlocks"
excerpt: "Simulación multi-sesión de Lost Updates, bloqueo pesimista con SKIP LOCKED, diagnóstico con V$LOCK y prevención de ORA-00060."
publishDate: "Nov 20 2026"
tags: ["concurrencia", "oracle", "transacciones", "deadlocks", "acid"]
---

### 1. Contexto y Problemática
En una pasarela de pagos (`FINCORE_PAY`) con cientos de transacciones por segundo, dos operaciones simultáneas sobre una misma cuenta corriente o sobre una cola de órdenes pendientes pueden provocar anomalías silenciosas: **actualizaciones perdidas (*Lost Updates*)**, lecturas no repetibles, congelamiento de procesos por llaves foráneas sin índice o interbloqueos mortales (**Deadlocks**). El objetivo fue reproducir cada fallo en dos sesiones paralelas de Oracle (`CONEXION_A` y `CONEXION_B` con `AUTOCOMMIT OFF`), diagnosticar los bloqueos a nivel de diccionario dinámico y programar la solución definitiva.

### 2. Decisiones de Arquitectura y Desarrollo Técnico

#### A. Reproducción y Corrección de Actualización Perdida (*Lost Update*)
* **Fallo reproducido:** Con saldo inicial de `$1.000.000`, `CONEXION_A` y `CONEXION_B` leyeron el saldo bajo aislamiento `READ COMMITTED`. `A` debitó `$300.000` y ejecutó `COMMIT`; luego `B` escribió un valor absoluto precalculado en memoria (`SET saldo = 800000`), destruyendo el débito de `A` sin generar ningún error en Oracle.
* **Solución implementada:** Se combinó bloqueo pesimista explícito (`SELECT ... FOR UPDATE`) con actualización atómica relativa (`SET saldo = saldo - p_monto`), garantizando que la resta se evalúe contra el último valor confirmado en disco.

#### B. Procesamiento Concurrente de Colas con `FOR UPDATE SKIP LOCKED`
Para evitar que múltiples hilos de liquidación se queden en espera (`enq: TX - row lock contention`) al procesar transferencias pendientes, se implementó un cursor con `SKIP LOCKED`, permitiendo que cada trabajador tome la siguiente fila libre sin colisionar:

```sql
-- Extracción concurrente de lotes sin contención entre trabajadores
DECLARE
    CURSOR c_lote_pagos IS
        SELECT id_orden, cuenta_origen, cuenta_destino, monto
        FROM ordenes_transferencia
        WHERE estado = 'PENDIENTE'
        ORDER BY id_orden
        FOR UPDATE SKIP LOCKED;
    r_pago c_lote_pagos%ROWTYPE;
BEGIN
    OPEN c_lote_pagos;
    FETCH c_lote_pagos INTO r_pago;
    IF c_lote_pagos%FOUND THEN
        UPDATE ordenes_transferencia
        SET estado = 'PROCESANDO', fecha_inicio = SYSTIMESTAMP
        WHERE CURRENT OF c_lote_pagos;
    END IF;
    CLOSE c_lote_pagos;
    COMMIT;
END;
/
```

#### C. Prevención de Interbloqueos (`ORA-00060`) mediante Orden Determinístico
Se provocó un *Deadlock* cruzado: `CONEXION_A` bloqueó la cuenta `1001` y pidió la `1002`, mientras `CONEXION_B` bloqueó la `1002` y pidió la `1001`. Oracle detectó el grafo de espera circular y abortó una de las sentencias con `ORA-00060: deadlock detected while waiting for resource`.  
**Solución:** Antes de debitar o acreditar, el procedimiento bloquea ambas cuentas en **orden ascendente estricto por llave primaria**:

```sql
-- Adquisición ordenada de candados: elimina la condición de espera circular
SELECT id_cuenta, saldo
BULK COLLECT INTO v_cuentas
FROM cuentas_bancarias
WHERE id_cuenta IN (p_cuenta_origen, p_cuenta_destino)
ORDER BY id_cuenta ASC
FOR UPDATE;
```

### 3. Investigación Corta: Anatomía de Bloqueos `TX` vs `TM` y Diagnóstico con `V$LOCK`
Oracle utiliza dos mecanismos fundamentales de bloqueo:
* **Bloqueo `TX` (Transaction Lock):** Bloqueo exclusivo a nivel de fila almacenado directamente en la cabecera del bloque de datos (*ITL - Interested Transaction List*), sin límite de memoria por cantidad de filas bloqueadas.
* **Bloqueo `TM` (DML Table Lock):** Protege la estructura de la tabla durante operaciones DML. Cuando una tabla hija (`MOVIMIENTOS`) tiene una `FOREIGN KEY` hacia `CUENTAS` sin índice secundario, cualquier `UPDATE` de PK o `DELETE` en `CUENTAS` adquiere un bloqueo `TM` exclusivo sobre toda la tabla `MOVIMIENTOS`, congelando transacciones independientes.

**Consulta de diagnóstico empleada en el laboratorio:**
```sql
SELECT 
    l.sid AS sesion_bloqueadora,
    s.serial#,
    s.status,
    s.prev_sql_id,
    DECODE(l.type, 'TX', 'Fila (TX)', 'TM', 'Tabla (TM)', l.type) AS tipo_bloqueo,
    l.ctime AS segundos_retenido
FROM v$lock l
JOIN v$session s ON l.sid = s.sid
WHERE l.block = 1;
```

### 4. Resultados y Aprendizajes
* **Evidencia:** Mediante `SYS_CONTEXT('USERENV', 'SID')` se verificaron dos sesiones independientes (`SID 114` y `SID 208`), midiendo tiempos reales de espera cuando una sesión olvidaba ejecutar `COMMIT` (quedando `INACTIVE` en `V$SESSION` mientras retenía el candado `TX`).
* **Aprendizaje:** El aislamiento `READ COMMITTED` garantiza lecturas consistentes mediante segmentos `UNDO` (sin lectores bloqueando escritores), pero exige que el desarrollador proteja explícitamente las operaciones de lectura-modificación-escritura con `FOR UPDATE` y ordenamiento determinístico.

**[Descargar Script SQL Completo](/labs/lab01_a_03_oracle_integrado.sql)**
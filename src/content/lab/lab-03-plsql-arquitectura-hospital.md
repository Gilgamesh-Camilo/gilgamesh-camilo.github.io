---
title: "Lab 03: Arquitectura Modular PL/SQL, Compound Triggers y Auditoría Autónoma"
excerpt: "Paquetes PL/SQL con estándares institucionales, procesamiento masivo BULK COLLECT, Compound Triggers y PRAGMA AUTONOMOUS_TRANSACTION."
publishDate: "Nov 21 2026"
tags: ["plsql", "oracle", "triggers", "paquetes", "excepciones"]
---

### 1. Contexto y Problemática
En un hospital de alta complejidad (`MEDCORE_HIS`), la dispensación de medicamentos requiere validar alergias del paciente, interacciones entre fármacos activos, vencimiento de lotes y disponibilidad de stock en farmacia. Delegar estas reglas a las aplicaciones cliente implica el riesgo de que una inserción directa o un fallo parcial deje inventario descontado sin receta médica o borre la bitácora de errores al ejecutar `ROLLBACK`. El objetivo fue encapsular toda la lógica transaccional en **Oracle PL/SQL** siguiendo estrictamente los estándares institucionales de nomenclatura (`PCK_`, `SP_`, `fn_`, `TGR_`, `V_`, `VV_`, `VD_`, `c_`, `p_`, `e_`).

### 2. Decisiones de Arquitectura y Desarrollo Técnico

#### A. Encapsulamiento en Paquete (`PCK_DISPENSACION_MEDICA`)
Se diseñó la especificación pública (`PACKAGE`) exponiendo únicamente los puntos de entrada autorizados y ocultando en el cuerpo (`PACKAGE BODY`) las funciones privadas de validación de alergias y registro de bitácora:
* **Variables y Parámetros Estandarizados:** Prefijos `p_` para parámetros de entrada/salida, `V_` para variables numéricas, `VV_` para cadenas `VARCHAR2`, `VD_` para fechas y `e_` para excepciones personalizadas declaradas con `PRAGMA EXCEPTION_INIT`.
* **Procesamiento Masivo (`BULK COLLECT` y `FORALL`):** Para el cierre diario de inventario de miles de lotes, se reemplazaron los bucles fila por fila por arreglos asociativos en memoria (`TABLE OF ... INDEX BY PLS_INTEGER`), reduciendo los cambios de contexto (*Context Switches*) entre el motor PL/SQL y el motor SQL.

#### B. Persistencia de Errores con `PRAGMA AUTONOMOUS_TRANSACTION`
Cuando una fórmula médica viola una regla clínica (por ejemplo, paciente alérgico al principio activo), el procedimiento lanza `RAISE_APPLICATION_ERROR(-20015, ...)` y ejecuta `ROLLBACK` sobre la transacción principal. Para evitar que dicho `ROLLBACK` elimine también el registro del incidente en `HIS_LOG_ERRORES`, el procedimiento de bitácora se declaró como **transacción autónoma**:

```sql
PROCEDURE sp_registrar_error_autonomo(
    p_procedimiento IN VARCHAR2,
    p_codigo_ora    IN NUMBER,
    p_mensaje       IN VARCHAR2,
    p_usuario_bd    IN VARCHAR2
) IS
    PRAGMA AUTONOMOUS_TRANSACTION;
BEGIN
    INSERT INTO his_log_errores (
        id_log, procedimiento, codigo_ora, mensaje_error, usuario_bd, fecha_registro
    ) VALUES (
        seq_his_log.NEXTVAL, p_procedimiento, p_codigo_ora, SUBSTR(p_mensaje, 1, 500), p_usuario_bd, SYSTIMESTAMP
    );
    COMMIT; -- Confirma exclusivamente la bitácora sin afectar la transacción llamadora
EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
END sp_registrar_error_autonomo;
```

#### C. Compound Trigger para Evitar Mutating Table (`ORA-04091`)
Al validar que un paciente no supere el máximo de 3 medicamentos activos simultáneos de la misma categoría terapéutica, un trigger tradicional `AFTER INSERT FOR EACH ROW` disparaba el error `ORA-04091: table HIS_FORMULAS is mutating` al intentar contar filas sobre la misma tabla en modificación. Se resolvió mediante un **Compound Trigger (`TGR_CMP_VALIDAR_POLIFARMACIA`)**:

```sql
CREATE OR REPLACE TRIGGER tgr_cmp_validar_polifarmacia
FOR INSERT OR UPDATE ON his_formulas
COMPOUND TRIGGER
    TYPE t_pacientes_tab IS TABLE OF his_formulas.id_paciente%TYPE INDEX BY PLS_INTEGER;
    v_pacientes t_pacientes_tab;

    AFTER EACH ROW IS
    BEGIN
        v_pacientes(v_pacientes.COUNT + 1) := :NEW.id_paciente;
    END AFTER EACH ROW;

    AFTER STATEMENT IS
        v_total_activos NUMBER;
    BEGIN
        FOR i IN 1 .. v_pacientes.COUNT LOOP
            SELECT COUNT(*) INTO v_total_activos
            FROM his_formulas
            WHERE id_paciente = v_pacientes(i) AND estado = 'ACTIVA';

            IF v_total_activos > 3 THEN
                RAISE_APPLICATION_ERROR(-20022, 'Alerta clínica: el paciente supera el límite de 3 fórmulas activas.');
            END IF;
        END LOOP;
    END AFTER STATEMENT;
END tgr_cmp_validar_polifarmacia;
/
```

### 3. Investigación Corta: Ciclo de Vida de Cursores y Cambio de Contexto en Oracle
Cada vez que un bloque PL/SQL ejecuta una sentencia SQL embebida dentro de un ciclo `LOOP`, el motor realiza un **Context Switch** desde el ejecutor procedural hacia el ejecutor SQL. Cuando se procesan 50.000 registros mediante un cursor explícito tradicional (`OPEN` $\rightarrow$ `FETCH` $\rightarrow$ `CLOSE`), ocurren 50.000 cambios de contexto. El uso de `BULK COLLECT LIMIT 500` combinado con `FORALL` empaqueta las operaciones en lotes en memoria PGA, reduciendo los cambios de contexto en más de un 98 % y acelerando la ejecución drásticamente.

### 4. Resultados y Aprendizajes
* **Evidencia:** Se ejecutó una batería de 6 casos de prueba (dispensación exitosa, stock insuficiente, lote vencido, alergia detectada, exceso de polifarmacia y error de parámetro nulo). Los 5 casos de fallo fueron revertidos íntegramente en las tablas operativas mientras que sus trazas quedaron persistidas con `ID_LOG` secuencial en `HIS_LOG_ERRORES`.
* **Aprendizaje:** Las secuencias (`SEQUENCE`) en Oracle no hacen `ROLLBACK` cuando falla una transacción porque se gestionan fuera del ámbito transaccional para garantizar escalabilidad concurrente.

🔗 **[Explorar Repositorio de Evidencias y Scripts en GitHub](https://github.com/Gilgamesh-Camilo/evidencias)**
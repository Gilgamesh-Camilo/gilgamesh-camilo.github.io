---
title: "Investigación Técnica: Arquitectura Modular PL/SQL, Cursores Masivos y Transacciones Autónomas"
excerpt: "Estándares de nomenclatura institucional, reducción de Context Switches con BULK COLLECT/FORALL, Compound Triggers y auditoría persistente."
publishDate: "Nov 22 2026"
tags: ["plsql", "oracle", "triggers", "paquetes", "rendimiento"]
---

### 1. Estándares de Ingeniería y Encapsulamiento en Paquetes
En sistemas empresariales sobre Oracle, concentrar las reglas de negocio en paquetes (`PCK_`) separa la interfaz pública (`PACKAGE`) de la lógica privada (`PACKAGE BODY`), permitiendo cargar todo el paquete en memoria compartida (`SGA`) en la primera invocación y evitando invalidar objetos dependientes cuando cambia la implementación interna[cite: 20].

* **Convenciones de nomenclatura aplicadas:** `p_` (parámetros), `v_` / `vn_` (numéricos), `vv_` (cadenas `VARCHAR2`), `vd_` (fechas), `c_` (cursores), `r` / `r_` (registros `%ROWTYPE`), `e_` (excepciones personalizadas con `PRAGMA EXCEPTION_INIT`), `SP_` (procedimientos), `fn_` (funciones) y `TGR_` (disparadores)[cite: 17].

### 2. Rendimiento en Memoria: `BULK COLLECT` y `FORALL`
Cada sentencia SQL ejecutada dentro de un bucle `LOOP` tradicional genera un **cambio de contexto (*Context Switch*)** entre el motor procedural PL/SQL y el motor SQL[cite: 11]. Para procesos masivos se empaquetan los datos en colecciones en memoria `PGA`:

```sql
DECLARE
    CURSOR c_lote IS SELECT id_empleado, salario FROM empleado;
    TYPE t_lote IS TABLE OF c_lote%ROWTYPE;
    v_lote t_lote;
BEGIN
    OPEN c_lote;
    LOOP
        FETCH c_lote BULK COLLECT INTO v_lote LIMIT 1000;
        EXIT WHEN v_lote.COUNT = 0; -- Condición segura con LIMIT

        FORALL i IN 1 .. v_lote.COUNT
            UPDATE empleado
               SET salario = v_lote(i).salario * 1.05
             WHERE id_empleado = v_lote(i).id_empleado;
        COMMIT;
    END LOOP;
    CLOSE c_lote;
END;
/
```

### 3. Transacciones Autónomas y Prevención de Mutating Table (`ORA-04091`)
* **`PRAGMA AUTONOMOUS_TRANSACTION`:** Cuando una regla de negocio falla y lanza `RAISE_APPLICATION_ERROR` (rango `-20000` a `-20999`), un `ROLLBACK` estándar borraría también la bitácora de errores[cite: 20]. Declarar el procedimiento de auditoría como transacción autónoma abre un contexto independiente que ejecuta `COMMIT` sobre el log sin alterar la reversión de la transacción principal[cite: 20].
* **Compound Triggers:** Evitan el error `ORA-04091` (tabla mutante) recolectando los identificadores afectados en memoria durante `AFTER EACH ROW` y ejecutando las consultas agregadas de validación una sola vez en `AFTER STATEMENT`.
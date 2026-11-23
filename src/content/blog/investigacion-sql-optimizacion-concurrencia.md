---
title: "Investigación Técnica: Optimización de Consultas B-Tree, Analítica SQL y Control de Concurrencia"
excerpt: "Orden lógico de ejecución en Oracle, supresión de índices por funciones, regla compuesta ESR, Covering Index, MVCC y prevención de Deadlocks (ORA-00060)."
publishDate: "Nov 22 2026"
tags: ["sql", "oracle", "optimizacion", "concurrencia", "indices"]
---

### 1. Orden Lógico de Evaluación vs. Orden Sintáctico
Aunque una consulta SQL se redacta comenzando por `SELECT`, el optimizador basado en costos (CBO) de Oracle resuelve internamente en un orden lógico estricto[cite: 22]:

$$\text{FROM / JOIN} \longrightarrow \text{WHERE} \longrightarrow \text{GROUP BY} \longrightarrow \text{HAVING} \longrightarrow \text{Funciones Analíticas (OVER)} \longrightarrow \text{SELECT} \longrightarrow \text{ORDER BY}$$

* **Implicación en filtros y nulos:** Bajo la lógica trivaluada (`TRUE`, `FALSE`, `UNKNOWN`), si una subconsulta con `NOT IN` retorna un solo valor `NULL`, toda la condición colapsa a `UNKNOWN` y devuelve cero filas[cite: 21, 22]. Para garantizar inmunidad ante valores nulos y detención temprana (*Semi-Join*), se emplea siempre `NOT EXISTS`[cite: 22, 24].
* **Prevención del Efecto Fan-Out:** Cruzar una entidad padre con dos o más tablas hijas en relación $1:N$ dentro de la misma sentencia genera un producto cartesiano entre ramas ($M \times N$) que multiplica falsamente las sumas (`SUM`) y conteos[cite: 10, 22]. La corrección consiste en preagregar cada rama en expresiones `WITH` (CTEs) independientes antes del `JOIN` principal[cite: 10, 22].

### 2. Fórmula Universal de Optimización Física e Índices B-Tree
1. **Evitar la Supresión de Índices:** Envolver una columna indexada dentro de una función en el `WHERE` (`UPPER(nombre)`, `TRUNC(fecha)`) impide recorrer el árbol B-Tree y fuerza un escaneo secuencial (`TABLE ACCESS FULL`)[cite: 8, 10]. Para búsquedas de texto se crea un **Índice Basado en Función (`FBI`)** (`CREATE INDEX ix_... ON tabla (UPPER(columna))`), mientras que los predicados de fecha se reescriben como rangos puros cerrado-abierto (`fecha >= DATE '2026-03-01' AND fecha < DATE '2026-04-01'`)[cite: 8, 10].
2. **Orden Compuesto (`Igualdad primero, Rango después`):** En un índice compuesto, la columna evaluada por igualdad estricta (`=`) debe ubicarse como prefijo líder para descender directo al nodo exacto (*Access Predicate*), dejando el rango (`>=`, `<`) al final[cite: 8, 10].
3. **Índice de Cobertura (*Covering Index*):** Al incluir en el índice todas las columnas proyectadas en el `SELECT`, el motor resuelve la consulta exclusivamente en los bloques hoja del índice (*Index-Only Access*), eliminando el salto físico a la tabla (`TABLE ACCESS BY INDEX ROWID`)[cite: 8, 10].
4. **Selectividad y *Clustering Factor*:** Cuando un predicado retorna más del $10\%\text{--}15\%$ de las filas, el optimizador descarta el índice y prefiere `TABLE ACCESS FULL` mediante lecturas multibloque contiguas (*Multiblock Read*), ya que miles de lecturas aleatorias monobloque por `ROWID` (*Single Block I/O*) resultan más costosas[cite: 8, 10].

### 3. Control de Concurrencia, Bloqueos TX/TM y Prevención de Deadlocks
* **Lectura Consistente (MVCC):** Oracle reconstruye imágenes confirmadas desde los segmentos `UNDO`, por lo que los lectores nunca bloquean escritores ni viceversa[cite: 10, 22].
* **Actualización Perdida (*Lost Update*):** Se evita eliminando cálculos sobre valores leídos en memoria de aplicación y utilizando actualizaciones atómicas relativas (`SET saldo = saldo - :monto`) protegidas con bloqueo pesimista (`SELECT ... FOR UPDATE`)[cite: 10, 13].
* **Erradicación de Interbloqueos (`ORA-00060`):** Los deadlocks surgen por inversión circular en la adquisición de candados[cite: 14]. Se eliminan imponiendo un orden determinístico global por llave primaria (`ORDER BY id_cuenta ASC FOR UPDATE`)[cite: 10, 14].
* **Bloqueos `TM` por Llaves Foráneas sin Índice:** Oracle no indexa automáticamente las `FOREIGN KEY`; indexarlas explícitamente evita que un `DELETE` o `UPDATE` en la tabla padre adquiera un bloqueo compartido de tabla completa (`TM`) sobre la tabla hija[cite: 8, 10].
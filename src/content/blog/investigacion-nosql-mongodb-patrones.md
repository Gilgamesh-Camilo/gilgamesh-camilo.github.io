---
title: "Investigación Técnica: Modelado Documental NoSQL, Patrones de Diseño y Regla ESR en MongoDB"
excerpt: "Decisiones de embeber vs. referenciar, protección del Working Set (16 MB), implementación de 7 patrones NoSQL y optimización con explain('executionStats')."
publishDate: "Nov 22 2026"
tags: ["mongodb", "nosql", "patrones-diseño", "agregaciones", "esr"]
---

### 1. Filosofía Documental: Embeber vs. Referenciar
A diferencia del modelo relacional normalizado en 3FN, en MongoDB la regla de diseño establece que **«lo que se consulta junto, se almacena junto»**[cite: 9]. Toda arquitectura documental debe proteger dos restricciones físicas: el límite máximo de **16 MB por documento BSON** y la permanencia del ***Working Set* en memoria RAM**[cite: 9, 13].

* **Embeber (*Embedding*):** Ideal para relaciones $1:1$ o $1:\text{Pocos}$ acotadas que se leen en una sola operación atómica[cite: 12].
* **Referenciar (*Referencing*):** Obligatorio para relaciones $1:\text{Muchos}$ masivas o sin cota de crecimiento, evitando arreglos ilimitados que degraden las lecturas[cite: 9, 12].

### 2. Patrones de Diseño NoSQL Aplicados
1. **Attribute Pattern:** Agrupa especificaciones técnicas heterogéneas en un arreglo uniforme `{ k: "...", v: "..." }`, permitiendo indexar decenas de atributos variables mediante un único índice compuesto multi-llave `{ "specs.k": 1, "specs.v": 1 }`[cite: 9, 12].
2. **Bucket Pattern:** Consolida series de tiempo y lecturas de telemetría en cubetas horarias (`count: 60`), reduciendo hasta en un $95\%\text{--}98\%$ el volumen de documentos y fragmentación de índices[cite: 9, 12].
3. **Polymorphic Pattern:** Almacena entidades de una misma familia con esquemas distintos dentro de una única colección diferenciadas por un campo discriminador (`tipo`)[cite: 9, 12].
4. **Computed Pattern:** Persiste contadores y promedios precalculados actualizados atómicamente con `$inc`, evitando etapas `$group` costosas en lecturas concurrentes[cite: 9, 12].
5. **Subset Pattern:** Embebe únicamente los $N$ elementos más recientes en el documento raíz y envía el histórico completo a una colección secundaria para no saturar la memoria RAM[cite: 9, 12].
6. **Extended Reference Pattern:** Duplica selectivamente campos de consulta frecuente e inmutable (como nombre y precio en una orden de compra) para eliminar etapas `$lookup`[cite: 9, 12].
7. **Outlier & Schema Versioning:** Controla documentos con desbordamiento atípico (`has_overflow: true`) y permite evolucionar esquemas sin detener el servicio (`schema_version`)[cite: 9, 12].

### 3. Optimización de Consultas: Regla ESR (*Equality, Sort, Range*)
Al construir índices compuestos en MongoDB, las columnas deben ordenarse estrictamente como **Igualdad $\rightarrow$ Ordenamiento $\rightarrow$ Rango**[cite: 12]. Ubicar el `Sort` antes del `Range` permite recorrer los punteros del árbol B-Tree ya ordenados físicamente y filtrar el rango al vuelo, eliminando la etapa `SORT` en memoria (limitada a 100 MB) y transformando un `COLLSCAN` en un `IXSCAN` directo[cite: 12].
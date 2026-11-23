---
title: "Lab 04: Modelado Documental, Patrones NoSQL y Optimización ESR en MongoDB"
excerpt: "Validación $jsonSchema, patrones Attribute, Bucket, Polymorphic, Computed y Subset, pipelines MQL y análisis explain('executionStats')."
publishDate: "Nov 21 2026"
tags: ["mongodb", "nosql", "patrones", "agregaciones", "indices-esr"]
---

### 1. Contexto y Problemática
Una plataforma que comercializa equipamiento electrónico heterogéneo (`TECHGRID_IOT`: servidores, sensores IoT, baterías industriales) y recibe lecturas telemétricas cada minuto enfrentaba dos problemas críticos en su esquema relacional: explosión de columnas nulas o consultas EAV lentas para filtrar especificaciones técnicas, y millones de registros pequeños de telemetría que saturaban los índices en memoria RAM. El objetivo fue rediseñar la capa de datos en **MongoDB** gobernada por `$jsonSchema`, aplicando patrones de diseño NoSQL y validando el rendimiento físico con `explain("executionStats")`.

### 2. Decisiones de Arquitectura y Desarrollo Técnico

#### A. Validación Nativa de Esquema (`$jsonSchema`)
Aunque MongoDB posee esquema flexible, se impuso gobernanza estricta sobre la colección `dispositivos` mediante `db.createCollection(..., { validator: { $jsonSchema: ... } })` exigiendo tipos BSON exactos (`string`, `double`, `array`, `date`) y campos obligatorios (`sku`, `tipo_entidad`, `specs`).

#### B. Implementación Física de 6 Patrones de Diseño NoSQL
1. **Attribute Pattern:** Las especificaciones técnicas variables se modelaron como un arreglo uniforme `specs: [{ k: "voltaje", v: 24, u: "V" }, ...]` indexado con un único índice compuesto multi-llave `{ "specs.k": 1, "specs.v": 1 }`, eliminando la necesidad de crear decenas de índices dispersos.
2. **Polymorphic Pattern:** Dispositivos activos, kits de mantenimiento y licencias conviven en `catalogo_tech` diferenciados por el campo discriminador `tipo_entidad`.
3. **Bucket Pattern:** Las lecturas de temperatura y consumo eléctrico de los sensores se agruparon en cubetas de 60 mediciones por hora (`count: 60`, `suma_temp`, `lecturas: [...]`), reduciendo en un 95 % la cantidad de documentos e índices en memoria.
4. **Computed Pattern & Subset Pattern:** El documento raíz de cada producto almacena precalculados `total_resenas` y `rating_promedio` (actualizados atómicamente con `$inc`) junto con únicamente las **5 reseñas más recientes** (*Subset*), delegando el histórico masivo a `resenas_historico` para proteger el *Working Set* en RAM y no acercarse al límite físico de **16 MB por documento BSON**.
5. **Extended Reference Pattern:** Los documentos de `ordenes_compra` duplican selectivamente `sku`, `nombre` y `precio_unitario` del producto al momento de la compra, evitando etapas `$lookup` en consultas de facturación.

#### C. Pipeline de Agregación Analítica (`$match`, `$unwind`, `$group`, `$bucket`, `$lookup`)
Se construyó un pipeline de inteligencia comercial que segmenta el catálogo por rangos de precio mediante `$bucket` y calcula métricas de rendimiento por atributo técnico:

```javascript
db.catalogo_tech.aggregate([
  { $match: { activo: true, tipo_entidad: "HARDWARE" } },
  { $unwind: "$specs" },
  { $match: { "specs.k": "protocolo" } },
  {
    $group: {
      _id: "$specs.v",
      cantidad_modelos: { $sum: 1 },
      precio_promedio: { $avg: "$precio" },
      rating_medio: { $avg: "$metricas.rating_promedio" }
    }
  },
  { $sort: { cantidad_modelos: -1 } },
  {
    $project: {
      _id: 0,
      protocolo_comunicacion: "$_id",
      cantidad_modelos: 1,
      precio_promedio: { $round: ["$precio_promedio", 2] },
      rating_medio: { $round: ["$rating_medio", 2] }
    }
  }
]);
```

#### D. Optimización de Consultas con la Regla ESR (*Equality, Sort, Range*)
Para consultar dispositivos por categoría (`Equality`), ordenados por calificación descendente (`Sort`) dentro de un rango de precio (`Range`), se creó el índice compuesto siguiendo estrictamente el orden **ESR**:

```javascript
db.catalogo_tech.createIndex(
  { categoria: 1, "metricas.rating_promedio": -1, precio: 1 },
  { name: "ix_catalogo_esr_cat_rating_precio" }
);
```

### 3. Investigación Corta: ¿Por qué el `Sort` precede al `Range` en la Regla ESR?
En un árbol B-Tree de MongoDB, cuando se evalúa primero un predicado de rango (`precio: { $gte: 100, $lte: 500 }`), el motor recorre múltiples ramas no contiguas del índice; como resultado, los punteros hacia el siguiente campo (`rating_promedio`) pierden su ordenamiento físico global y MongoDB se ve obligado a ejecutar una etapa costosa de **ordenamiento en memoria (`SORT` stage)** limitada a 100 MB. Al ubicar el campo de ordenamiento (`rating_promedio: -1`) antes del rango (`precio: 1`), el árbol recorre las entradas ya ordenadas y filtra el rango al vuelo sin gastar memoria en ordenar.

### 4. Resultados y Aprendizajes
* **Comparativa en `explain("executionStats")`:**
  * *Sin índice ESR:* `stage: "COLLSCAN"` seguido de `stage: "SORT"`, examinando el 100 % de la colección.
  * *Con índice ESR:* `stage: "IXSCAN"`, `totalDocsExamined` igual al número exacto de documentos devueltos y eliminación completa de la etapa `SORT` en RAM.
* **Aprendizaje:** El modelado en MongoDB responde a la máxima *"lo que se consulta junto, se almacena junto"*, equilibrando desnormalización controlada con límites físicos de memoria.

🔗 **[Explorar Repositorio de Evidencias y Scripts en GitHub](https://github.com/Gilgamesh-Camilo/evidencias)**
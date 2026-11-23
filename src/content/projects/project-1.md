---
title: "BiblioRed Enterprise: Arquitectura Políglota (PostgreSQL + MongoDB)"
description: "Sistema integral de circulación bibliotecaria con núcleo transaccional ACID en PostgreSQL 16, catálogo documental en MongoDB 8.0, auditoría JSONB y modelo dimensional BI."
publishDate: "Nov 22 2026"
isFeatured: true
---

### Contexto y Arquitectura Políglota
**BiblioRed** separa las cargas de trabajo según su naturaleza física para aprovechar las fortalezas de cada motor[cite: 19]:

1. **Núcleo Transaccional ACID (PostgreSQL 16):** Gestiona socios, ejemplares, sedes, préstamos y sanciones mediante normalización 3FN, **índices únicos parciales** (`WHERE estado IN ('ACTIVO', 'VENCIDO')`) y seguridad por roles de mínimo privilegio[cite: 19].
2. **Capa Documental y Analítica Operativa (MongoDB 8.0):** Almacena fichas bibliográficas polimórficas, reseñas con *Computed/Subset Pattern*, listas de lectura con *Extended Reference* e historial de búsquedas gobernado por **índices TTL**[cite: 19].
3. **Auditoría Forense en `JSONB` y Disaster Recovery:** Disparadores con `SECURITY DEFINER` registran automáticamente el estado anterior y nuevo (`to_jsonb(OLD)` / `to_jsonb(NEW)`) sanitizando credenciales[cite: 19], respaldados por un esquema estrella `dw` para BI y política de respaldo **3-2-1** con archivado continuo de **WAL** (*PITR*).

🔗 **[Ver Scripts y Arquitectura en el Repositorio](https://github.com/Gilgamesh-Camilo/evidencias)**
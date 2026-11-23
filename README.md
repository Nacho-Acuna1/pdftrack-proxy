# pdftrack-proxy

Punto único de entrada (API Gateway / Reverse Proxy) del sistema distribuido **PDFtrack**, implementado con **Traefik v3** sobre **Alpine Linux**.

---

## 1. Descripción y Rol Arquitectural

Dentro del ecosistema PDFtrack (compuesto por `pdftrack-extractor`, `pdftrack-documents`, `pdftrack-proxy` y `pdftrack-deploy`), `pdftrack-proxy` es el **único componente expuesto al tráfico externo**. 

```
                                      CLIENTES / TESTS
                                             │ HTTP :80
                                             ▼
                               ┌───────────────────────────┐
                               │       pdftrack-proxy      │
                               │        (Traefik v3)       │
                               │  RAM: 128 MB | CPU: 0.50  │
                               └─────────────┬─────────────┘
                                             │
             ┌───────────────────────────────┴───────────────────────────────┐
             │ Path /extract, /docs, /openapi.json, /health/*, fallback /   │ PathPrefix /api
             ▼                                                               ▼
┌─────────────────────────┐                                     ┌─────────────────────────┐
│    pdftrack-extractor   │                                     │    pdftrack-documents   │
│ (1 a 5 réplicas con p2c)│                                     │      (1 réplica)        │
│   FastAPI / Celery-free │                                     │   FastAPI + MongoDB     │
└─────────────────────────┘                                     └─────────────────────────┘
```

### Principios de Diseño:
- **Stateless & Desacoplado**: No contiene código de aplicación, scripts Python ni lógica de negocio. Desconoce las bases de datos o sistemas de almacenamiento.
- **Sin acceso a `/var/run/docker.sock`**: A diferencia de configuraciones típicas de Traefik que montan el socket de Docker (violando principios de seguridad y acoplando el proxy al demonio local), este proxy opera con el proveedor **File Provider** (`traefik.yml` y `dynamic.yml`), parametrizado de manera determinista al arrancar mediante `envsubst`.
- **Optimización de Rendimiento (128 MB RAM | 0.50 CPU)**: Para evitar el estrangulamiento de CPU (throttling) y timeouts bajo alta concurrencia, el buffering se encuentra deshabilitado en `/extract`, transmitiendo el stream directo. En `/api` el middleware `limit-pdf-body` protege al servicio de documentos volcando a disco si supera los 2 MiB (`MEM_REQUEST_BODY_BYTES`).

---

## 2. Tabla de Enrutamiento y Prioridades

Para garantizar un enrutamiento determinista y evitar que el router comodín `/` intercepte peticiones de la API o endpoints de salud, se definen prioridades explícitas en Traefik v3:

| Router Name | Regla de Path (Rule) | Prioridad | Middlewares | Upstream Destino | Descripción |
| :--- | :--- | :---: | :---: | :---: | :--- |
| `extractor-extract` | `Path('/extract')` | **100** | *Ninguno* | `extractor-svc` | Extracción síncrona de texto y metadatos de PDF (streaming sin buffering) |
| `extractor-health-live` | `Path('/health/live')` | **100** | *Ninguno* | `extractor-svc` | Liveness probe del extractor |
| `extractor-health-ready` | `Path('/health/ready')` | **100** | *Ninguno* | `extractor-svc` | Readiness probe del extractor |
| `extractor-openapi` | `Path('/openapi.json')` | **100** | *Ninguno* | `extractor-svc` | Esquema OpenAPI 3.1 del extractor |
| `extractor-docs` | `PathPrefix('/docs')` | **90** | *Ninguno* | `extractor-svc` | Interfaz interactiva Swagger UI del extractor |
| `documents-api` | `PathPrefix('/api')` | **80** | `limit-pdf-body` | `documents-svc` | CRUD completo y healthchecks del servicio de documentos |
| `extractor-fallback` | `PathPrefix('/')` | **1** | *Ninguno* | `extractor-svc` | Enrutador fallback hacia el extractor |
| `internal-ping` | `/ping` *(puerto 8082)* | N/A | *Ninguno* | Traefik Core | Health check interno del proxy (no expuesto externamente) |

---

## 3. Variables de Entorno (Factor III)

La configuración se gobierna al 100% mediante variables de entorno exportadas en el host o contenedor.

| Variable | Descripción | Valor por Defecto |
| :--- | :--- | :--- |
| `EXTRACTOR_HOST` | Hostname o alias DNS del servicio extractor | `extractor` |
| `EXTRACTOR_PORT` | Puerto HTTP interno del servicio extractor | `8000` |
| `DOCUMENTS_HOST` | Hostname o alias DNS del servicio documents | `documents` |
| `DOCUMENTS_PORT` | Puerto HTTP interno del servicio documents | `8001` |
| `PUBLIC_PORT` | Puerto público HTTP en el que escucha el proxy | `80` |
| `INTERNAL_PING_PORT` | Puerto interno para el endpoint `/ping` de Traefik | `8082` |
| `MAX_REQUEST_BODY_BYTES` | Tamaño máximo del cuerpo de la petición (55 MiB = 57,671,680 B) | `57671680` |
| `MEM_REQUEST_BODY_BYTES` | Límite en RAM antes de volcar body a disco temporal (2 MiB) | `2097152` |
| `PROXY_READ_TIMEOUT` | Tiempo máximo de espera para lectura de respuesta del upstream | `35s` |
| `PROXY_CONNECT_TIMEOUT` | Tiempo máximo para establecer conexión TCP con el upstream | `5s` |
| `PROXY_SEND_TIMEOUT` | Tiempo máximo para enviar la petición al upstream | `35s` |
| `PROXY_GRACE_TIMEOUT` | Tiempo de gracia para drenar conexiones activas ante SIGTERM | `30s` |
| `TRAEFIK_LOG_LEVEL` | Nivel de logs de Traefik (`DEBUG`, `INFO`, `WARN`, `ERROR`) | `WARN` |

---

## 4. Arquitectura de Balanceo: p2c, DNS Dinámico y Pool de Conexiones

### El Desafío del Escalado de 1 a 5 Réplicas sin `docker.sock`
En entornos donde no se expone el socket de Docker por seguridad, Traefik no puede inspeccionar los eventos de la API de Docker para descubrir réplicas dinámicamente. El upstream se configura estáticamente hacia una única URL:
```yaml
servers:
  - url: "http://${EXTRACTOR_HOST}:${EXTRACTOR_PORT}"
```

Cuando Docker Compose escala el servicio `extractor` a 5 réplicas (`docker compose up --scale extractor=5`), el servidor DNS interno de Docker (`127.0.0.11`) asocia el hostname `extractor` a las 5 direcciones IP privadas correspondientes, devolviéndolas mediante Round-Robin DNS.

### La Solución de Tres Capas:
1. **Evitar Conexiones Persistentes Estancadas (`maxIdleConnsPerHost: 2`)**:
   Por defecto, los clientes HTTP en Go mantienen un pool amplio de conexiones TCP abiertas (`keep-alive`). Si Traefik mantuviera abiertas decenas de conexiones hacia la primera IP resuelta, las requests se enviarían siempre a la misma réplica, anulando el balanceo.
   Al configurar:
   ```yaml
   serversTransports:
     default:
       maxIdleConnsPerHost: 2
   ```
   Traefik reutiliza como máximo 2 conexiones en reposo por host. Cuando entra una ráfaga de tráfico (por ejemplo, 100 VUs en k6), Traefik se ve forzado a abrir nuevos sockets TCP. Cada nueva conexión ejecuta una resolución DNS contra `127.0.0.11`, descubriendo y utilizando las 5 IPs de las réplicas escaladas de manera uniforme.
2. **Algoritmo Power of Two Choices (`strategy: p2c`)**:
   En Traefik v3, la estrategia `p2c` (equivalente moderno a `least_conn`) evalúa dos endpoints candidatos al azar y dirige la petición al que tenga menor número de conexiones en curso. Esto previene colas en réplicas que estén procesando PDFs pesados y distribuye el trabajo óptimamente sin sobrecargar ninguna instancia.
3. **Desacoplamiento Absoluto**:
   El proxy no requiere privilegios elevados en Docker ni reloads en caliente de archivos para absorber el escalado horizontal.

---

## 5. Resiliencia, Backpressure y Ausencia Intencional de Retry

### ¿Por qué NO se configura el middleware `retry` en Traefik?
En PDFtrack, el microservicio `pdftrack-extractor` implementa un mecanismo determinista de control de saturación (**backpressure**): cuando sus workers o colas internas están ocupados, responde inmediatamente con **HTTP 503 Service Unavailable** (o 429).

Si Traefik tuviera activado un middleware de reintentos (`retry`):
- Al recibir un 503 de una réplica saturada, Traefik reintentaría de inmediato contra otra réplica, enviando nuevamente el payload de hasta 50 MB.
- Bajo un test de estrés o spike masivo (100 VUs concurrentes), esto desencadenaría una **tormenta de reintentos** (*retry storm* o *thundering herd*), propagando la saturación en cascada a las 5 réplicas y provocando el colapso total de la infraestructura.
- **Decisión de Arquitectura**: Traefik transmite el `HTTP 503` directamente al cliente sin reintentos. Esto permite que el cliente o el arnés de prueba clasifique la respuesta como un *rechazo controlado* y respete el ritmo de procesamiento del sistema.

### Caída de Upstreams:
Si el servicio `extractor` o `documents` se encuentra apagado, inalcanzable o se rechaza la conexión a nivel TCP, Traefik responde de forma estándar e inmediata con **HTTP 502 Bad Gateway**.

---

## 6. Cumplimiento de Twelve-Factor App

- **Factor I (One codebase, one repo)**: Repositorio autónomo e independiente sin código compartido de otros servicios.
- **Factor III (Config in environment)**: Todas las variables se inyectan por entorno; cero hostnames o puertos hardcodeados en los templates.
- **Factor VII (Port binding)**: El puerto público de escucha (`PUBLIC_PORT`) es configurable por entorno; el Dockerfile utiliza `ARG PORT_ARG=80` para `EXPOSE`.
- **Factor VIII (Concurrency / Scaling)**: Soporta de 1 a 5 réplicas del extractor sin modificar la configuración gracias a `strategy: p2c`, `maxIdleConnsPerHost: 2` y DNS dinámico.
- **Factor IX (Disposability & Fast Startup)**: Arranca en menos de un segundo; Traefik corre como PID 1 vía `exec` en `entrypoint.sh` y dispone de `lifeCycle.graceTimeOut: 30s` para drenar conexiones activas ante `SIGTERM`.
- **Factor XI (Logs as event streams)**: Access log en formato JSON estructurado hacia `/dev/stdout` y logs de eventos/errores en JSON hacia `stderr`.
- **Factor XII (Admin processes)**: El script `validate-config.sh` permite validar estática y dinámicamente la configuración en el mismo entorno de ejecución antes de desplegar.

---

## 7. Guía de Comandos Operativos

### 1. Build de la imagen Docker
```bash
docker build -t pdftrack-proxy:latest .
```

### 2. Validación Administrativa de Configuración Offline (Factor XII)
Ejecuta la validación de configuración sin necesidad de levantar ningún servicio upstream ni depender de base de datos:
```bash
docker run --rm --entrypoint /validate-config.sh pdftrack-proxy:latest
```
*Salida esperada:*
```text
[validate-config] Step 1/3: Rendering templates with envsubst...
[validate-config] Step 2/3: Checking unresolved variables and basic YAML integrity...
[validate-config] Step 3/3: Starting Traefik in background to test parser and ping endpoint...
[validate-config] Ping endpoint http://127.0.0.1:8082/ping responded with HTTP 200 OK.
[validate-config] Static and dynamic configuration parser verified successfully.
[validate-config] Validation completed successfully (Factor XII). Exiting 0.
```

### 3. Ejecución del Proxy en una red Docker junto a Extractor y Documents
Para probar el proxy en conjunto con los microservicios en una red aislada de Docker:

```bash
# 1. Crear la red compartida
docker network create pdftrack-net

# 2. Levantar el proxy conectado a la red exponiendo el puerto 80
docker run -d \
  --name pdftrack-proxy \
  --network pdftrack-net \
  -p 80:80 \
  --memory 128m \
  --cpus 0.25 \
  -e EXTRACTOR_HOST=extractor \
  -e EXTRACTOR_PORT=8000 \
  -e DOCUMENTS_HOST=documents \
  -e DOCUMENTS_PORT=8001 \
  -e PUBLIC_PORT=80 \
  -e INTERNAL_PING_PORT=8082 \
  pdftrack-proxy:latest

# 3. Verificar logs estructurados en JSON
docker logs -f pdftrack-proxy
```

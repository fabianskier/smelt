# Smelt — Contexto del proyecto

> Documento para retomar el contexto en una nueva conversación con Claude.
> Última actualización: 2026-11-13. Estado: **entorno listo y proyecto Phoenix generado (paso 1.4)**. Ver §12 Progreso.

## 1. Qué es Smelt

Una **software factory personal y privada**, escrita en **Elixir**, que acompaña el desarrollo de software **de inicio a fin** (idea → código mergeado) y delega en **Claude Code** el trabajo que ya hace bien (pensar, escribir y revisar código).

- **Smelt (Elixir/OTP) orquesta**: estados, colas, concurrencia, gates, aprobaciones, dashboard.
- **Claude Code ejecuta**: discovery, specs, implementación, review (vía `claude -p` headless).
- **OpenSpec define los specs**: formato y ciclo de vida de los cambios (Spec-Driven Development).

Nombre: *smelt* = fundir mineral para extraer metal puro → idea cruda entra, código probado sale.

## 2. Contexto del usuario

- Mac M4, 16 GB RAM, macOS. Dotfiles en `~/.dotfiles` (stow + Brewfile + Makefile).
- Suscripción **Claude Pro ($20)** → límites de uso (ventanas de 5 h + tope semanal). Sin API key por ahora.
- Elixir, Erlang, `gh`, Docker y Ollama **no instalados** todavía. Claude Code 2.1.322 instalado.
- Objetivo de aprendizaje: aprovechar las bondades de Elixir/OTP construyendo esto.
- Proyecto **privado**: sin licencia, sin publicar en hex.pm, repo privado si se sube.

## 3. Flujo (SDD con OpenSpec)

```
Idea → Discovery → Proposal/Spec → Tasks → [por tarea] Build → Gate → Review → Merge+Archive → Retro
                    ✋ usuario      ✋ usuario            Claude   Elixir   Claude   ✋ usuario
```

Artefactos de OpenSpec, versionados en el repo de cada proyecto:

```
openspec/
  specs/<capability>/spec.md          # verdad actual del sistema (specs vivos)
  changes/<change>/
    proposal.md                       # Why / What Changes / Capabilities / Impact
    design.md                         # opcional
    tasks.md                          # - [ ] 1.1 ... (checklist)
    specs/<capability>/spec.md        # deltas: ADDED / MODIFIED / REMOVED / RENAMED
  changes/archive/YYYY-MM-DD-<change>/
```

Formato de requisitos: `### Requirement: X` con SHALL/MUST + `#### Scenario: Y` (exactamente 4 `#`) con **WHEN/THEN**.
Cada `Scenario` debe tener su test (ExUnit u otro). `openspec validate --strict` es parte del gate.

Mapeo de etapas:

| OpenSpec | Smelt |
|---|---|
| explore / propose | Discovery → Claude genera proposal + deltas + tasks → usuario aprueba |
| validate --strict | Gate del spec antes de construir |
| apply | Build por tarea en git worktree; Smelt lleva el estado leyendo `tasks.md` |
| — | Gate de tests: cada `Scenario` con test; tests existentes protegidos |
| — | Review: código vs deltas |
| archive | Al hacer merge → specs vivos actualizados (evita el drift spec↔código) |

**Niveles por tamaño** (para evitar burocracia): *fix* = solo la tarea · *feature chica* = proposal corto · *feature grande* = flujo completo.

## 4. Arquitectura

**Stack:** Phoenix 1.8 + LiveView · PostgreSQL 18 (Postgres.app en dev; conexión vía `DATABASE_URL`) · Oban (motor Postgres) · git local (worktrees + merge) · OpenSpec CLI (`--json`).

Componentes:

- **`Smelt.Runner` (behaviour)**: interfaz común para agentes (`run/2`, eventos en stream, resultado).
  - Implementación inicial: Claude Code CLI vía `Port` → `claude -p --output-format stream-json --verbose`, parseando eventos JSON y transmitiéndolos por PubSub. El costo y los tokens vienen en el stream.
  - Futuras: modelo local (Ollama), API key de Anthropic, `jido_harness` (Codex, Gemini CLI, etc.).
- **Máquina de estados** por cambio/tarea: GenServer bajo DynamicSupervisor + Registry, persistida en Postgres y retomada tras crash o reinicio.
- **Proveedores con capacidad propia**: una cola de Oban por proveedor (`queues: [claude: 1, local: 1]`, cambiable en caliente con `Oban.scale_queue/1`).
- **Gobernador por proveedor** (GenServer): detecta el límite de uso, pausa *solo esa* cola y la reanuda al liberarse.
- **Router** por etapa/riesgo, configurable con fallback:
  ```elixir
  routing: %{
    discovery: [:claude], build: [:claude], review: [:claude],
    summarize: [:local, :claude], triage: [:local, :claude]
  }
  ```
- **Gate determinista** (Elixir, sin IA): corre los checks del proyecto, `openspec validate --strict`, bloquea cambios a tests existentes y paths protegidos (usando la copia de `main`), limita el tamaño del diff.
- **Grafo de dependencias** de tareas (desde `tasks.md`): solo se paralelizan tareas independientes.
- **Cola de merge serializada**: un merge a la vez, con rebase sobre `main` y el gate otra vez antes de mergear.
- **Pool de gates**: tests en paralelo con puertos asignados por tarea.
- **Dashboard LiveView** en localhost: stream del agente en vivo, aprobar/rechazar con un clic, costo y tokens por tarea.
- **Estado de Smelt** en `.smelt/` por proyecto; preferencias de usuario en `~/.config/smelt/`. Nunca guarda credenciales.

## 5. Concurrencia y modelos

- Concurrencia en la arquitectura desde el día 1; la capacidad es configuración.
  - **Pro hoy**: `claude: 1`, `local: 1`.
  - **Max**: `claude: 2–3`.
  - **API key**: proveedor con presupuesto en dólares.
- **Modelos locales** (M4 16 GB → ~7–14B cuantizados): no sirven para el build agéntico multi-archivo. Se usan para lo mecánico, para ahorrar cuota de Claude: resumir logs de tests, mensajes de commit, triage, checks simples de review, y luego filtrar papers.
- Con Pro: modelo por defecto del plan, sin fijar modelos caros; menos agentes y más checkpoints humanos.

## 6. Niveles de autonomía

1. **Asistida** (inicio): el usuario aprueba spec, plan y merge.
2. **Supervisada**: auto-merge en bajo riesgo.
3. **Autónoma**: sin revisión humana; depende de la verificación automática.

Subir de nivel = cambiar la política por riesgo en la máquina de estados, justificado con métricas (fallas del gate, rondas por tarea).

## 7. Ruta de construcción

1. **Esqueleto**: Phoenix + Postgres + Oban; `Smelt.Runner` (behaviour + impl Claude Code) con el stream visible en LiveView.
2. **Una tarea de punta a punta**: worktree → build → gate → aprobación → merge.
3. **Robustez**: gobernador por proveedor, router, colas por proveedor, retomar tras crash o límite.
4. **Etapas previas**: idea → discovery → proposal/spec → tasks (OpenSpec).
5. **Concurrencia real**: grafo de dependencias + cola de merge.
6. **Review automático, retro y métricas.**
7. *(Opcional)* Proveedor local (Ollama) para resúmenes y commits.
8. **Después**: integración con GitHub (`gh`), sandbox en Rust para correr tests (binario aparte vía Port, o Rustler), indexado de código con tree-sitter.


## 8. Decisiones tomadas y por qué

| Decisión | Razón |
|---|---|
| Elixir/OTP propio, no Jido como base | Aprender OTP directo; `jido_harness` estaba en 3.0.0-rc (ACP, helper nativo C++, sin salida estructurada, sesiones que no sobreviven reinicios). `jido_ai` usa API key, no la suscripción. Se puede enchufar después vía el behaviour del Runner. |
| OpenSpec en vez de formato propio o Spec Kit | Formato probado con validador; orientado a cambios/deltas (brownfield); specs vivos que resuelven el drift; usable a mano hoy. Spec Kit es más pesado (fases rígidas, setup en Python). Costos: depende de Node (o binario/brew), telemetría opt-out, v2 reciente → integrar vía CLI `--json`. |
| Claude Code headless en vez de API directa | La suscripción Pro solo sirve vía la CLI de Claude Code. |
| Checkpoints humanos en vez de agentes approver/intake | Cuestan cero tokens; nivel de autonomía asistido al inicio. |
| PostgreSQL (no SQLite) + estado en DB; artefactos en el repo | Smelt podría volverse multiusuario (servidor compartido): Postgres sirve para local y para servidor, Oban completo (LISTEN/NOTIFY, multi-nodo), JSONB para eventos. Dev con Postgres.app (ya instalado, PG 18.7, auth *trust* local); Docker más adelante (sandbox, deploy). Conexión vía `DATABASE_URL` para cambiar de backend sin tocar código. |
| Frontend: LiveView ahora; React después si hace falta | LiveView da tiempo real sin API. Opciones futuras: islas de React dentro de LiveView (`live_react`), Inertia.js, o SPA + API/Channels (solo si hay multiusuario o móvil). Regla: toda la lógica en `lib/smelt/` (contextos) y eventos por PubSub; la web es una capa delgada e intercambiable. |
| Privado | Sin licencia ni publicación. Si se comparte: acceso al repo privado o binario cerrado (Burrito). Revisar los términos de Anthropic antes: los usuarios deben usar su propio Claude Code o API key, nunca la suscripción del autor. |
| Código y docs en inglés | Convención; las conversaciones pueden ser en español. |

## 9. Referencia: zazencodes software-factory v2

https://github.com/zazencodes/zazencodes-season-3/tree/main/src/software-factory-claude-code-v2 (GPLv3 → **tomar ideas, no copiar código**)

- Pipeline: intake → route → spec → build (worktree + PR draft) → gate (`checks.sh`) → reviewers en paralelo según riesgo → approver → merge. Máximo 3 rondas.
- **Se adopta**: separación juicio (agentes) / mecanismo (scripts deterministas); gate antes del review; checks protegidos (usar la copia de `main`); un worktree por trabajo; estado retomable; primera línea parseable en las salidas (`STATUS: READY`, `VERDICT: PASS`).
- **Se cambia**:
  - Depende de una sesión interactiva viva → app OTP supervisada.
  - Opus/Fable y hasta 4 reviewers con 3 jobs → no cabe en Pro.
  - `factory/jobs/` está en gitignore y los specs se pierden → OpenSpec archive.
  - Tests no protegidos → se bloquean.
  - Costo sacado de transcripts → viene de stream-json.
  - Approver de IA con merge automático → aprobación humana.
  - Dashboard estático → LiveView.

## 10. Proyectos para después (no prioritarios)

- **Radar de papers de IA**: arXiv (cs.AI/CL/SE/LG), HF Daily Papers, Semantic Scholar → filtro por intereses (modelo barato o local) → resumen orientado a criterio (afirmación, evidencia vs benchmark inflado, reproducibilidad, impacto hoy) → digest. Jobs de Oban; reutiliza el Runner y el router de Smelt.
- **Skills de Claude Code** en `~/.dotfiles/claude/` (stow → `~/.claude`):
  - `vale-la-pena`: evalúa herramientas nuevas → adoptar / probar / ignorar, con log de decisiones.
  - `ponerme-al-dia`: ruta de aprendizaje anclada a lo que ya sé, con mini-proyecto y fuentes primarias.
  - `repeticiones`: analiza el historial de zsh y de Claude Code → propone alias, script o skill, o dice explícitamente que no vale la pena.
- **Rust**: solo con una razón concreta (sandbox para tests, tree-sitter).

## 11. Modo de trabajo

**Paso a paso y guiado.** Cada paso sigue este orden:
1. Explicar el concepto (qué es, por qué lo usamos y cómo encaja).
2. Ejecutar el paso.
3. Verificar que funcionó.
4. Esperar al usuario antes de pasar al siguiente.

El objetivo es entender, no solo terminar.

## 12. Progreso (paso 1: esqueleto)

**Entorno** (en `~/.dotfiles`, todo commiteado y sin co-autor):
- `mise` vía Brewfile, con el hook en `zsh/.config/zsh/conf.d/tools.zsh`. Se queda la fórmula de Homebrew: el hook mide ~10 ms, así que se ignora el hint de mise.run.
- `gh` vía Brewfile, autenticado (protocolo ssh).
- Config global de mise en `mise/.config/mise/config.toml` (paquete de stow): `node 26.13.1`, `npm:@fission-ai/openspec 2.0.0` y `OPENSPEC_TELEMETRY=0`. No se usa Homebrew para openspec porque está desactualizado (1.17).
- CLI de Postgres.app en el PATH (condicional) en `paths.zsh`.

**Proyecto `~/code/smelt`:**
- `mise.toml`: `erlang 29.1.2`, `elixir 1.20.5-otp-29`.
- Generado con `mix phx.new . --app smelt --no-mailer --no-gettext` (Phoenix 1.8.16, Bandit, Tailwind, esbuild, LiveDashboard).
- `mix ecto.create` crea `smelt_dev` y `smelt_test`. `mix test` pasa 5 tests y el server responde en :4000.
- Hex, rebar3 y phx_new viven dentro de la instalación de Elixir de mise: al cambiar de versión de Elixir hay que reinstalarlos.
- `AGENTS.md` (Phoenix 1.8) contiene reglas para agentes. Hay que crear un `CLAUDE.md` que lo importe (`@AGENTS.md`).

**Siguientes pasos:**
1. **1.4 (falta):** revisar el `.gitignore`, hacer el primer commit (`chore: generate phoenix project`) y `gh repo create smelt --private --source . --push`. Pendiente: el repo de git existe pero no tiene commits.
2. **1.5:** `openspec init --tools claude`, y un `CLAUDE.md` que importe `AGENTS.md` y apunte a `CONTEXT.md`.
3. **1.6:** `DATABASE_URL` en `config/runtime.exs`, con el valor en `mise.toml` (`[env]`).
4. **1.7:** agregar Oban.
5. **1.8:** primer cambio de OpenSpec: `Smelt.Runner` (behaviour + implementación con Claude Code vía Port) y el stream en LiveView.

# Arquitetura do PulseDock

Versão 0.1.0 · macOS 15+ · Swift 6 (modo de linguagem 6, concorrência estrita) · SwiftUI + AppKit

O PulseDock é um app agente (`LSUIElement`) com três executáveis no mesmo bundle:

| Executável | Onde fica | Papel |
| --- | --- | --- |
| `PulseDock` | `Contents/MacOS/` | Dock, Agent Pulse, Mission Control, Ajustes |
| `pulsedock-hook` | `Contents/Helpers/` → copiado para `~/Library/Application Support/PulseDock/bin/` | Recebe hooks do Claude Code e do Codex, sanitiza e entrega ao app |
| `pulsedockctl` | `Contents/Helpers/` | Ferramenta de desenvolvimento: fixtures, replay, instalação de hooks, controles de captura |

## 1. Módulos

Um pacote SwiftPM com um target por módulo (ADR 0001). As setas indicam dependência.

```
                 ┌──────────────┐
                 │ PulseDockApp │  janelas, views, controllers, ajustes
                 └──────┬───────┘
     ┌──────────┬───────┼──────────┬───────────────┬───────────────┐
     ▼          ▼       ▼          ▼               ▼               ▼
 DockCore  DockRendering WidgetCore Persistence ClaudeCodeAdapter CodexAdapter
     │                     │          │               │    \          /    │
     └────► Diagnostics ◄──┘          ▼               ▼     AdapterSupport  │
                                   AgentCore ◄────────┴─────────┬───────────┘
                                                                ▼
                                                           AgentBridge  ◄── pulsedock-hook
```

| Módulo | Responsabilidade | Tipos principais |
| --- | --- | --- |
| `AgentCore` | Modelo universal de eventos e sessões, máquina de estados, staleness, prioridade, timeline, progresso, projetos, cenário demo | `AgentEvent`, `AgentSession`, `SessionReducer`, `AgentSessionEngine`, `StalenessPolicy`, `AgentPresenter`, `TimelineBuilder`, `ToolClassifier`, `ProjectResolver`, `DemoScenario` |
| `AgentBridge` | Protocolo de envelope, socket local (servidor e cliente), spool, sanitizador, redação de credenciais, inspeção de processos | `BridgeEnvelope`, `BridgeServer`, `BridgeClient`, `HookSanitizer`, `SecretRedactor`, `ProcessInspector`, `BridgePaths` |
| `AdapterSupport` | Edição segura de arquivos de configuração de terceiros (JSON com ordem preservada, seção `hooks`) | `ConfigFileEditor`, `HooksSectionEditor`, `OrderedJSON` |
| `ClaudeCodeAdapter` | Detecção, instalador de hooks, normalização dos eventos, registro de sessões | `ClaudeCodeDetector`, `ClaudeCodeHookInstaller`, `ClaudeCodeNormalizer`, `ClaudeSessionRegistry` |
| `CodexAdapter` | Hooks, `notify`, cliente do app-server e mapeamento do protocolo | `CodexHookInstaller`, `CodexNotifyInstaller`, `CodexNormalizer`, `CodexAppServerClient`, `CodexAppServerMapper` |
| `Persistence` | SQLite do sistema, migrações, eventos, sessões, ajustes, retenção | `SQLiteDatabase`, `Migrations`, `PersistenceController` |
| `DockCore` | NSWorkspace: apps instalados e em execução, abertura e alternância, ícones, janelas (AX opcional), Dock do sistema | `AppLauncher`, `RunningApplicationsMonitor`, `IconProvider`, `WindowInventory`, `SystemDock`, `SystemDockController`, `DisplayLocator` |
| `DockRendering` | Tokens, temas, Pulse Glass, molas, motor de magnificação, opções de acessibilidade | `DockMetrics`, `Theme`, `PulseGlassSurface`, `Spring`, `Magnification`, `Motion`, `AccessibilityOptions` |
| `WidgetCore` | Provedores de dados de widgets com custo controlado | `ClockProvider`, `SystemHealthProvider`, `NowPlayingProvider` |
| `Diagnostics` | `OSLog` por categoria, gravador de diagnóstico (buffer + log unificado), métricas do processo | `PulseLog`, `DiagnosticsRecorder`, `ProcessMetrics` |
| `PulseDockApp` | Ciclo de vida, dock, Agent UI, Mission Control, Ajustes, onboarding, notificações, Smart Return | `AppServices`, `DockModel`, `DockWindowController`, `AgentStore`, `AgentUIController`, `MissionControlModel`, `SettingsStore` |

Regra de dependência: os módulos de núcleo não importam AppKit/SwiftUI. Os módulos de UI usam isolamento
padrão no `MainActor`.

## 2. Pipeline de eventos dos agentes

Corresponde ao pipeline da especificação (§11.2):

```
Claude Code / Codex  ──hook (stdin JSON)──►  pulsedock-hook
   │  Provider Adapter: identifica fonte e evento         (ClaudeCodeNormalizer / CodexNormalizer)
   │  Event Validator: tamanho, JSON, campos obrigatórios  (HookEnvelopeBuilder)
   │  Sanitizer: remove conteúdo, redige credenciais       (HookSanitizer + SecretRedactor)
   ▼
 Unix socket 0600 (getpeereid = mesmo UID)  ──ou──►  spool privado (app fechado)
   ▼
 BridgeServer (fila própria) → AgentBridgeService
   │  Event Normalizer → [AgentEvent]                       (normalizadores dos adaptadores)
   ▼
 AgentSessionEngine: deduplicação, ordenação, redutor, buffer limitado
   │  Session State Machine                                 (SessionReducer)
   ▼
 AgentStore (MainActor): Persistent Event Store (PersistenceController, assíncrono)
   │  UI State Publisher: AgentPresenter.summarize → AggregateSummary (@Observable)
   ▼
 Agent Pulse (ilha) · Quick Peek · Agent Card · Mission Control · Notificações
```

### 2.1 `AgentEvent` (protocolo universal)

Campos: `id` (estável e único), `schemaVersion`, `provider`, `sessionID`, `turnID?`, `subagentID?`,
`subagentType?`, `projectPath?`, `kind`, `sourceTimestamp?`, `receivedAt`, `order` (relógio de parede +
boot ID + monotônico), `collection` (método de coleta: hook do Claude, hook/notify/app-server do Codex,
registro, reconciliação, fixture), `confidence`, `sourceEvent`, `activity?`, `tool?`, `attention?`,
`failure?`, `task?`, `plan?`, `origin?` e `metadata` (pares curtos, já sanitizados).

Identificadores (`SessionKey` = provedor + ID da sessão), estados (`SessionState`, `SessionLifecycle`,
`Confidence`) e eventos ficam em tipos separados.

### 2.2 Envelope do socket (`BridgeEnvelope`, v1)

NDJSON com `v`, `kind` (hook, notify, control), `source` (`claude_code`, `codex`, `pulsedock`), `event`,
`id`, `ts` (ms), `boot`, `mono` (ns), `payload` (já sanitizado), `ctx` (cadeia de processos, TTY e variáveis
de **lista branca**, como `TERM_PROGRAM`) e `helper` (versão e PID). Limite: 512 KiB por mensagem.

### 2.3 Regras de estado

Ver ADR 0005. Resumo: estados oficiais da especificação; o turno é separado da sessão; a confiança é
explícita; um evento fora de ordem dispara reaplicação; silêncio vira `stale`, não `idle`; o processo do
agente é checado a cada 30 s e ao acordar o Mac; nada de sucesso inferido.

### 2.4 Prioridade e agregação

`AgentPresenter` classifica cada sessão (atenção, falha recente, trabalhando, conclusão recente, ocioso,
desconhecido) e ordena nessa prioridade (§6.5). Sessões fixadas sobem dentro da categoria; sessões
silenciadas não tomam a ilha. O modo da ilha deriva do agregado: `attention(key)`, `failure(key)`,
`completionFlash(key)` (alguns segundos), `activity(key)` ou `compact`. Uma sessão aguardando aprovação
nunca fica escondida atrás de sessões trabalhando (`PresentationTests`, `LoadTests`).

## 3. Dock

- **Janela**: `DockPanel`, um `NSPanel` não ativador no nível do Dock, em todos os Spaces e fora dos Spaces
  de tela cheia. Ele só recebe eventos quando o ponteiro está na área interativa (ADR 0002).
  `DockWindowController` posiciona a janela na tela escolhida (principal, seguir o ponteiro ou uma tela
  específica, identificada por UUID), respeita o `visibleFrame` em Companion Mode, controla o auto-hide
  (atrasos configuráveis, borda da tela, supressão em tela cheia) e se reposiciona em mudanças de tela,
  resolução, escala e ao acordar.
- **Modelo**: `DockModel` (`@Observable`) junta os itens do ambiente ativo: fixados, apps em execução não
  fixados, divisores, Agent Pulse, widgets e Lixo. Mantém molas para ponteiro, amplitude, largura da ilha,
  ocultação e reordenação, e calcula a geometria apresentada com `Magnification.layout` (ADR 0003). Um
  `FrameDriver` (display link) só roda enquanto há movimento.
- **Renderização**: `DockRootView` desenha o vidro (`PulseGlassSurface`), os ícones (`IconProvider`, com cache
  de `CGImage` na resolução certa), indicadores, rótulo flutuante, ilha e widgets, nas posições exatas do
  layout e sem animações implícitas.
- **Interação**: `DockHostView` faz hit-test sobre a geometria apresentada. Clique abre ou alterna
  (`AppLauncher`, via LaunchServices). Arrastar reordena; arrastar para fora remove (cursor
  `disappearingItem`). Soltar arquivos em um app abre-os com ele; soltar no Lixo os move para o Lixo;
  soltar um `.app` na barra o fixa. O menu contextual é `NSMenu` nativo, com janelas (AX opcional),
  Mostrar no Finder, Manter no Dock, Ocultar, Encerrar, Forçar Encerramento (⌥) e Nova Instância (só
  quando o app não proíbe).
- **Ambientes**: cada `Workspace` tem fixados, ordem, tema, widgets, exibição de apps em execução e filtro
  de sessões de IA. Os presets são Desenvolvimento, Criativo, Pessoal e Foco. A troca muda só o dock, sem
  mexer em janelas de outros apps (atalho ⌃⌥⌘W).
- **Widgets**: Relógio (timer alinhado ao minuto), Saúde do Sistema (Mach + IOKit, intervalo configurável,
  pausado quando o dock está oculto), Tocando Agora (notificações distribuídas do Música/Spotify, sem
  permissão; controles via Apple Events), Quick Launch (coleções) e o próprio Agent Pulse.

## 4. Interface dos agentes

- **Agent Pulse (ilha)**: cápsula com largura **medida** do conteúdo real e animada por mola. Modos
  compacto, atividade, atenção, conclusão e falha. A luz ambiente é local à ilha e respira só em atividade
  ou atenção.
- **Quick Peek**: resumo ao repousar o ponteiro sobre a ilha (atraso configurável).
- **Agent Card**: painel ancorado (`AnchoredPanel`), com resumo, sessões ordenadas por prioridade, detalhe da
  atividade, tarefas e subagentes, origem (app/TTY), ações (abrir, Finder, copiar caminho, eventos, fixar,
  silenciar) e chips de integração. Os botões de aprovação aparecem **só** em sessões do Codex Managed Mode.
- **AI Mission Control**: `NavigationSplitView` com filtros (todas, precisam de atenção, em andamento,
  concluídas, histórico), projetos derivados automaticamente, cartões agrupados por projeto, detalhe com
  fatos, observabilidade da integração, progresso, subagentes e timeline (eventos pareados, agrupados,
  filtráveis e expansíveis). Busca e filtros por provedor, período, ordenação e tipo de evento.
- **Notificações**: `NotificationCoordinator`. Por padrão, só aprovações/perguntas e falhas notificam;
  pedidos que chegam juntos viram uma notificação só; há horário de silêncio; clicar na notificação aciona
  o Smart Return.
- **Smart Return**: aba exata do Terminal/iTerm2 pela TTY (Apple Events) → app hospedeiro identificado
  pela cadeia de processos → projeto aberto no editor hospedeiro → pasta no Finder. Nunca traz um terminal
  que não foi identificado a partir da sessão.
- **Privacy Mode** (⌃⌥⌘P): oculta nomes de projetos, caminhos e detalhes em todas as superfícies.
- **Demo Mode**: `DemoPlayer` reproduz `DemoScenario`; tudo leva o selo **DEMO** e nada vai para o histórico.

## 5. Concorrência

- UI e modelos no `MainActor` (isolamento padrão dos módulos de UI).
- `BridgeServer`: fila serial própria, com `DispatchSource` para accept/read. Entrega envelopes validados
  ao `MainActor`.
- `PersistenceController`: fila serial `utility`; nenhuma leitura ou escrita bloqueia a UI.
- `CodexAppServerClient`: `async`/`await` sobre stdio, com correlação de IDs JSON-RPC.
- Helper: síncrono e limitado no tempo (0,3 s para entrega, `alarm(2)` como proteção).

## 6. Caminhos

| O quê | Onde |
| --- | --- |
| Banco (ajustes, sessões, eventos) | `~/Library/Application Support/PulseDock/pulsedock.sqlite` |
| Socket e spool | `~/Library/Application Support/PulseDock/run/` (`0700`) |
| Helper estável | `~/Library/Application Support/PulseDock/bin/pulsedock-hook` |
| Backups de configurações de agentes | `~/Library/Application Support/PulseDock/backups/` |
| Configuração lida pelo helper (privacidade) | `~/Library/Application Support/PulseDock/helper-config.json` |
| Logs | Log unificado, subsistema `app.pulsedock.PulseDock` |

## 7. Como estender

- **Novo provedor (Plugin SDK futuro)**: um normalizador `BridgeEnvelope → [AgentEvent]` (ver
  `ClaudeCodeNormalizer`), um instalador baseado em `ConfigFileEditor`/`HooksSectionEditor` e uma
  `Source` nova no envelope. O motor, a UI e a persistência não mudam.
- **Novo widget**: um provedor em `WidgetCore` (custo explícito, pausa quando invisível), um `WidgetKind`
  e uma view em `PulseDockApp/Widgets`.
- **Novo tema**: um `Theme` em `DockRendering/Theme.swift` com material (vidro do macOS 26 + material
  legado), tons de estado e intensidade ambiente.

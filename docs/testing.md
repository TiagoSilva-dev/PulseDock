# Testes do PulseDock

Última execução: 2026-10-18 · macOS 27.0.1 · Apple M1 Pro · Xcode 27.1 / Swift 6.4 · Claude Code 2.1.302

## 1. Como rodar

```bash
swift test                          # 66 testes, 10 suítes (Swift Testing)
swift test --filter LoadTests       # só o benchmark de carga do motor
scripts/benchmark.sh release 30     # CPU ociosa, memória, tempo de abertura, pipeline
scripts/build-app.sh debug && open build/debug/PulseDock.app --args --developer --demo
```

Testes **simulados** (fixtures) e testes de **integração real** ficam separados abaixo. Fixtures nunca valem
como prova de compatibilidade com versões externas: elas seguem os schemas oficiais e são confirmadas por
sessões reais quando possível.

## 2. Testes automatizados (92 — todos passando)

| Suíte | Testes | Cobre |
| --- | --- | --- |
| Session state machine (`SessionReducerTests`) | 14 | turno ≠ tarefa; permissão espera e é liberada pelo resultado certo; ferramenta paralela não esconde permissão; negação sem resultado; interrupção inferida (novo prompt e `idle_prompt`); falha de API; teste falhando não encerra a sessão; hierarquia de subagentes; fim de sessão no meio do turno; compactação; hooks + notify contados uma vez; progresso só com total verificável |
| Engine robustness (`EngineRobustnessTests`) | 6 | ordem de chegada não muda o resultado; duplicados; silêncio ≠ ociosidade (stale); permissão espera com processo vivo; processo morto sem `SessionEnd`; buffer limitado |
| Presentation (`PresentationTests`) | 7 | sessão aguardando nunca fica atrás das que trabalham; silenciadas não tomam a ilha; flash de conclusão; classificação pelos programas literais; timeline pareada e agrupada; cenário demo marcado; projetos pela raiz do repositório |
| Load (`LoadTests`) | 1 | 25 sessões × 200 eventos (5.010), entrelaçados; a aprovação fica no topo; tempos impressos |
| Claude Code pipeline (`ClaudeCodePipelineTests`) | 4 | nenhum campo de conteúdo sobrevive ao sanitizador; cada fixture vira o evento documentado; detalhes só de campos concretos; replay da sessão com o estado esperado a cada passo |
| Claude usage (`ClaudeUsageTests`) | 5 | só números, modelo e pasta passam pelo sanitizador da status line (título da sessão, transcript, PR, repositório descartados); envelope → snapshot pelo formato do fio; custo diário por incrementos e sessões antigas como limite inferior; limites mais recentes, janelas vencidas somem, avisos 80/95% uma vez; projeção só com 10 min de crescimento e antes da renovação |
| Status line installer (`ClaudeStatusLineInstallerTests`) | 4 | instalação limpa e remoção byte a byte; status line existente encadeada (padding/refreshInterval preservados, comentário final inofensivo) e restaurada exatamente; restauração pelo fallback se o arquivo de encadeamento sumir; recusa sobrescrever mudança concorrente |
| Claude Code installer (`ClaudeCodeInstallerTests`) | 8 | preserva chaves e handlers de terceiros na ordem; idempotente e reversível; remove a seção `hooks` criada; não sobrescreve mudanças feitas após a prévia; JSON inválido é reportado; aspas em caminhos; versões antigas; registro de sessões sem ler `.key` |
| Codex (`CodexAdapterTests`) | 6 | hooks (inclusive falha de Bash e `Interrupt`); notify só fim de turno e sem conteúdo; instalação/remoção do `hooks.json`; encadeamento/restauração do notify; notify multilinha deixado para edição manual; app-server → eventos e aprovações com decisões da API |
| Agent bridge (`AgentBridgeTests`) | 9 | envelopes pelo socket; mensagens grandes descartadas; segundo servidor não rouba o socket; sem servidor o cliente desiste rápido; spool privado e drenagem atômica; redação de credenciais; `apply_patch` só com nomes de arquivo; níveis de detalhe de comando; validação; inspeção de processos |
| Persistence (`PersistenceTests`) | 5 | migração e ajustes; ordem de eventos e sessões; demo nunca gravado; histórico desligado / caminhos removidos / exclusão; retenção |
| Magnification (`MagnificationTests`) | 6 | sem magnificação sem ponteiro; alvo de clique estável; slots sem sobreposição; pico e crescimento limitados; vizinhos crescem menos; molas assentam |
| Agent Heartbeat (`HeartbeatTests`) | 5 | só eventos concretos viram batidas; silêncio é linha reta; raias por sessão e tipo mais importante; Radar de Testes (saída 0 passa, outro código falha, sem código é "terminou sem erro"); selo DEMO |
| Widgets (`WidgetCoreTests`) | 12 | timer/cronômetro/Pomodoro com relógio injetado; progresso do tempo e dias; links do YouTube (todos os formatos, outros sites rejeitados); respostas do Open-Meteo; conversão de unidades e vírgula decimal; área de transferência (ocultos ignorados, duplicados, limite); taxa de rede; tons de pele do emoji; vídeo do navegador (saída do script, títulos, aba escolhida, filtro dentro do script); scripts dos navegadores compilam com `osacompile` contra os dicionários instalados, sem enviar eventos |

### Fixtures e contratos

- **Claude Code**: `Tests/ClaudeCodeAdapterTests/Fixtures/hooks/01…23-*.json`, montados a partir do esquema
  documentado em `code.claude.com/docs/en/hooks` e confirmados pelos eventos reais da seção 3.
- **Codex**: payloads conforme os schemas gerados em `openai/codex/codex-rs/hooks/schema/generated` e o
  protocolo do app-server (`developers.openai.com/codex/app-server`).

## 3. Integração real executada

### Claude Code (hooks globais instalados com o instalador do app, com backup)

| Cenário da especificação (§21) | Resultado |
| --- | --- |
| Uma sessão Claude Code | ✅ esta sessão de desenvolvimento aparece no Agent Pulse, no card e no Mission Control |
| Evento de ferramenta atualiza a interface | ✅ `tool_started`/`tool_completed` com atividade ("Executando um comando" + comando sanitizado) |
| Ferramenta com erro | ✅ `ls /pulsedock-live-test-nonexistent-path` → `tool_failed · Bash · Exit code 1`, sessão seguiu `working` |
| Subagentes | ✅ `Explore` real: `subagent_started` → ferramentas atribuídas ao subagente → `subagent_stopped`; snapshot "Explore · concluído · 2 ferramentas" |
| Finalização normal | ✅ `turn_completed` → "Turno finalizado" |
| Compactação de contexto | ✅ `compaction_finished` durante a sessão |
| Reinício do PulseDock durante uma sessão | ✅ o app foi reiniciado várias vezes; a sessão foi restaurada do banco e os eventos seguiram chegando |
| Smart Return (origem) | ✅ origem capturada: Terminal · `ttys000` |
| Solicitação de permissão | ⏳ não observada ao vivo (sessão em modo automático); coberta por fixture oficial |
| Duas sessões simultâneas / projetos diferentes | ⏳ coberto por `LoadTests`; falta confirmar ao vivo (roteiro 4.1) |
| Falha de execução (`StopFailure`), interrupção, encerramento inesperado, sessão sem eventos | ⏳ cobertos por testes do motor; roteiro 4.1 |

### Codex

Não instalado neste Mac (decisão do usuário). Ver `docs/integrations/codex.md` §6 e o roteiro 4.2.

### Visual (capturas reais com `screencapture`)

Revisados em modo escuro: dock em repouso e com magnificação, ilha (atividade, atenção, falha e
conclusão), Agent Card, Mission Control, onboarding e todos os painéis de Ajustes, em inglês e pt-BR. Em modo claro
(forçado só no PulseDock com `pulsedockctl control appearance mode=light`): dock e Agent Card, sobre fundo
escuro, que é o pior caso. Problemas
encontrados e corrigidos: texto da ilha truncado, monogramas sobrepostos, quebras de linha no card, anel de
foco indevido, sessão real indistinguível das sessões demo, projetos homônimos, plural ("1 turns"),
datas truncadas, menu flutuante solto, barra lateral estreita em pt-BR, sliders com marcas densas,
números não localizados, prévias de tema quase idênticas, o seletor de demo dessincronizado e, no modo
claro, card com pouco contraste sobre fundo escuro (camada de legibilidade) e tons do Aurora sem variante
clara.

Ferramentas: com o app em `--developer`, `pulsedockctl control open what=card|missionControl|settings pane=…`,
`control hover x=0.3`, `control demo enabled=true`, `control appearance mode=light|dark|system`,
`control snapshot dir=…`, `control sleep` / `control wake`.

### Widgets (2026-10-19, capturas reais, escuro e claro)

- Revisados ao vivo: Agent Heartbeat (tile e painel), Pulse Buddy (humores trabalhando, alerta, falha), Dock
  Cinema (vídeo real tocando no player flutuante; pausa automática com aviso no pedido de aprovação da
  demo), Calendário e Lembretes (antes da permissão), Timer, Pomodoro, Contagem, Progresso do tempo, Clima
  (busca), Rede, Bateria, Nota, Atalhos, Água, Prateleira, AirDrop, Área de transferência, Conta-gotas,
  Emoji, Conversor e Cronômetro.
- Corrigido a partir das capturas: três raias paralelas no tile do Heartbeat (virou um traço único); Buddy
  com cor apagada; plural "1 eventos/min"; "1 days" na Contagem; painéis com sobra (altura medida pelo
  conteúdo); dock passando da largura da tela (ícones encolhem para caber); selo DEMO ausente no Heartbeat e
  no Buddy; campo de busca focado ao abrir, que fazia o AutoFill do macOS sobrepor uma sugestão ao painel.
- Desempenho: o Buddy animado a 30 fps custava 15% de CPU com um agente trabalhando; refeito com pulinhos
  por evento, volta a 0,14%.

### Desempenho (`scripts/benchmark.sh`, build de release)

| Métrica | Meta | Medido |
| --- | --- | --- |
| Abertura até o dock pronto | ≈ 1,5 s | **85 ms** |
| CPU ociosa (30 s, sem interação) | < 1 % | **0,15 %** em média (pico de 2,6 % numa amostra) |
| Memória (physical footprint) | < ≈ 180 MB | **44 MB** |
| Pipeline de eventos (debug) | — | 23 µs por evento; resumo de 25 sessões em 0,5 ms |

### Suspensão e retomada

Os handlers de `willSleep`/`didWake` foram exercitados com `pulsedockctl control sleep|wake` (mesmo código das
notificações do sistema). O log unificado registrou "will sleep: state saved" e "did wake: sessions reconciled".
Falta um ciclo real de suspensão do Mac (roteiro 4.3).

### Empacotamento

`scripts/package.sh`: ZIP (4,3 MB) e DMG UDZO (4,4 MB). O app dentro do DMG passa em
`codesign --verify --strict --deep`. Sem Developer ID neste Mac, a assinatura é ad-hoc e a notarização não roda.

## 4. Roteiros manuais pendentes

### 4.1 Claude Code

1. Abra dois terminais em projetos diferentes e inicie `claude` em cada um. A ilha deve mostrar os dois
   agentes e "+1"; o card deve listar as duas sessões com projetos distintos.
2. Peça algo que exija permissão (sem modo automático). A ilha fica âmbar ("Aprovação necessária") e a
   sessão vai para o topo. Aprove no terminal: a ilha volta para "Trabalhando".
3. Pressione Esc durante um turno e depois envie outro prompt: o turno anterior aparece como interrompido
   (inferido, com "?").
4. Feche um terminal com a sessão aberta: em até 30 s, a sessão aparece como encerrada.
5. Deixe uma sessão "trabalhando" sem eventos por mais de 10 min (por exemplo, `sleep 900` com permissão):
   o estado não vira "Ocioso"; com comando em execução, continua trabalhando até 45 min.
6. Clique na sessão no card: a aba exata do Terminal/iTerm2 deve vir para frente (o macOS pede Automação
   na primeira vez).

### 4.2 Codex real

1. `npm install -g @openai/codex` e login.
2. Ajustes › Agentes de IA › Codex › Conectar com Hooks…; no Codex, `/hooks` para confiar.
3. Rode uma tarefa curta: confira sessão, ferramentas e "Turno finalizado".
4. Alternativa notify: instale o notify e confirme que entre turnos a UI **não** mostra atividade.
5. Managed Mode: Iniciar uma Tarefa Gerenciada… com um comando que peça aprovação; aprove pelo Agent Card.

### 4.3 Sistema

- Monitor externo: conectar/desconectar com o dock em "Tela principal" e em "Seguir o ponteiro"; mudar
  resolução e escala.
- Suspender o Mac com uma sessão ativa e acordar: o dock reaparece na tela certa; sessões encerradas
  durante a suspensão aparecem como encerradas.
- Replacement Mode: ativar (consentimento do System Events), confirmar o auto-hide do Dock do macOS,
  voltar para Complementar e confirmar a restauração exata.
- Acessibilidade: VoiceOver na ilha e no card; Reduzir Movimento, Reduzir Transparência e Aumentar
  Contraste; navegação por teclado no card (Tab/setas/Return).
- Tela cheia: um app em tela cheia e um jogo sem borda não devem revelar o dock.
- Instalação em outro Mac: requer build assinado com Developer ID e notarizado.

## 5. Regressão

Todo bug reproduzível de forma determinística ganha teste. Os defeitos desta rodada foram visuais
(medição da ilha, quebras de linha, foco, plural, formatação) e foram validados por captura de tela, não
por teste automatizado. Fica pendente um teste de snapshot das views (ver `docs/roadmap.md`). O gerador de
carga ganhou `TestSupport.idPrefix`: sem ele, várias fábricas repetiam IDs e o motor descartava os eventos,
corretamente, como duplicados.

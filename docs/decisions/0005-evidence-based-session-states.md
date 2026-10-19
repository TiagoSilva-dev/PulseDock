# ADR 0005 — Estados de sessão baseados em evidência

- Status: aceito
- Data: 2026-10-18

## Contexto

"Uma integração visualmente impressionante que informa estados falsos é um defeito grave." Hooks não
garantem atualizações periódicas: um `swift build` de três minutos gera um `PreToolUse` e nada mais até o
`PostToolUse`. Interrupções pelo usuário (Esc) não geram `Stop`. Processos podem morrer sem `SessionEnd`.

## Decisão

1. **Estados oficiais** (`AgentCore/Model/States.swift`): `disconnected`, `idle`, `working`,
   `waiting_user`, `waiting_external`, `completed`, `failed`, `interrupted`, `stale`, `unknown`. O ciclo de vida
   da sessão (`SessionLifecycle`: `active`/`ended`) é separado do estado; o turno (`TurnRecord`) e as tarefas
   (`TaskInfo`) também são separados.
2. **Redutor puro**: `SessionReducer.reduce(sessão, evento) → sessão`. O `AgentSessionEngine` mantém um
   buffer limitado por sessão e **reaplica em ordem** quando chega um evento fora de ordem. A ordem usa
   relógio monotônico + boot ID quando disponíveis, e o relógio de parede como desempate. IDs repetidos e
   eventos idênticos quase simultâneos são descartados.
3. **Confiança explícita** em cada estado: `confirmed` (veio do agente), `inferred` (dedução determinística
   documentada) ou `unknown`. A UI mostra a confiança (por exemplo, o "?" no chip de estado).
4. **Regras que nunca inferem sucesso**:
   - `Stop` → turno `completed` ("Turno finalizado"), nunca "tarefa concluída". Tarefa concluída só com
     `TaskCompleted`.
   - Novo prompt com turno aberto, ou `idle_prompt` depois de um turno sem `Stop` → turno anterior
     `interrupted` (`inferred`).
   - Falha de ferramenta (inclusive teste falhando) é evento de falha **dentro** do turno; a sessão segue
     `working`. Só `StopFailure` (erro de API) torna o turno `failed`.
   - Processo do agente encerrado sem `SessionEnd` → sessão `ended`; turno aberto → `interrupted`.
5. **Silêncio não é ociosidade** (`StalenessPolicy`): `working` sem eventos vira `stale` após 10 min
   (configurável). Com um comando em execução observado (`PreToolUse` sem o par), o limite sobe para 45 min.
   Um pedido de permissão espera indefinidamente enquanto o processo estiver vivo.
6. **Liveness**: a cada 30 s, e imediatamente ao acordar o Mac, o app verifica se o processo do agente
   (PID + horário de início, para não confundir PID reutilizado) continua vivo. É uma checagem barata
   (`proc_pidinfo`, com `sysctl` como alternativa), sem ler conteúdo de nenhum processo.
7. **Atividades contextualizadas** só a partir de campos concretos (`ToolClassifier`): nome da ferramenta e
   programa literal do comando (por exemplo, `swift test` → "Executando testes"). Nunca a partir do texto
   do modelo.
8. **Progresso** só com total verificável (tarefas formais `TaskCreated`/`TaskCompleted` ou plano do
   Codex); sem isso, o indicador é indeterminado.

## Consequências

- O mesmo histórico de eventos produz sempre o mesmo estado, qualquer que seja a ordem de chegada (teste
  "Arrival order does not change the resulting session").
- A interface pode dizer "Sem atualizações há 12 min" em vez de mentir "Trabalhando".
- Os testes `SessionReducerTests`, `EngineRobustnessTests`, `PresentationTests` e `LoadTests` cobrem estas
  regras; os do pipeline do Claude Code usam payloads com o esquema oficial.

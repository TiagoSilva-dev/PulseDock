# Integração com o Claude Code

Status: **funcional e validada com sessões reais** (Claude Code 2.1.302, macOS 27.0.1, 2026-10-18).

## 1. Como funciona

```
Claude Code ──hook (stdin JSON)──► pulsedock-hook ──socket 0600──► PulseDock
                                        └── app fechado? ──► spool privado ──► lido na próxima abertura
```

- Usa só os **hooks oficiais** de `~/.claude/settings.json` (ajustes de usuário), então cobre todos os
  projetos sem configuração por projeto.
- O PulseDock **observa**. Aprovações são sempre respondidas no próprio Claude Code: hooks de observação
  não são transformados em controle remoto.

## 2. Instalação

### Pelo app (recomendado)

Ajustes › Agentes de IA › Claude Code › **Conectar…**

1. Detecta o executável (`~/.local/bin/claude`, Homebrew, npm global) e a versão.
2. Escolhe o conjunto de eventos da versão: 18 eventos a partir da 2.1.200; um conjunto conservador
   antes disso.
3. Explica o que será observado e mostra o **diff exato** do `settings.json`.
4. Faz **backup** em `~/Library/Application Support/PulseDock/backups/claude-settings-<data>.json`.
5. Mescla os hooks **sem tocar** em nenhuma outra chave nem em handlers de terceiros. A ordem é preservada
   e a edição é idempotente.
6. Recusa sobrescrever se o arquivo mudou entre a prévia e a aplicação, e reporta JSON inválido em vez de
   reescrevê-lo.
7. Valida o resultado e oferece **Testar Conexão** (o helper envia um evento de autoteste pelo socket).

O Claude Code recarrega o `settings.json`: sessões novas e em andamento passam a enviar eventos.

### Pela linha de comando

```bash
build/release/PulseDock.app/Contents/Helpers/pulsedockctl claude-hooks status
build/release/PulseDock.app/Contents/Helpers/pulsedockctl claude-hooks install    # mesmo instalador: prévia + backup + validação
build/release/PulseDock.app/Contents/Helpers/pulsedockctl claude-hooks uninstall  # remove só as entradas do PulseDock
```

### O que é instalado

Para cada evento, um handler identificado pelo caminho do helper:

```json
{
  "matcher": "*",
  "hooks": [{
    "type": "command",
    "command": "[ -x '<…>/PulseDock/bin/pulsedock-hook' ] && exec '<…>/PulseDock/bin/pulsedock-hook' claude-code PreToolUse || exit 0",
    "timeout": 5
  }]
}
```

- `matcher: "*"` só nos eventos que aceitam matcher.
- O teste `-x` mantém o Claude Code silencioso se o PulseDock for apagado sem desinstalar.
- O `exec` faz o helper herdar o processo do shell, então o pai dele é o próprio Claude Code. É isso que
  permite identificar o app hospedeiro e a TTY para o Smart Return.

## 3. Eventos e mapeamento

| Hook | Evento normalizado | Efeito no estado |
| --- | --- | --- |
| `SessionStart` | `session_started` | sessão conhecida → `idle` |
| `UserPromptSubmit` | `prompt_submitted` | novo turno → `working` ("Pensando"); turno anterior sem `Stop` → `interrupted` (inferido) |
| `PreToolUse` | `tool_started` (+ `plan_updated`/`task_*` para ferramentas de plano/tarefa) | atividade derivada da ferramenta e do comando literal |
| `PostToolUse` | `tool_completed` | ferramenta concluída; turno continua |
| `PostToolUseFailure` | `tool_failed` (categoria: tool/tests/build/interrupt, código de saída) | falha registrada; **sessão segue `working`** |
| `PostToolBatch` | `tool_batch_completed` | fecha o lote; resolve permissão negada sem resultado |
| `PermissionRequest` | `permission_requested` | `waiting_user` ("Aprovação necessária") |
| `PermissionDenied` | `permission_denied` | registra a negação (por exemplo, modo automático) |
| `Notification` `permission_prompt` / `elicitation_*` / `agent_needs_input` | `attention_needed` | `waiting_user` |
| `Notification` `idle_prompt` | `idle_reminder` | mantém `completed`, ou infere `interrupted` se o turno não terminou |
| `SubagentStart` / `SubagentStop` | `subagent_started` / `subagent_stopped` | hierarquia; ferramentas atribuídas ao subagente |
| `TaskCreated` / `TaskCompleted` | `task_created` / `task_completed` | progresso verificável (N de M) |
| `Stop` | `turn_completed` | turno `completed` ("Turno finalizado"), **não** "tarefa concluída" |
| `StopFailure` | `turn_failed` (categoria de API: rate limit, auth, cobrança…) | `failed` |
| `PreCompact` / `PostCompact` | `compaction_started` / `compaction_finished` | "Compactando o contexto" sem reiniciar o turno |
| `SessionEnd` | `session_ended` | ciclo de vida `ended`; turno aberto → `interrupted` |

Sem hook, também: processo do agente encerrado (liveness a cada 30 s e ao acordar o Mac) → sessão `ended`
com turno `interrupted`.

### Atividades exibidas (só de campos concretos)

`Read`/`Glob`/`Grep` → Lendo arquivos / Pesquisando no código · `Edit`/`Write`/`MultiEdit`/`NotebookEdit` →
Editando código · `Bash` → Executando um comando, ou, pelo programa literal: Executando testes
(`swift test`, `npm test`, `pytest`, `go test`, `cargo test`, `xcodebuild test`…), Compilando, Instalando
dependências, Usando o Git · `WebFetch`/`WebSearch` → Consultando a web · `Task`/`Agent` → Trabalhando com
subagentes · `TodoWrite`/tarefas → Atualizando o plano · MCP → Usando uma ferramenta.

## 4. Descoberta de sessões já abertas

Opcional (Ajustes › Agentes de IA › Confiabilidade dos estados): o PulseDock lê `~/.claude/sessions/<pid>.json`
(processo, pasta e nome, nunca os arquivos `.key`), com observação por vnode, sem polling. Assim encontra
sessões que começaram antes dele. É usado **só para descoberta e liveness**: o formato não é documentado, e o
estado nunca é decidido a partir dele.

## 5. Privacidade

O helper sanitiza **antes** de enviar (detalhes em `docs/privacy.md`):

- Nunca saem do helper: prompts, conteúdo de arquivos, saída de comandos, diffs, mensagens do assistente,
  `tool_response`, variáveis de ambiente.
- Comandos: por padrão, a linha de comando com credenciais removidas (até 240 caracteres). Pode ser
  reduzida a "apenas o programa" ou "nada".
- Caminhos de arquivo e consultas de pesquisa podem ser desligados.

## 6. Validação com sessões reais (2026-10-18)

Hooks instalados no `settings.json` global com o instalador do app (backup criado). Observado no
PulseDock, a partir desta própria sessão de desenvolvimento:

- `session_started`, `prompt_submitted`, `tool_started`/`tool_completed`, `tool_batch_completed`,
  `notification`, `turn_completed`, `compaction_finished`.
- Falha real: `ls` num caminho inexistente → `tool_failed · Bash · Exit code 1`.
- Subagente real (`Explore`): `subagent_started`, ferramentas do subagente atribuídas a ele (`subagentID`),
  `subagent_stopped`, e snapshot "Explore · concluído · 2 ferramentas".
- Smart Return: origem capturada como Terminal · `ttys000`.

Ainda não observados ao vivo (cobertos por fixtures com o esquema oficial): `PermissionRequest` (a sessão
estava em modo automático), `StopFailure`, `SessionEnd`, `TaskCreated`/`TaskCompleted` e duas sessões
simultâneas de projetos diferentes. Ver o roteiro manual em `docs/testing.md`.

## 7. Solução de problemas

| Sintoma | Verificação |
| --- | --- |
| Nada aparece | Ajustes › Agentes de IA › **Testar Conexão**; Avançado › Diagnóstico (socket "Escutando", helper "Instalado", último evento) |
| "precisa de reparo" | Hooks incompletos ou apontando para um helper antigo → **Reparar…** |
| Eventos atrasados após reabrir o app | Normal: eventos ocorridos com o app fechado vêm do spool na abertura |
| Erros do helper | `~/Library/Application Support/PulseDock/run/helper-errors.log` (sem conteúdo de sessão) |
| Socket | `pulsedockctl paths` e `pulsedockctl ping` |
| Logs | `/usr/bin/log show --predicate 'subsystem == "app.pulsedock.PulseDock"' --last 10m` |

## 8. Remoção

Ajustes › Agentes de IA › **Desconectar…**, Avançado › **Remover Todos os Hooks do PulseDock…** ou
`pulsedockctl claude-hooks uninstall`. Só os handlers cujo comando referencia `pulsedock-hook` são
removidos. Se a seção `hooks` não existia antes, ela some de novo. Um backup é salvo antes da mudança.

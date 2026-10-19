# Privacidade e permissões

**O PulseDock funciona inteiramente neste Mac e não envia nada a nenhum servidor.** Não há telemetria, conta,
atualização automática nem relatório de falhas remoto.

## 1. O que sai do agente (helper dos hooks)

A sanitização acontece **no helper**, antes de qualquer byte chegar ao socket ou ao spool
(`AgentBridge/HookSanitizer.swift`).

### Nunca é mantido

- Prompts do usuário (só o fato de que houve um prompt).
- Conteúdo de arquivos, diffs e patches (do `apply_patch` do Codex ficam só os nomes dos arquivos).
- Saída de comandos e `tool_response` (do erro, só a primeira linha, redigida e curta, por exemplo
  "Exit code 1").
- Mensagens do assistente (`last_assistant_message`, `input-messages` do notify do Codex).
- Variáveis de ambiente, exceto uma lista fechada de identificadores de terminal para o Smart Return:
  `TERM_PROGRAM`, `TERM_PROGRAM_VERSION`, `TERM_SESSION_ID`, `ITERM_SESSION_ID`, `__CFBundleIdentifier`,
  `TMUX_PANE`, `WEZTERM_PANE`, `KITTY_WINDOW_ID`, `CLAUDE_CODE_ENTRYPOINT`, `CLAUDE_PROJECT_DIR` (e um
  marcador de presença de `TMUX`).
- Credenciais e tokens (ver 1.2).

### Mantido, com limites

| Dado | Limite | Controle |
| --- | --- | --- |
| IDs de sessão, turno, ferramenta, subagente, tarefa | ≤ 160 caracteres | — |
| Pasta de trabalho (`cwd`) e caminho do transcript | ≤ 1024 caracteres | o conteúdo do transcript **nunca** é lido; só a data de modificação serve de sinal de atividade |
| Nome da ferramenta, tipo de subagente, modo de permissão, modelo | curtos | — |
| Linha de comando | ≤ 240 caracteres, credenciais redigidas | Ajustes › Privacidade › Comandos do shell: linha de comando sem credenciais / apenas o programa / nada |
| Caminhos de arquivos das ferramentas | nomes relativos ao projeto | pode ser desligado |
| Padrões de busca e consultas web | ≤ 80–160 caracteres | pode ser desligado |
| Títulos, mensagens de notificação, assunto de tarefa | ≤ 80–200 caracteres, redigidos | — |
| Cadeia de processos (PID, nome, início), TTY | — | usado para liveness e Smart Return |

As preferências do helper ficam em `~/Library/Application Support/PulseDock/helper-config.json`, que o app
escreve.

### 1.2 Redação de credenciais (`SecretRedactor`)

Os padrões preferem redigir a menos: cabeçalhos `Authorization`, `Bearer …`, usuário:senha em URLs,
atribuições `*KEY*/*TOKEN*/*SECRET*/*PASSWORD*=…`, flags `--password/--token/--api-key/…`, chaves `sk-…`,
tokens do GitHub (`ghp_…`, `github_pat_…`), GitLab, Slack, AWS (`AKIA…`), Google (`AIza…`), JWTs, blocos de
chave privada PEM e sequências longas de alta entropia. Testado em "Credentials are redacted from commands,
URLs and messages".

## 2. O que fica guardado no Mac

| Onde | O quê |
| --- | --- |
| `~/Library/Application Support/PulseDock/pulsedock.sqlite` | ajustes; sessões (snapshot do estado); eventos sanitizados |
| `…/PulseDock/run/` (`0700`) | socket (`0600`), spool de eventos sanitizados (`0600`, ≤ 4 MiB), log de erros do helper (sem conteúdo de sessão) |
| `…/PulseDock/backups/` | cópias dos arquivos de configuração dos agentes feitas antes de cada mudança |
| `…/PulseDock/bin/pulsedock-hook` | cópia estável do helper |
| `…/PulseDock/claude-statusline-chain.json` (`0600`) | só se você já tinha uma status line: o objeto dela, para continuar rodando e ser restaurado |
| tabela `settings` (chave `widgets.data.v1`) | Uso do Claude: percentuais e renovação dos limites, custo estimado e linhas por dia (35 dias), último snapshot por sessão (1 dia). Só números, modelo e pasta do projeto |

Controles em Ajustes › Privacidade:

- **Manter um histórico de sessões e eventos**: desligado, só o estado atual vive em memória.
- **Manter os caminhos completos dos projetos no histórico**: desligado, só o nome do projeto é gravado.
- **Apagar o histórico após N dias** (padrão 14).
- **Apagar Histórico…**: apaga sessões e eventos na hora.
- Dados do Modo Demonstração **nunca** são gravados.

## 3. Privacy Mode

Atalho ⌃⌥⌘P, na barra de menus, no card (ícone de olho) ou em Ajustes. Oculta nomes de projetos, caminhos,
títulos de sessão, comandos e detalhes de tarefas **em todas as superfícies**: dock, Quick Peek, Agent
Card, Mission Control e notificações. Fica só o genérico ("Claude Code · Trabalhando"). O PulseDock não tenta
detectar compartilhamento de tela, porque não há API oficial confiável para isso. O atalho existe para ser
ativado antes de apresentar.

## 4. Permissões do macOS

Todas são opcionais, pedidas **no contexto** em que são necessárias, e com degradação elegante.

| Permissão | Quando é pedida | Para quê | Sem ela |
| --- | --- | --- | --- |
| Acessibilidade | "Mostrar Títulos das Janelas…" no menu de um app | listar, restaurar e trazer janelas de outros apps | o dock abre e alterna apps; o menu mostra a contagem de janelas |
| Automação → Terminal / iTerm2 | primeiro Smart Return para uma sessão no terminal | selecionar a aba exata pela TTY | ativa o app hospedeiro identificado |
| Automação → System Events | assistente do Replacement Mode | ocultar o Dock do macOS automaticamente | Replacement Mode indisponível |
| Automação → Música / Spotify | primeiro clique num controle do Tocando Agora | play/pause/próxima | informações continuam (notificações distribuídas) |
| Automação → Finder | "Esvaziar Lixo…" | esvaziar pelo Finder | — |
| Notificações | primeira vez que algo merece notificar | aprovações, perguntas, falhas | a ilha continua destacando |
| Itens de Início | "Abrir o PulseDock ao iniciar a sessão" | `SMAppService` | — |
| Calendários / Lembretes | "Permitir…" no painel do widget Calendário ou Lembretes | mostrar eventos (com botão de chamada) e concluir lembretes | o widget explica e mostra só a data |
| Pastas (Downloads, Mesa, Documentos) | primeira abertura do widget Downloads/Capturas de tela | listar os itens mais recentes | o widget explica como permitir |
| Automação de navegadores (Safari, Chrome…) | "Detectar" no painel do Dock Cinema | mostrar o vídeo do YouTube aberto numa aba; o script devolve só abas do YouTube (endereço e título), nada é gravado | o painel explica e oferece abrir Ajustes |
| Colar de Outros Apps (macOS 15.4+) | "Começar a Registrar…" no widget Área de transferência | registrar o histórico sem alertas (requer "Permitir Sempre") | nada é registrado |

O PulseDock **não** usa Gravação de Tela, Monitoramento de Entrada, Acesso Total ao Disco, localização nem APIs
privadas.

### 4.1 Widgets que acessam a internet (só depois de uma ação do usuário)

| Widget | Destino | O que é enviado |
| --- | --- | --- |
| Clima | `geocoding-api.open-meteo.com`, `api.open-meteo.com` | o nome digitado na busca; depois, as coordenadas da cidade escolhida (a cada 30 min com o widget visível) |
| Dock Cinema | `youtube-nocookie.com`, `youtube.com/oembed`, `i.ytimg.com` | o vídeo que o usuário adicionou; player em modo de privacidade aprimorada, sem cookies persistentes (`WKWebsiteDataStore.nonPersistent`) |

Os demais widgets são locais. A Área de transferência guarda o histórico **só na memória** (textos fixados
são a exceção) e ignora itens marcados como ocultos ou transitórios por gerenciadores de senha.
O desfoque do vidro é do próprio sistema, sem captura de tela.

## 5. Arquivos de terceiros que o PulseDock lê ou escreve

| Arquivo | Leitura | Escrita |
| --- | --- | --- |
| `~/.claude/settings.json` | para mostrar a prévia | só com consentimento: mescla/remove **apenas** handlers do PulseDock e, se você conectar o Uso do Claude, a chave `statusLine` (a sua é preservada e restaurada), com backup |
| `~/.claude/sessions/<pid>.json` | opcional, descoberta de sessões (processo, pasta, nome); arquivos `.key` nunca são abertos | nunca |
| `~/.codex/hooks.json`, `~/.codex/config.toml` | para mostrar a prévia | só com consentimento, com backup |
| Preferências do Dock (`com.apple.dock`) | importar apps fixados e detectar o auto-hide | só no Replacement Mode, com ponto de restauração |
| `Info.plist` de apps | nome, ícone, suporte a múltiplas instâncias | nunca |

## 6. Comunicação local

Unix domain socket em diretório `0700`, arquivo `0600`, `getpeereid` exigindo o mesmo UID, mensagens de no
máximo 512 KiB e validação de esquema. Não há porta TCP nem endpoint HTTP.

## 7. Diagnóstico exportado

Avançado › Exportar Diagnóstico Sanitizado… gera um arquivo com versão, estado das integrações, contadores
e entradas do gravador de diagnóstico (mensagens de infraestrutura). Não inclui prompts, caminhos nem texto
de comandos.

## 8. Remover tudo

1. Ajustes › Avançado › **Remover Todos os Hooks do PulseDock…** (Claude Code e Codex, com backup).
2. Se usou o Replacement Mode: Avançado › **Restaurar o Dock do macOS**.
3. Desligar "Abrir o PulseDock ao iniciar a sessão", encerrar o app e apagar o `.app`.
4. Apagar `~/Library/Application Support/PulseDock/`.

`scripts/uninstall.sh` faz os passos 1, 3 e 4 (com confirmação) e lembra o passo 2.

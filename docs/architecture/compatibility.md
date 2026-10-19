# Matriz de compatibilidade

Alvo: **macOS 15 Sequoia ou superior**, Apple Silicon e Intel (build de release universal).

## 1. Sistema operacional

| Recurso | macOS 15 | macOS 26+ | Como o PulseDock lida |
| --- | --- | --- | --- |
| Material do dock e dos painéis | `NSVisualEffectView` (`.behindWindow`) | Liquid Glass (`glassEffect`) | `PulseGlassSurface` escolhe pelo `#available`; Avançado › Compatibilidade força o caminho do macOS 15 para conferência |
| Display link por view (`NSView.displayLink`) | ✅ (14+) | ✅ | motor de molas |
| `Mutex` (Synchronization) | ✅ (15+) | ✅ | `DiagnosticsRecorder` |
| `onGeometryChange`, `onKeyPress`, `focusEffectDisabled`, `toolbar(removing:)` | ✅ | ✅ | medição da ilha, teclado no card, Ajustes |
| Ativação cooperativa (14+) | ✅ | ✅ | abrir/alternar via LaunchServices (ADR 0002) |
| `SMAppService` (abrir ao iniciar a sessão) | ✅ | ✅ | exige o `.app`; com `swift run`, a opção fica indisponível com aviso |
| `UserNotifications` | ✅ | ✅ | exige o `.app` assinado |
| Prompt periódico "ignorar o seletor de janelas privadas" | ✅ (15+) | ✅ | não afeta o PulseDock (ele não captura a tela) |
| `diskutil image create` (empacotamento) | ❌ | ✅ (27) | `scripts/package.sh` cai para `hdiutil` |

## 2. Hardware

| Arquitetura | Build | Verificado |
| --- | --- | --- |
| Apple Silicon (arm64) | debug e release | ✅ M1 Pro, macOS 27.0.1 |
| Intel (x86_64) | release (universal) | ⚠️ só teste de fumaça sob Rosetta (`pulsedockctl` e helper); falta um Mac Intel real |

## 3. Ferramentas de build

| Ferramenta | Mínimo | Motivo |
| --- | --- | --- |
| Swift tools | 6.2 | `defaultIsolation(MainActor.self)`; modo de linguagem Swift 6 |
| Xcode / Command Line Tools | com SDK do macOS 26+ | APIs do Liquid Glass (com `#available` para o macOS 15) |
| Python 3 | 3.9+ | `scripts/localize.py` |

## 4. Agentes

| Agente | Versão | Integração |
| --- | --- | --- |
| Claude Code | 2.1.200+ | 18 eventos (inclusive `PostToolBatch`, `PermissionDenied`, `StopFailure`, tarefas, compactação) |
| Claude Code | < 2.1.200 | conjunto conservador (`SessionStart`, `SessionEnd`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `Notification`, `SubagentStop`, `Stop`, `PreCompact`) |
| Codex | com hooks | Observe Mode via `hooks.json` (requer `/hooks` para confiar) |
| Codex | sem hooks | Observe Mode via `notify` (só fim de turno) |
| Codex | com `app-server` | Managed Mode |

Verificado ao vivo: Claude Code 2.1.302. Codex: só contra schemas e protocolo oficiais (não instalado).

## 5. Terminais e hospedeiros (Smart Return)

| Hospedeiro | Identificação | Retorno |
| --- | --- | --- |
| Terminal.app | cadeia de processos + TTY | aba exata (Apple Events) |
| iTerm2 | cadeia de processos + TTY / `ITERM_SESSION_ID` | sessão exata (Apple Events) |
| VS Code, Cursor, Windsurf, Zed, IntelliJ, Antigravity | cadeia de processos | abre a pasta do projeto no próprio editor (foca a janela já aberta) |
| Ghostty, Warp, WezTerm, kitty e outros terminais | cadeia de processos (+ variáveis de painel) | ativa o app hospedeiro |
| tmux | o servidor do tmux não descende do terminal; usa o `__CFBundleIdentifier` herdado, quando existe | ativa o terminal identificado (sem selecionar o painel); sem identificação, abre a pasta |
| Desconhecido | — | pasta do projeto no Finder |

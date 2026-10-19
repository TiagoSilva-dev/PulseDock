# ADR 0001 — Um único pacote SwiftPM com um target por módulo

- Status: aceito
- Data: 2026-10-18

## Contexto

A especificação sugere `Packages/<Módulo>` (vários pacotes) e um projeto Xcode. O PulseDock precisa de:
builds reproduzíveis pela linha de comando (agentes de código e CI), três executáveis (app, helper dos hooks,
`pulsedockctl`), fronteiras de módulo verificadas pelo compilador e um bundle `.app` assinado.

## Decisão

- Um `Package.swift` na raiz, com um target por módulo da arquitetura: `Diagnostics`, `AgentCore`,
  `AgentBridge`, `AdapterSupport`, `Persistence`, `ClaudeCodeAdapter`, `CodexAdapter`, `DockRendering`,
  `DockCore`, `WidgetCore` e `PulseDockApp`, mais os executáveis `PulseDock`, `PulseDockHook`
  (`pulsedock-hook`) e `PulseDockCtl` (`pulsedockctl`).
- Os módulos de núcleo (`AgentCore`, `AgentBridge`, `AdapterSupport`, adaptadores, `Persistence`,
  `Diagnostics`) dependem só de Foundation, sem AppKit. Por isso o helper dos hooks continua pequeno e rápido.
- Os módulos de UI usam `defaultIsolation(MainActor.self)` (Swift 6.2+), em modo de linguagem Swift 6 com
  concorrência estrita.
- O `.app` é montado por `scripts/build-app.sh`: copia os executáveis, gera o `Info.plist`, copia as
  localizações e o ícone, e assina (ad-hoc por padrão; Developer ID com `PULSEDOCK_SIGN_IDENTITY`).
- O nome `WidgetKitInternal` da especificação virou `WidgetCore`, para não ser confundido com o WidgetKit da Apple.

## Alternativas consideradas

- **Projeto Xcode (`.xcodeproj`)**: o `project.pbxproj` é frágil para edição por agentes e não é reproduzível
  sem o Xcode aberto. Geradores (XcodeGen/Tuist) exigiriam instalar ferramentas.
- **Vários pacotes em `Packages/`**: mais `Package.swift` para manter, sem ganho real de isolamento sobre
  targets separados do mesmo pacote.

## Consequências

- `swift build` e `swift test` funcionam sem o Xcode aberto; o pacote também abre no Xcode para depurar.
- Recursos do app (localização, ícone) não usam `Bundle.module`, para não depender do acessor gerado pelo
  SwiftPM dentro de um `.app`. São copiados para `Contents/Resources` pelo script de build.
- `UserNotifications` e `SMAppService` exigem o bundle: em `swift run`, essas funções degradam com aviso.

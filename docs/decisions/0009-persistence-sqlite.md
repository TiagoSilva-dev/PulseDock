# ADR 0009 — Persistência em SQLite do sistema, fora da thread principal

- Status: aceito
- Data: 2026-10-18

## Contexto

O PulseDock guarda preferências (ambientes, temas, widgets), sessões e eventos sanitizados para o histórico
do Mission Control. O app precisa continuar fluido com dezenas de sessões e nunca bloquear a thread
principal em disco.

## Decisão

- SQLite da própria plataforma (`import SQLite3`), sem dependências externas, por um wrapper fino
  (`SQLiteDatabase`): WAL, `synchronous = NORMAL`, `busy_timeout` de 2 s e `foreign_keys`.
- Migrações ordenadas, controladas por `PRAGMA user_version` (`Migrations.swift`).
- `PersistenceController` concentra o acesso numa fila serial privada (`qos: .utility`). Escritas são
  assíncronas e em lote; as leituras usadas pela UI também são assíncronas.
- Tabelas: `events` (evento sanitizado + ordem monotônica + boot ID), `sessions` (snapshot do estado) e
  `settings` (JSON versionado das preferências, decodificado de forma tolerante, para que um campo novo
  nunca invalide o arquivo antigo).
- Política de privacidade aplicada **na escrita** (`PersistencePolicy`): histórico desligável, caminhos
  completos removíveis, retenção configurável (14 dias por padrão). Dados de demonstração **nunca** são
  gravados.
- Arquivo: `~/Library/Application Support/PulseDock/pulsedock.sqlite`.

## Consequências

- Reiniciar o app restaura preferências e sessões; a reconciliação de liveness corrige as que terminaram
  enquanto ele estava fechado.
- Testes: `PersistenceTests` (migração, ida e volta das configurações, ordem, demo nunca gravado,
  histórico desligado, caminhos removidos, exclusão e retenção).

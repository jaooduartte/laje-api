# LAJE API

API dedicada do LAJE App, responsável por centralizar as regras de negócio,
autenticação, persistência de dados e comunicação entre o frontend e a
infraestrutura PostgreSQL.

## Arquitetura

Frontend (React)
↓
REST API
↓
LAJE API (Node.js + Express)
↓
PostgreSQL

## Ambientes

### Produção LAJE

A aplicação atualmente utilizada pela LAJE permanece utilizando a
infraestrutura existente baseada em Supabase.

### TCC / Portfólio

O ambiente acadêmico utiliza uma API dedicada e infraestrutura própria,
com backend e banco de dados hospedados na AWS.

## Stack

- Node.js
- TypeScript
- Express
- PostgreSQL
- Docker
- AWS

## Desenvolvimento

Requer Node.js 22 ou superior.

Principais comandos:

```bash
npm run dev
npm run build
npm start
npm run typecheck
npm run lint
npm run format:check
npm test
npm run test:unit
npm run test:e2e
npm run test:coverage
```

`npm start` executa o build automaticamente antes de iniciar `dist/server.js`.
Os testes usam o runner nativo do Node com suporte TypeScript via `tsx`.

A documentação completa de instalação, arquitetura e estratégia de migração
será consolidada na tarefa específica de documentação da API.

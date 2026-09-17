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

Documentação de instalação e execução será adicionada durante a evolução
da API.
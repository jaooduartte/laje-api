# LAJE-148 — ReDoS e criptografia de refresh cookies

Após integrar a LAJE-39, a análise `security-extended` da `main` encontrou dois achados High ([execução original](https://github.com/jaooduartte/laje-api/actions/runs/38774394898)) que não apareciam na comparação das PRs.

1. `js/polynomial-redos`: a leitura de `Authorization: Bearer` utilizava regex com backtracking. Agora faz extração linear com `slice`, validação do separador e rejeição explícita de tokens vazios.
2. `js/clear-text-storage-of-sensitive-data`: o refresh token aleatório era armazenado em cookie HttpOnly/Secure sem criptografia adicional. O cookie agora recebe **AES-256-GCM** com nonce de 96 bits aleatório, tag de 128 bits e chave derivada via HMAC-SHA-256 a partir do segredo JWT, com separação de domínio `laje-refresh-cookie-encryption-v1`.

O armazenamento de sessões no PostgreSQL não mudou: o banco continua guardando **apenas SHA-256 do token aleatório**, e o cookie continua HttpOnly, Secure em produção, SameSite conforme a arquitetura. Os cookies legados (tokens aleatórios de 32 bytes codificados em 43 caracteres base64url) são aceitos durante a transição; novas emissões usam exclusivamente o formato `v1.iv.tag.ciphertext`. Cookies cifrados adulterados ou com chave incorreta são rejeitados. A rotação de `AUTH_JWT_SECRET` invalida JWTs e cookies criptografados, exigindo novo login (o mesmo segredo precisa ser consistente entre réplicas ECS). Não versionar chaves.

Os testes unitários cobrem ida/volta, nonce aleatório, adulteração, chave inválida, compatibilidade legada e parsing de headers, sem alterar dados de produção. Testes e CodeQL devem ser verificados em CI; **não aplicar deploy da API automaticamente**.

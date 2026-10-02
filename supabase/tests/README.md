# pgTAP — testes de RLS

Cenários obrigatórios (CLAUDE.md §8). **Não remover nenhum.**

- `member` não lê foto com menores de criança não vinculada
- `member` não lê foto privada sem grant
- responsável lê a foto do filho vinculado
- `uploader` não consegue `DELETE` em foto
- `INSERT` em `photo_faces` de foto marcada falha
- marcar `contains_minors` apaga embeddings existentes
- `member` não consegue inserir em `guardians`
- `anon` não lê foto com menores de evento público
- `uploader` não torna evento público

Se uma das travas de proteção a menores derrubar um teste, **o teste está
errado** — a trava não se relaxa.

```bash
npx supabase test db
```

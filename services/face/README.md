# services/face — Python 3.12 + FastAPI + InsightFace

Detecta rostos e gera embeddings. Roda no Fly.io, CPU basta.
**Só o servidor chama** — nunca exposto ao navegador. Auth por `X-Service-Token`.

```
main.py     FastAPI: /detect, /embed, /health, /metrics
tests/      pytest
```

Contrato completo em docs/CONTRATO.md §3.

Invioláveis (CLAUDE.md §5.2):

- Embedding facial é dado pessoal sensível (LGPD art. 11). Tratar como senha.
- `/embed` roda **inteiramente em memória**: sem `tempfile`, sem escrita em
  disco, sem log do payload. Existe teste que falha se algo for gravado.
- `/detect` faz streaming da URL assinada e não persiste a imagem.
- Nenhuma resposta ao navegador contém vetor bruto. Nem para debug.

InsightFace `buffalo_l`, 512 dimensões, L2-normalizado. Limiar cosseno `< 0.38`
como ponto de partida — **calibrar com fotos reais do primeiro evento**. Falso
positivo (devolver estranho) é muito pior que falso negativo.

Convenções: `ruff` + `mypy`, tipagem explícita nos handlers.

```bash
cd services/face && uvicorn main:app --reload
cd services/face && pytest
```

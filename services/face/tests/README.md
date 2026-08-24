# pytest — services/face

Teste obrigatório (CLAUDE.md §8): `/embed` **não escreve nada em disco**.
Instrumentar o filesystem durante a chamada e falhar se qualquer arquivo for
criado. Não remover.

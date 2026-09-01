module.exports = {
  extends: ["@commitlint/config-conventional"],
  rules: {
    "scope-enum": [
      2,
      "always",
      [
        "db", // supabase/: migrations, RLS, pgTAP
        "worker", // worker/ (Go)
        "face", // services/face/ (Python)
        "infra", // infra/ (OpenTofu)
        "ci", // .github/workflows
        "docs", // docs/, CONTRIBUTING.md
        "deps", // package.json e afins
        "repo", // configuração geral do repositório
      ],
    ],
    "scope-empty": [2, "never"],
    "subject-case": [2, "never", ["start-case", "pascal-case", "upper-case"]],
  },
};

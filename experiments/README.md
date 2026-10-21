# experiments

비교 실험 하나가 폴더 하나입니다. `..\new-exp.ps1 -Name <이름>`으로 만듭니다.

```
<이름>\
├─ experiment.json   설명·모델·만든 날
├─ NOTES.md          B 구성·관찰·결론
├─ REPORT.md         ..\report.ps1 결과
├─ fixture\          실습 원본 프로젝트(A/B 출발점)
├─ plugins\          B 전용 플러그인(--plugin-dir)
├─ skills\           B 전용 스킬(<스킬>\SKILL.md)
├─ prompts\          지시문(.md)
├─ mcp-B.json        B 전용 MCP 서버
├─ config-B\         (git 제외) B 설정 폴더 · 로그인 토큰
└─ results\          (git 제외) 반복 측정 결과
```

자세한 사용법은 [../docs/usage.md](../docs/usage.md)를 보세요.

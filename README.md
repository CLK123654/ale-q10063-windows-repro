# 通知预算的SQLite发送裁决与配额审计

这个仓库只保存本题正文、四个最终附件、完成后的SQLite脚本和独立Windows门禁。业务入口读取离线通知数据库及三个规则文件，使用SQLite完成静默时段、幂等、去重和两级配额裁决，再导出发送计划、抑制审计及活动配额报告。

四个附件位于artifacts目录，任务正文位于task目录，完成版SQL位于candidate目录。工作流使用windows-2025、Node.js24和SQLite3.51.2，在两个带中文和空格的新目录中各运行两次，同时检查额度变化、规则文件缺失和CRLF换行。

在Windows PowerShell中执行：

    ./scripts/windows_gate.ps1 -RepositoryRoot $PWD -EvidenceRoot $env:TEMP/ale-q10063-evidence

安装SQLite时需要联网。正式任务运行只访问本机文件，不使用外部服务。

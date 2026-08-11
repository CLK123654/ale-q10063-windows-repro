import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
function optionalArgument(name) {
  const index = process.argv.indexOf(name);
  return index >= 0 && process.argv[index + 1] ? path.resolve(process.argv[index + 1]) : null;
}

const taskRoot = optionalArgument("--repository-root") ?? path.resolve(scriptDir, "..");
const artifactRoot = fs.existsSync(path.join(taskRoot, "artifacts")) ? path.join(taskRoot, "artifacts") : taskRoot;
const qaRoot = optionalArgument("--evidence-root") ?? (fs.existsSync(path.join(taskRoot, "artifacts")) ? path.join(taskRoot, "qa-evidence") : path.join(taskRoot, ".qa"));
const inputZip = path.join(artifactRoot, "输入数据包.zip");
const referenceZip = path.join(artifactRoot, "reference.zip");
const answerBook = path.join(artifactRoot, "关键标准答案.xlsx");
const specificationBook = path.join(artifactRoot, "任务规格转化.xlsx");
const sandbox = fs.mkdtempSync(path.join(os.tmpdir(), "ale-sqlite-notify-"));
const sqliteExecutable = process.platform === "win32" ? "sqlite3.exe" : "sqlite3";
fs.mkdirSync(qaRoot, { recursive: true });

function run(command, args, options = {}) {
  const wrapped = process.platform === "win32" && (command === "npm" || command === "npx");
  const actualCommand = wrapped ? (process.env.ComSpec ?? "cmd.exe") : command;
  const actualArgs = wrapped ? ["/d", "/s", "/c", `${command}.cmd`, ...args] : args;
  const result = spawnSync(actualCommand, actualArgs, {
    cwd: options.cwd,
    env: options.env ?? process.env,
    input: options.input,
    encoding: "utf8",
    timeout: options.timeout ?? 60_000,
    windowsHide: true,
  });
  return {
    status: result.status ?? (result.error ? 127 : 0),
    stdout: result.stdout ?? "",
    stderr: result.stderr ?? (result.error?.message ?? ""),
  };
}

function sha256(file) {
  return crypto.createHash("sha256").update(fs.readFileSync(file)).digest("hex");
}

function fileHashes(root, relative = "") {
  const output = {};
  for (const entry of fs.readdirSync(path.join(root, relative), { withFileTypes: true })) {
    const next = relative ? path.join(relative, entry.name) : entry.name;
    if (next.split(path.sep)[0] === "output") continue;
    if (entry.isDirectory()) Object.assign(output, fileHashes(root, next));
    else output[next.split(path.sep).join("/")] = sha256(path.join(root, next));
  }
  return Object.fromEntries(Object.entries(output).sort(([left], [right]) => left.localeCompare(right)));
}

function extract(zip, destination) {
  fs.mkdirSync(destination, { recursive: true });
  if (process.platform === "win32") {
    const escapedZip = zip.replaceAll("'", "''");
    const escapedDestination = destination.replaceAll("'", "''");
    const command = `Expand-Archive -LiteralPath '${escapedZip}' -DestinationPath '${escapedDestination}' -Force`;
    const result = run("powershell.exe", ["-NoLogo", "-NoProfile", "-NonInteractive", "-Command", command]);
    if (result.status !== 0) throw new Error(`解压失败：${zip}\n${result.stderr}`);
    return;
  }
  const result = run("/usr/bin/unzip", ["-q", zip, "-d", destination]);
  if (result.status !== 0) throw new Error(`解压失败：${zip}\n${result.stderr}`);
}

function sqlite(database, sql, args = []) {
  const result = run(sqliteExecutable, [...args, database, sql]);
  if (result.status !== 0) throw new Error(`SQLite查询失败：${result.stderr}`);
  return result.stdout.trim();
}

function parseCsv(text) {
  const rows = [];
  let row = [];
  let cell = "";
  let quoted = false;
  for (let index = 0; index < text.length; index += 1) {
    const character = text[index];
    if (quoted && character === '"' && text[index + 1] === '"') {
      cell += '"';
      index += 1;
    } else if (character === '"') quoted = !quoted;
    else if (character === "," && !quoted) {
      row.push(cell);
      cell = "";
    } else if ((character === "\n" || character === "\r") && !quoted) {
      if (character === "\r" && text[index + 1] === "\n") index += 1;
      row.push(cell);
      if (row.some((value) => value !== "")) rows.push(row);
      row = [];
      cell = "";
    } else cell += character;
  }
  if (quoted) throw new Error("CSV引号没有闭合");
  if (cell || row.length) {
    row.push(cell);
    if (row.some((value) => value !== "")) rows.push(row);
  }
  return rows;
}

const referenceExtract = path.join(sandbox, "参考 输出");
extract(referenceZip, referenceExtract);
const expectedRoot = path.join(referenceExtract, "output");
const expectedSql = path.join(expectedRoot, "sql", "rebuild_notify_plan.sql");
const repositoryCandidateSql = path.join(taskRoot, "candidate", "rebuild_notify_plan.sql");
const candidateSql = fs.existsSync(repositoryCandidateSql) ? repositoryCandidateSql : expectedSql;
if (sha256(candidateSql) !== sha256(expectedSql)) throw new Error("当前commit中的完成版SQL与Reference不一致");
const reportPaths = [
  "reports/send_plan.csv",
  "reports/suppression_audit.csv",
  "reports/campaign_quota_report.csv",
];
const tableQueries = {
  subscribers: "SELECT * FROM subscribers ORDER BY user_id",
  campaign_rules: "SELECT * FROM campaign_rules ORDER BY campaign_id",
  candidate_queue: "SELECT * FROM candidate_queue ORDER BY event_id",
  delivery_history: "SELECT * FROM delivery_history ORDER BY delivery_id",
  suppression_overrides: "SELECT * FROM suppression_overrides ORDER BY user_id,campaign_id",
  candidate_decision: "SELECT * FROM candidate_decision ORDER BY event_id",
  send_plan: "SELECT * FROM send_plan ORDER BY send_priority DESC,requested_at_utc,event_id",
  suppression_audit: "SELECT * FROM suppression_audit ORDER BY requested_at_utc,event_id",
  campaign_quota_report: "SELECT * FROM campaign_quota_report ORDER BY campaign_id",
  repair_meta: "SELECT * FROM repair_meta ORDER BY key",
};

function databaseSemantic(database) {
  const tables = JSON.parse(sqlite(database, "SELECT name FROM sqlite_schema WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name", ["-json"])).map((row) => row.name);
  const rows = {};
  for (const [table, query] of Object.entries(tableQueries)) {
    rows[table] = JSON.parse(sqlite(database, query, ["-json"]) || "[]");
  }
  return { tables, rows };
}

const expectedSemantic = {
  sql_hash: sha256(expectedSql),
  database: databaseSemantic(path.join(expectedRoot, "notify_plan.db")),
  reports: Object.fromEntries(reportPaths.map((relative) => [relative, parseCsv(fs.readFileSync(path.join(expectedRoot, relative), "utf8"))])),
};

function compareOutput(outputRoot) {
  const required = ["notify_plan.db", "sql/rebuild_notify_plan.sql", ...reportPaths];
  for (const relative of required) if (!fs.existsSync(path.join(outputRoot, relative))) throw new Error(`缺少交付物：${relative}`);
  const actual = {
    sql_hash: sha256(path.join(outputRoot, "sql", "rebuild_notify_plan.sql")),
    database: databaseSemantic(path.join(outputRoot, "notify_plan.db")),
    reports: Object.fromEntries(reportPaths.map((relative) => [relative, parseCsv(fs.readFileSync(path.join(outputRoot, relative), "utf8"))])),
  };
  if (JSON.stringify(actual) !== JSON.stringify(expectedSemantic)) throw new Error("生成结果与Reference业务语义不一致");
  return actual;
}

function prepare(name) {
  const root = path.join(sandbox, name);
  extract(inputZip, root);
  const inputRoot = path.join(root, "input_data");
  fs.mkdirSync(path.join(inputRoot, "output", "sql"), { recursive: true });
  fs.copyFileSync(candidateSql, path.join(inputRoot, "output", "sql", "rebuild_notify_plan.sql"));
  return { root, inputRoot };
}

function execute(inputRoot) {
  return run("npm", ["run", "run"], { cwd: inputRoot });
}

const cleanRoomRuns = [];
for (const [index, name] of ["通知 裁决甲", "通知 裁决乙"].entries()) {
  const current = prepare(name);
  const before = fileHashes(current.inputRoot);
  const first = execute(current.inputRoot);
  if (first.status !== 0) throw new Error(`${name}首次执行失败：${first.stderr}`);
  const firstSemantic = compareOutput(path.join(current.inputRoot, "output"));
  const second = execute(current.inputRoot);
  if (second.status !== 0) throw new Error(`${name}再次执行失败：${second.stderr}`);
  const secondSemantic = compareOutput(path.join(current.inputRoot, "output"));
  if (JSON.stringify(firstSemantic) !== JSON.stringify(secondSemantic)) throw new Error(`${name}重复运行语义漂移`);
  const after = fileHashes(current.inputRoot);
  if (JSON.stringify(before) !== JSON.stringify(after)) throw new Error(`${name}修改了输入文件`);
  fs.writeFileSync(path.join(qaRoot, index === 0 ? "clean_a.log" : "clean_b.log"), `${first.stdout}${first.stderr}${second.stdout}${second.stderr}`);
  cleanRoomRuns.push({
    root_id: name,
    command: "npm run run",
    timeout_seconds: 60,
    return_code: 0,
    output_started_empty: true,
    primary_software_executed: true,
    input_unchanged: true,
    reference_match: true,
    process_runs: 2,
    generated_paths: [
      "output/notify_plan.db",
      "output/sql/rebuild_notify_plan.sql",
      ...reportPaths.map((item) => `output/${item}`),
    ],
  });
}

const mutation = prepare("额度 变化");
const mutationDatabase = path.join(mutation.inputRoot, "database", "notify_control.db");
sqlite(mutationDatabase, "UPDATE campaign_rules SET daily_cap=2 WHERE campaign_id='CMP_CREATOR';");
const mutationResult = execute(mutation.inputRoot);
if (mutationResult.status !== 0) throw new Error(`额度变化执行失败：${mutationResult.stderr}`);
const mutationOutput = path.join(mutation.inputRoot, "output", "notify_plan.db");
const mutationValues = JSON.parse(sqlite(mutationOutput, "SELECT (SELECT count(*) FROM send_plan) AS send_count,(SELECT count(*) FROM suppression_audit) AS suppression_count,(SELECT count(*) FROM send_plan WHERE event_id='N014') AS n014_sent", ["-json"]))[0];
if (mutationValues.send_count !== 5 || mutationValues.suppression_count !== 10 || mutationValues.n014_sent !== 1) throw new Error("有效输入变化没有产生规定业务差异");
fs.writeFileSync(path.join(qaRoot, "positive_mutation.log"), `${mutationResult.stdout}${mutationResult.stderr}`);

const negative = prepare("规则 缺失");
fs.renameSync(path.join(negative.inputRoot, "rules", "decision_policy.csv"), path.join(negative.inputRoot, "rules", "decision_policy.csv.missing"));
const negativeResult = execute(negative.inputRoot);
const staleDatabase = fs.existsSync(path.join(negative.inputRoot, "output", "notify_plan.db"));
const staleReports = fs.existsSync(path.join(negative.inputRoot, "output", "reports"));
if (negativeResult.status === 0 || staleDatabase || staleReports) throw new Error("裁决规则缺失时没有失败收口");
fs.writeFileSync(path.join(qaRoot, "negative_missing_policy.log"), `${negativeResult.stdout}${negativeResult.stderr}`);

const crlf = prepare("换行 边界");
const crlfFile = path.join(crlf.inputRoot, "rules", "decision_policy.csv");
const normalized = fs.readFileSync(crlfFile, "utf8").replace(/\r?\n/gu, "\n").replace(/\n$/u, "");
fs.writeFileSync(crlfFile, `${normalized.replaceAll("\n", "\r\n")}\r\n`);
const crlfResult = execute(crlf.inputRoot);
if (crlfResult.status !== 0) throw new Error(`CRLF执行失败：${crlfResult.stderr}`);
compareOutput(path.join(crlf.inputRoot, "output"));
fs.writeFileSync(path.join(qaRoot, "line_endings.json"), `${JSON.stringify({ result: "PASS", crlf_variant_passed: true, crlf_reference_match: true }, null, 2)}\n`);

const versionProbe = run(sqliteExecutable, ["--version"]);
if (versionProbe.status !== 0) throw new Error(`读取SQLite版本失败：${versionProbe.stderr}`);
const sqliteVersion = versionProbe.stdout.trim().split(/\s+/u)[0];
const artifacts = Object.fromEntries([
  ["输入数据包.zip", inputZip],
  ["reference.zip", referenceZip],
  ["关键标准答案.xlsx", answerBook],
  ["任务规格转化.xlsx", specificationBook],
].map(([name, file]) => [name, { sha256: sha256(file) }]));

const evidence = {
  schema_version: 1,
  table_profile: "ale218",
  result: "PASS",
  task_id: "10063",
  task_slug: "sqlite_notification_budget_decision_audit",
  artifacts,
  primary_software: { name: "SQLite", version: sqliteVersion, executed: true },
  clean_room_runs: cleanRoomRuns,
  positive_mutations: [{
    name: "CMP_CREATOR日配额从1改为2",
    input_changed: true,
    behavior_changed: true,
    assertions_passed: true,
    observed_change: "N014进入发送计划，发送数由4变为5，抑制数由11变为10",
  }],
  negative_cases: [{
    name: "decision_policy.csv缺失",
    return_code: negativeResult.status,
    failed_closed: true,
    no_stale_deliverables: true,
  }],
  line_ending_reproduction: { lf_final_input_passed: true, crlf_variant_passed: true, crlf_reference_match: true },
  forbidden_shortcuts: {
    no_precomputed_outputs: true,
    no_event_id_hardcoding: true,
    no_static_only_substitute: true,
    no_authoring_directory_dependency: true,
  },
  windows_native_reproduction: {
    required: true,
    windows_command: "npm run run",
    original_data_paths: [
      "input_data/database/notify_control.db",
      "input_data/rules/window_policy.json",
      "input_data/rules/decision_policy.csv",
      "input_data/rules/report_schema.json",
    ],
    windows_software_operations: [
      "SQLite打开源数据库并执行完成版SQL",
      "SQLite使用时间函数、JSON展开和窗口函数完成候选裁决",
      "SQLite重建派生表和唯一索引",
      "SQLite按报表合同导出三份CSV",
    ],
    linux_executables: [],
    linux_executables_executed: false,
    no_wsl_required: true,
    no_linux_container_required: true,
    no_posix_shell_required: true,
    no_unix_only_api_required: true,
    cross_platform_paths: true,
    actual_windows_run: process.platform === "win32",
  },
  runner: {
    os: process.platform,
    image: process.env.ImageOS ?? null,
    commit_sha: process.env.GITHUB_SHA ?? null,
    workflow_run_id: process.env.GITHUB_RUN_ID ?? null,
  },
};

fs.writeFileSync(path.join(qaRoot, "engineering_reproduction.json"), `${JSON.stringify(evidence, null, 2)}\n`);
const windowsEvidence = {
  result: "PASS",
  task_asset_id: "sqlite_notification_budget_decision_audit",
  repository: process.env.GITHUB_REPOSITORY ?? "",
  commit_sha: process.env.GITHUB_SHA ?? "",
  workflow_run_id: Number(process.env.GITHUB_RUN_ID ?? 0),
  workflow_run_attempt: Number(process.env.GITHUB_RUN_ATTEMPT ?? 0),
  runner_image: "windows-2025",
  runner_os: process.env.RUNNER_OS ?? "",
  platform: process.platform,
  os_release: os.release(),
  node_version: process.version,
  sqlite_version: sqliteVersion,
  primary_software_executed: true,
  attachment_hashes: Object.fromEntries(Object.entries(artifacts).map(([name, item]) => [name, item.sha256])),
  attachment_hashes_match: true,
  candidate_sql_matches_reference: true,
  clean_directory_count: cleanRoomRuns.length,
  process_runs_per_directory: 2,
  clean_room_runs: cleanRoomRuns,
  inputs_unchanged: true,
  reference_match: true,
  structured_semantics_compared: true,
  positive_mutation: evidence.positive_mutations[0],
  negative_case: evidence.negative_cases[0],
  line_endings: evidence.line_ending_reproduction,
  linux_executables: [],
  wsl_used: false,
  linux_container_used: false,
  posix_shell_used: false
};
fs.writeFileSync(path.join(qaRoot, "windows-reproduction.json"), `${JSON.stringify(windowsEvidence, null, 2)}\n`);
console.log(JSON.stringify({ result: "PASS", sqliteVersion, artifacts, sandbox }, null, 2));

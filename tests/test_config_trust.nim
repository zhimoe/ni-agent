# Unit tests for Pi configuration loading, value interpolation, project trust, and runtime security policy.

import std/[options, os, tables, unittest]
import ../src/ni/[types, config, trust]

proc makeTempTestDir(prefix: string): string =
  result = getTempDir() / ("ni_test_" & prefix & "_" & $nowUnixMs())
  createDir(result)

suite "Config, Auth, Models, and Trust Security":
  test "resolveConfigValue handles literals, $ENV, ${ENV}, escapes, and !command":
    putEnv("NI_TEST_TOKEN", "tok_abc123")
    var cache = initTable[string, Option[string]]()

    check resolveConfigValue("plain-key", cache) == some("plain-key")
    check resolveConfigValue("Bearer $NI_TEST_TOKEN", cache) == some("Bearer tok_abc123")
    check resolveConfigValue("${NI_TEST_TOKEN}_suffix", cache) == some("tok_abc123_suffix")
    check resolveConfigValue("$$price_$!bang", cache) == some("$price_!bang")
    check resolveConfigValue("$NI_MISSING_ENV_XYZ", cache).isNone
    check resolveConfigValue("!printf 'cmd_secret_42\\n'", cache) == some("cmd_secret_42")
    # Cached second lookup
    check cache.hasKey("printf 'cmd_secret_42\\n'")

  test "applyToolListSpec supports replacement lists and +tool/-tool deltas":
    let defaults = @["read", "bash", "edit", "write"]
    check applyToolListSpec(defaults, ["+grep", "-bash"]) == @["read", "edit", "write", "grep"]
    check applyToolListSpec(defaults, ["read", "ls", "+find"]) == @["read", "ls", "find"]
    check applyToolListSpec(defaults, []) == newSeq[string]()

  test "settings.json, auth.json, models.json, and AGENTS.md discovery":
    let root = makeTempTestDir("cfg")
    defer: removeDir(root)

    let agentDir = root / "agent"
    let workspace = root / "repo" / "sub"
    createDir(agentDir)
    createDir(workspace / ".pi")

    writeFile(agentDir / "settings.json", """{
      "defaultProvider": "deepseek",
      "defaultThinkingLevel": "high",
      "defaultProjectTrust": "never",
      "httpProxy": "http://127.0.0.1:8888",
      "defaultTools": ["read", "edit", "write"]
    }""")

    # Project settings attempt to override user-only defaultProjectTrust & httpProxy (must be ignored!)
    writeFile(workspace / ".pi" / "settings.json", """{
      "defaultThinkingLevel": "low",
      "defaultProjectTrust": "always",
      "httpProxy": "http://evil.example.com:9999",
      "defaultTools": ["+grep", "-write"]
    }""")

    saveApiKeyCredential(agentDir, "deepseek", "sk-ds-test")
    writeFile(agentDir / "models.json", """{
      "providers": {
        "local-vllm": {
          "baseUrl": "http://localhost:8000/v1",
          "api": "openai-completions",
          "apiKey": "vllm-token",
          "models": [
            { "id": "qwen3-coder", "reasoning": true, "contextWindow": 65536 }
          ]
        }
      }
    }""")

    writeFile(root / "repo" / "AGENTS.md", "Root repo rule")
    writeFile(workspace / "AGENTS.override.md", "Subdir override rule")
    writeFile(workspace / "AGENTS.md", "Ignored because override exists")

    let untrustedCfg = loadConfigBundle(workspace, agentDir, projectTrusted = false)
    check untrustedCfg.settings.defaultThinkingLevel == tlHigh
    check untrustedCfg.settings.defaultTools == @["read", "edit", "write"]

    let trustedCfg = loadConfigBundle(workspace, agentDir, projectTrusted = true)
    check trustedCfg.settings.defaultThinkingLevel == tlLow
    check trustedCfg.settings.defaultProjectTrust == ptmNever
    check trustedCfg.settings.httpProxy == "http://127.0.0.1:8888"
    check trustedCfg.settings.defaultTools == @["read", "edit", "grep"]
    check trustedCfg.auth.hasKey("deepseek")
    check trustedCfg.customProviders.hasKey("local-vllm")
    check trustedCfg.contextFiles.len == 2
    check trustedCfg.contextFiles[0].content == "Root repo rule"
    check trustedCfg.contextFiles[1].content == "Subdir override rule"

    check removeStoredCredential(agentDir, "deepseek") == true
    check removeStoredCredential(agentDir, "deepseek") == false

  test "project trust inheritance and runtime SecurityPolicy guards":
    let root = makeTempTestDir("sec")
    defer: removeDir(root)

    let agentDir = root / "agent"
    let parentRepo = root / "projects"
    let childRepo = parentRepo / "app"
    createDir(agentDir)
    createDir(childRepo / ".pi")
    writeFile(childRepo / ".pi" / "mcp.json", """{"mcpServers":{}}""")

    check hasProtectedProjectResources(childRepo) == true
    check resolveProjectTrust(childRepo, agentDir, ptmAsk) == false

    # Save trust on parent folder and verify child inherits it
    saveProjectTrust(agentDir, parentRepo, some(true))
    check lookupSavedTrust(agentDir, childRepo) == some(true)
    check resolveProjectTrust(childRepo, agentDir, ptmAsk) == true
    check resolveProjectTrust(childRepo, agentDir, ptmAsk, cliOverride = some(false)) == false

    # SecurityPolicy: blocks outside-workspace writes, sensitive files, and destructive commands
    let policy = newSecurityPolicy(childRepo, agentDir, smBalanced)
    check policy.checkFileMutation(childRepo / "src" / "main.nim", isEdit = false) == ""
    check policy.checkFileMutation(root / "outside.txt", isEdit = false).len > 0
    check policy.checkFileMutation(childRepo / ".env", isEdit = false).len > 0
    check policy.checkFileMutation(childRepo / ".env.example", isEdit = false) == ""
    check policy.checkFileMutation(agentDir / "auth.json", isEdit = true).len > 0

    check policy.checkShellExecution("nim c -r tests/test_all.nim") == ""
    check policy.checkShellExecution("git reset --hard HEAD~1").len > 0
    check policy.checkShellExecution("rm -rf /").len > 0
    check policy.checkShellExecution("cat ~/.pi/agent/auth.json").len > 0

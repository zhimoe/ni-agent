# Master unit and integration test suite for `ni`.

include ./test_config_trust
include ./test_provider_agent
include ./test_tools_skills_mcp
include ./test_cli_e2e
include ./test_tui_markdown_rpc

echo "\nAll ni test suites passed!"

# Structured system prompt builder compatible with Pi's section layout.

import std/[sets, strutils, tables]
import ./[types, config, tools, skills, mcp]

type
  PromptBuildInput* = object
    cwd*: string
    customSystemPrompt*: string
    appendSystemPrompt*: string
    cliAppendPrompts*: seq[string]
    contextFiles*: seq[ContextFile]
    toolRegistry*: ToolRegistry
    skills*: seq[Skill]
    mcpManager*: McpManager

proc renderProjectContextSection(files: openArray[ContextFile]): string =
  if files.len == 0:
    return ""
  var blocks: seq[string] = @["Project-specific instructions and guidelines:"]
  for cf in files:
    blocks.add("<project_instructions path=\"" & cf.path.replace('\\', '/') & "\">\n" &
               cf.content & "\n</project_instructions>")
  blocks.join("\n\n")

proc buildSystemPrompt*(input: PromptBuildInput): string =
  ## Assemble the complete system prompt from preamble, active tools, rules, context files, skills, MCP servers, and cwd.
  var sections: seq[string] = @[]

  if input.customSystemPrompt.strip().len > 0:
    sections.add(input.customSystemPrompt.strip())
  else:
    sections.add("You are a coding assistant running inside ni, a fast Nim coding agent compatible with Pi. Help users inspect files, run commands, clarify requirements, and modify code accurately.")

    if not input.toolRegistry.isNil:
      var toolLines: seq[string] = @[]
      var ruleLines: seq[string] = @[]
      var seenRules = initHashSet[string]()

      for tname, tool in input.toolRegistry.tools.pairs:
        if tname in input.toolRegistry.activeNames and tool.exposure != teHidden:
          let snip = if tool.snippet.len > 0: tool.snippet else: tool.description
          toolLines.add("- " & tname & ": " & snip)
          for g in tool.guidelines:
            let trimmed = g.strip()
            if trimmed.len > 0 and trimmed notin seenRules:
              seenRules.incl(trimmed)
              ruleLines.add("- " & trimmed)

      ruleLines.add("- Be concise and direct in your responses.")
      ruleLines.add("- Show file paths clearly when reading or modifying files.")

      let toolsText = if toolLines.len > 0: toolLines.join("\n") else: "(none)"
      sections.add("<tools>\n" & toolsText & "\n</tools>")
      sections.add("<rules>\n" & ruleLines.join("\n") & "\n</rules>")

  var addenda: seq[string] = @[]
  if input.appendSystemPrompt.strip().len > 0:
    addenda.add(input.appendSystemPrompt.strip())
  for extra in input.cliAppendPrompts:
    if extra.strip().len > 0:
      addenda.add(extra.strip())
  if addenda.len > 0:
    sections.add("<addendum>\n" & addenda.join("\n\n") & "\n</addendum>")

  let projCtx = renderProjectContextSection(input.contextFiles)
  if projCtx.len > 0:
    sections.add("<project_context>\n" & projCtx & "\n</project_context>")

  if input.skills.len > 0 and not input.toolRegistry.isNil:
    let reader = if "read" in input.toolRegistry.activeNames: "read"
                 elif "bash" in input.toolRegistry.activeNames: "bash"
                 else: ""
    if reader.len > 0:
      let skillsXml = formatSkillsForPrompt(input.skills, reader)
      if skillsXml.len > 0:
        sections.add("<skills>\n" & skillsXml & "\n</skills>")

  if not input.mcpManager.isNil:
    let mcpSec = formatMcpServersPromptSection(input.mcpManager)
    if mcpSec.len > 0:
      sections.add("<mcp_servers>\n" & mcpSec & "\n</mcp_servers>")

  sections.add("<cwd>\n" & input.cwd.replace('\\', '/') & "\n</cwd>")
  sections.join("\n\n")

# Orchestrator Builder

A visual node editor for building and running agent teams in Zeron v3.

![Orchestrator Builder running in Zeron](docs/screenshot.png)

[Watch the one-minute showcase](docs/saved-team-showcase.mp4). Music: [“Smash It” by Shane Ivers](https://www.silvermansound.com/free-music/smash-it), [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). Trimmed, tempo-matched and faded for the video.

## Install

1. Download the `.zeron-plugin` package from the [latest release](https://github.com/Master0fFate/zeron-orchestration-builder/releases/latest).
2. In Zeron, open Settings → Plugins → Install and select the file.
3. Review and approve the requested permissions, then open Orchestrator Builder from the sidebar.

The plugin requires Zeron v3 and a configured agent. No changes to Zeron or separate helper are needed.

## Use

- The first install opens a starter team. Choose **New team** to preview and create a workflow preset or start with **Blank**. Add or edit blocks from the toolbar. Creating a team does not change existing teams or start a run.
- Drag a block to move it. Drag an output dot to another block's input dot to connect them. Select a line to edit its condition or remove it. Conditions are Always, Pass and Fail; a Fail return needs a retry limit from 1 to 10. The limit counts failure returns across the entire run. Save connection applies settings; Remove connection deletes it. Incomplete drafts can be saved and checked later.
- Drag empty canvas space to pan, scroll to zoom at the pointer, and use Fit to frame the graph. The grid can be turned on or off from the toolbar.
- Select a block's settings icon to edit its name, icon, runtime, provider, model and role instructions. Choose Other agent to enter a custom runtime ID. Save the block to apply the edits.
- Custom icons are self-contained SVG files up to 16 KB. Zeron stores their contents with the team in the plugin's own storage; they are not separate files in the signed plugin folder.
- The team name is shown in the header and can be changed through its edit control. Open Team to create a new team or switch between saved teams. Names, positions, settings and connections are saved locally.
- In Team, export the current team to a JSON file or import a team JSON file as a separate saved team. Plain teams use version 2, saved-team compositions use version 3, and workflows with the change-review blocks use version 4. Custom SVG icons and embedded team snapshots are included.
- Open Team for the name and checks. Checks flag missing inputs and outputs, invalid routes, unreachable blocks, missing role instructions, incomplete model choices, missing Finish blocks and unbounded cycles. A manually entered model ID is not checked against the catalog.

New role blocks start with editable default instructions. Custom instructions replace the default; Restore default puts it back. They are task text, not a system prompt. Chief is an entry point, not an agent turn: its settings are not used for runs, and it is not linked to the active chat. The plugin does not intercept the main chat's messages.

## Workflow presets

| Preset | Use it to |
| --- | --- |
| Plan, build, review | Turn a brief into a plan, implement it, and get a separate review. |
| Plan only | Get ordered steps and acceptance criteria without changing anything. |
| Research & compare | Gather evidence, compare options, and make a recommendation. |
| Review & revise | Draft, review, and send concrete issues back to the writer for up to two revisions. |
| Review a change | Review a Git change by folder and prepare an unsent draft. Requires a change source and a checkout that can read its diff. |
| Blank | Start with Chief and wire your own workflow. |

Each preset is an editable copy with no model pinned. Pick a destination with a configured default agent or choose a runtime and model for each role. The four general presets do not need a Git change source.

## Reuse a saved team

1. Save a complete team, such as a release-note review team.
2. Switch to another team and choose **Add block → Saved team**. Select the review team and choose **Add block**.
3. Connect the new block like any other. Give it one **Always** output. Open the block’s settings to see its saved roles.

Builder copies the source into the block. Editing the source doesn’t change existing copies; remove and re-add a block to refresh it. You can include several saved teams in a workflow, but a saved team cannot itself contain team blocks. To share the composed workflow, export its JSON; recipients don’t need to import each source team separately.

When the run reaches a team block, its roles get the original task and run in their own chats. The embedded team’s **Finish** returns a bounded list of findings to the parent workflow, rather than ending the run. **Team output** shows the latest returned findings and their evidence. Later parent roles receive the handoff as context, not as instructions. These findings are agent reports, not independent verification.

## Review a change

- **Changes** reads a commit, compares two refs, or reads a GitHub pull request. Choose the source in **Start**. Local sources use the selected session’s Git checkout; PRs use Zeron’s GitHub connection. The next blocks get the resolved revision and changed paths. From Git History, **Review in Orchestrator Builder** stages that commit; open Builder to review the inputs and start the run.
- **Check** follows **Yes** or **No** for changed files, documentation changes, or PR CI. It does not start an agent. Pending or unavailable CI blocks instead of taking the No route.
- **For each** runs a copy of a saved team once per changed top-level folder, or once per item in a list you enter. Each item gets fresh chats; items run one at a time. Set a maximum of 1–8 items. **Collect** must follow directly and returns findings with their originating items.
- **Draft** prepares text from the findings. Open **Review draft**, review the citations, then choose **Append to composer**. Builder never sends it. Exact changed-line citations from bounded local diffs can become inline review comments; other evidence stays in the text. Changes supplies context, not an isolated or revision-pinned agent checkout.

## Run a team

Select Start, enter a task, select an existing session on this device under Destination and confirm. The session supplies its device and, when present, project; check the IDs in the selection before starting. Remote destinations are unsupported: they may start a chat but cannot be relied on to deliver the tool call or terminal events to this runner. Local Git and composer actions require a destination on this device. The selected session is not sent messages. If no valid local session is available, create one on this device first. The runner validates the destination and team before claiming the journal, and snapshots both for the run; later edits, team switches or session changes do not change it. The destination is stored in the run journal, including for interrupted runs. Acceptance starts asynchronous journal setup, not a guarantee that a chat was sent. The status and reason show progress or failure, and the route is a block ID in the run snapshot, not necessarily the team currently displayed.

The runner follows Chief's output and starts one chat per role block per run on the selected device and project, using that block's runtime and model when set. The first prompt starts with the block and team names to distinguish chat titles. Repeat visits reuse that block's chat and its context, including retries; separate blocks and separate runs have separate chats. It sends the task, role instructions and previous reports as task text. Each role is asked to call the Zeron `submit_report` tool once with its exact step reference (`nonce`) and a short human-readable `report`, then respond naturally. A role with Pass and Fail outputs also supplies `result` as `pass` or `fail`; an Always role omits it. If the role cannot complete its work, its report starts with the exact line `Status: blocked`; a review finding that work needs another pass is instead `result: fail`. Reports must be nonempty and at most 8192 bytes. The tool is exposed to Pi as `zeron_orchestrator_builder__submit_report`; names in other harnesses may differ. The final chat reply is not used for routing.

The tool records the report in SQLite before acknowledging it. A report received before a dispatch receipt remains pending under its caller's actual chat ID and is used only if that ID matches the receipt and its step nonce. The journal snapshots role chats, visits, dispatches and receipts, including message IDs and delivery when provided. Events arriving during dispatch are buffered until the receipt is saved. The runner advances only after its own turn starts and finishes successfully and the matching report and receipt are saved. Identical repeated submissions are accepted; conflicting submissions block. A completed turn without a matching report blocks rather than guessing or resending. Only the parent team’s Finish ends a composed run. Open chat opens the latest available run chat; it may belong to an earlier block, not the displayed route. The runner does not link the existing active chat or inherit its model.

Before reuse, the runner checks that the chat still exists on the selected device and project and its reported status is idle, absent or done. Working, waiting, input, failed and unknown statuses block. This check is advisory: status can lag and another person can start a turn between the check and delivery. Do not use or move run chats while the run is active. A turn's initial start may lack attribution in Zeron 0.3.7; its terminal event must still be attributed. Missing or foreign attribution and unexpected turn events block. The runner sends repeat visits with queue mode; if Zeron reports a queued delivery, the runner records the chat and message ID and blocks because it may still execute. Never blindly resend or create a replacement chat.

Use one Always output, or a Pass and a Fail output for a role. A Fail connection returning to a preceding block needs a retry limit of 1–10. A parent connection’s limit applies across the run; a connection inside a saved team has a fresh limit each time that team block starts. Exhausting it blocks the run. Every cycle must be bounded by such a return. These limits do not guarantee a successful result.

Stop prevents further dispatch but cannot cancel an in-flight turn or queued message. A stop, agent error or request for input, missing or invalid report, exhausted retry, ambiguous delivery, timeout, journal error or unexpected terminal event can block the run. A turn may still be running when the outcome is unknown. Some journal operations and listener registration have a 10-minute deadline; active agent turns do not. The runner does not resume automatically after interruption.

For a blocked or interrupted run, use Open chat when available to inspect the latest known chat, then Review / abandon. The chat can belong to an earlier block or be unavailable. Abandoning does not cancel in-flight or queued messages: inspect the chats and ensure any in-flight agent and queued messages are stopped or otherwise resolved before confirming. Confirmation requests an asynchronous journal update; watch the status and reason for the result. It does not retry or restart the run. Abandonment is refused while a journal claim, chat dispatch, receipt or report journal update is pending, and may be unavailable or fail if journal ownership is uncertain. In those cases the journal may remain locked and need manual review. An unknown delivery can remain unknown even after pending operations settle; check the chats before deciding whether to abandon.

## Development

Create a development plugin folder with `zeron plugin new`, copy the source files into it, and sign with `zeron plugin sign orchestrator-builder`. Zeron must be running. In addition to running chats, Builder asks for access to session paths and device identity, Git History menus, the named `git` command, read-only GitHub data, and unsent composer drafts. It does not request GitHub write access.

## Limitations

The canvas describes the current editable team, not live block status or evidence that a workflow has run. Agent questions, automatic recovery and Chief inheritance are not implemented. Review roles run as agents; human review is for blocked, interrupted or unknown runs, not normal review steps. Manual abandonment does not stop agents, cancel queued messages or resolve unknown delivery. Prior reports are passed as untrusted context.

Zeron 0.3.7 may omit Pi's terminal reply; this handoff does not depend on it and requires no host patch, shell or native helper. The plugin remains subject to Zeron's loop guard. Keep Zeron open and the plugin running on this device for the entire run: without a service, tool calls and turn events are handled by the window. Closing or restarting it interrupts the run; it is not resumed or resent automatically. Remote runs are unsupported. Agent tool availability and behavior depend on the selected harness and model.

## Design and source

The experimental `orchestrator-wallpaper` Zeron v3 template in `host/zeron-template` is intended to show Zeron's own new-chat wallpaper behind the builder using the same image or wallpaper plugin and effect settings. Its wallpaper rendering has not been verified. Without that template the builder uses the normal page background. The plugin cannot detect a wallpaper, so turn the grid off manually if desired. Cards use Zeron's frosted material and its transparency preference.

The starting team uses a simple plan, work and review sequence informed by [Anthropic's workflow guidance](https://www.anthropic.com/research/building-effective-agents) and [OpenAI's orchestration guidance](https://developers.openai.com/api/docs/guides/agents/orchestration). It is a starting diagram, not a guarantee of quality.

The plugin uses Zeron theme tokens and `@ds` components. Visual guidance comes from [unslop](https://github.com/heydamir/unslop) by Damir Sokolovsky, licensed CC BY 4.0. `zeron.luau` is the Zeron plugin SDK from [zeronsh/zeron](https://github.com/zeronsh/zeron), licensed under MIT; see `ZERON-LICENSE`.

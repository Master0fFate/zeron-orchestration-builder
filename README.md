# Orchestrator Builder

A visual node editor for building and running agent teams in Zeron v3.

Builder is a separately installed plugin for wiring and running a workflow. Run details reads its local journal; interrupted runs are not resumed automatically.

![Orchestrator Builder running in Zeron](docs/screenshot.png)

## Install

1. Download the `.zeron-plugin` package from the [latest release](https://github.com/Master0fFate/zeron-orchestration-builder/releases/latest).
2. In Zeron, open Settings → Plugins → Install and select the file.
3. Review and approve the requested permissions, then open Orchestrator Builder from the sidebar.

The plugin requires Zeron v3 and a configured agent. To use Run team from the composer, allow draft access. Builder observes the active draft and copies its text into a separate run form when you click Run team.

### Permissions and data

- `pages.add`, `ui.add`, and `navigate` add the Builder page, composer button, and Git History action, and let you open role chats. `models.read` lists available models. `files` enables file dialogs for team JSON and SVG icons.
- `sessions.read`, `files.read`, and `devices` expose session status, checkout paths, and device information so Builder can select and check local destinations. `messages.send` starts role chats and sends follow-up prompts; `tools` exposes `submit_report`. The manifest also requests `messages.read`, which allows chat text to be read; the runner uses submitted reports rather than reading final chat replies for routing.
- `draft` can read unsent composer text. `compose` can append review text and inline comments to an unsent draft on request. `github` reads PR data through Zeron and does not grant GitHub write access. `commands` is limited to `git`, which Builder uses to check local destinations and read selected changes.

Builder stores saved teams locally and keeps run snapshots in local SQLite, including tasks, workflow instructions, destination paths, submitted reports, and Ask decisions. There is no automatic pruning or per-run delete, and abandoning a run keeps its data. Uninstalling Builder removes its local storage, not role chats or exported files. Tasks, role instructions, and relevant context are sent to the configured role agents, which may use an external model provider. Avoid putting secrets in tasks or reports. Ask gates the workflow route, not what an agent can do with its harness permissions.

## Use

- The first install opens a starter team. Choose **New team** to preview and create a workflow preset or start with **Blank**. Add or edit blocks from the toolbar. Creating a team does not change existing teams or start a run.
- Drag a block to move it. Drag an output dot to another block's input dot to connect them. Select a line to edit its condition or remove it. Conditions are Always, Pass and Fail; a Fail return needs a retry limit from 1 to 10. The limit counts failure returns across the entire run. Save connection applies settings; Remove connection deletes it. Incomplete drafts can be saved and checked later.
- Drag empty canvas space to pan, scroll to zoom at the pointer, and use Fit to frame the graph. The grid can be turned on or off from the toolbar.
- Select a block's settings icon to edit its name, icon, runtime, provider, model and role instructions. Choose Other agent to enter a custom runtime ID. Save the block to apply the edits.
- Custom icons are self-contained SVG files up to 16 KB. Zeron stores their contents with the team in the plugin's own storage; they are not separate files in the signed plugin folder.
- The team name is shown in the header and can be changed through its edit control. Open Team to create a new team or switch between saved teams. Names, positions, settings and connections are saved locally.
- In Team, export the current team to a JSON file or import a team JSON file as a separate saved team. Plain teams use version 2, saved-team compositions use version 3, and workflows with the change-review blocks use version 4. Version 5 is reserved for teams with an Ask block. Older plugin versions that only support versions 2–4 cannot import version 5 files. Custom SVG icons and embedded team snapshots are included.
- Open Team for the name and checks. Checks flag missing inputs and outputs, invalid routes, unreachable blocks, missing role instructions, incomplete model choices, missing Finish blocks and unbounded cycles. A manually entered model ID is not checked against the catalog.

Use Builder in one Zeron window at a time, and keep that window open for the entire run. Team-edit conflict checks are best-effort: Builder can refuse a write when it sees a newer library, but stale copies in separate windows can still overwrite each other. If a team edit is refused, **Team → Export draft JSON** exports the first conflicted draft. It stays in that window when you navigate away from Builder; later failed edits do not replace it. Export before closing or restarting the window or plugin. Reopen Builder and reapply the edits to the current team rather than overwriting newer work.

New role blocks start with editable default instructions. Custom instructions replace the default; Restore default puts it back. They are task text, not a system prompt. Chief is an entry point, not an agent turn: its settings are not used for runs, and it is not linked to the active chat. The plugin does not intercept the main chat's messages.

## Workflow presets

| Preset | Use it to |
| --- | --- |
| Plan, build, review | Turn a brief into a plan, implement it, and get a separate review. |
| Plan only | Get ordered steps and acceptance criteria without changing anything. |
| Research & compare | Gather evidence, compare options, and make a recommendation. |
| Research & approve | Review a local change proposal and choose whether to start implementation, then get a separate review. |
| Review & revise | Draft, review, and send concrete issues back to the writer for up to two revisions. |
| Review a change | Review a Git change by folder and prepare an unsent draft. Requires a change source and a checkout that can read its diff. |
| Blank | Start with Chief and wire your own workflow. |

Each preset is an editable copy with no model pinned. Pick a destination with a configured default agent or choose a runtime and model for each role. Only Review a change needs a Git change source.

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

Select Start, enter a task, select an existing session on this device under Destination and confirm. Each time you open Start from the toolbar, choose the destination again. A commit staged from Git History can supply the destination instead. The session supplies its device, project and working folder when available; check the destination before starting. Remote destinations are unsupported: they may start a chat but cannot be relied on to deliver the tool call or terminal events to this runner. Local Git and composer actions require a destination on this device. The selected session is not sent messages. If no valid local session is available, create one on this device first. The runner validates the destination and team before claiming the journal, and snapshots both for the run; later edits, team switches or session changes do not change it. The destination is stored in the run journal, including for interrupted runs. Acceptance starts asynchronous journal setup, not a guarantee that a chat was sent. The status and reason show progress or failure. Run details shows the saved route from the run snapshot, not the team currently displayed.

To launch from a composer, type a task in **New chat** or an existing chat on this device and click **Run team** beside the microphone. If Zeron shows **Add a project** instead of a composer, use its command palette: **New chat in… → No project**. No project or chat needs to be created first. Drafts with attachment chips (including files, images, chat references and review comments) are rejected. Only draft text is copied; quotes, other composer context and chat history are not forwarded. Builder neither sends nor clears the original draft.

In **Start run**, select a **Saved team** and review or edit the copied task. Builder snapshots the saved graph when you select it; later saves and unsaved Builder edits are not included. Select **Start** from the originating composer to launch without opening Builder.

- From **New chat**, pick a **Local destination** in Builder. A local project uses its displayed folder, which Builder verifies at Start using Git (the folder need not be a Git repository). **No project (local)** uses Zeron’s scratch folder for each role chat separately, not a shared project checkout. Builder does not inherit the New chat composer’s project, device, branch, worktree, agent, or model settings. Roles use Zeron’s defaults unless the team pins a runtime or model. Teams with **Changes**, **Check**, **Draft**, or **For each** fed by changed files need an existing chat. A **For each** with manual items can run from New chat.
- From an existing chat, the dialog shows that chat’s destination and rechecks it at Start. Provide a change source if the team needs one. If the location changed, choose **Discard copy** and use **Run team** again from the intended chat.

**Review copy** from another composer lets you review or discard the copy, but not start it. Your graph, regular Start form and original draft remain unchanged.

The copy and your edits stay in window memory, not durable storage. Don’t rely on them surviving a window or plugin restart. Closing the dialog keeps the copy; **Discard copy** clears it. After Start is accepted, the copy stays available for review even if journal setup fails. You cannot start that copy again. Check **Run details** before trying another run, especially if delivery is unknown. Staging does not start a run or schedule any sends or retries. Open Builder to track progress or answer an Ask block.

The runner follows Chief's output and starts one chat per role block per run on the selected device and project, using that block's runtime and model when set. It passes the captured working folder to Zeron, including a session’s worktree. A known worktree without a visible path is unavailable rather than falling back to the project root. Zeron still applies its normal scratch-folder rules for projectless chats. The first prompt starts with the block and team names to distinguish chat titles. Repeat visits reuse that block's chat and its context, including retries; separate blocks and separate runs have separate chats. It sends the task, role instructions and previous reports as task text. Each role is asked to call the Zeron `submit_report` tool once with its exact step reference (`nonce`) and a short human-readable `report`, then respond naturally. A role with Pass and Fail outputs also supplies `result` as `pass` or `fail`; an Always role omits it. If the role cannot complete its work, its report starts with the exact line `Status: blocked`; a review finding that work needs another pass is instead `result: fail`. Reports must be nonempty and at most 8192 bytes. The tool is exposed to Pi as `zeron_orchestrator_builder__submit_report`; names in other harnesses may differ. The final chat reply is not used for routing.

The tool records the report in SQLite before acknowledging it. A report received before a dispatch receipt remains pending under its caller's actual chat ID and is used only if that ID matches the receipt and its step nonce. The journal snapshots role chats, visits, dispatches and receipts, including message IDs and delivery when provided. Events arriving during dispatch are buffered until the receipt is saved. The runner advances only after its own turn starts and finishes successfully and the matching report and receipt are saved. Identical repeated submissions are accepted; conflicting submissions block. A completed turn without a matching report blocks rather than guessing or resending. Only the parent team’s Finish ends a composed run. Open chat opens the latest available run chat; it may belong to an earlier block, not the displayed route. The runner does not link the existing active chat or inherit its model.

Before reuse, the runner checks that the chat still exists on the selected device and project and its reported status is idle, absent or done. Working, waiting, input, failed and unknown statuses block. This check is advisory: status can lag and another person can start a turn between the check and delivery. Do not use or move run chats while the run is active. A turn's initial start may lack attribution in Zeron 0.3.7; its terminal event must still be attributed. Missing or foreign attribution and unexpected turn events block. The runner sends repeat visits with queue mode; if Zeron reports a queued delivery, the runner records the chat and message ID and blocks because it may still execute. Never blindly resend or create a replacement chat.

Use one Always output, or a Pass and a Fail output for a role. A Fail connection returning to a preceding block needs a retry limit of 1–10. A parent connection’s limit applies across the run; a connection inside a saved team has a fresh limit each time that team block starts. Exhausting it blocks the run. Every cycle must be bounded by such a return. These limits do not guarantee a successful result.

Stop prevents further dispatch but cannot cancel an in-flight turn or queued message. A stop, agent error or request for input, missing or invalid report, exhausted retry, ambiguous delivery, timeout, journal error or unexpected terminal event can block the run. A turn may still be running when the outcome is unknown. Some journal operations and listener registration have a 10-minute deadline; active agent turns do not. The runner does not resume automatically after interruption.

## Ask for a decision

**Ask** is optional. Teams without an Ask block run without a human decision gate. To add one, place **Ask** in the root team, enter a fixed question in its settings, and connect one **Always** output. Ask does not start or message a chat. The runner displays the question from the run snapshot, even if the canvas has changed.

To try it, choose **New team → Research & approve**. Read the Researcher's proposal before choosing **Continue** to start the Worker or **Stop** to end the run without starting it. If the proposal needs changes, stop and start a new run with a revised task. Ask gates the route, not agent permissions: the Researcher is asked to work read-only and avoid external services, but it runs before Ask and can still take actions its harness permits.

In any team, choose **Continue** to take the output or **Stop** to end the run without taking it. The decision must be saved to the journal before the runner proceeds or releases the lock. Neither action is available while the Ask checkpoint or decision is saving. If a save times out, the run blocks; the timeout does not cancel the write. Check **Run details** before taking further action. Chat replies and agent reports cannot answer Ask. If the window restarts, inspect the saved question and decision in **Run details**; the interrupted run cannot be resumed.

## Run details

Open **Run details** from the run controls or **Review run**. **Current run** reads the last saved checkpoint for the run known to this window and labels the window’s runner status separately. If there is no current run to show, **Saved checkpoint** prefers the locked journal entry, otherwise the newest entry by creation order. Use **Refresh** to reread the selected view. This is read-only inspection of Builder’s local runs, not a live trace or an engine crew board.

**Run history** lists saved runs newest first, six per page, with the saved team name, status and whether the run was locked when read. Use **Older**, **Newer** or **Newest** to browse, and **View run** to open a saved checkpoint. Selecting a historical run does not change which run Builder can abandon.

The checkpoint shows the saved team name, run ID, journal status, lock, phase, reason, route and destination when recorded. **Ask decisions** shows saved questions and their decisions when present; it does not answer them.

Use **Run frame** to switch between the root team and saved child frames from saved-team blocks or **For each**. For more than six frames, use **Previous frames** and **Next frames**. A newly opened run starts on its saved checkpoint frame when identified, otherwise the root frame. The selected frame shows its saved block and, for child frames, the parent block, phase and item when recorded and recognized. Switching frames changes the role chats and visits shown, not the saved route.

**Role chats** lists only the selected frame’s recorded role-to-chat links, in saved team order. Use **Previous chats** and **Next chats** when there are more than six. **Open chat** is available when Zeron still lists that session. The status beside each chat comes from Zeron’s session list and may be unknown or unavailable. It is advisory: it does not prove run progress, message delivery or that work has stopped.

**Role visits** shows saved visits newest first within the selected frame, with receipts (including delivery and message ID when present), report previews, saved Pass/Fail decisions and chat links. The view flags invalid saved evidence where detected. A saved submission is not necessarily an accepted report. Reports are agent claims, not independent verification. A queued message may still execute; do not resend it based on the checkpoint.

## Review a blocked run

Inspect **Run details** and the run chats before choosing **Abandon run** in **Review run**. The main **Open chat** control may point to an earlier block or be unavailable. If another Zeron window still owns the run, stop the runner there first. Stop or resolve any in-flight turns and queued messages before confirming. Builder cannot verify that work has stopped.

Builder validates the active checkpoint on recovery and rereads it before abandoning. It checks that the saved phase, role visits, chats, receipts and reports agree where required. It refuses abandonment while a dispatch or journal write is pending, when the write or dispatch outcome is unknown, or when it cannot validate the active entry. It only marks the run abandoned if the validated checkpoint still matches at the time of the update. Watch the status and reason for the result: successful abandonment releases the journal lock but does not cancel work, resend messages or restart the run.

If dispatch remains unresolved after pending operations settle, inspect the destination’s session list and the journal manually. Do not resend. Builder will not abandon that run through the UI: its active slot stays locked, blocking new runs.

## Development

Use a dedicated development plugin folder. Keep `zeron-plugin.json` unsigned in the source checkout: this repository distributes signed release packages, not raw Git installs. Zeron signs the staged manifest and file bytes. For an unsigned development plugin, use **Sign as mine** in Settings → Plugins. Then export the reviewed plugin with `zeron plugin export <id>`. Export re-signs your own plugin and packages its installed folder, so review that folder before exporting and do not edit the package afterward.

## Limitations

The canvas describes the current editable team, not live block status or evidence that a workflow has run. Questions from agents, automatic recovery and Chief inheritance are not implemented. Review roles run as agents; use Ask where the workflow needs an explicit human decision. Manual abandonment does not stop agents, cancel queued messages or resolve unknown delivery. Prior reports are passed as untrusted context.

The handoff does not depend on final chat reply text. The plugin remains subject to Zeron's loop guard. Keep Zeron open and the plugin running on this device for the entire run: tool calls and turn events are handled by the window, not a background service. Closing or restarting it interrupts the run; it is not resumed or resent automatically. Remote runs are unsupported. Agent tool availability and behavior depend on the selected harness and model.

## Design and source

Builder uses Zeron’s page background and frosted material. It cannot detect wallpaper; turn off the grid if it makes your background harder to read.

The starting team uses a simple plan, work and review sequence informed by [Anthropic's workflow guidance](https://www.anthropic.com/research/building-effective-agents) and [OpenAI's orchestration guidance](https://developers.openai.com/api/docs/guides/agents/orchestration). It is a starting diagram, not a guarantee of quality.

The plugin uses Zeron theme tokens and `@ds` components. Visual guidance comes from [unslop](https://github.com/heydamir/unslop) by Damir Sokolovsky, licensed CC BY 4.0. `zeron.luau` is the Zeron plugin SDK from [zeronsh/zeron](https://github.com/zeronsh/zeron), licensed under MIT; see `ZERON-LICENSE`.

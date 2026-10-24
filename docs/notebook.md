# Notes and memory

Open **Notes** in Whisp. Choose **Record idea**, speak, and choose **Stop recording**.
Whisp saves the recording and original transcript in a dated page, then uses your
configured OpenAI writing model to organize it. The recording never pastes into
another app. Fn still works as normal dictation. Recordings stop after 15 minutes;
Whisp currently records its microphone, not system or meeting audio.

Choose **New note** to write a page. Titles and Markdown text save after a short
pause. **Read** displays formatted text, **Transcript** keeps the original words,
and **Play recording** plays the saved audio. Search matches title, body, and
transcript. The export button saves a Markdown file. Dates use US Eastern.

Your original note saves before AI organization starts. If AI is unavailable,
the original transcript and audio stay available. If recognition fails, Whisp
keeps an audio-only note. There is no automatic external action or publication.

## Memory

**Memory → About me & projects** holds your saved writing profile. Use **Save profile**
after changes; earlier profile versions are kept in the local backups folder.

With **Remember preferences and work context from voice notes** enabled, Whisp
extracts up to five explicitly stated facts from each organized note. Each fact
must cite an exact quote in the note. Open its **Source note** to inspect that
quote. Click a fact to correct it, uncheck it to stop using it, or use the trash
button to forget it. Deleting a note also removes memories learned from it.
Memory extraction uses AI and may need correction. A forgotten fact is not automatically extracted again when its source is reorganized. Ordinary dictation is not learned automatically.

Work-in-progress facts use the Activity type and stop entering AI prompts after
14 days. Other enabled facts stay until you change or forget them. The most recent
32 relevant facts are included with the saved profile, up to 5,000 characters.
Preferences and current context guide writing; they do not authorize actions.
Whisp does not continuously listen or watch other apps.

## Local storage

Everything lives in the selected profile, normally `~/.whisp/`:

- `notebook.sqlite3`: SQLite database for pages, memories, provenance, and settings.
- `notebook.sqlite3-wal` and `-shm`: SQLite concurrency files while it is open.
- `note-audio/<note-id>.wav`: original voice recordings.
- `context.md`: the writing profile.
- `backups/`: earlier profile copies.

The database uses SQLite WAL and a five-second busy timeout. The app and connector
can use it together. Back up the profile with Whisp and connected assistants closed,
or use SQLite's backup API for a live database. Do not copy only the database file
while its WAL is active. The database and recordings are local plaintext files with
owner-only permissions; they are not cloud-synced or encrypted by Whisp.

OpenAI streaming sends microphone audio and vocabulary to OpenAI. Note organization
sends the transcript and saved context to OpenAI, not the retained audio file.
Writing requests set `store: false`. Local recognition without an AI key can still
save recordings and transcripts. There is no local AI memory extraction fallback.

## Connect assistants

Whisp includes a Python 3 standard-library MCP server. It uses stdio, starts when
an assistant connects, and exits when that connection closes. It opens no TCP port,
requires no API token, and accesses only the selected Whisp profile.

From a source checkout:

```bash
python3 /absolute/path/to/whisp/scripts/notebook_mcp.py --profile ~/.whisp
```

The MCP configuration is:

```json
{
  "mcpServers": {
    "whisp-notebook": {
      "command": "/usr/bin/python3",
      "args": ["/absolute/path/to/whisp/scripts/notebook_mcp.py", "--profile", "/absolute/path/to/.whisp"]
    }
  }
}
```

The tools are `search_notebook`, `get_note`, `save_note`, `update_note`,
`list_memories`, `remember`, `update_memory`, `forget_memory`, `get_profile`,
and `update_profile`. Updates require the previous record timestamp or exact
profile text to avoid overwriting concurrent edits. Source-linked facts need an
exact supporting quote. Clients must obtain user authorization before mutations.

For a local assistant without MCP, use a one-shot call:

```bash
python3 scripts/notebook_mcp.py --call search_notebook --arguments '{"query":"ideas"}'
```

A locally running MCP client such as Claude Code or Codex can launch this process.
A cloud-only ChatGPT conversation cannot directly launch a process on your Mac;
it needs a supported local connector or executor. No public tunnel is provided.
After adding a client configuration, reconnect or start a new client session.
The Whisp app checks for external changes every three seconds.

Protocol references: [stdio transport](https://modelcontextprotocol.io/specification/2025-06-18/basic/transports)
and [connection lifecycle](https://modelcontextprotocol.io/specification/2025-06-18/basic/lifecycle).

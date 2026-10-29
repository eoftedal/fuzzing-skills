# Fuzzing skills for native Node and Ruby dependencies

Agent skills for Claude Code, Codex and OpenCode that find memory-safety bugs in the native code
behind Node.js and Ruby packages with AFL++. The skills stop at a classified, minimized
reproducer you can send to the maintainer. They do not develop exploits.

The repo is a Claude Code plugin marketplace with two plugins:

| plugin | fuzzes |
|---|---|
| `fuzzing-native-node-dependencies` | the native libraries behind NAN / node-addon-api / N-API addons (node-gyp builds, prebuilt `.node` files) |
| `fuzzing-native-ruby-dependencies` | the C code behind Ruby gems' C extensions (mkmf / `extconf.rb`, including vendored libraries) |

Each plugin has four skills, used in this order:

1. **build a harness** (`build-a-nan-napi-fuzzing-harness` or `build-a-ruby-c-extension-fuzzing-harness`):
   a direct AFL++ harness for the native library, proven against the real package with a
   fidelity gate, a fault-injection self-test and a smoke run.
2. **`derive-a-fuzzing-corpus-from-source`**: a seed corpus written from the parser source.
3. **`run-a-fuzzing-campaign`**: the AFL++ campaigns, with a manifest of how each ran.
4. **`triage-fuzzing-findings`**: screen, bucket, minimize and confirm crashes and hangs
   against the package installed fresh from npm or RubyGems.

See each plugin's `skills/README.md` for the files the skills hand each other.

## Requirements

The skills drive the tools; they do not install them. Run them on Linux with:

- AFL++ (developed against 4.33c) and clang, with ASan
- Node.js and npm with node-gyp's build toolchain, for the Node plugin
- Ruby with its development headers, for the Ruby plugin
- `python3`, `bash` and the usual build tools

A Docker container with these installed is the easiest setup; fuzzing on macOS is not supported.

## Install in Claude Code as a marketplace

In Claude Code, add the marketplace and install the plugin(s) you need:

```
/plugin marketplace add eoftedal/fuzzing-skills
/plugin install fuzzing-native-node-dependencies@node-security-skills
/plugin install fuzzing-native-ruby-dependencies@node-security-skills
```

From a local clone, point the marketplace at the directory instead:

```
/plugin marketplace add /path/to/fuzzing-skills
```

Installing both plugins is fine: plugin skills are namespaced by plugin, so the two
same-named corpus, campaign and triage skills do not clash. Update later with
`/plugin marketplace update node-security-skills`.

## Install by copying into a skills folder

This works for Claude Code, Codex and OpenCode. Each skill is a directory with a `SKILL.md`, so
installing one means copying the directory into a folder the agent scans:

| agent | all projects | one project (in the repo) |
|---|---|---|
| Claude Code | `~/.claude/skills/` | `.claude/skills/` |
| Codex | `~/.agents/skills/` | `.agents/skills/` |
| OpenCode | `~/.config/opencode/skills/` | `.opencode/skills/` |

OpenCode also reads the Claude Code and Codex folders (`~/.claude/skills/`, `~/.agents/skills/`
and their project versions), so a copy made for either of those also works in OpenCode.

Clone the repo and copy one plugin's four skill directories into the folder, here the Node
plugin into Codex's user folder:

```sh
git clone https://github.com/eoftedal/fuzzing-skills.git
DEST=~/.agents/skills        # or ~/.claude/skills, ~/.config/opencode/skills, ...
mkdir -p "$DEST"
for d in fuzzing-skills/plugins/fuzzing-native-node-dependencies/skills/*/; do
  cp -R "${d%/}" "$DEST/"
done
```

For Ruby, copy from `plugins/fuzzing-native-ruby-dependencies/skills/` instead. Start a new
session afterwards so the agent picks up the skills.

Two things to keep in mind:

- **Copy all four skills of a plugin into the same folder.** The scripts find each other through
  the sibling skill directories (the harness skill's `init_workspace.sh` writes their paths to
  the workspace's `fuzz.env`), so the four must stay side by side.
- **Install only one of the two plugins by copying.** The corpus, campaign and triage skills
  have the same names in both plugins. In one folder, the second copy overwrites the first.
  OpenCode requires skill names to be unique across all the folders it reads, and Codex lists
  same-named skills from different folders side by side without telling them apart. To use
  both plugins, install them as Claude Code plugins, which namespaces the skills.

## Usage

Ask the agent to fuzz a package, for example "fuzz the native addon of the npm package `<name>`"
or "fuzz the C extension of the gem `<name>`". The harness skill triggers first, creates the fuzz
workspace and its `fuzz.env`, and each skill names the next one when it is done.

## Repository layout

```
.claude-plugin/marketplace.json     the marketplace
plugins/<plugin>/.claude-plugin/    the plugin manifest
plugins/<plugin>/skills/<skill>/
  SKILL.md                          the instructions Claude loads
  EVIDENCE.md                       the measurements behind each rule (not loaded)
  references/                       longer explanations, loaded on demand
  resources/                        scripts and templates run from the fuzz workspace
scripts/check_shared.sh             checks the scripts both plugins carry a copy of stay in sync
```

See [CLAUDE.md](CLAUDE.md) for contributor notes.

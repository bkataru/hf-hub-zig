# CLI Reference

Complete command-line interface reference for `hf-hub`.

## Global Options

These options are available for all commands:

| Option | Description |
|--------|-------------|
| `--token <TOKEN>` | HuggingFace API token (overrides `HF_TOKEN` env) |
| `--endpoint <URL>` | API endpoint URL (default: `https://huggingface.co`) |
| `--cache-dir <PATH>` | Cache directory (overrides `HF_HOME` env) |
| `--timeout <MS>` | Request timeout in milliseconds (default: 30000) |
| `--no-progress` | Disable progress bars |
| `--no-color` | Disable colored output |
| `--json` | Output in JSON format |
| `-h, --help` | Show help message |
| `-V, --version` | Show version information |

## Commands

### search

Search for models on HuggingFace Hub.

```bash
hf-hub search [OPTIONS] <QUERY>
```

**Arguments:**
- `<QUERY>` - Search query string

**Options:**

| Option | Description |
|--------|-------------|
| `--limit <N>` | Maximum results to return (default: 20) |
| `--offset <N>` | Pagination offset (default: 0) |
| `--sort <FIELD>` | Sort by: `downloads`, `likes`, `trending`, `created`, `modified` |
| `--direction <DIR>` | Sort direction: `asc` or `desc` (default: `desc`) |
| `--author <ORG>` | Filter by organization/author |
| `--filter <TAG>` | Filter by tag (e.g., `gguf`, `text-generation`) |
| `--gguf-only` | Only show models with GGUF files |
| `--full` | Include full model details |

**Examples:**

```bash
# Basic search
hf-hub search "llama 7b"

# Search for GGUF models, sorted by downloads
hf-hub search "mistral" --gguf-only --sort downloads

# Search with pagination
hf-hub search "qwen" --limit 10 --offset 20

# Filter by author
hf-hub search "gguf" --author TheBloke --limit 50

# JSON output for scripting
hf-hub search "phi" --json | jq '.models[].id'
```

**Output Format:**

Normal output shows a table:
```
  Model                                  Downloads    Likes   Modified
  ─────────────────────────────────────────────────────────────────────
  TheBloke/Llama-2-7B-GGUF               1,234,567    2,345   2024-01-15
  TheBloke/Mistral-7B-Instruct-v0.2      987,654      1,234   2024-01-10
```

JSON output:
```json
{
  "models": [
    {
      "id": "TheBloke/Llama-2-7B-GGUF",
      "downloads": 1234567,
      "likes": 2345,
      "last_modified": "2024-01-15T10:30:00Z"
    }
  ],
  "total": 100,
  "limit": 20,
  "offset": 0
}
```

---

### download

Download files from a model repository.

```bash
hf-hub download [OPTIONS] <MODEL_ID> [FILE]
```

**Arguments:**
- `<MODEL_ID>` - HuggingFace model ID (e.g., `TheBloke/Llama-2-7B-GGUF`)
- `[FILE]` - Specific file to download (optional; if omitted, downloads all files)

**Options:**

| Option | Description |
|--------|-------------|
| `-o, --output <DIR>` | Output directory (default: current directory) |
| `--revision <REV>` | Git revision/branch (default: `main`) |
| `--use-cache` | Check cache first before downloading (default: true) |
| `--no-cache` | Bypass cache, always download |
| `--no-resume` | Don't resume partial downloads |
| `--parallel <N>` | Number of parallel downloads (default: 1) |
| `--filter <PATTERN>` | Download files matching pattern |
| `--gguf-only` | Only download .gguf files |
| `--dry-run` | Show what would be downloaded without downloading |

**Examples:**

```bash
# Download a specific file
hf-hub download TheBloke/Llama-2-7B-GGUF llama-2-7b.Q4_K_M.gguf

# Download to specific directory
hf-hub download TheBloke/Llama-2-7B-GGUF -o ~/models/

# Download all GGUF files with 4 parallel connections
hf-hub download TheBloke/Llama-2-7B-GGUF --gguf-only --parallel 4

# Download with pattern matching
hf-hub download TheBloke/Llama-2-7B-GGUF --filter "Q4_K*"

# Check what would be downloaded
hf-hub download TheBloke/Llama-2-7B-GGUF --gguf-only --dry-run

# Download from specific revision
hf-hub download meta-llama/Llama-2-7b-hf --revision v1.0
```

**Progress Display:**

```
⏳ llama-2-7b.Q4_K_M.gguf
   [████████████░░░░░░░░░░░░]  48%  12.3 MB/s  ETA 2m 30s
```

---

### list

List files in a model repository.

```bash
hf-hub list [OPTIONS] <MODEL_ID>
```

**Arguments:**
- `<MODEL_ID>` - HuggingFace model ID

**Options:**

| Option | Description |
|--------|-------------|
| `--revision <REV>` | Git revision/branch (default: `main`) |
| `--gguf-only` | Only show GGUF files |
| `--size-format <FMT>` | Size format: `human` (default), `bytes`, `kb`, `mb`, `gb` |

**Examples:**

```bash
# List all files
hf-hub list TheBloke/Llama-2-7B-GGUF

# List only GGUF files
hf-hub list TheBloke/Llama-2-7B-GGUF --gguf-only

# JSON output
hf-hub list meta-llama/Llama-2-7b-hf --json

# Show sizes in bytes
hf-hub list TheBloke/Llama-2-7B-GGUF --size-format bytes
```

**Output Format:**

```
Files in TheBloke/Llama-2-7B-GGUF:

  Filename                           Size       Type
  ───────────────────────────────────────────────────
  llama-2-7b.Q2_K.gguf               2.83 GB    GGUF
  llama-2-7b.Q4_K_M.gguf             3.80 GB    GGUF
  llama-2-7b.Q5_K_M.gguf             4.45 GB    GGUF
  config.json                        564 B      
  README.md                          12.3 KB    

Total: 5 files, 11.08 GB
```

---

### info

Get detailed information about a model.

```bash
hf-hub info [OPTIONS] <MODEL_ID>
```

**Arguments:**
- `<MODEL_ID>` - HuggingFace model ID

**Options:**

| Option | Description |
|--------|-------------|
| `--revision <REV>` | Git revision/branch (default: `main`) |

**Examples:**

```bash
# Get model info
hf-hub info TheBloke/Llama-2-7B-GGUF

# JSON output
hf-hub info meta-llama/Llama-2-7b-hf --json
```

**Output Format:**

```
Model: TheBloke/Llama-2-7B-GGUF

  Author          TheBloke
  Downloads       1,234,567
  Likes           2,345
  Last Modified   2024-01-15T10:30:00Z
  Pipeline        text-generation
  Library         transformers
  Private         No
  Gated           No

Tags:
  gguf, llama, llama-2, text-generation, 7b

Files: 15 (12.5 GB total, 10 GGUF files)
```

---

### cache

Manage the local cache.

```bash
hf-hub cache <SUBCOMMAND> [OPTIONS]
```

**Subcommands:**

#### cache info

Show cache statistics.

```bash
hf-hub cache info
```

**Output:**
```
Cache Statistics

  Cache directory    ~/.cache/huggingface/hub
  Repositories       5
  Total files        42
  Total size         28.5 GB
  GGUF files         15
  GGUF size          24.2 GB
```

#### cache clear

Clear the cache.

```bash
hf-hub cache clear [OPTIONS]
```

**Options:**

| Option | Description |
|--------|-------------|
| `-f, --force` | Skip confirmation prompt |
| `-p, --pattern <PAT>` | Only clear repos/files matching pattern |

**Examples:**

```bash
# Clear entire cache (prompts for confirmation)
hf-hub cache clear

# Force clear without confirmation
hf-hub cache clear --force

# Clear specific repository pattern
hf-hub cache clear --pattern "TheBloke/*" --force

# Clear all GGUF-related caches
hf-hub cache clear --pattern "*GGUF*" --force
```

#### cache clean

Remove partial/corrupted downloads (`.part` files).

```bash
hf-hub cache clean
```

#### cache dir

Print the cache directory path.

```bash
hf-hub cache dir
```

Output:
```
/home/user/.cache/huggingface/hub
```

---

### user

Show current authenticated user information.

```bash
hf-hub user [OPTIONS]
```

**Options:**

| Option | Description |
|--------|-------------|
| `--check` | Only check if authenticated (exit code 0 if yes, 1 if no) |

**Examples:**

```bash
# Show user info
hf-hub user

# Check authentication status
hf-hub user --check && echo "Authenticated" || echo "Not authenticated"
```

**Output:**
```
Authenticated User

  Username        johndoe
  Name            John Doe
  Email           john@example.com
  Account Type    user
  Pro             Yes
```

If not authenticated:
```
Not authenticated. Set HF_TOKEN environment variable or use --token.
```

---

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | General error |
| 2 | Invalid arguments |
| 3 | Network error |
| 4 | Authentication error |
| 5 | Not found |

## Environment Variables

| Variable | Description |
|----------|-------------|
| `HF_TOKEN` | HuggingFace API token for private model access |
| `HF_ENDPOINT` | Override API endpoint (default: `https://huggingface.co`) |
| `HF_HOME` | Override cache directory |
| `HF_TIMEOUT` | Request timeout in milliseconds |
| `NO_COLOR` | Disable colored output when set to any value |

## Shell Completion

Generate shell completion scripts:

```bash
# Bash
hf-hub --completions bash > ~/.local/share/bash-completion/completions/hf-hub

# Zsh
hf-hub --completions zsh > ~/.zfunc/_hf-hub

# Fish
hf-hub --completions fish > ~/.config/fish/completions/hf-hub.fish
```

## Examples

### Download the Best Quantization

```bash
# List available quantizations
hf-hub list TheBloke/Llama-2-7B-GGUF --gguf-only

# Download Q4_K_M (good balance of quality/size)
hf-hub download TheBloke/Llama-2-7B-GGUF llama-2-7b.Q4_K_M.gguf
```

### Search and Download Workflow

```bash
# Find models
hf-hub search "mistral 7b instruct" --gguf-only --sort downloads --limit 5

# Get info about top result
hf-hub info TheBloke/Mistral-7B-Instruct-v0.2-GGUF

# List files
hf-hub list TheBloke/Mistral-7B-Instruct-v0.2-GGUF --gguf-only

# Download
hf-hub download TheBloke/Mistral-7B-Instruct-v0.2-GGUF mistral-7b-instruct-v0.2.Q4_K_M.gguf
```

### Batch Download Script

```bash
#!/bin/bash
models=(
    "TheBloke/Llama-2-7B-GGUF:llama-2-7b.Q4_K_M.gguf"
    "TheBloke/Mistral-7B-v0.1-GGUF:mistral-7b-v0.1.Q4_K_M.gguf"
    "TheBloke/CodeLlama-7B-GGUF:codellama-7b.Q4_K_M.gguf"
)

for item in "${models[@]}"; do
    model="${item%%:*}"
    file="${item##*:}"
    echo "Downloading $model / $file"
    hf-hub download "$model" "$file" -o ~/models/
done
```

### JSON Processing with jq

```bash
# Get download counts for search results
hf-hub search "llama gguf" --json | jq '.models[] | {id, downloads}'

# List GGUF files with sizes
hf-hub list TheBloke/Llama-2-7B-GGUF --json | jq '.files[] | select(.is_gguf) | {filename, size}'

# Find largest GGUF file
hf-hub list TheBloke/Llama-2-7B-GGUF --json | jq '[.files[] | select(.is_gguf)] | max_by(.size)'
```

# Skills

# herdr-pair - starts side herdr pane and run parallel agent
[herdr-pair](herdr-pair/SKILL.md)

## 1. Install codex
```
npm i -g @openai/codex     # or: brew install codex
codex --version
```
replace default config.toml with the following:
```
model_provider = "fuelix"
model = "gpt-6.1-sol"

[model_providers.fuelix]
name = "fuelix"
base_url = "https://api.fuelix.ai/v1"
env_key = "FUELIX_API_KEY"
wire_api = "responses"
query_params = {}
```

## 2. Setup fuelix api key
Get the key if you not yet have one:
https://dev.fuelix.ai/en/apps/default

Export the key via env var FUELIX_API_KEY and add to .zshrc or .bashrc

## 3. Install herdr
```
curl -fsSL https://herdr.dev/install.sh | sh
# or
brew install herdr
herdr --version
```
Test launch from your project directory
```
herdr
```

## 4. Install the "herdr-pair" skill
```
cp -r herdr-pair ~/.claude/skills
```

## 5. Usage
investigate Jira ticket AVS5-12345 and propose a fix, then fire up /herdr-pair codex agent to review your plan, align on a solution.